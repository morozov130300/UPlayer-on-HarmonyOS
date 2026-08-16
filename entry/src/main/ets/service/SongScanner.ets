import { picker, fileIo as fs } from '@kit.CoreFileKit'
import { common } from '@kit.AbilityKit'
import { SongInfo } from '../model/SongInfo'
import { FolderInfo } from '../model/FolderInfo'
import { DataService } from './DataService'
import Logger from '../common/utils/Logger'

const TAG = 'SongScanner'

const AUDIO_EXTENSIONS: string[] = ['.mp3', '.flac', '.wav', '.aac', '.m4a', '.ogg', '.wma', '.ape']

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
      for (let i = 0; i < uris.length; i++) {
        const uri: string = uris[i]
        const fileName: string = this.getFileNameFromUri(uri)
        if (this.isAudioFile(fileName)) {
          const song: SongInfo = SongInfo.fromFile(uri, fileName)
          songs.push(song)
        }
      }
      Logger.info(TAG, `picked ${songs.length} audio files`)
      return songs
    } catch (err) {
      Logger.error(TAG, `pickAudioFiles error: ${JSON.stringify(err)}`)
      return []
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
    const lastSlash: number = uri.lastIndexOf('/')
    const lastBackslash: number = uri.lastIndexOf('\\')
    const sepIdx: number = lastSlash > lastBackslash ? lastSlash : lastBackslash
    if (sepIdx >= 0) {
      return uri.substring(sepIdx + 1)
    }
    return uri
  }
}
