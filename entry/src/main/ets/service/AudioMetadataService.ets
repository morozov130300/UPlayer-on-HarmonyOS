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

  async extractAndSaveMetadata(song: SongInfo, context: common.UIAbilityContext): Promise<void> {
    let extractor: media.AVMetadataExtractor | undefined = undefined
    let file: fs.File | undefined = undefined
    try {
      extractor = await media.createAVMetadataExtractor()
      file = fs.openSync(song.filePath)
      let fileSize: number = 0
      try {
        fileSize = fs.statSync(song.filePath).size
      } catch (statErr) {
        Logger.warn(TAG, `statSync failed for ${song.fileName}: ${JSON.stringify(statErr)}`)
      }
      let avFile: media.AVFileDescriptor = {
        fd: file.fd,
        offset: 0,
        length: fileSize
      }
      extractor.fdSrc = avFile

      let metadata: media.AVMetadata = await extractor.fetchMetadata()

      if (metadata.title !== undefined) {
        let metaTitle: string = metadata.title as string
        if (metaTitle.length > 0) {
          song.title = metaTitle
        }
      }
      if (metadata.artist !== undefined) {
        let metaArtist: string = metadata.artist as string
        if (metaArtist.length > 0) {
          song.artist = metaArtist
        }
      }
      if (metadata.album !== undefined) {
        let metaAlbum: string = metadata.album as string
        if (metaAlbum.length > 0) {
          song.album = metaAlbum
        }
      }

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
