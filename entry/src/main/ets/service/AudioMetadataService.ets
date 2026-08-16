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

export class AudioMetadataService {
  private static instance: AudioMetadataService = new AudioMetadataService()

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

      // 提取文本元数据（标题、歌手、专辑）
      let metadata: media.AVMetadata = await extractor.fetchMetadata()

      if (metadata.title !== undefined) {
        let metaTitle: string = '' + metadata.title
        if (metaTitle.length > 0) {
          song.title = metaTitle
        }
      }
      if (metadata.artist !== undefined) {
        let metaArtist: string = '' + metadata.artist
        if (metaArtist.length > 0) {
          song.artist = metaArtist
        }
      }
      if (metadata.album !== undefined) {
        let metaAlbum: string = '' + metadata.album
        if (metaAlbum.length > 0) {
          song.album = metaAlbum
        }
      }
      if (metadata.duration !== undefined) {
        let metaDuration: number = Number(metadata.duration)
        if (metaDuration > 0) {
          song.duration = metaDuration
        }
      }

      song.albumArtPath = ''
    } catch (err) {
      Logger.warn(TAG, `Metadata extraction failed for ${song.fileName}: ${JSON.stringify(err)}`)
    } finally {
      if (extractor !== undefined) {
        extractor.release()
      }
      if (file !== undefined) {
        fs.closeSync(file)
      }
    }
  }

  cleanupCoverCache(context: common.UIAbilityContext, songs: SongInfo[]): void {
    for (let i = 0; i < songs.length; i++) {
      songs[i].albumArtPath = ''
    }
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

  // 按需从音频文件提取封面PixelMap（用于AVSession等场景）
  async fetchAlbumCover(song: SongInfo): Promise<image.PixelMap | undefined> {
    let file: fs.File | undefined = undefined
    let source: image.ImageSource | undefined = undefined
    let extractor: media.AVMetadataExtractor | undefined = undefined
    try {
      file = fs.openSync(song.uri.length > 0 ? song.uri : song.filePath, fs.OpenMode.READ_ONLY)
      const fileSize: number = fs.statSync(file.fd).size
      const data: ArrayBuffer | undefined = uplayer.getAlbumCover(file.fd, fileSize,
        song.uri.length > 0 ? song.uri : song.filePath)
      if (data !== undefined && data.byteLength > 0) {
        source = image.createImageSource(data)
        return await this.decodeCover(source)
      }
      extractor = await media.createAVMetadataExtractor()
      const avFd: media.AVFileDescriptor = { fd: file.fd, offset: 0, length: fileSize }
      extractor.fdSrc = avFd
      const fallbackCover: image.PixelMap = await extractor.fetchAlbumCover()
      const fallbackInfo: image.ImageInfo = await fallbackCover.getImageInfo()
      const fallbackLongEdge: number = fallbackInfo.size.width > fallbackInfo.size.height ?
        fallbackInfo.size.width : fallbackInfo.size.height
      if (fallbackLongEdge > COVER_MAX_EDGE) {
        const fallbackScale: number = COVER_MAX_EDGE / fallbackLongEdge
        await fallbackCover.scale(fallbackScale, fallbackScale, image.AntiAliasingLevel.HIGH)
      }
      await this.cacheFallbackCover(song.uri.length > 0 ? song.uri : song.filePath, fallbackCover)
      return fallbackCover
    } catch (err) {
      Logger.warn(TAG, `Album cover extraction failed for ${song.fileName}: ${JSON.stringify(err)}`)
      return undefined
    } finally {
      if (source !== undefined) {
        await source.release()
      }
      if (extractor !== undefined) {
        extractor.release()
      }
      if (file !== undefined) {
        fs.closeSync(file)
      }
    }
  }

  private async decodeCover(source: image.ImageSource): Promise<image.PixelMap> {
    const info: image.ImageInfo = await source.getImageInfo()
    const longEdge: number = info.size.width > info.size.height ? info.size.width : info.size.height
    const scale: number = longEdge > COVER_MAX_EDGE ? COVER_MAX_EDGE / longEdge : 1
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
      if (packer !== undefined) {
        packer.release()
      }
    }
  }

  clearMemoryCache(): void {
    uplayer.clearAlbumCoverCache()
  }
}
