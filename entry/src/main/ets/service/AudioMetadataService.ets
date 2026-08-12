// 音频元数据提取服务，使用AVMetadataExtractor读取歌曲标题、歌手、专辑封面等
import { media } from '@kit.MediaKit'
import { fileIo as fs } from '@kit.CoreFileKit'
import { image } from '@kit.ImageKit'
import { common } from '@kit.AbilityKit'
import { SongInfo } from '../model/SongInfo'
import Logger from '../common/utils/Logger'

const TAG = 'AudioMetadataService'

export class AudioMetadataService {
  private static instance: AudioMetadataService = new AudioMetadataService()

  public static getInstance(): AudioMetadataService {
    return AudioMetadataService.instance
  }

  // 提取元数据并更新SongInfo，封面保存到cache目录
  async extractAndSaveMetadata(song: SongInfo, context: common.UIAbilityContext): Promise<void> {
    let extractor: media.AVMetadataExtractor | undefined = undefined
    let file: fs.File | undefined = undefined
    try {
      extractor = await media.createAVMetadataExtractor()
      file = fs.openSync(song.uri.length > 0 ? song.uri : song.filePath, fs.OpenMode.READ_ONLY)
      const sourcePath: string = song.uri.length > 0 ? song.uri : song.filePath
      const stat = fs.statSync(sourcePath)
      const avFd: media.AVFileDescriptor = { fd: file.fd, offset: 0, length: stat.size }
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

      let cover: image.PixelMap | undefined = undefined
      try {
        cover = await extractor.fetchAlbumCover()
        song.albumArtPath = await this.saveAlbumCover(cover, song.id, context)
      } catch (coverErr) {
        song.albumArtPath = ''
        Logger.info(TAG, `No album cover for ${song.fileName}`)
      } finally {
        if (cover !== undefined) {
          cover.release()
        }
      }
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

  private async saveAlbumCover(cover: image.PixelMap, songId: string,
    context: common.UIAbilityContext): Promise<string> {
    const coverDir: string = context.filesDir + '/covers'
    const coverPath: string = coverDir + '/cover_' + songId + '.jpg'
    let packer: image.ImagePacker | undefined = undefined
    let coverFile: fs.File | undefined = undefined
    try {
      fs.mkdirSync(coverDir, true)
      packer = image.createImagePacker()
      const options: image.PackingOption = {
        format: 'image/jpeg',
        quality: 80
      }
      let packedData: ArrayBuffer = await packer.packToData(cover, options)
      coverFile = fs.openSync(coverPath,
        fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC)
      fs.writeSync(coverFile.fd, packedData)
      return coverPath
    } catch (err) {
      Logger.warn(TAG, `saveAlbumCover error: ${JSON.stringify(err)}`)
      return ''
    } finally {
      if (coverFile !== undefined) {
        fs.closeSync(coverFile)
      }
      if (packer !== undefined) {
        packer.release()
      }
    }
  }

  // 按需从音频文件提取封面PixelMap（用于AVSession等场景）
  async fetchAlbumCover(song: SongInfo): Promise<image.PixelMap | undefined> {
    let extractor: media.AVMetadataExtractor | undefined = undefined
    let file: fs.File | undefined = undefined
    try {
      extractor = await media.createAVMetadataExtractor()
      file = fs.openSync(song.uri.length > 0 ? song.uri : song.filePath, fs.OpenMode.READ_ONLY)
      const sourcePath: string = song.uri.length > 0 ? song.uri : song.filePath
      const stat = fs.statSync(sourcePath)
      const avFd: media.AVFileDescriptor = { fd: file.fd, offset: 0, length: stat.size }
      extractor.fdSrc = avFd
      let cover: image.PixelMap = await extractor.fetchAlbumCover()
      return cover
    } catch (err) {
      Logger.info(TAG, `No album cover for ${song.fileName}`)
      return undefined
    } finally {
      if (extractor !== undefined) {
        extractor.release()
      }
      if (file !== undefined) {
        fs.closeSync(file)
      }
    }
  }

  async repairAlbumCovers(songs: SongInfo[], context: common.UIAbilityContext): Promise<boolean> {
    let changed: boolean = false
    for (let i = 0; i < songs.length; i++) {
      const song: SongInfo = songs[i]
      if (song.albumArtPath.length > 0 && fs.accessSync(song.albumArtPath)) {
        continue
      }
      const oldPath: string = song.albumArtPath
      await this.extractAndSaveMetadata(song, context)
      if (song.albumArtPath !== oldPath) {
        changed = true
      }
    }
    return changed
  }
}
