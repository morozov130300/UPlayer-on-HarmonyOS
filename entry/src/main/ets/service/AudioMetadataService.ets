// 音频元数据提取服务，使用AVMetadataExtractor读取歌曲标题、歌手、专辑封面等
import { fileIo as fs } from '@kit.CoreFileKit'
import { image } from '@kit.ImageKit'
import { common } from '@kit.AbilityKit'
import { SuppressWarnings, SuppressWarningsType } from '@kit.BasicServicesKit'
import { SongInfo } from '../model/SongInfo'
import Logger from '../common/utils/Logger'
import uplayer from 'libuplayer.so'
import { extractCoverData, fetchFallbackCoverData, CoverDataResult } from './MetadataTask'
import { AppStorageKeyConstants } from '../common/constants/AppStorageKeyConstants'

const TAG = 'AudioMetadataService'
const COVER_MAX_EDGE: number = 640
const COVER_CACHE_MAX_ENTRIES: number = 256
const COVER_CACHE_MAX_BYTES: number = 96 * 1024 * 1024
const COVER_EXTRACTION_CONCURRENCY: number = 3
const COVER_EXTRACTION_QUEUE_MAX: number = 48
const FALLBACK_FAILURE_THRESHOLD: number = 3
const FALLBACK_COOLDOWN_MS: number = 1000
const NEGATIVE_COVER_COOLDOWN_MS: number = 60000

export enum CoverPriority {
  LOW = 0,
  MEDIUM = 1,
  HIGH = 2
}

export enum AlbumCoverSize {
  SMALL = 96,
  MEDIUM = 320,
  LARGE = 640
}

class AlbumCoverCacheEntry {
  key: string = ''
  pixelMap: image.PixelMap | undefined = undefined
  bytes: number = 0
  references: number = 0
  lastAccess: number = 0
  cached: boolean = true
}

export class AlbumCoverLease {
  readonly pixelMap: image.PixelMap
  private entry: AlbumCoverCacheEntry | undefined
  private service: AudioMetadataService | undefined

  constructor(service: AudioMetadataService, entry: AlbumCoverCacheEntry) {
    this.service = service
    this.entry = entry
    this.pixelMap = entry.pixelMap as image.PixelMap
  }

  release(): void {
    if (this.entry === undefined || this.service === undefined) {
      return
    }
    this.service.releaseAlbumCover(this.entry)
    this.entry = undefined
    this.service = undefined
  }
}

class CoverQueueItem {
  priority: CoverPriority = CoverPriority.LOW
  run: () => void = () => {}
  resolve: (value: image.PixelMap | undefined) => void = () => {}
}

// AVMetadataExtractor 文本元数据提取调度队列已随 extractAndSaveMetadata 一并移除：
// 当前元数据提取由 MetadataTask 承担，本服务只保留封面提取与缓存

@SuppressWarnings({rules: [SuppressWarningsType.SYSCAP]})
export class AudioMetadataService {
  private static instance: AudioMetadataService = new AudioMetadataService()
  private coverExtractionActive: number = 0
  private coverExtractionQueue: CoverQueueItem[] = []
  private coverCache: Map<string, AlbumCoverCacheEntry> = new Map<string, AlbumCoverCacheEntry>()
  private pendingCovers: Map<string, Promise<AlbumCoverCacheEntry | undefined>> =
    new Map<string, Promise<AlbumCoverCacheEntry | undefined>>()
  private cacheBytes: number = 0
  private accessCounter: number = 0
  private fallbackFailureCount: number = 0
  private fallbackCircuitUntil: number = 0
  private fallbackProbeActive: boolean = false
  // 单文件负缓存：仅记录确认无嵌入封面的文件，key=sourcePath，value=记录时间戳
  private negativeCoverCache: Map<string, number> = new Map<string, number>()
  // 封面任务生命周期 generation：应用销毁/缓存清理后使排队与执行中的任务失效
  private coverLifecycleGeneration: number = 0

  public static getInstance(): AudioMetadataService {
    return AudioMetadataService.instance
  }

  async acquireAlbumCover(song: SongInfo, maxEdge: number = AlbumCoverSize.LARGE,
    priority: CoverPriority = CoverPriority.HIGH): Promise<AlbumCoverLease | undefined> {
    const normalizedEdge: number = this.normalizeCoverEdge(maxEdge)
    const key: string = this.coverKey(song, normalizedEdge)
    let entry: AlbumCoverCacheEntry | undefined = this.coverCache.get(key)
    if (entry === undefined) {
      let pending: Promise<AlbumCoverCacheEntry | undefined> | undefined = this.pendingCovers.get(key)
      if (pending === undefined) {
        pending = this.loadCacheEntry(song, key, normalizedEdge, priority)
        this.pendingCovers.set(key, pending)
      }
      entry = await pending
    }
    if (entry === undefined || entry.pixelMap === undefined) {
      return undefined
    }
    entry.references++
    entry.lastAccess = ++this.accessCounter
    return new AlbumCoverLease(this, entry)
  }

  prefetchAlbumCover(song: SongInfo, maxEdge: number = AlbumCoverSize.SMALL,
    priority: CoverPriority = CoverPriority.LOW): void {
    this.acquireAlbumCover(song, maxEdge, priority).then((lease: AlbumCoverLease | undefined) => {
      lease?.release()
    }).catch((err: Error) => {
      Logger.debug(TAG, `Album cover prefetch failed: ${JSON.stringify(err)}`)
    })
  }

  prefetchAlbumCovers(songs: SongInfo[], maxEdge: number = AlbumCoverSize.SMALL,
    priority: CoverPriority = CoverPriority.LOW): void {
    for (let i = 0; i < songs.length; i++) {
      if (songs[i].isAvailable) this.prefetchAlbumCover(songs[i], maxEdge, priority)
    }
  }

  // 判断某文件是否已确认无嵌入封面（负缓存命中），供组件决定是否重试
  isCoverConfirmedAbsent(song: SongInfo): boolean {
    const sourcePath: string = song.uri.length > 0 ? song.uri : song.filePath
    const negativeAt: number | undefined = this.negativeCoverCache.get(sourcePath)
    if (negativeAt === undefined) {
      return false
    }
    return new Date().getTime() - negativeAt < NEGATIVE_COVER_COOLDOWN_MS
  }

  releaseAlbumCover(entry: AlbumCoverCacheEntry): void {
    entry.references = Math.max(0, entry.references - 1)
    if (!entry.cached && entry.references === 0 && entry.pixelMap !== undefined) {
      entry.pixelMap.release()
      entry.pixelMap = undefined
    }
    this.trimCoverCache()
  }

  private async loadCacheEntry(song: SongInfo, key: string, maxEdge: number,
    priority: CoverPriority): Promise<AlbumCoverCacheEntry | undefined> {
    try {
      const pixelMap: image.PixelMap | undefined = await this.loadAlbumCover(song, maxEdge, priority)
      if (pixelMap === undefined) return undefined
      const info: image.ImageInfo = await pixelMap.getImageInfo()
      const entry: AlbumCoverCacheEntry = new AlbumCoverCacheEntry()
      entry.key = key
      entry.pixelMap = pixelMap
      entry.bytes = Math.max(1, info.size.width * info.size.height * 4)
      entry.lastAccess = ++this.accessCounter
      this.coverCache.set(key, entry)
      this.cacheBytes += entry.bytes
      this.trimCoverCache()
      return entry
    } finally {
      this.pendingCovers.delete(key)
    }
  }

  private trimCoverCache(): void {
    while (this.coverCache.size > COVER_CACHE_MAX_ENTRIES || this.cacheBytes > COVER_CACHE_MAX_BYTES) {
      let oldestKey: string = ''
      let oldestAccess: number = Number.MAX_VALUE
      this.coverCache.forEach((candidate: AlbumCoverCacheEntry, key: string) => {
        if (candidate.references === 0 && candidate.lastAccess < oldestAccess) {
          oldestKey = key
          oldestAccess = candidate.lastAccess
        }
      })
      if (oldestKey.length === 0) return
      const oldest: AlbumCoverCacheEntry | undefined = this.coverCache.get(oldestKey)
      if (oldest === undefined) return
      this.coverCache.delete(oldestKey)
      this.cacheBytes = Math.max(0, this.cacheBytes - oldest.bytes)
      oldest.cached = false
      if (oldest.pixelMap !== undefined) {
        oldest.pixelMap.release()
        oldest.pixelMap = undefined
      }
    }
  }

  private normalizeCoverEdge(maxEdge: number): number {
    if (maxEdge <= AlbumCoverSize.SMALL) return AlbumCoverSize.SMALL
    if (maxEdge <= AlbumCoverSize.MEDIUM) return AlbumCoverSize.MEDIUM
    return AlbumCoverSize.LARGE
  }

  private coverKey(song: SongInfo, maxEdge: number): string {
    const sourcePath: string = song.uri.length > 0 ? song.uri : song.filePath
    return sourcePath + '#' + maxEdge
  }

  private async loadAlbumCover(song: SongInfo, maxEdge: number,
    priority: CoverPriority): Promise<image.PixelMap | undefined> {
    const sourcePath: string = song.uri.length > 0 ? song.uri : song.filePath
    const nativeResult: CoverDataResult = await extractCoverData(sourcePath)
    if (nativeResult.ok) {
      const cover: image.PixelMap | undefined = await this.decodeTempCover(nativeResult.tempPath, maxEdge)
      try {
        fs.unlinkSync(nativeResult.tempPath)
      } catch (err) {
      }
      if (cover !== undefined) {
        Logger.debug(TAG, `Album cover native hit for ${song.fileName}`)
        return cover
      }
      Logger.warn(TAG, `Album cover native decode failed for ${song.fileName}`)
    } else if (nativeResult.errorMessage.length > 0) {
      Logger.warn(TAG, `Album cover native extraction failed for ${song.fileName}: ${nativeResult.errorMessage}`)
    }

    const now: number = new Date().getTime()
    const negativeAt: number | undefined = this.negativeCoverCache.get(sourcePath)
    if (negativeAt !== undefined && now - negativeAt < NEGATIVE_COVER_COOLDOWN_MS) {
      Logger.debug(TAG, `Album cover negative cache hit for ${song.fileName}`)
      return undefined
    }

    const fallbackTask: Promise<image.PixelMap | undefined> =
      this.scheduleFallbackCover(song, sourcePath, maxEdge, priority)
    return await fallbackTask
  }

  // 有界并发调度 fallback 封面提取，避免串行排队导致首屏大量占位图
  private scheduleFallbackCover(song: SongInfo, sourcePath: string,
    maxEdge: number, priority: CoverPriority): Promise<image.PixelMap | undefined> {
    return new Promise<image.PixelMap | undefined>((resolve: (value: image.PixelMap | undefined) => void): void => {
      const run: () => void = (): void => {
        const snapshotGen: number = this.coverLifecycleGeneration
        this.coverExtractionActive++
        this.fetchFallbackCover(song, sourcePath, maxEdge).then((cover: image.PixelMap | undefined) => {
          if (snapshotGen !== this.coverLifecycleGeneration) {
            cover?.release()
            resolve(undefined)
            return
          }
          resolve(cover)
        }).catch(() => {
          if (snapshotGen !== this.coverLifecycleGeneration) {
            resolve(undefined)
            return
          }
          resolve(undefined)
        }).finally(() => {
          this.coverExtractionActive--
          this.drainCoverQueue()
        })
      }
      if (this.coverExtractionActive < COVER_EXTRACTION_CONCURRENCY) {
        run()
      } else {
        if (this.coverExtractionQueue.length >= COVER_EXTRACTION_QUEUE_MAX) {
          let dropIndex: number = -1
          for (let i = this.coverExtractionQueue.length - 1; i >= 0; i--) {
            if (this.coverExtractionQueue[i].priority < priority) {
              dropIndex = i
              break
            }
          }
          if (dropIndex < 0) {
            resolve(undefined)
            return
          }
          const dropped: CoverQueueItem = this.coverExtractionQueue[dropIndex]
          this.coverExtractionQueue.splice(dropIndex, 1)
          dropped.resolve(undefined)
        }
        const item: CoverQueueItem = new CoverQueueItem()
        item.priority = priority
        item.run = run
        item.resolve = resolve
        this.coverExtractionQueue.push(item)
        this.coverExtractionQueue.sort((a: CoverQueueItem, b: CoverQueueItem) => b.priority - a.priority)
      }
    })
  }

  private drainCoverQueue(): void {
    while (this.coverExtractionActive < COVER_EXTRACTION_CONCURRENCY && this.coverExtractionQueue.length > 0) {
      const next: CoverQueueItem | undefined = this.coverExtractionQueue.shift()
      if (next !== undefined) {
        next.run()
      }
    }
  }

  /**
   * 从沙箱临时文件解码封面（路径重载的 createImageSource 在本设备验证可用）。
   * 解码失败或异常返回 undefined，调用方负责删除临时文件。
   */
  private async decodeTempCover(tempPath: string, maxEdge: number): Promise<image.PixelMap | undefined> {
    let source: image.ImageSource | undefined = undefined
    try {
      source = image.createImageSource(tempPath)
      if (source === undefined) {
        Logger.error(TAG, `createImageSource(path) returned undefined for ${tempPath}`)
        return undefined
      }
      return await this.decodeCover(source, maxEdge)
    } catch (err) {
      Logger.warn(TAG, `decodeTempCover failed ${tempPath}: ${String(err)}`.substring(0, 200))
      return undefined
    } finally {
      if (source !== undefined) {
        try {
          await source.release()
        } catch (err) {
          Logger.warn(TAG, `ImageSource release failed: ${JSON.stringify(err)}`)
        }
      }
    }
  }

  /** 读取临时文件字节（用于写入 native 封面缓存） */
  private readTempFileBytes(tempPath: string): ArrayBuffer | undefined {
    try {
      const file: fs.File = fs.openSync(tempPath, fs.OpenMode.READ_ONLY)
      try {
        const size: number = fs.statSync(file.fd).size
        if (size <= 0) {
          return undefined
        }
        const data: ArrayBuffer = new ArrayBuffer(size)
        fs.readSync(file.fd, data)
        return data
      } finally {
        fs.closeSync(file)
      }
    } catch (err) {
      Logger.warn(TAG, `readTempFileBytes failed ${tempPath}: ${String(err)}`.substring(0, 200))
      return undefined
    }
  }

  private async fetchFallbackCover(song: SongInfo, sourcePath: string,
    maxEdge: number): Promise<image.PixelMap | undefined> {
    // 诊断日志：记录每个文件的封面提取流程，帮助定位主线程异常原因
    const now: number = new Date().getTime()
    if (now < this.fallbackCircuitUntil) return undefined
    const halfOpen: boolean = this.fallbackFailureCount >= FALLBACK_FAILURE_THRESHOLD
    if (halfOpen && this.fallbackProbeActive) return undefined
    if (halfOpen) this.fallbackProbeActive = true
    let tempPath: string | undefined = undefined
    try {
      const result: CoverDataResult = await fetchFallbackCoverData(sourcePath)
      if (result.ok) {
        tempPath = result.tempPath
      }
      if (result.errorMessage.length > 0) {
        // taskpool 内部异常（打开/提取/写临时文件失败等），按失败处理；
        // 不加入负缓存（负缓存仅针对确认无封面的情况），允许下次重试
        Logger.warn(TAG,
          `fallback cover failed for ${song.fileName}: ${result.errorMessage}`)
        this.recordFallbackFailure()
        return undefined
      }
      if (result.none) {
        // 任务池明确确认：文件无嵌入封面，进入负缓存
        this.negativeCoverCache.set(sourcePath, new Date().getTime())
        return undefined
      }
      // 封面提取成功，重置熔断器
      this.fallbackFailureCount = 0
      this.fallbackCircuitUntil = 0
      this.negativeCoverCache.delete(sourcePath)
      const cover: image.PixelMap | undefined = await this.decodeTempCover(result.tempPath, maxEdge)
      if (cover !== undefined) {
        // 读取临时文件字节写入 native 缓存，供后续 ID3 路径直接命中
        const data: ArrayBuffer | undefined = this.readTempFileBytes(result.tempPath)
        if (data !== undefined) {
          uplayer.cacheAlbumCover(sourcePath, data)
        }
        Logger.debug(TAG, `Album cover fallback success for ${song.fileName}`)
        return cover
      }
      // 解码失败视为失败
      this.recordFallbackFailure()
      return undefined
    } catch (err) {
      Logger.warn(TAG, `Album cover fallback failed for ${song.fileName}: ${String(err)}`.substring(0, 200))
      return undefined
    } finally {
      if (tempPath !== undefined) {
        try {
          fs.unlinkSync(tempPath)
        } catch (err) {
          Logger.warn(TAG, `temp cover unlink failed: ${String(err)}`.substring(0, 120))
        }
      }
      if (halfOpen) this.fallbackProbeActive = false
    }
  }

  private recordFallbackFailure(): void {
    this.fallbackFailureCount++
    if (this.fallbackFailureCount >= FALLBACK_FAILURE_THRESHOLD) {
      this.fallbackCircuitUntil = new Date().getTime() + FALLBACK_COOLDOWN_MS
      Logger.error(TAG, `Album cover fallback circuit open cooldownMs=${FALLBACK_COOLDOWN_MS}`)
    }
  }

  private async decodeCover(source: image.ImageSource, maxEdge: number): Promise<image.PixelMap> {
    const info: image.ImageInfo = await source.getImageInfo()
    const longEdge: number = Math.max(info.size.width, info.size.height)
    const scale: number = longEdge > maxEdge ? maxEdge / longEdge : 1
    const desiredSize: image.Size = {
      width: Math.max(1, Math.round(info.size.width * scale)),
      height: Math.max(1, Math.round(info.size.height * scale))
    }
    const options: image.DecodingOptions = { desiredSize: desiredSize }
    return await source.createPixelMap(options)
  }

  clearMemoryCache(): void {
    // 使排队与执行中的封面任务失效，避免回写已销毁对象
    this.coverLifecycleGeneration++
    this.coverExtractionQueue.length = 0
    this.coverExtractionActive = 0
    this.coverCache.forEach((entry: AlbumCoverCacheEntry) => {
      entry.cached = false
      if (entry.references === 0 && entry.pixelMap !== undefined) {
        const pm: image.PixelMap | undefined = entry.pixelMap
        entry.pixelMap = undefined
        if (pm !== undefined) {
          try {
            pm.release()
          } catch (err) {
            Logger.warn(TAG, `Album cover pixelMap release failed: ${JSON.stringify(err)}`)
          }
        }
      }
    })
    this.coverCache.clear()
    this.pendingCovers.clear()
    this.negativeCoverCache.clear()
    this.cacheBytes = 0
    this.fallbackFailureCount = 0
    this.fallbackCircuitUntil = 0
    this.fallbackProbeActive = false
    try {
      uplayer.clearAlbumCoverCache()
    } catch (err) {
      Logger.warn(TAG, `clearAlbumCoverCache failed: ${JSON.stringify(err)}`)
    }
  }
}
