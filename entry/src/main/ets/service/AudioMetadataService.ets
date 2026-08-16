// 音频元数据提取服务，使用AVMetadataExtractor读取歌曲标题、歌手、专辑封面等
import { media } from '@kit.MediaKit'
import { fileIo as fs } from '@kit.CoreFileKit'
import { image } from '@kit.ImageKit'
import { common } from '@kit.AbilityKit'
import { SongInfo } from '../model/SongInfo'
import Logger from '../common/utils/Logger'
import uplayer from 'libuplayer.so'

const TAG = 'AudioMetadataService'
const COVER_MAX_EDGE: number = 640
const COVER_CACHE_MAX_ENTRIES: number = 40
const COVER_CACHE_MAX_BYTES: number = 32 * 1024 * 1024
const COVER_EXTRACTION_CONCURRENCY: number = 1
const COVER_EXTRACTION_QUEUE_MAX: number = 24
const FALLBACK_FAILURE_THRESHOLD: number = 1
const FALLBACK_COOLDOWN_MS: number = 30000

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

  public static getInstance(): AudioMetadataService {
    return AudioMetadataService.instance
  }

  // 提取文本元数据；封面严格按需从音频文件读取到内存
  async extractAndSaveMetadata(song: SongInfo, context: common.UIAbilityContext): Promise<void> {
    let extractor: media.AVMetadataExtractor | undefined = undefined
    let file: fs.File | undefined = undefined
    try {
      extractor = await media.createAVMetadataExtractor()
      file = fs.openSync(song.uri.length > 0 ? song.uri : song.filePath, fs.OpenMode.READ_ONLY)
      const fileSize: number = fs.statSync(file.fd).size
      const avFd: media.AVFileDescriptor = { fd: file.fd, offset: 0, length: fileSize }
      extractor.fdSrc = avFd

      let metadata: media.AVMetadata = await extractor.fetchMetadata()
      if (metadata.title !== undefined) {
        let metaTitle: string = '' + metadata.title
        if (metaTitle.length > 0) song.title = metaTitle
      }
      if (metadata.artist !== undefined) {
        let metaArtist: string = '' + metadata.artist
        if (metaArtist.length > 0) song.artist = metaArtist
      }
      if (metadata.album !== undefined) {
        let metaAlbum: string = '' + metadata.album
        if (metaAlbum.length > 0) song.album = metaAlbum
      }
      if (metadata.duration !== undefined) {
        let metaDuration: number = Number(metadata.duration)
        if (metaDuration > 0) song.duration = metaDuration
      }
      song.albumArtPath = ''
    } catch (err) {
      Logger.warn(TAG, `Metadata extraction failed for ${song.fileName}: ${JSON.stringify(err)}`)
    } finally {
      if (extractor !== undefined) {
        try {
          await extractor.release()
        } catch (err) {
          Logger.warn(TAG, `AVMetadataExtractor release failed: ${JSON.stringify(err)}`)
        }
      }
      if (file !== undefined) fs.closeSync(file)
    }
  }

  cleanupCoverCache(context: common.UIAbilityContext, songs: SongInfo[]): void {
    for (let i = 0; i < songs.length; i++) songs[i].albumArtPath = ''
  }

  async migrateLegacyCovers(context: common.UIAbilityContext, songs: SongInfo[]): Promise<boolean> {
    let changed: boolean = false
    for (let i = 0; i < songs.length; i++) {
      if (songs[i].albumArtPath.length > 0) {
        songs[i].albumArtPath = ''
        changed = true
      }
    }
    return changed
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

  prefetchAlbumCovers(songs: SongInfo[], maxEdge: number = AlbumCoverSize.SMALL): void {
    for (let i = 0; i < songs.length; i++) {
      if (songs[i].isAvailable) this.prefetchAlbumCover(songs[i], maxEdge)
    }
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
    let file: fs.File | undefined = undefined
    let source: image.ImageSource | undefined = undefined
    try {
      file = fs.openSync(sourcePath, fs.OpenMode.READ_ONLY)
      const fileSize: number = fs.statSync(file.fd).size
      const data: ArrayBuffer | undefined = uplayer.getAlbumCover(file.fd, fileSize, sourcePath)
      if (data !== undefined && data.byteLength > 0) {
        source = image.createImageSource(data)
        const cover: image.PixelMap = await this.decodeCover(source, maxEdge)
        Logger.debug(TAG, `Album cover native hit for ${song.fileName}`)
        return cover
      }
    } catch (err) {
      Logger.warn(TAG, `Album cover native extraction failed for ${song.fileName}: ${JSON.stringify(err)}`)
    } finally {
      if (source !== undefined) {
        try {
          await source.release()
        } catch (err) {
          Logger.warn(TAG, `ImageSource release failed: ${JSON.stringify(err)}`)
        }
      }
      if (file !== undefined) fs.closeSync(file)
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
        this.coverExtractionActive++
        this.fetchFallbackCover(song, sourcePath, maxEdge).then((cover: image.PixelMap | undefined) => {
          resolve(cover)
        }).catch(() => {
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

  private async fetchFallbackCover(song: SongInfo, sourcePath: string,
    maxEdge: number): Promise<image.PixelMap | undefined> {
    const now: number = new Date().getTime()
    if (now < this.fallbackCircuitUntil) return undefined
    const halfOpen: boolean = this.fallbackFailureCount >= FALLBACK_FAILURE_THRESHOLD
    if (halfOpen && this.fallbackProbeActive) return undefined
    if (halfOpen) this.fallbackProbeActive = true
    try {
      const cover: image.PixelMap | undefined = await this.tryFetchFallbackCover(song, sourcePath, maxEdge)
      if (cover !== undefined) {
        this.fallbackFailureCount = 0
        this.fallbackCircuitUntil = 0
        return cover
      }
      this.recordFallbackFailure()
      return undefined
    } finally {
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

  private async tryFetchFallbackCover(song: SongInfo, sourcePath: string,
    maxEdge: number): Promise<image.PixelMap | undefined> {
    let file: fs.File | undefined = undefined
    let extractor: media.AVMetadataExtractor | undefined = undefined
    let fallbackCover: image.PixelMap | undefined = undefined
    try {
      file = fs.openSync(sourcePath, fs.OpenMode.READ_ONLY)
      const fileSize: number = fs.statSync(file.fd).size
      extractor = await media.createAVMetadataExtractor()
      const avFd: media.AVFileDescriptor = { fd: file.fd, offset: 0, length: fileSize }
      extractor.fdSrc = avFd
      fallbackCover = await extractor.fetchAlbumCover()
      const fallbackInfo: image.ImageInfo = await fallbackCover.getImageInfo()
      const fallbackLongEdge: number = Math.max(fallbackInfo.size.width, fallbackInfo.size.height)
      if (fallbackLongEdge > COVER_MAX_EDGE) {
        const cacheScale: number = COVER_MAX_EDGE / fallbackLongEdge
        await fallbackCover.scale(cacheScale, cacheScale, image.AntiAliasingLevel.HIGH)
      }
      await this.cacheFallbackCover(sourcePath, fallbackCover)
      const resizedInfo: image.ImageInfo = await fallbackCover.getImageInfo()
      const resizedLongEdge: number = Math.max(resizedInfo.size.width, resizedInfo.size.height)
      if (resizedLongEdge > maxEdge) {
        const displayScale: number = maxEdge / resizedLongEdge
        await fallbackCover.scale(displayScale, displayScale, image.AntiAliasingLevel.HIGH)
      }
      Logger.debug(TAG, `Album cover fallback success for ${song.fileName}`)
      const cover: image.PixelMap = fallbackCover
      fallbackCover = undefined
      return cover
    } catch (err) {
      if (fallbackCover !== undefined) fallbackCover.release()
      Logger.warn(TAG, `Album cover fallback failed for ${song.fileName}: ${JSON.stringify(err)}`)
      return undefined
    } finally {
      if (extractor !== undefined) {
        try {
          await extractor.release()
        } catch (err) {
          Logger.warn(TAG, `AVMetadataExtractor release failed: ${JSON.stringify(err)}`)
        }
      }
      if (file !== undefined) fs.closeSync(file)
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

  private async cacheFallbackCover(key: string, cover: image.PixelMap): Promise<void> {
    let packer: image.ImagePacker | undefined = undefined
    try {
      packer = image.createImagePacker()
      const options: image.PackingOption = { format: 'image/jpeg', quality: 90 }
      const data: ArrayBuffer = await packer.packToData(cover, options)
      uplayer.cacheAlbumCover(key, data)
    } catch (err) {
      Logger.warn(TAG, `Memory cover cache failed: ${JSON.stringify(err)}`)
    } finally {
      if (packer !== undefined) packer.release()
    }
  }

  clearMemoryCache(): void {
    this.coverCache.forEach((entry: AlbumCoverCacheEntry) => {
      entry.cached = false
      if (entry.references === 0 && entry.pixelMap !== undefined) {
        entry.pixelMap.release()
        entry.pixelMap = undefined
      }
    })
    this.coverCache.clear()
    this.pendingCovers.clear()
    this.cacheBytes = 0
    uplayer.clearAlbumCoverCache()
  }
}
