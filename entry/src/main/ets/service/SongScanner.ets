import { picker, fileIo as fs, fileShare } from '@kit.CoreFileKit'
import { common } from '@kit.AbilityKit'
import { SongInfo } from '../model/SongInfo'
import { FolderInfo } from '../model/FolderInfo'
import { DataService, AUDIO_EXTENSIONS } from './DataService'
import { AudioMetadataService } from './AudioMetadataService'
import Logger from '../common/utils/Logger'

const TAG = 'SongScanner'

export class SongScanner {
  private static instance: SongScanner = new SongScanner()

  public static getInstance(): SongScanner {
    return SongScanner.instance
  }

  public isAudioFile(fileName: string): boolean {
    const lower: string = fileName.toLowerCase()
    for (let i = 0; i < AUDIO_EXTENSIONS.length; i++) {
      if (lower.endsWith(AUDIO_EXTENSIONS[i])) {
        return true
      }
    }
    return false
  }

  public async pickAudioFiles(context: common.UIAbilityContext): Promise<SongInfo[]> {
    try {
      const options: picker.DocumentSelectOptions = new picker.DocumentSelectOptions()
      const docPicker: picker.DocumentViewPicker = new picker.DocumentViewPicker(context)
      const uris: string[] = await docPicker.select(options)
      if (uris.length === 0) {
        return []
      }
      const songs: SongInfo[] = []
      const metadataService: AudioMetadataService = AudioMetadataService.getInstance()
      Logger.info(TAG, `picker returned ${uris.length} URIs`)
      const allUrisToPersist: string[] = []
      const metadataTasks: Promise<void>[] = []
      for (let i = 0; i < uris.length; i++) {
        const uri: string = uris[i]
        const fileName: string = this.getFileNameFromUri(uri)
        const isAudio: boolean = this.isAudioFile(fileName)
        Logger.info(TAG, `uri=${uri} fileName=${fileName} isAudio=${isAudio}`)
        if (isAudio) {
          const song: SongInfo = SongInfo.fromFile(uri, fileName)
          if (song.lyricUri.length > 0) {
            try {
              fs.accessSync(song.lyricUri)
              allUrisToPersist.push(song.lyricUri)
            } catch (_) {
              song.lyricPath = ''
              song.lyricUri = ''
            }
          }
          songs.push(song)
          allUrisToPersist.push(uri)
          metadataTasks.push(metadataService.extractAndSaveMetadata(song, context))
          if (metadataTasks.length >= 4) {
            await Promise.all(metadataTasks)
            metadataTasks.length = 0
          }
        }
      }
      if (metadataTasks.length > 0) {
        await Promise.all(metadataTasks)
      }
      await this.persistUris(allUrisToPersist)
      AudioMetadataService.getInstance().prefetchAlbumCovers(songs)
      Logger.info(TAG, `picked ${songs.length} audio files`)
      return songs
    } catch (err) {
      Logger.error(TAG, `pickAudioFiles error: ${JSON.stringify(err)}`)
      return []
    }
  }

  private async persistUris(uris: string[]): Promise<void> {
    if (!canIUse('SystemCapability.FileManagement.AppFileService.FolderAuthorization')) {
      Logger.info(TAG, 'persistUris: FolderAuthorization not supported on this device')
      return
    }
    try {
      const policies: fileShare.PolicyInfo[] = []
      for (let i = 0; i < uris.length; i++) {
        const policyInfo: fileShare.PolicyInfo = {
          uri: uris[i],
          operationMode: fileShare.OperationMode.READ_MODE,
        }
        policies.push(policyInfo)
      }
      await fileShare.persistPermission(policies)
      Logger.info(TAG, 'persistUris: persistPermission success')
    } catch (err) {
      Logger.error(TAG, `persistUris: persistPermission failed: ${JSON.stringify(err)}`)
    }
  }

  public async pickFolder(context: common.UIAbilityContext): Promise<FolderInfo | null> {
    try {
      const options: picker.DocumentSelectOptions = new picker.DocumentSelectOptions()
      const docPicker: picker.DocumentViewPicker = new picker.DocumentViewPicker(context)
      const uris: string[] = await docPicker.select(options)
      if (uris.length === 0) {
        return null
      }
      const folderUri: string = uris[0]
      const folder: FolderInfo = FolderInfo.fromPath(folderUri)
      Logger.info(TAG, `picked folder: ${folderUri}`)
      return folder
    } catch (err) {
      Logger.error(TAG, `pickFolder error: ${JSON.stringify(err)}`)
      return null
    }
  }

  private getFileNameFromUri(uri: string): string {
    // Handle content:// URIs by extracting the display name portion
    // Also handle file:// and raw paths
    const decoded: string = decodeURIComponent(uri)
    const lastSlash: number = decoded.lastIndexOf('/')
    const lastBackslash: number = decoded.lastIndexOf('\\')
    const sepIdx: number = lastSlash > lastBackslash ? lastSlash : lastBackslash
    if (sepIdx >= 0) {
      const namePart: string = decoded.substring(sepIdx + 1)
      // Strip query params if any
      const queryIdx: number = namePart.indexOf('?')
      if (queryIdx > 0) {
        return namePart.substring(0, queryIdx)
      }
      return namePart
    }
    return uri
  }
}
