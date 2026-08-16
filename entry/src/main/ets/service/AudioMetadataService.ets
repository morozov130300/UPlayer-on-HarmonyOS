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
      file = fs.openSync(song.filePath, fs.OpenMode.READ_ONLY)
      // 直接使用 fd 作为数据源
      const avFd: media.AVFileDescriptor = { fd: file.fd, offset: 0, length: 0 }
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

      // 提取专辑封面并保存为JPEG文件
      try {
        let cover: image.PixelMap = await extractor.fetchAlbumCover()
        song.albumArtPath = await this.saveAlbumCover(cover, song.id, context)
      } catch (coverErr) {
        Logger.info(TAG, `No album cover for ${song.fileName}`)
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

  // 将PixelMap封面编码为JPEG并写入cache/covers/目录
  private async saveAlbumCover(cover: image.PixelMap, songId: string, context: common.UIAbilityContext): Promise<string> {
    const coverDir: string = context.cacheDir + '/covers'
    const coverPath: string = coverDir + '/cover_' + songId + '.jpg'

    try {
      fs.mkdirSync(coverDir, true)
    } catch (mkErr) {
      Logger.warn(TAG, `mkdir error: ${JSON.stringify(mkErr)}`)
    }

    let packer: image.ImagePacker = image.createImagePacker()
    let packingOpt: image.PackingOption = {
      format: 'image/jpeg',
      quality: 80
    }
    try {
      let packedData: ArrayBuffer = await packer.packing(cover, packingOpt)
      let coverFile: fs.File = fs.openSync(coverPath, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY)
      fs.writeSync(coverFile.fd, packedData)
      fs.closeSync(coverFile)
    } catch (packErr) {
      Logger.warn(TAG, `saveAlbumCover error: ${JSON.stringify(packErr)}`)
    }
    packer.release()

    return coverPath
  }
}
