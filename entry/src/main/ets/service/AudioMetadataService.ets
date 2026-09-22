// 音频元数据提取服务，使用AVMetadataExtractor读取歌曲标题、歌手、专辑封面等
import { fileIo as fs } from '@kit.CoreFileKit'
import { image } from '@kit.ImageKit'
import { common } from '@kit.AbilityKit'
import { BusinessError, SuppressWarnings, SuppressWarningsType } from '@kit.BasicServicesKit'
import { SongInfo } from '../model/SongInfo'
import Logger from '../common/utils/Logger'
import uplayer from 'libuplayer.so'
import { extractCoverData, fetchFallbackCoverData } from './MetadataTask'

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
    let source: image.ImageSource | undefined = undefined
    try {
      const data: ArrayBuffer | undefined = await extractCoverData(sourcePath)
      if (data !== undefined && data.byteLength > 0) {
        source = image.createImageSource(data)
        const cover: image.PixelMap = await this.decodeCover(source, maxEdge)
        Logger.debug(TAG, `Album cover native hit for ${song.fileName}`)
        return cover
      }
    } catch (err) {
      const error = err as BusinessError
      Logger.warn(TAG,
        `Album cover native extraction failed for ${song.fileName}: code=${error.code} sourcePath=${sourcePath}`)
    } finally {
      if (source !== undefined) {
        try {
          await source.release()
        } catch (err) {
          Logger.warn(TAG, `ImageSource release failed: ${JSON.stringify(err)}`)
        }
      }
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
   * 安全提取 err 的可读字段。
   * 注意：BusinessError 的 message 字段在某些 ArkTS 编译器版本中不能直接通过属性访问，
   * 需通过 (err as Record<string, Object>) 间接访问或仅用 JSON.stringify 兜底。
   */
  private describeError(err: Object): string {
    try {
      const e: Record<string, Object> = err as Record<string, Object>
      const codeVal: number | undefined = e['code'] as number | undefined
      const msgVal: string | undefined = e['message'] as string | undefined
      return `code=${String(codeVal ?? 'n/a')} msg=${String(msgVal ?? 'n/a')}`
    } catch (_) {
      return 'error (unavailable)'
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
    let source: image.ImageSource | undefined = undefined
    try {
      const data: ArrayBuffer | undefined = await fetchFallbackCoverData(sourcePath)
      if (data === undefined) {
        // taskpool 内部异常或无法获取封面，按失败处理；不加入负缓存（负缓存仅针对
        // 明确返回空字节的情况），允许下次重试
        Logger.warn(TAG, `fallback data undefined for ${song.fileName}: taskpool returned undefined`)
        this.recordFallbackFailure()
        return undefined
      }
      if (data.byteLength === 0) {
        // 任务池明确返回空 ArrayBuffer：文件无嵌入封面，进入负缓存
        this.negativeCoverCache.set(sourcePath, new Date().getTime())
        return undefined
      }
      // 封面提取成功，重置熔断器
      this.fallbackFailureCount = 0
      this.fallbackCircuitUntil = 0
      this.negativeCoverCache.delete(sourcePath)
      // 先解码再缓存：若 decodeCover 抛出，不需要写入缓存（否则脏数据会污染后续请求）
      source = image.createImageSource(data)
      let cover: image.PixelMap | undefined = undefined
      try {
        cover = await this.decodeCover(source, maxEdge)
      } finally {
        if (source !== undefined) {
          try {
            await source.release()
          } catch (_) { /* ignore */ }
          source = undefined
        }
      }
      if (cover !== undefined) {
        uplayer.cacheAlbumCover(sourcePath, data)
        Logger.debug(TAG, `Album cover fallback success for ${song.fileName}`)
        return cover
      }
      // decodeCover 返回 undefined 视为失败
      this.recordFallbackFailure()
      return undefined
    } catch (err) {
      Logger.warn(TAG, `Album cover fallback failed for ${song.fileName}: ${this.describeError(err as Object)}`)
      return undefined
    } finally {
      if (source !== undefined) {
        try {
          await source.release()
        } catch (err) {
          Logger.warn(TAG, `ImageSource release failed: ${this.describeError(err as Object)}`)
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
