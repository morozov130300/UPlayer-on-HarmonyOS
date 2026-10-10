import { picker, fileShare } from '@kit.CoreFileKit'
import { common } from '@kit.AbilityKit'
import { SongInfo } from '../model/SongInfo'
import { FolderInfo } from '../model/FolderInfo'
import { AUDIO_EXTENSIONS, DataService, ImportResult } from './DataService'
import { AudioMetadataService } from './AudioMetadataService'
import { applyMetadataToSong, extractSongMetadata } from './MetadataTask'
import { AppStorageKeyConstants } from '../common/constants/AppStorageKeyConstants'
import { LyricFile } from '../common/constants/LyricConst'
import Logger from '../common/utils/Logger'

const TAG = 'SongScanner'

// TaskPool 并发提取的工人数：PC 多核收益明显，6 路在 fd/CPU 占用与吞吐间平衡
const METADATA_CONCURRENCY: number = 6
// 增量流式入库的批大小：每提取完这么多首回调一次 onBatch 入库刷新列表
const IMPORT_BATCH_SIZE: number = 8

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

  // onBatch：增量流式入库回调。提供时，每提取完 IMPORT_BATCH_SIZE 首（含结尾尾批）回调一次，
  // 每首歌恰通过回调交付一次，调用方不得再对返回值整体 addSongs；
  // 不提供时行为与旧版一致（全部提取完一次性返回，由调用方自行入库）。
  public async pickAudioFiles(context: common.UIAbilityContext,
    onBatch?: (batch: SongInfo[]) => void): Promise<SongInfo[]> {
    try {
      const options: picker.DocumentSelectOptions = new picker.DocumentSelectOptions()
      const docPicker: picker.DocumentViewPicker = new picker.DocumentViewPicker(context)
      const uris: string[] = await docPicker.select(options)
      if (uris.length === 0) {
        return []
      }
      const songs: SongInfo[] = []
      Logger.info(TAG, `picker returned ${uris.length} URIs`)
      // 按 README 约定，导入时用户会同时选中与歌曲同名的 .lrc/.krc。
      // 用「解码后去掉扩展名的完整路径（小写）」做配对键，直接命中用户实际授权的那一个文件，
      // 而不是靠字符串拼接去撞运气（旧实现用派生路径 + fs.access，中文/空格/大小写都会失配，
      // 且 fs.access 对 picker docs URI 本身就不可靠）。
      const lyricUriByKey: Map<string, string> = new Map<string, string>()
      const allUrisToPersist: string[] = []
      for (let i = 0; i < uris.length; i++) {
        const uri: string = uris[i]
        const fileName: string = this.getFileNameFromUri(uri)
        if (this.isAudioFile(fileName)) {
          songs.push(SongInfo.fromFile(uri, fileName))
        } else if (this.isLyricFile(fileName)) {
          lyricUriByKey.set(this.lyricMatchKey(uri), uri)
        }
      }
      // 歌词绑定：只匹配本次显式选中的同名歌词文件
      for (let i = 0; i < songs.length; i++) {
        this.attachLyric(songs[i], lyricUriByKey)
      }
      for (let i = 0; i < songs.length; i++) {
        allUrisToPersist.push(songs[i].uri)
        if (songs[i].lyricUri.length > 0) {
          allUrisToPersist.push(songs[i].lyricUri)
        }
      }
      if (songs.length > 0) {
        // 进度状态：导入中 / 总数 / 已完成。
        // 浮层必须在授权持久化之前出现：persistUris 随文件数线性变慢（实测约 300ms/16 个 URI），
        // 若先授权再亮浮层，picker 确认后会有一段完全无反馈的空窗
        AppStorage.setOrCreate(AppStorageKeyConstants.KEY_IMPORT_RUNNING, true)
        AppStorage.setOrCreate(AppStorageKeyConstants.KEY_IMPORT_TOTAL, songs.length)
        AppStorage.setOrCreate(AppStorageKeyConstants.KEY_IMPORT_DONE, 0)
        try {
          // 先持久化授权，再进行后台提取
          await this.persistUris(allUrisToPersist)
          await this.extractMetadataParallel(songs, onBatch)
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

  // TaskPool 并行提取元数据：固定工人数滚动消费队列，每完成一首更新进度；
  // 提供 onBatch 时按 IMPORT_BATCH_SIZE 攒批回调，让调用方边提取边入库边刷新列表。
  // batchBuffer 仅在主线程事件循环内读写（worker 回调 resolve 在主线程），无并发问题
  private async extractMetadataParallel(songs: SongInfo[],
    onBatch?: (batch: SongInfo[]) => void): Promise<void> {
    let nextIndex: number = 0
    let doneCount: number = 0
    const batchBuffer: SongInfo[] = []
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
        batchBuffer.push(song)
        if (batchBuffer.length >= IMPORT_BATCH_SIZE) {
          this.flushBatch(batchBuffer, onBatch)
        }
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
    this.flushBatch(batchBuffer, onBatch)
  }

  // 攒批交付：满批或收尾时把缓冲区整体交给 onBatch（splice 清空复用）
  private flushBatch(batchBuffer: SongInfo[], onBatch?: (batch: SongInfo[]) => void): void {
    if (onBatch !== undefined && batchBuffer.length > 0) {
      onBatch(batchBuffer.splice(0))
    }
  }

  // 三个导入入口（首页加号/歌单页加号/全局悬浮加号）的统一导入流程：
  // 选歌 → 分批提取 → 每批入库（两页列表经 KEY_LIBRARY_REVISION 的 @Watch 自动逐批刷新）→ 汇总计数。
  // pickAudioFiles 异常中断时，已完成批次均已入库，计数如实返回
  public async importSongs(context: common.UIAbilityContext,
    dataService: DataService): Promise<ImportResult> {
    const total: ImportResult = new ImportResult()
    await this.pickAudioFiles(context, (batch: SongInfo[]): void => {
      const result: ImportResult = dataService.addSongs(batch)
      total.newCount += result.newCount
      total.dupCount += result.dupCount
    })
    return total
  }

  private isLyricFile(fileName: string): boolean {
    const lower: string = fileName.toLowerCase()
    return lower.endsWith(LyricFile.LRC) || lower.endsWith(LyricFile.KRC)
  }

  // 配对键：解码后的「目录 + 文件名（去扩展名）」，统一小写以容忍大小写差异。
  // 必须保留目录部分，避免把不同文件夹里的同名文件错配到一起。
  private lyricMatchKey(uri: string): string {
    const decoded: string = decodeURIComponent(uri)
    const dotIdx: number = decoded.lastIndexOf('.')
    const base: string = dotIdx > 0 ? decoded.substring(0, dotIdx) : decoded
    return base.toLowerCase()
  }

  // 歌词绑定：只认用户在本次选择中「显式选中的同名歌词文件」，不做任何同目录推导或探测。
  // 推导出来的引用一旦失效，运行期无法判断失效原因，只会让「有没有歌词」变成不可靠的猜测。
  private attachLyric(song: SongInfo, lyricUriByKey: Map<string, string>): void {
    const matched: string | undefined = lyricUriByKey.get(this.lyricMatchKey(song.uri))
    if (matched !== undefined) {
      song.lyricUri = matched
      song.lyricPath = decodeURIComponent(matched)
      return
    }
    // 未选中同名歌词文件：清掉 fromFile 的乐观派生值（那个 .lrc 未必真的存在），
    // 避免在数据库里留下一个打不开的假引用。
    // 已有歌曲上原有的有效引用由 addSongs 的非空覆盖规则保留，不会被这里波及。
    song.lyricPath = ''
    song.lyricUri = ''
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
