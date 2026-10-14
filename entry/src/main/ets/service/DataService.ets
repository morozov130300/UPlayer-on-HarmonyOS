import { SongInfo } from '../model/SongInfo'
import { FolderInfo } from '../model/FolderInfo'
import { PreferencesUtil } from '../common/utils/PreferencesUtil'
import { AppStorageKeyConstants } from '../common/constants/AppStorageKeyConstants'
import { common } from '@kit.AbilityKit'
import { fileIo as fs, fileShare } from '@kit.CoreFileKit'
import { SongDatabase } from './SongDatabase'
import Logger from '../common/utils/Logger'
import { BusinessError } from '@kit.BasicServicesKit'
import { MusicPlayMode } from '../common/constants/PlayerConstants'
import { AudioMetadataService } from './AudioMetadataService'
import { clearLyricCache } from './LyricLoader'

const TAG = 'DataService'

const KEY_FOLDER_LIST: string = 'uplayer_folder_list'
const KEY_SETTINGS: string = 'uplayer_settings'
const KEY_SORT_MODE: string = 'uplayer_sort_mode'
const KEY_VIEW_MODE: string = 'uplayer_view_mode'
const KEY_FILTER_STATE: string = 'uplayer_filter_state'
const KEY_SELECTED_FOLDERS: string = 'uplayer_selected_folders'
const KEY_FAVORITES_SELECTED: string = 'uplayer_favorites_selected'
const KEY_PLAY_NEXT_QUEUE: string = 'uplayer_play_next_queue'
const KEY_PLAY_MODE: string = 'uplayer_play_mode'
const EQUALIZER_MIN_GAIN_DB: number = -10
const EQUALIZER_MAX_GAIN_DB: number = 10

export const AUDIO_EXTENSIONS: string[] = [
  '.mp3', '.flac', '.wav', '.aac', '.m4a', '.ogg', '.wma', '.ape',
  '.opus', '.aiff', '.aif', '.alac', '.dsf', '.dff', '.wv', '.tta',
  '.mp2', '.mpa', '.mpeg', '.mpc', '.ac3', '.eac3', '.dts', '.ra',
  '.amr', '.awb', '.mid', '.midi', '.xmf', '.rtttl', '.smaf', '.imy',
  '.3gp', '.3g2', '.webm', '.mka'
]

export class ImportResult {
  newCount: number = 0
  dupCount: number = 0
}

export class LibraryDeleteResult {
  removedSongIds: string[] = []
  currentSongRemoved: boolean = false
  currentSongIndex: number = -1
}

class FilterStateRecord {
  selectedFolderPaths: string[] = []
  favoritesSelected: boolean = false
}

export class AppSettingsData {
  plusButtonScrollHide: boolean = true
  themeMode: string = 'system'
  primaryColor: string = '#007DFF'
  eqEnabled: boolean = false
  eqBands: number[] = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
  // OHAudioSuite 系统音效：声场/环境/美声/空间渲染（类型值 1-4；空间渲染模式 0=摆位 1=旋转 2=扩展）
  soundFieldEnabled: boolean = false
  soundFieldType: number = 1
  environmentEnabled: boolean = false
  environmentType: number = 1
  beautifierEnabled: boolean = false
  beautifierType: number = 1
  spaceRenderEnabled: boolean = false
  spaceRenderMode: number = 0
  spaceRenderValues: number[] = [0, 0, 0]
  // 通用变声（主链内）：类型 1-10
  generalVoiceChangeEnabled: boolean = false
  generalVoiceChangeType: number = 1
  // 降噪（无参数）
  noiseReductionEnabled: boolean = false
  // 传统变声：性别 1=女 2=男，类型 1-7，音调 0=系统推荐 / [0.3,3.0] 自定义
  pureVoiceChangeEnabled: boolean = false
  pureVoiceChangeGender: number = 1
  pureVoiceChangeType: number = 1
  pureVoiceChangePitch: number = 0
  // 变速变调：速度 [0.5,10.0]，音调 [0.1,5.0]
  tempoPitchEnabled: boolean = false
  tempoSpeed: number = 1
  tempoPitch: number = 1
  // 音源分离：输出 1=仅人声 2=仅伴奏 3=混合
  separationEnabled: boolean = false
  separationOutput: number = 1
  playSpeed: number = 1
  folderSortMode: string = 'name'
  fadeInOut: boolean = false
  // 耳机/蓝牙等输出设备断开时是否继续播放（系统默认路由到扬声器）；关闭则断开时自动暂停并提示
  continuePlayOnHeadsetUnplug: boolean = false
  // 通知/提示音响起时保持本应用音量不被系统压低（AudioSession 并发策略，默认关）
  ignoreNotificationDuck: boolean = false
  fontSizeScale: number = 1.0
  displaySizeScale: number = 1.0
  tabStyle: string = 'classic'
  glassBlurStrength: number = 25
  homeTopBlurStrength: number = 25
  tabIndicatorOpacity: number = 50
  // 质感握姿：开启后系统根据单手握持方向自动让首页顶部模糊预览/控件靠左或靠右
  holdingHandEnabled: boolean = true
  // 底部栏点击/拖动指示器风格：light=跟手光效，mask=白色蒙版，off=关闭
  // mask 仅在有鼠标/触控板的设备上提供（设置页按检测结果显隐开关，无鼠标时降级为 off）
  tabTouchIndicator: string = 'light'
  // 跟手光效颜色：white=白光，theme=主题色光
  tabLightColor: string = 'theme'
  }

export class DataService {
  private static instance: DataService = new DataService()
  private songsCache: SongInfo[] | undefined = undefined
  // 拖拽重排等高频更新场景下，延迟并合并磁盘写入，降低擦写次数
  private saveSongsTimer: number = -1
  private pendingSongs: SongInfo[] | undefined = undefined
  private readonly SAVE_SONGS_DEBOUNCE_MS: number = 300
  // 数据库快照：记录已落库的行内容，flush 时做增量 diff（新增 INSERT / 变更 UPDATE / 删除 DELETE）
  private dbSnapshot: Map<string, SongInfo> = new Map<string, SongInfo>()
  private flushInFlight: boolean = false
  private flushQueued: boolean = false
  // initToAppStorage 幂等标志：EntryAbility 与页面都会调用，重复执行会重复跑可访问性检查
  private appStorageInitialized: boolean = false
  // 文件夹列表 RDB 缓存：init() 完成前 getFolders 返回空列表
  private foldersCache: FolderInfo[] | undefined = undefined
  private saveFoldersChain: Promise<void> = Promise.resolve()
  // activatePersistedUris 幂等标志：曲库缓存未就绪时跳过（等 init 完成后由 init 补跑），
  // 已执行过一次后不再重复，避免可访问性检查跑两遍制造授权竞态
  private persistedUrisActivated: boolean = false
  // 曲库加载失败标志：init() 异常时置位。init 降级会把 songsCache 置空以便放行授权激活与封面门禁，
  // 但「加载失败」与「曲库为空」在缓存里长得一样。pruneFilterAndFolders 必须靠本标志区分二者，
  // 否则一次读取失败就会被当成"文件夹都不存在"从而清空 folders 表
  private libraryLoadFailed: boolean = false

  public static getInstance(): DataService {
    return DataService.instance
  }

  // 初始化曲库数据库并加载全量歌曲到内存缓存；EntryAbility 在 UI 加载前调用
  public async init(context: common.UIAbilityContext): Promise<void> {
    this.libraryLoadFailed = false
    try {
      await SongDatabase.getInstance().init(context)
      const songs: SongInfo[] = await SongDatabase.getInstance().queryAllSongs()
      this.songsCache = songs
      const snapshot: Map<string, SongInfo> = new Map<string, SongInfo>()
      for (let i = 0; i < songs.length; i++) {
        snapshot.set(songs[i].id, this.cloneSong(songs[i]))
      }
      this.dbSnapshot = snapshot
      await this.initFolders()
      // init 完成后缓存已就绪：收敛历史脏筛选状态（initToAppStorage 可能先于 init 完成，
      // 之前因缓存未就绪被守卫跳过），保证启动后胶囊不残留已删文件夹
      this.pruneFilterAndFolders(songs)
      // UI 可能已在 init 完成前加载（开屏超时降级路径）：bump 修订号让首页/歌单
      // 经 @Watch(KEY_LIBRARY_REVISION) 自动重载；补跑授权激活（降级路径下
      // initToAppStorage 先执行时被「缓存未就绪」守卫跳过）
      this.bumpLibraryRevision()
      void this.activatePersistedUris()
      Logger.info(TAG, `init: loaded ${songs.length} songs from database`)
    } catch (err) {
      this.songsCache = []
      this.dbSnapshot = new Map<string, SongInfo>()
      // 加载失败：置位标志，pruneFilterAndFolders 据此拒绝收敛（缓存被置空只是为放行授权激活与封面门禁，
      // 不代表曲库真的为空）
      this.libraryLoadFailed = true
      // 失败同样可能发生在降级路径（initToAppStorage 已先跑完）：缓存已置空即可就绪，
      // 补跑一次授权激活，放行 notifyFileAccessReady 封面门禁
      void this.activatePersistedUris()
      Logger.error(TAG, `init failed: ${JSON.stringify(err)}`)
    }
  }

  // 从 folders 表加载文件夹列表到内存缓存
  private async initFolders(): Promise<void> {
    try {
      this.foldersCache = await SongDatabase.getInstance().queryAllFolders()
    } catch (err) {
      Logger.error(TAG, `initFolders failed: ${JSON.stringify(err)}`)
    }
  }

  // 立即把暂存的歌曲列表增量写入数据库（幂等，可安全多次调用）
  flushPendingSongWrites(): void {
    if (this.saveSongsTimer !== -1) {
      clearTimeout(this.saveSongsTimer)
      this.saveSongsTimer = -1
    }
    if (this.pendingSongs === undefined) {
      return
    }
    void this.doFlushSongWrites()
  }

  // 增量落库：与数据库快照 diff，只写有变化的行，禁止全表重写
  private async doFlushSongWrites(): Promise<void> {
    if (this.flushInFlight) {
      this.flushQueued = true
      return
    }
    this.flushInFlight = true
    const current: SongInfo[] | undefined = this.pendingSongs
    this.pendingSongs = undefined
    try {
      if (current !== undefined) {
        const inserts: SongInfo[] = []
        const updates: SongInfo[] = []
        const currentIds: Set<string> = new Set<string>()
        for (let i = 0; i < current.length; i++) {
          currentIds.add(current[i].id)
          const snapshotRow: SongInfo | undefined = this.dbSnapshot.get(current[i].id)
          if (snapshotRow === undefined) {
            inserts.push(current[i])
          } else if (!this.songEquals(snapshotRow, current[i])) {
            updates.push(current[i])
          }
        }
        const deletes: string[] = []
        this.dbSnapshot.forEach((snapshotRow: SongInfo, id: string) => {
          if (!currentIds.has(id)) {
            deletes.push(id)
          }
        })
        const db: SongDatabase = SongDatabase.getInstance()
        await db.insertSongs(inserts)
        await db.updateSongs(updates)
        await db.deleteSongsByIds(deletes)
        const snapshot: Map<string, SongInfo> = new Map<string, SongInfo>()
        for (let i = 0; i < current.length; i++) {
          snapshot.set(current[i].id, this.cloneSong(current[i]))
        }
        this.dbSnapshot = snapshot
        if (inserts.length > 0 || updates.length > 0 || deletes.length > 0) {
          Logger.info(TAG, `flush: +${inserts.length} ~${updates.length} -${deletes.length} rows`)
          // 有实际写入才收敛 WAL：把只增不减的 wal 文件 TRUNCATE 回最小体积（异步、失败只记日志）
          void db.checkpoint()
        }
      }
    } catch (err) {
      Logger.error(TAG, `flush song writes failed: ${JSON.stringify(err)}`)
    } finally {
      this.flushInFlight = false
      if (this.flushQueued) {
        this.flushQueued = false
        void this.doFlushSongWrites()
      }
    }
  }

  private cloneSong(song: SongInfo): SongInfo {
    const copy: SongInfo = new SongInfo()
    copy.id = song.id
    copy.name = song.name
    copy.title = song.title
    copy.artist = song.artist
    copy.album = song.album
    copy.filePath = song.filePath
    copy.uri = song.uri
    copy.fileName = song.fileName
    copy.folderPath = song.folderPath
    copy.folderName = song.folderName
    copy.duration = song.duration
    copy.bitrate = song.bitrate
    copy.sampleRate = song.sampleRate
    copy.addedTime = song.addedTime
    copy.sortOrder = song.sortOrder
    copy.isFavorite = song.isFavorite
    copy.isAvailable = song.isAvailable
    copy.lyricPath = song.lyricPath
    copy.lyricUri = song.lyricUri
    copy.genre = song.genre
    copy.year = song.year
    copy.track = song.track
    copy.disc = song.disc
    copy.comment = song.comment
    copy.composer = song.composer
    copy.conductor = song.conductor
    copy.albumArtist = song.albumArtist
    copy.author = song.author
    copy.language = song.language
    copy.mimeType = song.mimeType
    copy.dateTime = song.dateTime
    copy.encoder = song.encoder
    copy.description = song.description
    copy.hasAudio = song.hasAudio
    copy.hasVideo = song.hasVideo
    copy.videoWidth = song.videoWidth
    copy.videoHeight = song.videoHeight
    copy.channels = song.channels
    copy.bitDepth = song.bitDepth
    copy.codec = song.codec
    copy.trackCount = song.trackCount
    copy.fileSize = song.fileSize
    return copy
  }

  private songEquals(a: SongInfo, b: SongInfo): boolean {
    return a.id === b.id && a.name === b.name && a.title === b.title && a.artist === b.artist &&
      a.album === b.album && a.filePath === b.filePath && a.uri === b.uri && a.fileName === b.fileName &&
      a.folderPath === b.folderPath && a.folderName === b.folderName && a.duration === b.duration &&
      a.bitrate === b.bitrate && a.sampleRate === b.sampleRate && a.addedTime === b.addedTime &&
      a.sortOrder === b.sortOrder && a.isFavorite === b.isFavorite && a.isAvailable === b.isAvailable &&
      a.lyricPath === b.lyricPath && a.lyricUri === b.lyricUri && a.genre === b.genre && a.year === b.year &&
      a.track === b.track && a.disc === b.disc && a.comment === b.comment && a.composer === b.composer &&
      a.conductor === b.conductor && a.albumArtist === b.albumArtist && a.author === b.author &&
      a.language === b.language && a.mimeType === b.mimeType && a.dateTime === b.dateTime &&
      a.encoder === b.encoder && a.description === b.description && a.hasAudio === b.hasAudio &&
      a.hasVideo === b.hasVideo && a.videoWidth === b.videoWidth && a.videoHeight === b.videoHeight &&
      a.channels === b.channels && a.bitDepth === b.bitDepth && a.codec === b.codec &&
      a.trackCount === b.trackCount && a.fileSize === b.fileSize
  }

  private scheduleSaveSongs(songs: SongInfo[]): void {
    // 内存缓存与 AppStorage 同步立即生效；仅磁盘写做防抖合并
    this.songsCache = songs
    AppStorage.setOrCreate(AppStorageKeyConstants.KEY_SONG_LIST, songs.slice())
    const revision: number = AppStorage.get<number>(AppStorageKeyConstants.KEY_LIBRARY_REVISION) ?? 0
    AppStorage.setOrCreate(AppStorageKeyConstants.KEY_LIBRARY_REVISION, revision + 1)
    this.pendingSongs = songs
    if (this.saveSongsTimer !== -1) {
      clearTimeout(this.saveSongsTimer)
    }
    this.saveSongsTimer = setTimeout(() => {
      this.saveSongsTimer = -1
      this.flushPendingSongWrites()
    }, this.SAVE_SONGS_DEBOUNCE_MS)
  }

  private getPref(): PreferencesUtil {
    return PreferencesUtil.getInstance()
  }

  // ═══════════ Song serialization ═══════════
  // 歌曲 ↔ 数据库行 的转换由 SongDatabase 负责

  // ═══════════ Song CRUD ═══════════

  getSongs(): SongInfo[] {
    if (this.songsCache !== undefined) {
      return this.songsCache
    }
    // 数据库初始化完成前返回空列表；init() 完成后缓存始终可用
    return []
  }

  // 按 id 在完整曲库中查找歌曲；播放中歌曲可能被过滤条件踢出 KEY_SONG_LIST（可见队列），
  // 因此查找必须基于全量曲库缓存，而非 AppStorage 中的列表
  getSongById(songId: string): SongInfo | undefined {
    if (songId.length === 0) {
      return undefined
    }
    const songs: SongInfo[] = this.getSongs()
    for (let i = 0; i < songs.length; i++) {
      if (songs[i].id === songId) {
        return songs[i]
      }
    }
    return undefined
  }

  // 统一的「按 id 解析当前播放歌曲」：先在调用方持有的列表（通常是 KEY_SONG_LIST 渲染队列，
  // 保持对其的渲染依赖，曲库整体刷新时同步重渲染）中查找，被过滤掉时回退全量曲库，最终回退空对象。
  static currentSongFromList(songList: SongInfo[], songId: string): SongInfo {
    if (songList !== undefined) {
      for (let i = 0; i < songList.length; i++) {
        if (songList[i].id === songId) {
          return songList[i]
        }
      }
    }
    const song: SongInfo | undefined = DataService.getInstance().getSongById(songId)
    return song !== undefined ? song : new SongInfo()
  }

  saveSongs(songs: SongInfo[]): void {
    this.scheduleSaveSongs(songs)
  }

  // 拖拽重排专用：仅更新内存缓存与磁盘（防抖合并），不 bump KEY_LIBRARY_REVISION，
  // 避免首页列表在拖拽过程中被 @Watch 触发整体 reload 而闪烁/跳动。
  saveSongsNoReload(songs: SongInfo[]): void {
    this.songsCache = songs
    AppStorage.setOrCreate(AppStorageKeyConstants.KEY_SONG_LIST, songs.slice())
    this.pendingSongs = songs
    if (this.saveSongsTimer !== -1) {
      clearTimeout(this.saveSongsTimer)
    }
    this.saveSongsTimer = setTimeout(() => {
      this.saveSongsTimer = -1
      this.flushPendingSongWrites()
    }, this.SAVE_SONGS_DEBOUNCE_MS)
  }

  addSongs(newSongs: SongInfo[]): ImportResult {
    const songs: SongInfo[] = this.getSongs()
    const existingIndexes: Map<string, number> = new Map<string, number>()
    for (let i = 0; i < songs.length; i++) {
      existingIndexes.set(songs[i].filePath, i)
    }
    // 新歌曲追加到自定义排序末尾：取当前最大 sortOrder 的下一个值，批量导入连续编号
    let nextSortOrder: number = 1
    for (let i = 0; i < songs.length; i++) {
      if (songs[i].sortOrder >= nextSortOrder) {
        nextSortOrder = songs[i].sortOrder + 1
      }
    }
const result: ImportResult = new ImportResult()
    let lyricChanged: boolean = false
    for (let i: number = 0; i < newSongs.length; i++) {
      const existingIndex: number | undefined = existingIndexes.get(newSongs[i].filePath)
      if (existingIndex !== undefined) {
        songs[existingIndex].title = newSongs[i].title
        songs[existingIndex].artist = newSongs[i].artist
        songs[existingIndex].album = newSongs[i].album
        songs[existingIndex].duration = newSongs[i].duration
        songs[existingIndex].uri = newSongs[i].uri
        // 重新导入时同步歌词路径（含用户选中的 .lrc/.krc 配对结果）。
        // 仅在本次扫描确实解析出歌词时才覆盖：若本次未选中歌词文件，
        // 必须保留数据库里已存的引用，否则会把有效歌词引用抹掉（历史丢歌词的路径之一）
        if (newSongs[i].lyricUri.length > 0 || newSongs[i].lyricPath.length > 0) {
          songs[existingIndex].lyricPath = newSongs[i].lyricPath
          songs[existingIndex].lyricUri = newSongs[i].lyricUri
          lyricChanged = true
        }
        songs[existingIndex].isAvailable = true
        result.dupCount++
      } else {
        newSongs[i].sortOrder = nextSortOrder
        nextSortOrder++
        existingIndexes.set(newSongs[i].filePath, songs.length)
        songs.push(newSongs[i])
        result.newCount++
      }
    }
    this.saveSongs(songs)
    if (lyricChanged) {
      this.bumpLyricRevision()
    }
return result
  }

  // 统一的歌曲删除入口：与 removeSongsByFolders 相同的全链路清理
  // （播放队列 / 筛选状态 / 文件夹列表 / 当前播放），主页多选删除必须走这里，
  // 否则删除后筛选胶囊、folders 缓存等会残留已删文件夹
  removeSongsByIds(ids: string[]): LibraryDeleteResult {
    const result: LibraryDeleteResult = new LibraryDeleteResult()
    if (ids.length === 0) {
      return result
    }
    const idSet: Set<string> = new Set<string>()
    for (let i = 0; i < ids.length; i++) {
      idSet.add(ids[i])
    }
    const songs: SongInfo[] = this.getSongs()
    const currentPath: string = AppStorage.get<string>('uplayer_current_song_path') ?? ''
    let currentSongId: string = ''
    for (let i = 0; i < songs.length; i++) {
      if (songs[i].filePath === currentPath) {
        currentSongId = songs[i].id
        break
      }
    }
    const remainingSongs: SongInfo[] = []
    const removedIds: Set<string> = new Set<string>()
    for (let i = 0; i < songs.length; i++) {
      if (idSet.has(songs[i].id)) {
        result.removedSongIds.push(songs[i].id)
        removedIds.add(songs[i].id)
      } else {
        remainingSongs.push(songs[i])
      }
    }
    if (result.removedSongIds.length === 0) {
      return result
    }
    const queue: string[] = this.getPlayNextQueue()
    const remainingQueue: string[] = []
    for (let i = 0; i < queue.length; i++) {
      if (!removedIds.has(queue[i])) {
        remainingQueue.push(queue[i])
      }
    }
    this.setPlayNextQueue(remainingQueue)
    this.pruneFilterAndFolders(remainingSongs)
    result.currentSongRemoved = currentSongId.length > 0 && removedIds.has(currentSongId)
    if (!result.currentSongRemoved && currentSongId.length > 0) {
      for (let i = 0; i < remainingSongs.length; i++) {
        if (remainingSongs[i].id === currentSongId) {
          result.currentSongIndex = i
          break
        }
      }
    }
    if (result.currentSongRemoved) {
      AppStorage.setOrCreate(AppStorageKeyConstants.KEY_SELECT_INDEX, -1)
      AppStorage.setOrCreate('uplayer_current_title', '')
      AppStorage.setOrCreate('uplayer_current_artist', '')
      AppStorage.setOrCreate('uplayer_current_song_id', '')
      AppStorage.setOrCreate('uplayer_current_cover_state', 'placeholder')
      AppStorage.setOrCreate('uplayer_current_album_art', '')
      AppStorage.setOrCreate('uplayer_current_song_path', '')
      AppStorage.setOrCreate(AppStorageKeyConstants.KEY_PROGRESS, 0)
      AppStorage.setOrCreate(AppStorageKeyConstants.KEY_PROGRESS_MAX, 0)
      AppStorage.setOrCreate(AppStorageKeyConstants.KEY_TOTAL_MS_TIME, 0)
      AppStorage.setOrCreate(AppStorageKeyConstants.KEY_CURRENT_TIME, '00:00')
      AppStorage.setOrCreate(AppStorageKeyConstants.KEY_TOTAL_TIME, '00:00')
    } else if (result.currentSongIndex >= 0) {
      AppStorage.setOrCreate(AppStorageKeyConstants.KEY_SELECT_INDEX, result.currentSongIndex)
    }
    this.saveSongs(remainingSongs)
    this.flushPendingSongWrites()
    return result
  }

  // 按剩余曲库收敛筛选状态与文件夹列表：剔除已无任何歌曲的文件夹路径。
  // 只清「空文件夹」——多文件夹筛选下部分删除不能误清仍有歌曲的选中项；
  // setSelectedFolderPaths 内部会 bump KEY_FILTER_REVISION，首页胶囊经 @Watch 自动刷新。
  // songsCache 未就绪（init 前）时不做收敛：以空曲库为基准会误清持久化的筛选状态。
  //
  // 两条拒绝收敛的判据（收敛会落盘删除 folders 表，不可逆）：
  //   1) init() 加载失败（libraryLoadFailed）：降级时 songsCache 被置空，与"曲库真空"同形，无法区分；
  //   2) 曲库非空但存在 folderPath 读不出来的歌：folderPath 由 SongDatabase.rsGetString 读取，
  //      列缺失或值为 NULL 时返回空串，此时 livePaths 会变成空集，让"文件夹全都不存在"成为误判。
  // 真正的空曲库（remainingSongs 为空）不在此列，仍按原逻辑清理，行为不变。
  private pruneFilterAndFolders(remainingSongs: SongInfo[]): void {
    if (this.songsCache === undefined || this.libraryLoadFailed) {
      return
    }
    const livePaths: Set<string> = new Set<string>()
    let missingFolderPath: number = 0
    for (let i = 0; i < remainingSongs.length; i++) {
      if (remainingSongs[i].folderPath.length > 0) {
        livePaths.add(remainingSongs[i].folderPath)
      } else {
        missingFolderPath++
      }
    }
    if (missingFolderPath > 0) {
      Logger.error(TAG, `prune skipped: folderPath unreadable songs=${remainingSongs.length}` +
        ` missing=${missingFolderPath} folders=${this.getFolders().length}`)
      return
    }
    const selectedPaths: string[] = this.getSelectedFolderPaths()
    const remainingSelected: string[] = []
    let filterChanged: boolean = false
    for (let i = 0; i < selectedPaths.length; i++) {
      if (livePaths.has(selectedPaths[i])) {
        remainingSelected.push(selectedPaths[i])
      } else {
        filterChanged = true
      }
    }
    if (filterChanged) {
      this.setSelectedFolderPaths(remainingSelected)
    }
    const folders: FolderInfo[] = this.getFolders()
    const remainingFolders: FolderInfo[] = []
    let foldersChanged: boolean = false
    for (let i = 0; i < folders.length; i++) {
      if (livePaths.has(folders[i].path)) {
        remainingFolders.push(folders[i])
      } else {
        foldersChanged = true
      }
    }
    if (foldersChanged) {
      this.saveFolders(remainingFolders)
    }
  }

  removeSongsByFolders(folderPaths: string[]): LibraryDeleteResult {
    const result: LibraryDeleteResult = new LibraryDeleteResult()
    if (folderPaths.length === 0) {
      return result
    }
    const pathSet: Set<string> = new Set<string>()
    for (let i = 0; i < folderPaths.length; i++) {
      pathSet.add(folderPaths[i])
    }
    const songs: SongInfo[] = this.getSongs()
    const currentPath: string = AppStorage.get<string>('uplayer_current_song_path') ?? ''
    let currentSongId: string = ''
    for (let i = 0; i < songs.length; i++) {
      if (songs[i].filePath === currentPath) {
        currentSongId = songs[i].id
        break
      }
    }
    const remainingSongs: SongInfo[] = []
    const removedIds: Set<string> = new Set<string>()
    for (let i = 0; i < songs.length; i++) {
      if (pathSet.has(songs[i].folderPath)) {
        result.removedSongIds.push(songs[i].id)
        removedIds.add(songs[i].id)
      } else {
        remainingSongs.push(songs[i])
      }
    }
    if (result.removedSongIds.length === 0) {
      return result
    }
    const queue: string[] = this.getPlayNextQueue()
    const remainingQueue: string[] = []
    for (let i = 0; i < queue.length; i++) {
      if (!removedIds.has(queue[i])) {
        remainingQueue.push(queue[i])
      }
    }
    this.setPlayNextQueue(remainingQueue)
    const selectedPaths: string[] = this.getSelectedFolderPaths()
    const remainingSelectedPaths: string[] = []
    for (let i = 0; i < selectedPaths.length; i++) {
      if (!pathSet.has(selectedPaths[i])) {
        remainingSelectedPaths.push(selectedPaths[i])
      }
    }
    this.setSelectedFolderPaths(remainingSelectedPaths)
    const folders: FolderInfo[] = this.getFolders()
    const remainingFolders: FolderInfo[] = []
    for (let i = 0; i < folders.length; i++) {
      if (!pathSet.has(folders[i].path)) {
        remainingFolders.push(folders[i])
      }
    }
    this.saveFolders(remainingFolders)
    result.currentSongRemoved = currentSongId.length > 0 && removedIds.has(currentSongId)
    if (!result.currentSongRemoved && currentSongId.length > 0) {
      for (let i = 0; i < remainingSongs.length; i++) {
        if (remainingSongs[i].id === currentSongId) {
          result.currentSongIndex = i
          break
        }
      }
    }
    if (result.currentSongRemoved) {
      AppStorage.setOrCreate(AppStorageKeyConstants.KEY_SELECT_INDEX, -1)
      AppStorage.setOrCreate('uplayer_current_title', '')
      AppStorage.setOrCreate('uplayer_current_artist', '')
      AppStorage.setOrCreate('uplayer_current_song_id', '')
      AppStorage.setOrCreate('uplayer_current_cover_state', 'placeholder')
      AppStorage.setOrCreate('uplayer_current_album_art', '')
      AppStorage.setOrCreate('uplayer_current_song_path', '')
      AppStorage.setOrCreate(AppStorageKeyConstants.KEY_PROGRESS, 0)
      AppStorage.setOrCreate(AppStorageKeyConstants.KEY_PROGRESS_MAX, 0)
      AppStorage.setOrCreate(AppStorageKeyConstants.KEY_TOTAL_MS_TIME, 0)
      AppStorage.setOrCreate(AppStorageKeyConstants.KEY_CURRENT_TIME, '00:00')
      AppStorage.setOrCreate(AppStorageKeyConstants.KEY_TOTAL_TIME, '00:00')
    } else if (result.currentSongIndex >= 0) {
      AppStorage.setOrCreate(AppStorageKeyConstants.KEY_SELECT_INDEX, result.currentSongIndex)
    }
    this.saveSongs(remainingSongs)
    this.flushPendingSongWrites()
    return result
  }

  toggleFavorite(songId: string): boolean {
    const songs: SongInfo[] = this.getSongs()
    let newFav: boolean = false
    for (let i = 0; i < songs.length; i++) {
      if (songs[i].id === songId) {
        songs[i].isFavorite = !songs[i].isFavorite
        newFav = songs[i].isFavorite
        break
      }
    }
    this.saveSongs(songs)
    return newFav
  }

  updateSongFields(songId: string, updatedList: SongInfo[]): void {
    const songs: SongInfo[] = updatedList
    let modified: boolean = false
    for (let i = 0; i < songs.length; i++) {
      if (songs[i].id === songId) {
        modified = true
        break
      }
    }
    if (modified) {
      this.songsCache = songs
      AppStorage.setOrCreate(AppStorageKeyConstants.KEY_SONG_LIST, songs.slice())
      this.scheduleSaveSongs(songs)
    }
  }

  // ═══════════ Folder CRUD ═══════════

  getFolders(): FolderInfo[] {
    if (this.foldersCache !== undefined) {
      return this.foldersCache
    }
    // init 未完成时返回空列表
    return []
  }

  saveFolders(folders: FolderInfo[]): void {
    this.foldersCache = folders
    // 串行化全量替换
    this.saveFoldersChain = this.saveFoldersChain.then((): Promise<void> => {
      return SongDatabase.getInstance().replaceFolders(folders)
    }).catch((err: BusinessError) => {
      Logger.error(TAG, `saveFolders to rdb failed: ${JSON.stringify(err)}`)
    })
  }

  // ═══════════ Settings ═══════════

  // 设置读取统一取值助手：持久化 JSON 由历史版本写入，可能缺键 / 类型不符 / 值非法。
  // 禁止再写 `r['x'] as T` 裸强转——历史缺陷正是 5 个字段漏了兜底，读到 undefined 后被
  // 设置页的 playSpeed.toFixed() / ColorHelper.hexToRgb().replace() 直接抛错整页崩掉。
  // 命中兜底或修正时打 warn 并带字段名与实测值，便于真机一次确认命中点。
  private pickBool(r: Record<string, Object>, key: string, def: boolean): boolean {
    const v: Object | undefined = r[key]
    if (typeof v === 'boolean') {
      return v
    }
    if (v !== undefined) {
      Logger.warn(TAG, `settings ${key} invalid(${typeof v}), fallback ${def}`)
    }
    return def
  }

  private pickNum(r: Record<string, Object>, key: string, def: number, min: number, max: number): number {
    const v: Object | undefined = r[key]
    if (typeof v !== 'number' || !Number.isFinite(v)) {
      if (v !== undefined) {
        Logger.warn(TAG, `settings ${key} invalid(${typeof v}), fallback ${def}`)
      }
      return def
    }
    const clamped: number = Math.min(max, Math.max(min, v))
    if (clamped !== v) {
      Logger.warn(TAG, `settings ${key} out of range(${v}), clamped ${clamped}`)
    }
    return clamped
  }

  private pickStr(r: Record<string, Object>, key: string, def: string): string {
    const v: Object | undefined = r[key]
    if (typeof v === 'string') {
      return v
    }
    if (v !== undefined) {
      Logger.warn(TAG, `settings ${key} invalid(${typeof v}), fallback ${def}`)
    }
    return def
  }

  // 颜色必须是 #RRGGBB：消费侧一律交给 ColorHelper.hexToRgb（内部 hex.replace('#','')），
  // 非字符串或格式不符会抛 TypeError，而 primaryColor 被设置页四个分区全部使用
  private pickColor(r: Record<string, Object>, key: string, def: string): string {
    const v: Object | undefined = r[key]
    if (typeof v === 'string' && /^#[0-9a-fA-F]{6}$/.test(v)) {
      return v
    }
    if (v !== undefined) {
      Logger.warn(TAG, `settings ${key} invalid color(${v}), fallback ${def}`)
    }
    return def
  }

  // 定长数值数组（spaceRenderValues）：非数组时整体回退默认，元素逐个校验有限性
  private pickNumArray(r: Record<string, Object>, key: string, def: number[]): number[] {
    const out: number[] = def.slice()
    const v: Object | undefined = r[key]
    if (!Array.isArray(v)) {
      if (v !== undefined) {
        Logger.warn(TAG, `settings ${key} invalid(not array), fallback [${out.join(',')}]`)
      }
      return out
    }
    const arr: Object[] = v as Object[]
    for (let i = 0; i < arr.length && i < out.length; i++) {
      const item: Object = arr[i]
      if (typeof item === 'number' && Number.isFinite(item)) {
        out[i] = item
      }
    }
    return out
  }

  getSettings(): AppSettingsData {
    const raw = this.getPref().getValue(KEY_SETTINGS)
    if (raw === undefined) {
      return new AppSettingsData()
    }
    try {
      const r: Record<string, Object> = JSON.parse(raw as string) as Record<string, Object>
      const s: AppSettingsData = new AppSettingsData()
      s.plusButtonScrollHide = this.pickBool(r, 'plusButtonScrollHide', true)
      s.themeMode = this.pickStr(r, 'themeMode', 'system')
      s.primaryColor = this.pickColor(r, 'primaryColor', '#007DFF')
      s.eqEnabled = this.pickBool(r, 'eqEnabled', false)
      let rawEqBands: Object | undefined = r['eqBands']
      let eqBandsMigrated: boolean = false
      if (rawEqBands !== undefined) {
        const bands: number[] = rawEqBands as number[]
        for (let i = 0; i < bands.length && i < 10; i++) {
          const normalized: number = Math.max(EQUALIZER_MIN_GAIN_DB,
            Math.min(EQUALIZER_MAX_GAIN_DB, Math.round(bands[i])))
          s.eqBands[i] = normalized
          eqBandsMigrated = eqBandsMigrated || normalized !== bands[i]
        }
      }
      s.playSpeed = this.pickNum(r, 'playSpeed', 1, 0.5, 3)
      let rawSoundFieldEnabled: Object | undefined = r['soundFieldEnabled']
      s.soundFieldEnabled = rawSoundFieldEnabled !== undefined ? rawSoundFieldEnabled as boolean : false
      let rawSoundFieldType: Object | undefined = r['soundFieldType']
      s.soundFieldType = rawSoundFieldType !== undefined ? rawSoundFieldType as number : 1
      let rawEnvironmentEnabled: Object | undefined = r['environmentEnabled']
      s.environmentEnabled = rawEnvironmentEnabled !== undefined ? rawEnvironmentEnabled as boolean : false
      let rawEnvironmentType: Object | undefined = r['environmentType']
      s.environmentType = rawEnvironmentType !== undefined ? rawEnvironmentType as number : 1
      let rawBeautifierEnabled: Object | undefined = r['beautifierEnabled']
      s.beautifierEnabled = rawBeautifierEnabled !== undefined ? rawBeautifierEnabled as boolean : false
      let rawBeautifierType: Object | undefined = r['beautifierType']
      s.beautifierType = rawBeautifierType !== undefined ? rawBeautifierType as number : 1
      let rawSpaceRenderEnabled: Object | undefined = r['spaceRenderEnabled']
      s.spaceRenderEnabled = rawSpaceRenderEnabled !== undefined ? rawSpaceRenderEnabled as boolean : false
      // 空间渲染模式必须是 SpaceRenderTable.MODE_DEFAULTS 的合法下标（0/1/2）：
      // 越界会让设置页 MODE_DEFAULTS[mode] 取到 undefined 再取 .length 抛错
      s.spaceRenderMode = Math.round(this.pickNum(r, 'spaceRenderMode', 0, 0, 2))
      s.spaceRenderValues = this.pickNumArray(r, 'spaceRenderValues', s.spaceRenderValues)
      let rawGeneralVoiceChangeEnabled: Object | undefined = r['generalVoiceChangeEnabled']
      s.generalVoiceChangeEnabled = rawGeneralVoiceChangeEnabled !== undefined ?
        rawGeneralVoiceChangeEnabled as boolean : false
      let rawGeneralVoiceChangeType: Object | undefined = r['generalVoiceChangeType']
      s.generalVoiceChangeType = rawGeneralVoiceChangeType !== undefined ?
        rawGeneralVoiceChangeType as number : 1
      let rawNoiseReductionEnabled: Object | undefined = r['noiseReductionEnabled']
      s.noiseReductionEnabled = rawNoiseReductionEnabled !== undefined ?
        rawNoiseReductionEnabled as boolean : false
      let rawPureVoiceChangeEnabled: Object | undefined = r['pureVoiceChangeEnabled']
      s.pureVoiceChangeEnabled = rawPureVoiceChangeEnabled !== undefined ?
        rawPureVoiceChangeEnabled as boolean : false
      let rawPureVoiceChangeGender: Object | undefined = r['pureVoiceChangeGender']
      s.pureVoiceChangeGender = rawPureVoiceChangeGender !== undefined ?
        rawPureVoiceChangeGender as number : 1
      let rawPureVoiceChangeType: Object | undefined = r['pureVoiceChangeType']
      s.pureVoiceChangeType = rawPureVoiceChangeType !== undefined ?
        rawPureVoiceChangeType as number : 1
      let rawPureVoiceChangePitch: Object | undefined = r['pureVoiceChangePitch']
      s.pureVoiceChangePitch = rawPureVoiceChangePitch !== undefined ?
        rawPureVoiceChangePitch as number : 0
      let rawTempoPitchEnabled: Object | undefined = r['tempoPitchEnabled']
      s.tempoPitchEnabled = rawTempoPitchEnabled !== undefined ? rawTempoPitchEnabled as boolean : false
      let rawTempoSpeed: Object | undefined = r['tempoSpeed']
      s.tempoSpeed = rawTempoSpeed !== undefined ? rawTempoSpeed as number : 1
      let rawTempoPitch: Object | undefined = r['tempoPitch']
      s.tempoPitch = rawTempoPitch !== undefined ? rawTempoPitch as number : 1
      let rawSeparationEnabled: Object | undefined = r['separationEnabled']
      s.separationEnabled = rawSeparationEnabled !== undefined ? rawSeparationEnabled as boolean : false
      let rawSeparationOutput: Object | undefined = r['separationOutput']
      s.separationOutput = rawSeparationOutput !== undefined ? rawSeparationOutput as number : 1
      let rawFolderSort: Object | undefined = r['folderSortMode']
      s.folderSortMode = rawFolderSort !== undefined ? rawFolderSort as string : 'name'
      let rawFadeInOut: Object | undefined = r['fadeInOut']
      s.fadeInOut = rawFadeInOut !== undefined ? rawFadeInOut as boolean : false
      let rawFontSizeScale: Object | undefined = r['fontSizeScale']
      s.fontSizeScale = rawFontSizeScale !== undefined ? rawFontSizeScale as number : 1.0
      let rawDisplaySizeScale: Object | undefined = r['displaySizeScale']
      s.displaySizeScale = rawDisplaySizeScale !== undefined ? rawDisplaySizeScale as number : 1.0
      let rawTabStyle: Object | undefined = r['tabStyle']
      s.tabStyle = rawTabStyle !== undefined ? rawTabStyle as string : 'classic'
      let rawGlassBlurStrength: Object | undefined = r['glassBlurStrength']
      s.glassBlurStrength = rawGlassBlurStrength !== undefined ? rawGlassBlurStrength as number : 25
      let rawHomeTopBlurStrength: Object | undefined = r['homeTopBlurStrength']
      s.homeTopBlurStrength = rawHomeTopBlurStrength !== undefined ? rawHomeTopBlurStrength as number : 25
      let rawTabIndicatorOpacity: Object | undefined = r['tabIndicatorOpacity']
      s.tabIndicatorOpacity = rawTabIndicatorOpacity !== undefined ? rawTabIndicatorOpacity as number : 50
      let rawHoldingHandEnabled: Object | undefined = r['holdingHandEnabled']
      s.holdingHandEnabled = rawHoldingHandEnabled !== undefined ? rawHoldingHandEnabled as boolean : true
      let rawTabTouchIndicator: Object | undefined = r['tabTouchIndicator']
      let tabTouchIndicator: string = rawTabTouchIndicator !== undefined ? rawTabTouchIndicator as string : 'light'
      // 「白色蒙版」选项已删除，底部栏触摸指示全面改为跟手光效：旧值 'mask' 迁移为 'light'
      s.tabTouchIndicator = tabTouchIndicator === 'mask' ? 'light' : tabTouchIndicator
      let rawTabLightColor: Object | undefined = r['tabLightColor']
      s.tabLightColor = rawTabLightColor !== undefined ? rawTabLightColor as string : 'theme'
      let rawContinuePlayOnHeadsetUnplug: Object | undefined = r['continuePlayOnHeadsetUnplug']
      s.continuePlayOnHeadsetUnplug = rawContinuePlayOnHeadsetUnplug !== undefined ? rawContinuePlayOnHeadsetUnplug as boolean : false
      let rawIgnoreNotificationDuck: Object | undefined = r['ignoreNotificationDuck']
      s.ignoreNotificationDuck = rawIgnoreNotificationDuck !== undefined ? rawIgnoreNotificationDuck as boolean : false
      if (eqBandsMigrated) {
        this.saveSettings(s)
      }
      return s
    } catch (e) {
      return new AppSettingsData()
    }
  }

  // immediate=false 时只写内存并走 300ms 惰性 flush，供拖动过程中逐帧调用，避免每帧落盘
  saveSettings(settings: AppSettingsData, immediate: boolean = true): void {
    const normalizedBands: number[] = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
    for (let i = 0; i < settings.eqBands.length && i < normalizedBands.length; i++) {
      normalizedBands[i] = Math.max(EQUALIZER_MIN_GAIN_DB,
        Math.min(EQUALIZER_MAX_GAIN_DB, Math.round(settings.eqBands[i])))
    }
    settings.eqBands = normalizedBands
    const r: Record<string, Object> = {}
    r['plusButtonScrollHide'] = settings.plusButtonScrollHide
    r['themeMode'] = settings.themeMode
    r['primaryColor'] = settings.primaryColor
    r['eqEnabled'] = settings.eqEnabled
    r['eqBands'] = settings.eqBands
    r['soundFieldEnabled'] = settings.soundFieldEnabled
    r['soundFieldType'] = settings.soundFieldType
    r['environmentEnabled'] = settings.environmentEnabled
    r['environmentType'] = settings.environmentType
    r['beautifierEnabled'] = settings.beautifierEnabled
    r['beautifierType'] = settings.beautifierType
    r['spaceRenderEnabled'] = settings.spaceRenderEnabled
    r['spaceRenderMode'] = settings.spaceRenderMode
    r['spaceRenderValues'] = settings.spaceRenderValues
    r['generalVoiceChangeEnabled'] = settings.generalVoiceChangeEnabled
    r['generalVoiceChangeType'] = settings.generalVoiceChangeType
    r['noiseReductionEnabled'] = settings.noiseReductionEnabled
    r['pureVoiceChangeEnabled'] = settings.pureVoiceChangeEnabled
    r['pureVoiceChangeGender'] = settings.pureVoiceChangeGender
    r['pureVoiceChangeType'] = settings.pureVoiceChangeType
    r['pureVoiceChangePitch'] = settings.pureVoiceChangePitch
    r['tempoPitchEnabled'] = settings.tempoPitchEnabled
    r['tempoSpeed'] = settings.tempoSpeed
    r['tempoPitch'] = settings.tempoPitch
    r['separationEnabled'] = settings.separationEnabled
    r['separationOutput'] = settings.separationOutput
    r['playSpeed'] = settings.playSpeed
    r['folderSortMode'] = settings.folderSortMode
    r['fadeInOut'] = settings.fadeInOut
    r['fontSizeScale'] = settings.fontSizeScale
    r['displaySizeScale'] = settings.displaySizeScale
    r['tabStyle'] = settings.tabStyle
    r['glassBlurStrength'] = settings.glassBlurStrength
    r['homeTopBlurStrength'] = settings.homeTopBlurStrength
    r['tabIndicatorOpacity'] = settings.tabIndicatorOpacity

    r['holdingHandEnabled'] = settings.holdingHandEnabled
    r['tabTouchIndicator'] = settings.tabTouchIndicator
    r['tabLightColor'] = settings.tabLightColor
    r['continuePlayOnHeadsetUnplug'] = settings.continuePlayOnHeadsetUnplug
    r['ignoreNotificationDuck'] = settings.ignoreNotificationDuck
    this.getPref().preferencesPut(KEY_SETTINGS, JSON.stringify(r), immediate)
    // 跨页实时联动只推"有独立消费键"的字段（整份 settings 对象无消费者，不再推送，避免死广播）
    AppStorage.setOrCreate('uplayer_fade_in_out', settings.fadeInOut)
    AppStorage.setOrCreate('uplayer_plus_button_scroll_hide', settings.plusButtonScrollHide)
    AppStorage.setOrCreate(AppStorageKeyConstants.KEY_CONTINUE_PLAY_ON_UNPLUG, settings.continuePlayOnHeadsetUnplug)
    AppStorage.setOrCreate(AppStorageKeyConstants.KEY_IGNORE_NOTIFICATION_DUCK, settings.ignoreNotificationDuck)
  }

  // ═══════════ Simple string flags ═══════════

  getSortMode(): string {
    const raw = this.getPref().getValue(KEY_SORT_MODE)
    if (raw === undefined) return 'name'
    return raw as string
  }

  setSortMode(mode: string): void {
    this.getPref().preferencesPut(KEY_SORT_MODE, mode)
    AppStorage.setOrCreate(KEY_SORT_MODE, mode)
  }

  getViewMode(): string {
    const raw = this.getPref().getValue(KEY_VIEW_MODE)
    if (raw === undefined) return 'flat'
    return raw as string
  }

  setViewMode(mode: string): void {
    this.getPref().preferencesPut(KEY_VIEW_MODE, mode)
    AppStorage.setOrCreate(KEY_VIEW_MODE, mode)
  }

  getPlayMode(): MusicPlayMode {
    const raw = this.getPref().getValue(KEY_PLAY_MODE)
    if (raw === MusicPlayMode.SINGLE_CYCLE || raw === MusicPlayMode.ORDER || raw === MusicPlayMode.RANDOM) {
      return raw as MusicPlayMode
    }
    return MusicPlayMode.ORDER
  }

  setPlayMode(mode: MusicPlayMode): void {
    this.getPref().preferencesPut(KEY_PLAY_MODE, mode)
    AppStorage.setOrCreate(AppStorageKeyConstants.KEY_PLAY_MODE, mode)
  }

  private readFilterState(): FilterStateRecord {
    const state: FilterStateRecord = new FilterStateRecord()
    const pref: PreferencesUtil = this.getPref()
    const rawState = pref.getValue(KEY_FILTER_STATE)
    if (rawState === undefined) {
      return state
    }
    try {
      const record: Record<string, Object> = JSON.parse(rawState as string) as Record<string, Object>
      const rawPaths: Object | undefined = record['selectedFolderPaths']
      const rawFavorites: Object | undefined = record['favoritesSelected']
      state.selectedFolderPaths = rawPaths !== undefined ? (rawPaths as string[]).slice() : []
      state.favoritesSelected = rawFavorites !== undefined ? rawFavorites as boolean : false
      if (state.favoritesSelected) {
        state.selectedFolderPaths = []
      }
    } catch (e) {
      Logger.error(TAG, 'readFilterState failed')
    }
    return state
  }

  getSelectedFolderPaths(): string[] {
    return this.readFilterState().selectedFolderPaths
  }

  setFilterState(paths: string[], favoritesSelected: boolean): void {
    const state: FilterStateRecord = new FilterStateRecord()
    state.selectedFolderPaths = favoritesSelected ? [] : paths.slice()
    state.favoritesSelected = favoritesSelected
    this.getPref().preferencesPut(KEY_FILTER_STATE, JSON.stringify(state))
    AppStorage.setOrCreate(KEY_SELECTED_FOLDERS, state.selectedFolderPaths.slice())
    AppStorage.setOrCreate(KEY_FAVORITES_SELECTED, state.favoritesSelected)
    const revision: number = AppStorage.get<number>(AppStorageKeyConstants.KEY_FILTER_REVISION) ?? 0
    AppStorage.setOrCreate(AppStorageKeyConstants.KEY_FILTER_REVISION, revision + 1)
  }

  setSelectedFolderPaths(paths: string[]): void {
    this.setFilterState(paths, this.isFavoritesSelected())
  }

  isFavoritesSelected(): boolean {
    return this.readFilterState().favoritesSelected
  }

  // ═══════════ Play Next Queue ═══════════

  getPlayNextQueue(): string[] {
    const raw = this.getPref().getValue(KEY_PLAY_NEXT_QUEUE)
    if (raw === undefined) return []
    try {
      return JSON.parse(raw as string) as string[]
    } catch (e) {
      return []
    }
  }

  setPlayNextQueue(queue: string[]): void {
    this.getPref().preferencesPut(KEY_PLAY_NEXT_QUEUE, JSON.stringify(queue))
    AppStorage.setOrCreate(KEY_PLAY_NEXT_QUEUE, queue)
  }

  addToPlayNext(songId: string): void {
    const queue: string[] = this.getPlayNextQueue()
    queue.push(songId)
    this.setPlayNextQueue(queue)
  }

  shiftPlayNext(): string | undefined {
    const queue: string[] = this.getPlayNextQueue()
    if (queue.length === 0) return undefined
    const id: string = queue[0]
    queue.splice(0, 1)
    this.setPlayNextQueue(queue)
    return id
  }

  // ═══════════ Init ═══════════

  // 歌词引用发生集合级变化（重新导入覆盖）时通知各个歌词视图重新加载。
  // 只做「通知刷新」，不做任何数据推导或找回：损坏原因不可知，任何自动猜测都是伪命题，
  // 唯一的正经做法是在源头阻止歌词字段被破坏（见 repairAvailabilityAndRefresh）。
  private bumpLibraryRevision(): void {
    const revision: number = AppStorage.get<number>(AppStorageKeyConstants.KEY_LIBRARY_REVISION) ?? 0
    AppStorage.setOrCreate(AppStorageKeyConstants.KEY_LIBRARY_REVISION, revision + 1)
  }

  private bumpLyricRevision(): void {
    const revision: number = AppStorage.get<number>(AppStorageKeyConstants.KEY_LYRIC_REVISION) ?? 0
    AppStorage.setOrCreate(AppStorageKeyConstants.KEY_LYRIC_REVISION, revision + 1)
    // 歌词引用集合变化：清掉内存缓存，各歌词视图 Watch 重载时重新读盘
    clearLyricCache()
  }

  initToAppStorage(): AppSettingsData {
    // 幂等：EntryAbility 与页面都调用过本函数，重复执行会把可访问性检查跑两遍并制造授权竞态
    if (this.appStorageInitialized) {
      return this.getSettings()
    }
    this.appStorageInitialized = true
    const settings: AppSettingsData = this.getSettings()
    // 启动期收敛历史脏数据：持久化的筛选状态里可能残留已无歌曲的文件夹路径
    // （旧版本主页删除路径不清理筛选状态导致落盘），按当前曲库剔除，胶囊即恢复正确
    this.pruneFilterAndFolders(this.getSongs())
    AppStorage.setOrCreate(AppStorageKeyConstants.KEY_LIBRARY_REVISION, 0)
    AppStorage.setOrCreate(AppStorageKeyConstants.KEY_FILTER_REVISION, 0)
    AppStorage.setOrCreate(AppStorageKeyConstants.KEY_LYRIC_REVISION, 0)
    AppStorage.setOrCreate(KEY_SORT_MODE, this.getSortMode())
    AppStorage.setOrCreate(KEY_VIEW_MODE, this.getViewMode())
    AppStorage.setOrCreate(AppStorageKeyConstants.KEY_PLAY_MODE, this.getPlayMode())
    // 启动期不在激活授权前跑可访问性检查：此时 docs URI 尚未激活，openSync 必然失败并
    // 把全部 226 首误标为不可用并落库，导致激活完成后 UI 仍显示灰色、点击歌曲没反应。
    // 可在访性检查完全由 activatePersistedUris 在授权激活后统一执行一次。
    AppStorage.setOrCreate(KEY_FOLDER_LIST, this.getFolders())
    AppStorage.setOrCreate(KEY_SELECTED_FOLDERS, this.getSelectedFolderPaths())
    AppStorage.setOrCreate(KEY_FAVORITES_SELECTED, this.isFavoritesSelected())
    AppStorage.setOrCreate(KEY_PLAY_NEXT_QUEUE, this.getPlayNextQueue())
    AppStorage.setOrCreate('uplayer_primary_color', settings.primaryColor)
    AppStorage.setOrCreate('uplayer_theme_mode', settings.themeMode)
    AppStorage.setOrCreate('uplayer_fade_in_out', settings.fadeInOut)
    AppStorage.setOrCreate(AppStorageKeyConstants.KEY_CONTINUE_PLAY_ON_UNPLUG, settings.continuePlayOnHeadsetUnplug)
    AppStorage.setOrCreate(AppStorageKeyConstants.KEY_IGNORE_NOTIFICATION_DUCK, settings.ignoreNotificationDuck)
    AppStorage.setOrCreate('uplayer_font_size_scale', settings.fontSizeScale)
    AppStorage.setOrCreate('uplayer_display_size_scale', settings.displaySizeScale)
    AppStorage.setOrCreate('uplayer_tab_style', settings.tabStyle)
    AppStorage.setOrCreate('uplayer_glass_blur_strength', settings.glassBlurStrength)
    AppStorage.setOrCreate('uplayer_home_top_blur_strength', settings.homeTopBlurStrength)
    AppStorage.setOrCreate('uplayer_tab_indicator_opacity', settings.tabIndicatorOpacity)
    AppStorage.setOrCreate('uplayer_plus_button_scroll_hide', settings.plusButtonScrollHide)
    AppStorage.setOrCreate('uplayer_holding_hand_enabled', settings.holdingHandEnabled)
    AppStorage.setOrCreate('uplayer_tab_touch_indicator', settings.tabTouchIndicator)
    AppStorage.setOrCreate('uplayer_tab_light_color', settings.tabLightColor)
    this.activatePersistedUris()
    return settings
  }

  private isPersistableUri(value: string): boolean {
    return value.startsWith('file://') || value.startsWith('datashare://') || value.startsWith('content://')
  }

  async activatePersistedUris(): Promise<void> {
    // 曲库缓存未就绪时跳过：此时无 URI 可激活，且 repairAvailabilityAndRefresh 会以空曲库为
    // 基准空跑，可能把有权限歌曲误标不可用并落库；等 init 完成缓存就绪后由 init 补跑。
    // persistedUrisActivated 保证整体只成功执行一次（initToAppStorage 与 init 补跑二选一）
    if (this.songsCache === undefined || this.persistedUrisActivated) {
      return
    }
    this.persistedUrisActivated = true
    if (!canIUse('SystemCapability.FileManagement.AppFileService.FolderAuthorization')) {
      Logger.info(TAG, 'activatePersistedUris: FolderAuthorization not supported')
      AudioMetadataService.getInstance().notifyFileAccessReady()
      return
    }
    const songs: SongInfo[] = this.getSongs()
    const uniqueUris: Set<string> = new Set<string>()
    for (let i = 0; i < songs.length; i++) {
      if (this.isPersistableUri(songs[i].uri)) uniqueUris.add(songs[i].uri)
      if (this.isPersistableUri(songs[i].lyricUri)) uniqueUris.add(songs[i].lyricUri)
    }
    const uris: string[] = Array.from(uniqueUris)
    const batchSize: number = 500
    for (let offset = 0; offset < uris.length; offset += batchSize) {
      const batch: string[] = uris.slice(offset, offset + batchSize)
      const policies: fileShare.PolicyInfo[] = []
      // 读写授权单独一组：新导入歌曲已持久化 READ|WRITE（编辑歌曲信息需真实写回源文件），
      // 旧库歌曲只持久化过读权限时该组 check 不过、自动跳过，不影响原有读激活
      const rwPolicies: fileShare.PolicyInfo[] = []
      for (let i = 0; i < batch.length; i++) {
        policies.push({ uri: batch[i], operationMode: fileShare.OperationMode.READ_MODE })
        rwPolicies.push({
          uri: batch[i],
          operationMode: fileShare.OperationMode.READ_MODE | fileShare.OperationMode.WRITE_MODE
        })
      }
      try {
        const persistent: boolean[] = await fileShare.checkPersistentPermission(policies)
        const authorized: fileShare.PolicyInfo[] = []
        for (let i = 0; i < policies.length; i++) {
          if (persistent[i]) authorized.push(policies[i])
        }
        if (authorized.length > 0) {
          await fileShare.activatePermission(authorized)
          Logger.info(TAG, `activatePersistedUris: activated ${authorized.length} URIs`)
        }
        const persistentRw: boolean[] = await fileShare.checkPersistentPermission(rwPolicies)
        const authorizedRw: fileShare.PolicyInfo[] = []
        for (let i = 0; i < rwPolicies.length; i++) {
          if (persistentRw[i]) authorizedRw.push(rwPolicies[i])
        }
        if (authorizedRw.length > 0) {
          await fileShare.activatePermission(authorizedRw)
          Logger.info(TAG, `activatePersistedUris: activated rw ${authorizedRw.length} URIs`)
        }
      } catch (err) {
        const error: BusinessError<Array<fileShare.PolicyErrorResult>> =
          err as BusinessError<Array<fileShare.PolicyErrorResult>>
        // 先取出到局部变量：直接访问 error.data 时 ArkTS 不做属性收窄，会报 possibly undefined
        const failedUris: Array<fileShare.PolicyErrorResult> | undefined = error.data
        if (failedUris !== undefined) {
          for (let i = 0; i < failedUris.length; i++) {
            Logger.error(TAG, `activatePersistedUris failed uri=${failedUris[i].uri} code=${failedUris[i].code}`)
          }
        } else {
          Logger.error(TAG, `activatePersistedUris failed: code=${error.code} message=${error.message}`)
        }
      }
    }
    // 持久化授权激活完成后重新校验歌曲可访问性，并刷新 KEY_SONG_LIST 及 LIBRARY_REVISION
    // 让 UI 感知最新状态（即使可访问性校验未检测到变化也执行刷新）。
    // 注意：歌词字段不再参与该校验（校验里已彻底移除清空逻辑），因此「误判」只影响
    // isAvailable，不会再有数据被销毁。
    this.repairAvailabilityAndRefresh()
    // 放行等待授权激活的封面加载（修复启动竞态：封面抢跑 open 全量 EPERM 触发熔断）
    AudioMetadataService.getInstance().notifyFileAccessReady()
  }

  /**
   * 修复不可用歌曲的可访问性状态并刷新 AppStorage。
   * 覆盖场景：之前构建版本在授权激活前错误地把全部歌曲标为不可用并已落库，
   * 激活完成后需要重新检测并把实际可访问的歌曲恢复为可用状态。
   */
  private repairAvailabilityAndRefresh(): void {
    const songs: SongInfo[] = this.getSongs()
    let changed: boolean = false
    for (let i: number = 0; i < songs.length; i++) {
      const accessPath: string = songs[i].uri.length > 0 ? songs[i].uri : songs[i].filePath
      try {
        const file: fs.File = fs.openSync(accessPath, fs.OpenMode.READ_ONLY)
        fs.closeSync(file)
        if (!songs[i].isAvailable) {
          songs[i].isAvailable = true
          changed = true
        }
      } catch {
        if (songs[i].isAvailable) {
          songs[i].isAvailable = false
          changed = true
        }
      }
    }
    let unavailableCount: number = 0
    for (let i: number = 0; i < songs.length; i++) {
      if (!songs[i].isAvailable) unavailableCount++
    }
    if (unavailableCount > 0) {
      Logger.warn(TAG, `repairAvailabilityAndRefresh total=${songs.length} unavailable=${unavailableCount}`)
    }
    // 无论是否变化都刷新 AppStorage，确保 UI 立刻拿到最新状态
    AppStorage.setOrCreate(AppStorageKeyConstants.KEY_SONG_LIST, songs.slice())
    const revision: number = AppStorage.get<number>(AppStorageKeyConstants.KEY_LIBRARY_REVISION) ?? 0
    AppStorage.setOrCreate(AppStorageKeyConstants.KEY_LIBRARY_REVISION, revision + 1)
    if (changed) {
      this.saveSongs(songs)
      this.flushPendingSongWrites()
    }
  }
}
