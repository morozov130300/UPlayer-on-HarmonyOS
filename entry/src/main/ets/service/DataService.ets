import { SongInfo } from '../model/SongInfo'
import { FolderInfo } from '../model/FolderInfo'
import { PreferencesUtil } from '../common/utils/PreferencesUtil'
import { AppStorageKeyConstants } from '../common/constants/AppStorageKeyConstants'
import { fileIo as fs, fileShare } from '@kit.CoreFileKit'
import Logger from '../common/utils/Logger'
import { BusinessError } from '@kit.BasicServicesKit'
import { MusicPlayMode } from '../common/constants/PlayerConstants'

const TAG = 'DataService'

const KEY_SONG_LIST: string = 'uplayer_song_list'
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
  showLyrics: boolean = true
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
  // 玻璃风格细节：厚度（0-100，独立控制 ImmersiveStyle 档位）+ 饱和度 + 亮度
  // 厚度与模糊强度完全独立：thickness 控系统材质档位，blurStrength 控 backgroundEffect 半径
  glassThickness: number = 50
  glassSaturation: number = 1.4
  glassBrightness: number = 1.02
  // 质感握姿：开启后系统根据单手握持方向自动让首页顶部模糊预览/控件靠左或靠右
  holdingHandEnabled: boolean = true
  // 底部栏跟手光效颜色：white=纯白光，theme=跟随主题色（暗黑默认白光，明亮默认主题色，由 SettingsDetailPage 按明暗模式初始化）
  lightColorMode: string = 'white'
  // 底部栏点击/拖动指示器风格：light=跟手光效，mask=白色蒙版（与 light 互斥）
  tabTouchIndicator: string = 'light'
  // 液态玻璃交互形变：按压/拖动时产生 Q 弹反馈
  interactive: boolean = true
  // 材质层赋色：叠加一层半透明颜色降低折射可见程度，undefined=不赋色
  materialColor: string | undefined = undefined
  // 自动反色：子树文字/图标根据材质背景色自动反色
  colorInvert: boolean = false
  // 材质阴影：启用时材质自带阴影效果，优先于 shadow 通用属性
  applyShadow: boolean = true
  }

export class DataService {
  private static instance: DataService = new DataService()
  private songsCache: SongInfo[] | undefined = undefined
  // 拖拽重排等高频更新场景下，延迟并合并磁盘写入，降低擦写次数
  private saveSongsTimer: number = -1
  private pendingSongs: SongInfo[] | undefined = undefined
  private readonly SAVE_SONGS_DEBOUNCE_MS: number = 300

  public static getInstance(): DataService {
    return DataService.instance
  }

  // 立即把暂存的歌曲列表写入磁盘（幂等，可安全多次调用）
  flushPendingSongWrites(): void {
    if (this.saveSongsTimer !== -1) {
      clearTimeout(this.saveSongsTimer)
      this.saveSongsTimer = -1
    }
    if (this.pendingSongs === undefined) {
      return
    }
    const songs: SongInfo[] = this.pendingSongs
    this.pendingSongs = undefined
    const records: Record<string, Object>[] = []
    for (let i = 0; i < songs.length; i++) {
      records.push(this.songToRecord(songs[i]))
    }
    this.writeJsonArray(KEY_SONG_LIST, records as object[])
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

  private songToRecord(song: SongInfo): Record<string, Object> {
    const r: Record<string, Object> = {}
    r['id'] = song.id
    r['name'] = song.name
    r['title'] = song.title
    r['artist'] = song.artist
    r['album'] = song.album
    r['filePath'] = song.filePath
    r['uri'] = song.uri
    r['fileName'] = song.fileName
    r['folderPath'] = song.folderPath
    r['folderName'] = song.folderName
    r['duration'] = song.duration
    r['bitrate'] = song.bitrate
    r['sampleRate'] = song.sampleRate
    r['addedTime'] = song.addedTime
    r['sortOrder'] = song.sortOrder
    r['isFavorite'] = song.isFavorite
    r['isAvailable'] = song.isAvailable
    r['lyricPath'] = song.lyricPath
    r['lyricUri'] = song.lyricUri
    return r
  }

  private recordToSong(r: Record<string, Object>): SongInfo {
    const song: SongInfo = new SongInfo()
    song.id = r['id'] as string
    song.name = r['name'] as string
    let rawTitle: Object | undefined = r['title']
    if (rawTitle === undefined || (rawTitle as string).length === 0) {
      song.title = song.name
    } else {
      song.title = rawTitle as string
    }
    song.artist = r['artist'] as string
    song.album = r['album'] as string
    song.filePath = r['filePath'] as string
    let rawUri: Object | undefined = r['uri']
    song.uri = rawUri !== undefined ? rawUri as string : song.filePath
    song.fileName = r['fileName'] as string
    song.folderPath = r['folderPath'] as string
    song.folderName = r['folderName'] as string
    song.duration = r['duration'] as number
    let rawBitrate: Object | undefined = r['bitrate']
    song.bitrate = rawBitrate !== undefined ? rawBitrate as number : 0
    let rawSampleRate: Object | undefined = r['sampleRate']
    song.sampleRate = rawSampleRate !== undefined ? rawSampleRate as number : 0
    song.addedTime = r['addedTime'] as number
    const rawSortOrder: Object | undefined = r['sortOrder']
    if (rawSortOrder !== undefined) {
      song.sortOrder = rawSortOrder as number
    } else {
      // 旧数据迁移：早期版本无 sortOrder，用添加时间保证自定义排序的合理初始顺序
      song.sortOrder = song.addedTime
    }
    song.isFavorite = r['isFavorite'] as boolean
    song.isAvailable = r['isAvailable'] as boolean
    song.lyricPath = r['lyricPath'] as string
    let rawLyricUri: Object | undefined = r['lyricUri']
    song.lyricUri = rawLyricUri !== undefined ? rawLyricUri as string : ''
    return song
  }

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
    const arr: object[] = this.readJsonArray(KEY_SONG_LIST)
    const result: SongInfo[] = []
    for (let i = 0; i < arr.length; i++) {
      result.push(this.recordToSong(arr[i] as Record<string, Object>))
    }
    this.songsCache = result
    return result
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
    for (let i = 0; i < newSongs.length; i++) {
      const existingIndex: number | undefined = existingIndexes.get(newSongs[i].filePath)
      if (existingIndex !== undefined) {
        songs[existingIndex].title = newSongs[i].title
        songs[existingIndex].artist = newSongs[i].artist
        songs[existingIndex].album = newSongs[i].album
        songs[existingIndex].duration = newSongs[i].duration
        songs[existingIndex].uri = newSongs[i].uri
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
      s.showLyrics = r['showLyrics'] as boolean
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
      // glassThickness：新字段，0-100 连续值直接映射 ImmersiveStyle 档位
      // glassStyle：旧字段（已废弃），兼容老数据时迁移到 glassThickness
      let rawGlassThickness: Object | undefined = r['glassThickness']
      s.glassThickness = rawGlassThickness !== undefined ? Math.max(0, Math.min(100, rawGlassThickness as number)) : 50
      if (s.glassThickness === 50 && r['glassStyle'] !== undefined) {
        // 老数据无 glassThickness，从旧 glassStyle 迁移
        const raw: Object = r['glassStyle']
        if (typeof raw === 'number') {
          s.glassThickness = Math.max(0, Math.min(100, raw as number))
        } else if (typeof raw === 'string') {
          const legacy: string = raw as string
          if (legacy === 'thin') s.glassThickness = 20
          else if (legacy === 'thick') s.glassThickness = 80
          else s.glassThickness = 50
        }
      }
      let rawGlassSaturation: Object | undefined = r['glassSaturation']
      s.glassSaturation = rawGlassSaturation !== undefined ? rawGlassSaturation as number : 1.4
      let rawGlassBrightness: Object | undefined = r['glassBrightness']
      s.glassBrightness = rawGlassBrightness !== undefined ? rawGlassBrightness as number : 1.02
      let rawHoldingHandEnabled: Object | undefined = r['holdingHandEnabled']
      s.holdingHandEnabled = rawHoldingHandEnabled !== undefined ? rawHoldingHandEnabled as boolean : true
      let rawLightColorMode: Object | undefined = r['lightColorMode']
      s.lightColorMode = rawLightColorMode !== undefined ? rawLightColorMode as string : 'white'
      let rawTabTouchIndicator: Object | undefined = r['tabTouchIndicator']
      s.tabTouchIndicator = rawTabTouchIndicator !== undefined ? rawTabTouchIndicator as string : 'light'
      let rawInteractive: Object | undefined = r['interactive']
      s.interactive = rawInteractive !== undefined ? rawInteractive as boolean : true
      let rawMaterialColor: Object | undefined = r['materialColor']
      s.materialColor = rawMaterialColor !== undefined ? rawMaterialColor as string : undefined
      let rawColorInvert: Object | undefined = r['colorInvert']
      s.colorInvert = rawColorInvert !== undefined ? rawColorInvert as boolean : false
      let rawApplyShadow: Object | undefined = r['applyShadow']
      s.applyShadow = rawApplyShadow !== undefined ? rawApplyShadow as boolean : true
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
    r['showLyrics'] = settings.showLyrics
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
    r['glassSaturation'] = settings.glassSaturation
    r['glassBrightness'] = settings.glassBrightness
    r['holdingHandEnabled'] = settings.holdingHandEnabled
    r['lightColorMode'] = settings.lightColorMode
    r['tabTouchIndicator'] = settings.tabTouchIndicator
    r['interactive'] = settings.interactive
    r['materialColor'] = settings.materialColor
    r['colorInvert'] = settings.colorInvert
    r['applyShadow'] = settings.applyShadow
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
      try {
        fs.accessSync(accessPath)
        songs[i].isAvailable = true
      } catch (e) {
        songs[i].isAvailable = false
      }
      if (songs[i].lyricUri.length > 0) {
        try {
          fs.accessSync(songs[i].lyricUri)
        } catch (e) {
          songs[i].lyricPath = ''
          songs[i].lyricUri = ''
        }
      } else if (songs[i].lyricPath.length > 0) {
        try {
          fs.accessSync(songs[i].lyricPath)
        } catch (e) {
          songs[i].lyricPath = ''
        }
      }
      if (songs[i].isAvailable !== prevAvailable) {
        changed = true
      }
    }
    if (changed) {
      this.saveSongs(songs)
      // 启动期的可访问性修复立即落盘，避免残留待写缓存
      this.flushPendingSongWrites()
    }
  }

  // ═══════════ Init ═══════════

  initToAppStorage(): AppSettingsData {
    const settings: AppSettingsData = this.getSettings()
    AppStorage.setOrCreate(KEY_SETTINGS, settings)
    AppStorage.setOrCreate(AppStorageKeyConstants.KEY_LIBRARY_REVISION, 0)
    AppStorage.setOrCreate(AppStorageKeyConstants.KEY_FILTER_REVISION, 0)
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
    AppStorage.setOrCreate('uplayer_show_lyrics', settings.showLyrics)
    AppStorage.setOrCreate('uplayer_fade_in_out', settings.fadeInOut)
    AppStorage.setOrCreate('uplayer_font_size_scale', settings.fontSizeScale)
    AppStorage.setOrCreate('uplayer_display_size_scale', settings.displaySizeScale)
    AppStorage.setOrCreate('uplayer_tab_style', settings.tabStyle)
    AppStorage.setOrCreate('uplayer_glass_blur_strength', settings.glassBlurStrength)
    AppStorage.setOrCreate('uplayer_home_top_blur_strength', settings.homeTopBlurStrength)
    AppStorage.setOrCreate('uplayer_tab_indicator_opacity', settings.tabIndicatorOpacity)
    AppStorage.setOrCreate('uplayer_glass_thickness', settings.glassThickness)
    AppStorage.setOrCreate('uplayer_glass_saturation', settings.glassSaturation)
    AppStorage.setOrCreate('uplayer_glass_brightness', settings.glassBrightness)
    AppStorage.setOrCreate('uplayer_holding_hand_enabled', settings.holdingHandEnabled)
    AppStorage.setOrCreate('uplayer_light_color_mode', settings.lightColorMode)
    AppStorage.setOrCreate('uplayer_tab_touch_indicator', settings.tabTouchIndicator)
    AppStorage.setOrCreate('uplayer_interactive', settings.interactive)
    AppStorage.setOrCreate('uplayer_material_color', settings.materialColor ?? '')
    AppStorage.setOrCreate('uplayer_color_invert', settings.colorInvert)
    AppStorage.setOrCreate('uplayer_apply_shadow', settings.applyShadow)
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
        if (error.data !== undefined) {
          for (let i = 0; i < error.data.length; i++) {
            Logger.error(TAG, `activatePersistedUris failed uri=${error.data[i].uri} code=${error.data[i].code}`)
          }
        } else {
          Logger.error(TAG, `activatePersistedUris failed: code=${error.code} message=${error.message}`)
        }
      }
    }
  }
}
