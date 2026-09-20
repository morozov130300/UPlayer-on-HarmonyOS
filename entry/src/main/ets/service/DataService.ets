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
import { normalizeGlassThickness } from '../common/utils/GlassUtil'

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
  playSpeed: number = 1
  folderSortMode: string = 'name'
  fadeInOut: boolean = false
  fontSizeScale: number = 1.0
  displaySizeScale: number = 1.0
  tabStyle: string = 'classic'
  glassBlurStrength: number = 25
  homeTopBlurStrength: number = 25
  tabIndicatorOpacity: number = 50
  // 玻璃风格细节：厚度（0-100，独立控制 ImmersiveStyle 档位）
  // 厚度与模糊强度完全独立：thickness 控系统材质档位，blurStrength 控 backgroundEffect 半径
  glassThickness: number = 50
  // 质感握姿：开启后系统根据单手握持方向自动让首页顶部模糊预览/控件靠左或靠右
  holdingHandEnabled: boolean = true
  // 底部栏跟手光效颜色：white=纯白光，theme=跟随主题色（暗黑默认白光，明亮默认主题色，由 SettingsDetailPage 按明暗模式初始化）
  lightColorMode: string = 'white'
  // 底部栏点击/拖动指示器风格：light=跟手光效，mask=白色蒙版，off=关闭
  // mask 仅在有鼠标/触控板的设备上提供（设置页按检测结果显隐开关，无鼠标时降级为 off）
  tabTouchIndicator: string = 'light'
  // 液态玻璃交互形变：按压/拖动时产生 Q 弹反馈
  interactive: boolean = true
  // 自动反色：子树文字/图标根据材质背景色自动适配
  colorInvert: boolean = false
  // 材质阴影：启用时材质自带阴影效果，优先于 shadow 通用属性
  applyShadow: boolean = true
  // 系统组件液态玻璃：Toast 等调用级 systemMaterial 的总开关（API 26+ 且设备支持才实际生效）
  systemComponentGlass: boolean = true
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

  public static getInstance(): DataService {
    return DataService.instance
  }

  // 初始化曲库数据库并加载全量歌曲到内存缓存；EntryAbility 在 UI 加载前调用
  public async init(context: common.UIAbilityContext): Promise<void> {
    try {
      await SongDatabase.getInstance().init(context)
      const songs: SongInfo[] = await SongDatabase.getInstance().queryAllSongs()
      this.songsCache = songs
      const snapshot: Map<string, SongInfo> = new Map<string, SongInfo>()
      for (let i = 0; i < songs.length; i++) {
        snapshot.set(songs[i].id, this.cloneSong(songs[i]))
      }
      this.dbSnapshot = snapshot
      Logger.info(TAG, `init: loaded ${songs.length} songs from database`)
    } catch (err) {
      this.songsCache = []
      this.dbSnapshot = new Map<string, SongInfo>()
      Logger.error(TAG, `init failed: ${JSON.stringify(err)}`)
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
      a.hasVideo === b.hasVideo && a.videoWidth === b.videoWidth && a.videoHeight === b.videoHeight
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

  // ═══════════ Generic JSON read/write via Preferences ═══════════

  private readJsonArray(key: string): object[] {
    const raw = this.getPref().getValue(key)
    if (raw === undefined) {
      return []
    }
    try {
      return JSON.parse(raw as string) as object[]
    } catch (e) {
      Logger.error(TAG, `readJsonArray error for ${key}`)
      return []
    }
  }

  private writeJsonArray(key: string, data: object[]): void {
    this.getPref().preferencesPut(key, JSON.stringify(data))
  }

  // ═══════════ Song serialization ═══════════
  // 歌曲 ↔ 数据库行 的转换由 SongDatabase 负责

  private folderToRecord(folder: FolderInfo): Record<string, Object> {
    const r: Record<string, Object> = {}
    r['id'] = folder.id
    r['name'] = folder.name
    r['path'] = folder.path
    r['songCount'] = folder.songCount
    r['addedTime'] = folder.addedTime
    r['isAvailable'] = folder.isAvailable
    r['isFavorite'] = folder.isFavorite
    r['sortOrder'] = folder.sortOrder
    return r
  }

  private recordToFolder(r: Record<string, Object>): FolderInfo {
    const folder: FolderInfo = new FolderInfo()
    folder.id = r['id'] as string
    folder.name = r['name'] as string
    folder.path = r['path'] as string
    folder.songCount = r['songCount'] as number
    folder.addedTime = r['addedTime'] as number
    folder.isAvailable = r['isAvailable'] as boolean
    let rawFav: Object | undefined = r['isFavorite']
    folder.isFavorite = rawFav !== undefined ? rawFav as boolean : false
    let rawSort: Object | undefined = r['sortOrder']
    folder.sortOrder = rawSort !== undefined ? rawSort as number : 0
    return folder
  }

  // ═══════════ Song CRUD ═══════════

  getSongs(): SongInfo[] {
    if (this.songsCache !== undefined) {
      return this.songsCache
    }
    // 数据库初始化完成前返回空列表；init() 完成后缓存始终可用
    return []
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

  removeSong(songId: string): void {
    const songs: SongInfo[] = this.getSongs()
    const filtered: SongInfo[] = []
    for (let i = 0; i < songs.length; i++) {
      if (songs[i].id !== songId) {
        filtered.push(songs[i])
      }
    }
    this.saveSongs(filtered)
    this.flushPendingSongWrites()
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

  removeSongsByFolder(folderPath: string): void {
    this.removeSongsByFolders([folderPath])
  }

  getFavoriteSongs(): SongInfo[] {
    const songs: SongInfo[] = this.getSongs()
    const favs: SongInfo[] = []
    for (let i = 0; i < songs.length; i++) {
      if (songs[i].isFavorite) {
        favs.push(songs[i])
      }
    }
    return favs
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
    const cached: object | undefined = AppStorage.get<FolderInfo[]>(KEY_FOLDER_LIST)
    if (cached !== undefined) {
      return cached as FolderInfo[]
    }
    const arr: object[] = this.readJsonArray(KEY_FOLDER_LIST)
    const result: FolderInfo[] = []
    for (let i = 0; i < arr.length; i++) {
      result.push(this.recordToFolder(arr[i] as Record<string, Object>))
    }
    AppStorage.setOrCreate(KEY_FOLDER_LIST, result)
    return result
  }

  saveFolders(folders: FolderInfo[]): void {
    AppStorage.setOrCreate(KEY_FOLDER_LIST, folders)
    const records: Record<string, Object>[] = []
    for (let i = 0; i < folders.length; i++) {
      records.push(this.folderToRecord(folders[i]))
    }
    this.writeJsonArray(KEY_FOLDER_LIST, records as object[])
  }

  addFolder(folder: FolderInfo): void {
    const folders: FolderInfo[] = this.getFolders()
    folders.push(folder)
    this.saveFolders(folders)
  }

  removeFolder(folderId: string): void {
    const folders: FolderInfo[] = this.getFolders()
    const filtered: FolderInfo[] = []
    for (let i = 0; i < folders.length; i++) {
      if (folders[i].id !== folderId) {
        filtered.push(folders[i])
      }
    }
    this.saveFolders(filtered)
  }

  toggleFolderFavorite(folderId: string): boolean {
    const folders: FolderInfo[] = this.getFolders()
    let newFav: boolean = false
    for (let i = 0; i < folders.length; i++) {
      if (folders[i].id === folderId) {
        folders[i].isFavorite = !folders[i].isFavorite
        newFav = folders[i].isFavorite
        break
      }
    }
    this.saveFolders(folders)
    return newFav
  }

  updateFolderSortOrder(folderId: string, newOrder: number): void {
    const folders: FolderInfo[] = this.getFolders()
    for (let i = 0; i < folders.length; i++) {
      if (folders[i].id === folderId) {
        folders[i].sortOrder = newOrder
        break
      }
    }
    this.saveFolders(folders)
  }

  // ═══════════ Settings ═══════════

  getSettings(): AppSettingsData {
    const raw = this.getPref().getValue(KEY_SETTINGS)
    if (raw === undefined) {
      return new AppSettingsData()
    }
    try {
      const r: Record<string, Object> = JSON.parse(raw as string) as Record<string, Object>
      const s: AppSettingsData = new AppSettingsData()
      s.plusButtonScrollHide = r['plusButtonScrollHide'] as boolean
      s.themeMode = r['themeMode'] as string
      s.primaryColor = r['primaryColor'] as string
      s.eqEnabled = r['eqEnabled'] as boolean
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
      s.playSpeed = r['playSpeed'] as number
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
      // 玻璃风格细节（带迁移默认值，老数据走默认值不会破坏既有体验）
      // glassThickness：固定 6 档（0=关闭 + 官方五档 20/40/60/80/100），非档位旧值归一到最近档
      // glassStyle：旧字段（已废弃），兼容老数据时迁移到 glassThickness
      let rawGlassThickness: Object | undefined = r['glassThickness']
      s.glassThickness = rawGlassThickness !== undefined
        ? normalizeGlassThickness(rawGlassThickness as number) : 60
      if (rawGlassThickness === undefined && r['glassStyle'] !== undefined) {
        // 老数据无 glassThickness，从旧 glassStyle 迁移
        const raw: Object = r['glassStyle']
        if (typeof raw === 'number') {
          s.glassThickness = normalizeGlassThickness(raw as number)
        } else if (typeof raw === 'string') {
          const legacy: string = raw as string
          if (legacy === 'thin') s.glassThickness = 20
          else if (legacy === 'thick') s.glassThickness = 80
          else s.glassThickness = 60
        }
      }
      let rawHoldingHandEnabled: Object | undefined = r['holdingHandEnabled']
      s.holdingHandEnabled = rawHoldingHandEnabled !== undefined ? rawHoldingHandEnabled as boolean : true
      let rawLightColorMode: Object | undefined = r['lightColorMode']
      s.lightColorMode = rawLightColorMode !== undefined ? rawLightColorMode as string : 'white'
      let rawTabTouchIndicator: Object | undefined = r['tabTouchIndicator']
      s.tabTouchIndicator = rawTabTouchIndicator !== undefined ? rawTabTouchIndicator as string : 'light'
      let rawInteractive: Object | undefined = r['interactive']
      s.interactive = rawInteractive !== undefined ? rawInteractive as boolean : true
      let rawColorInvert: Object | undefined = r['colorInvert']
      s.colorInvert = rawColorInvert !== undefined ? rawColorInvert as boolean : false
      let rawApplyShadow: Object | undefined = r['applyShadow']
      s.applyShadow = rawApplyShadow !== undefined ? rawApplyShadow as boolean : true
      let rawSystemComponentGlass: Object | undefined = r['systemComponentGlass']
      s.systemComponentGlass = rawSystemComponentGlass !== undefined ? rawSystemComponentGlass as boolean : true
      if (eqBandsMigrated) {
        this.saveSettings(s)
      }
      return s
    } catch (e) {
      return new AppSettingsData()
    }
  }

  saveSettings(settings: AppSettingsData): void {
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
    r['playSpeed'] = settings.playSpeed
    r['folderSortMode'] = settings.folderSortMode
    r['fadeInOut'] = settings.fadeInOut
    r['fontSizeScale'] = settings.fontSizeScale
    r['displaySizeScale'] = settings.displaySizeScale
    r['tabStyle'] = settings.tabStyle
    r['glassBlurStrength'] = settings.glassBlurStrength
    r['homeTopBlurStrength'] = settings.homeTopBlurStrength
    r['tabIndicatorOpacity'] = settings.tabIndicatorOpacity
    r['glassThickness'] = settings.glassThickness

    r['holdingHandEnabled'] = settings.holdingHandEnabled
    r['lightColorMode'] = settings.lightColorMode
    r['tabTouchIndicator'] = settings.tabTouchIndicator
    r['interactive'] = settings.interactive
    r['colorInvert'] = settings.colorInvert
    r['applyShadow'] = settings.applyShadow
    r['systemComponentGlass'] = settings.systemComponentGlass
    this.getPref().preferencesPut(KEY_SETTINGS, JSON.stringify(r))
    AppStorage.setOrCreate(KEY_SETTINGS, settings)
    AppStorage.setOrCreate('uplayer_fade_in_out', settings.fadeInOut)
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
    const pref: PreferencesUtil = this.getPref()
    const rawState = pref.getValue(KEY_FILTER_STATE)
    if (rawState !== undefined) {
      try {
        const record: Record<string, Object> = JSON.parse(rawState as string) as Record<string, Object>
        const state: FilterStateRecord = new FilterStateRecord()
        const rawPaths: Object | undefined = record['selectedFolderPaths']
        const rawFavorites: Object | undefined = record['favoritesSelected']
        state.selectedFolderPaths = rawPaths !== undefined ? (rawPaths as string[]).slice() : []
        state.favoritesSelected = rawFavorites !== undefined ? rawFavorites as boolean : false
        if (state.favoritesSelected) {
          state.selectedFolderPaths = []
        }
        return state
      } catch (e) {
        Logger.error(TAG, 'readFilterState failed, falling back to legacy keys')
      }
    }
    const state: FilterStateRecord = new FilterStateRecord()
    const rawPaths = pref.getValue(KEY_SELECTED_FOLDERS)
    if (rawPaths !== undefined) {
      try {
        state.selectedFolderPaths = (JSON.parse(rawPaths as string) as string[]).slice()
      } catch (e) {
        state.selectedFolderPaths = []
      }
    }
    const rawFavorites = pref.getValue(KEY_FAVORITES_SELECTED)
    state.favoritesSelected = rawFavorites !== undefined ? rawFavorites as boolean : false
    if (state.favoritesSelected) {
      state.selectedFolderPaths = []
    }
    if (rawPaths !== undefined || rawFavorites !== undefined) {
      pref.preferencesPut(KEY_FILTER_STATE, JSON.stringify(state))
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

  setFavoritesSelected(selected: boolean): void {
    this.setFilterState(this.getSelectedFolderPaths(), selected)
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

  // ═══════════ Accessibility Check ═══════════

  checkSongsAccessibility(): void {
    const songs: SongInfo[] = this.getSongs()
    let changed: boolean = false
    for (let i: number = 0; i < songs.length; i++) {
      const prevAvailable: boolean = songs[i].isAvailable
      const accessPath: string = songs[i].uri.length > 0 ? songs[i].uri : songs[i].filePath
      // 与封面提取相同的打开校验：外置盘缺失时 accessSync 可能误判存在，openSync 才可靠抛 13900002
      try {
        const file: fs.File = fs.openSync(accessPath, fs.OpenMode.READ_ONLY)
        fs.closeSync(file)
        songs[i].isAvailable = true
      } catch (e) {
        songs[i].isAvailable = false
      }
      // ⚠️ 这里绝不能清空 lyricPath / lyricUri。
      // 这是本 bug 的根因：本函数在 initToAppStorage 中被同步调用，那时持久化授权
      // （activatePersistedUris）尚未激活，picker docs URI 的 openSync 必然失败；
      // 一旦据此清空歌词字段，第二次校验（激活完成后）也无法恢复已被销毁的值，
      // 且 changed 分支会把清空结果落库，造成歌词被永久抹除、播放器显示「无歌词」。
      // 歌词文件还可能位于临时未挂载的外置存储，删除引用更是不该有的副作用。
      // 引用是否有效只由导入这个源头决定；文件读不到就如实显示「无歌词」，
      // 绝不在运行期猜测、推导或改写歌词引用。
      if (songs[i].isAvailable !== prevAvailable) {
        changed = true
      }
    }
    let unavailableCount: number = 0
    for (let j: number = 0; j < songs.length; j++) {
      if (!songs[j].isAvailable) {
        unavailableCount++
      }
    }
    if (unavailableCount > 0) {
      Logger.warn(TAG, `checkSongsAccessibility total=${songs.length} unavailable=${unavailableCount}`)
    }
    if (changed) {
      this.saveSongs(songs)
      // 启动期的可访问性修复立即落盘，避免残留待写缓存
      this.flushPendingSongWrites()
    }
  }

  // ═══════════ Init ═══════════

  // 歌词引用发生集合级变化（重新导入覆盖）时通知各个歌词视图重新加载。
  // 只做「通知刷新」，不做任何数据推导或找回：损坏原因不可知，任何自动猜测都是伪命题，
  // 唯一的正经做法是在源头阻止歌词字段被破坏（见 checkSongsAccessibility）。
  private bumpLyricRevision(): void {
    const revision: number = AppStorage.get<number>(AppStorageKeyConstants.KEY_LYRIC_REVISION) ?? 0
    AppStorage.setOrCreate(AppStorageKeyConstants.KEY_LYRIC_REVISION, revision + 1)
  }

  initToAppStorage(): AppSettingsData {
    // 幂等：EntryAbility 与页面都调用过本函数，重复执行会把可访问性检查跑两遍并制造授权竞态
    if (this.appStorageInitialized) {
      return this.getSettings()
    }
    this.appStorageInitialized = true
    const settings: AppSettingsData = this.getSettings()
    AppStorage.setOrCreate(KEY_SETTINGS, settings)
    AppStorage.setOrCreate(AppStorageKeyConstants.KEY_LIBRARY_REVISION, 0)
    AppStorage.setOrCreate(AppStorageKeyConstants.KEY_FILTER_REVISION, 0)
    AppStorage.setOrCreate(AppStorageKeyConstants.KEY_LYRIC_REVISION, 0)
    AppStorage.setOrCreate(KEY_SORT_MODE, this.getSortMode())
    AppStorage.setOrCreate(KEY_VIEW_MODE, this.getViewMode())
    AppStorage.setOrCreate(AppStorageKeyConstants.KEY_PLAY_MODE, this.getPlayMode())
    this.checkSongsAccessibility()
    AppStorage.setOrCreate(AppStorageKeyConstants.KEY_SONG_LIST, this.getSongs())
    AppStorage.setOrCreate(KEY_FOLDER_LIST, this.getFolders())
    AppStorage.setOrCreate(KEY_SELECTED_FOLDERS, this.getSelectedFolderPaths())
    AppStorage.setOrCreate(KEY_FAVORITES_SELECTED, this.isFavoritesSelected())
    AppStorage.setOrCreate(KEY_PLAY_NEXT_QUEUE, this.getPlayNextQueue())
    AppStorage.setOrCreate('uplayer_primary_color', settings.primaryColor)
    AppStorage.setOrCreate('uplayer_theme_mode', settings.themeMode)
    AppStorage.setOrCreate('uplayer_fade_in_out', settings.fadeInOut)
    AppStorage.setOrCreate('uplayer_font_size_scale', settings.fontSizeScale)
    AppStorage.setOrCreate('uplayer_display_size_scale', settings.displaySizeScale)
    AppStorage.setOrCreate('uplayer_tab_style', settings.tabStyle)
    AppStorage.setOrCreate('uplayer_glass_blur_strength', settings.glassBlurStrength)
    AppStorage.setOrCreate('uplayer_home_top_blur_strength', settings.homeTopBlurStrength)
    AppStorage.setOrCreate('uplayer_tab_indicator_opacity', settings.tabIndicatorOpacity)
    AppStorage.setOrCreate('uplayer_glass_thickness', settings.glassThickness)

    AppStorage.setOrCreate('uplayer_holding_hand_enabled', settings.holdingHandEnabled)
    AppStorage.setOrCreate('uplayer_light_color_mode', settings.lightColorMode)
    AppStorage.setOrCreate('uplayer_tab_touch_indicator', settings.tabTouchIndicator)
    AppStorage.setOrCreate('uplayer_interactive', settings.interactive)
    AppStorage.setOrCreate('uplayer_color_invert', settings.colorInvert)
    AppStorage.setOrCreate('uplayer_apply_shadow', settings.applyShadow)
    AppStorage.setOrCreate('uplayer_system_component_glass', settings.systemComponentGlass)
    this.activatePersistedUris()
    return settings
  }

  private isPersistableUri(value: string): boolean {
    return value.startsWith('file://') || value.startsWith('datashare://') || value.startsWith('content://')
  }

  async activatePersistedUris(): Promise<void> {
    if (!canIUse('SystemCapability.FileManagement.AppFileService.FolderAuthorization')) {
      Logger.info(TAG, 'activatePersistedUris: FolderAuthorization not supported')
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
      for (let i = 0; i < batch.length; i++) {
        policies.push({ uri: batch[i], operationMode: fileShare.OperationMode.READ_MODE })
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
    // 持久化授权激活完成后重新校验歌曲可访问性：
    // initToAppStorage 首次 checkSongsAccessibility 时激活可能尚未完成，
    // 会导致已持久化授权的歌曲被误判为不可用（首页灰色），此处纠正回来。
    // 注意：歌词字段不再参与该校验（校验里已彻底移除清空逻辑），
    // 因此「误判」只影响 isAvailable，不会再有数据被销毁。
    this.checkSongsAccessibility()
  }
}
