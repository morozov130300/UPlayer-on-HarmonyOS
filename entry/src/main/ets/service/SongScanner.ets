import { picker, fileIo as fs, fileShare } from '@kit.CoreFileKit'
import { common } from '@kit.AbilityKit'
import { SongInfo } from '../model/SongInfo'
import { FolderInfo } from '../model/FolderInfo'
import { DataService, AUDIO_EXTENSIONS } from './DataService'
import { AudioMetadataService } from './AudioMetadataService'
import { applyMetadataToSong, extractSongMetadata } from './MetadataTask'
import { AppStorageKeyConstants } from '../common/constants/AppStorageKeyConstants'
import Logger from '../common/utils/Logger'

const TAG = 'SongScanner'

// TaskPool 并发提取的工人数：过多会挤占 fd 与 CPU，4 路已能充分并行
const METADATA_CONCURRENCY: number = 4

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
      Logger.info(TAG, `picker returned ${uris.length} URIs`)
      const allUrisToPersist: string[] = []
      for (let i = 0; i < uris.length; i++) {
        const uri: string = uris[i]
        const fileName: string = this.getFileNameFromUri(uri)
        const isAudio: boolean = this.isAudioFile(fileName)
        if (isAudio) {
          const song: SongInfo = SongInfo.fromFile(uri, fileName)
          songs.push(song)
          allUrisToPersist.push(uri)
        }
      }
      // 歌词存在性检查：异步 access 并发执行，避免主线程串行阻塞
      const lyricChecks: Promise<boolean>[] = []
      for (let i = 0; i < songs.length; i++) {
        lyricChecks.push(this.checkLyricExists(songs[i]))
      }
      const lyricResults: boolean[] = await Promise.all(lyricChecks)
      for (let i = 0; i < songs.length; i++) {
        if (lyricResults[i]) {
          allUrisToPersist.push(songs[i].lyricUri)
        } else {
          songs[i].lyricPath = ''
          songs[i].lyricUri = ''
        }
      }
      // 先持久化授权，再进行后台提取
      await this.persistUris(allUrisToPersist)

      if (songs.length > 0) {
        // 进度状态：导入中 / 总数 / 已完成
        AppStorage.setOrCreate(AppStorageKeyConstants.KEY_IMPORT_RUNNING, true)
        AppStorage.setOrCreate(AppStorageKeyConstants.KEY_IMPORT_TOTAL, songs.length)
        AppStorage.setOrCreate(AppStorageKeyConstants.KEY_IMPORT_DONE, 0)
        try {
          await this.extractMetadataParallel(songs)
        } finally {
          AppStorage.setOrCreate(AppStorageKeyConstants.KEY_IMPORT_DONE, songs.length)
          AppStorage.setOrCreate(AppStorageKeyConstants.KEY_IMPORT_RUNNING, false)
        }
        AudioMetadataService.getInstance().prefetchAlbumCovers(songs)
      }
      Logger.info(TAG, `picked ${songs.length} audio files`)
      return songs
    } catch (err) {
      AppStorage.setOrCreate(AppStorageKeyConstants.KEY_IMPORT_RUNNING, false)
      Logger.error(TAG, `pickAudioFiles error: ${JSON.stringify(err)}`)
      return []
    }
  }

  // TaskPool 并行提取元数据：固定工人数滚动消费队列，每完成一首更新进度
  private async extractMetadataParallel(songs: SongInfo[]): Promise<void> {
    let nextIndex: number = 0
    let doneCount: number = 0
    const worker = async (): Promise<void> => {
      let index: number = nextIndex
      nextIndex++
      while (index < songs.length) {
        const song: SongInfo = songs[index]
        const sourceUri: string = song.uri.length > 0 ? song.uri : song.filePath
        const record: Record<string, string> | undefined = await extractSongMetadata(sourceUri)
        if (record !== undefined) {
          applyMetadataToSong(song, record)
        }
        doneCount++
        AppStorage.setOrCreate(AppStorageKeyConstants.KEY_IMPORT_DONE, doneCount)
        index = nextIndex
        nextIndex++
      }
    }
    const workerCount: number = Math.min(METADATA_CONCURRENCY, songs.length)
    const workers: Promise<void>[] = []
    for (let i = 0; i < workerCount; i++) {
      workers.push(worker())
    }
    await Promise.all(workers)
  }

  private async checkLyricExists(song: SongInfo): Promise<boolean> {
    if (song.lyricUri.length === 0) {
      return false
    }
    try {
      await fs.access(song.lyricUri)
      return true
    } catch (err) {
      return false
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
