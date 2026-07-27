import { SongInfo } from '../model/SongInfo'
import { FolderInfo } from '../model/FolderInfo'
import { PreferencesUtil } from '../common/utils/PreferencesUtil'
import { AppStorageKeyConstants } from '../common/constants/AppStorageKeyConstants'
import Logger from '../common/utils/Logger'

const TAG = 'DataService'

const KEY_SONG_LIST: string = 'uplayer_song_list'
const KEY_FOLDER_LIST: string = 'uplayer_folder_list'
const KEY_SETTINGS: string = 'uplayer_settings'
const KEY_SORT_MODE: string = 'uplayer_sort_mode'
const KEY_VIEW_MODE: string = 'uplayer_view_mode'
const KEY_SELECTED_FOLDERS: string = 'uplayer_selected_folders'
const KEY_FAVORITES_SELECTED: string = 'uplayer_favorites_selected'

export const AUDIO_EXTENSIONS: string[] = [
  '.mp3', '.flac', '.wav', '.aac', '.m4a', '.ogg', '.wma', '.ape',
  '.opus', '.aiff', '.aif', '.alac', '.dsf', '.dff', '.wv', '.tta',
  '.mp2', '.mpa', '.mpeg', '.mpc', '.ac3', '.eac3', '.dts', '.ra',
  '.amr', '.awb', '.mid', '.midi', '.xmf', '.rtttl', '.smaf', '.imy',
  '.3gp', '.3g2', '.webm', '.mka'
]

export class AppSettingsData {
  plusButtonScrollHide: boolean = true
  themeMode: string = 'system'
  primaryColor: string = '#007DFF'
  showLyrics: boolean = true
  enableNotification: boolean = true
  eqEnabled: boolean = false
  volumeGain: number = 0
  playSpeed: number = 1
  audioEffect: string = 'none'
  folderSortMode: string = 'name'
  fadeInOut: boolean = false
}

export class DataService {
  private static instance: DataService = new DataService()

  public static getInstance(): DataService {
    return DataService.instance
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
    r['fileName'] = song.fileName
    r['folderPath'] = song.folderPath
    r['folderName'] = song.folderName
    r['duration'] = song.duration
    r['bitrate'] = song.bitrate
    r['sampleRate'] = song.sampleRate
    r['albumArtPath'] = song.albumArtPath
    r['addedTime'] = song.addedTime
    r['isFavorite'] = song.isFavorite
    r['isAvailable'] = song.isAvailable
    r['lyricPath'] = song.lyricPath
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
    song.fileName = r['fileName'] as string
    song.folderPath = r['folderPath'] as string
    song.folderName = r['folderName'] as string
    song.duration = r['duration'] as number
    let rawBitrate: Object | undefined = r['bitrate']
    song.bitrate = rawBitrate !== undefined ? rawBitrate as number : 0
    let rawSampleRate: Object | undefined = r['sampleRate']
    song.sampleRate = rawSampleRate !== undefined ? rawSampleRate as number : 0
    let rawAlbumArt: Object | undefined = r['albumArtPath']
    song.albumArtPath = rawAlbumArt !== undefined ? rawAlbumArt as string : ''
    song.addedTime = r['addedTime'] as number
    song.isFavorite = r['isFavorite'] as boolean
    song.isAvailable = r['isAvailable'] as boolean
    song.lyricPath = r['lyricPath'] as string
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
    const arr: object[] = this.readJsonArray(KEY_SONG_LIST)
    const result: SongInfo[] = []
    for (let i = 0; i < arr.length; i++) {
      result.push(this.recordToSong(arr[i] as Record<string, Object>))
    }
    return result
  }

  saveSongs(songs: SongInfo[]): void {
    const records: Record<string, Object>[] = []
    for (let i = 0; i < songs.length; i++) {
      records.push(this.songToRecord(songs[i]))
    }
    this.writeJsonArray(KEY_SONG_LIST, records as object[])
    AppStorage.setOrCreate(AppStorageKeyConstants.KEY_SONG_LIST, songs)
  }

  addSongs(newSongs: SongInfo[]): void {
    const songs: SongInfo[] = this.getSongs()
    for (let i = 0; i < newSongs.length; i++) {
      songs.push(newSongs[i])
    }
    this.saveSongs(songs)
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
  }

  removeSongsByFolder(folderPath: string): void {
    const songs: SongInfo[] = this.getSongs()
    const filtered: SongInfo[] = []
    for (let i = 0; i < songs.length; i++) {
      if (songs[i].folderPath !== folderPath) {
        filtered.push(songs[i])
      }
    }
    this.saveSongs(filtered)
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
      s.enableNotification = r['enableNotification'] as boolean
      s.eqEnabled = r['eqEnabled'] as boolean
      s.volumeGain = r['volumeGain'] as number
      s.playSpeed = r['playSpeed'] as number
      s.audioEffect = r['audioEffect'] as string
      let rawFolderSort: Object | undefined = r['folderSortMode']
      s.folderSortMode = rawFolderSort !== undefined ? rawFolderSort as string : 'name'
      let rawFadeInOut: Object | undefined = r['fadeInOut']
      s.fadeInOut = rawFadeInOut !== undefined ? rawFadeInOut as boolean : false
      return s
    } catch (e) {
      return new AppSettingsData()
    }
  }

  saveSettings(settings: AppSettingsData): void {
    const r: Record<string, Object> = {}
    r['plusButtonScrollHide'] = settings.plusButtonScrollHide
    r['themeMode'] = settings.themeMode
    r['primaryColor'] = settings.primaryColor
    r['showLyrics'] = settings.showLyrics
    r['enableNotification'] = settings.enableNotification
    r['eqEnabled'] = settings.eqEnabled
    r['volumeGain'] = settings.volumeGain
    r['playSpeed'] = settings.playSpeed
    r['audioEffect'] = settings.audioEffect
    r['folderSortMode'] = settings.folderSortMode
    r['fadeInOut'] = settings.fadeInOut
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

  getSelectedFolderPaths(): string[] {
    const raw = this.getPref().getValue(KEY_SELECTED_FOLDERS)
    if (raw === undefined) return []
    try {
      return JSON.parse(raw as string) as string[]
    } catch (e) {
      return []
    }
  }

  setSelectedFolderPaths(paths: string[]): void {
    this.getPref().preferencesPut(KEY_SELECTED_FOLDERS, JSON.stringify(paths))
    AppStorage.setOrCreate(KEY_SELECTED_FOLDERS, paths)
  }

  isFavoritesSelected(): boolean {
    const raw = this.getPref().getValue(KEY_FAVORITES_SELECTED)
    if (raw === undefined) return false
    return raw as boolean
  }

  setFavoritesSelected(selected: boolean): void {
    this.getPref().preferencesPut(KEY_FAVORITES_SELECTED, selected)
    AppStorage.setOrCreate(KEY_FAVORITES_SELECTED, selected)
  }

  // ═══════════ Init ═══════════

  initToAppStorage(): void {
    AppStorage.setOrCreate(KEY_SETTINGS, this.getSettings())
    AppStorage.setOrCreate(KEY_SORT_MODE, this.getSortMode())
    AppStorage.setOrCreate(KEY_VIEW_MODE, this.getViewMode())
    AppStorage.setOrCreate(AppStorageKeyConstants.KEY_SONG_LIST, this.getSongs())
    AppStorage.setOrCreate(KEY_FOLDER_LIST, this.getFolders())
    AppStorage.setOrCreate(KEY_SELECTED_FOLDERS, this.getSelectedFolderPaths())
    AppStorage.setOrCreate(KEY_FAVORITES_SELECTED, this.isFavoritesSelected())
    const s: AppSettingsData = this.getSettings()
    AppStorage.setOrCreate('uplayer_primary_color', s.primaryColor)
    AppStorage.setOrCreate('uplayer_theme_mode', s.themeMode)
    AppStorage.setOrCreate('uplayer_show_lyrics', s.showLyrics)
    AppStorage.setOrCreate('uplayer_notification', s.enableNotification)
    AppStorage.setOrCreate('uplayer_fade_in_out', s.fadeInOut)
  }
}
