import { SongInfo } from '../model/SongInfo'
import { FolderInfo } from '../model/FolderInfo'
import { PreferencesUtil } from '../common/utils/PreferencesUtil'
import Logger from '../common/utils/Logger'

const TAG = 'DataService'

const KEY_SONG_LIST: string = 'uplayer_song_list'
const KEY_FOLDER_LIST: string = 'uplayer_folder_list'
const KEY_SETTINGS: string = 'uplayer_settings'
const KEY_ACTIVE_FOLDER: string = 'uplayer_active_folder'
const KEY_SORT_MODE: string = 'uplayer_sort_mode'
const KEY_VIEW_MODE: string = 'uplayer_view_mode'
const KEY_LIST_MODE: string = 'uplayer_list_mode'

export class AppSettingsData {
  plusButtonVisible: boolean = true
  themeMode: string = 'system'
  primaryColor: string = '#007DFF'
  showLyrics: boolean = true
  enableNotification: boolean = true
  backgroundPlayback: boolean = true
  eqEnabled: boolean = false
  volumeGain: number = 0
  playSpeed: number = 1
  audioEffect: string = 'none'
}

function asString(val: Object): string {
  return val as string
}

function asNumber(val: Object): number {
  return val as number
}

function asBoolean(val: Object): boolean {
  return val as boolean
}

export class DataService {
  private static instance: DataService = new DataService()

  public static getInstance(): DataService {
    return DataService.instance
  }

  private getPref(): PreferencesUtil {
    return PreferencesUtil.getInstance()
  }

  private getJsonFromPref(key: string): string {
    const raw = this.getPref().getValue(key)
    if (raw !== undefined) {
      return raw as string
    }
    return '[]'
  }

  private setJsonToPref(key: string, data: object[]): void {
    this.getPref().preferencesPut(key, JSON.stringify(data))
  }

  private parseSongInfo(obj: object): SongInfo {
    const song: SongInfo = new SongInfo()
    const record = obj as Record<string, Object>
    song.id = asString(record['id'])
    song.name = asString(record['name'])
    song.artist = asString(record['artist'])
    song.album = asString(record['album'])
    song.filePath = asString(record['filePath'])
    song.fileName = asString(record['fileName'])
    song.folderPath = asString(record['folderPath'])
    song.folderName = asString(record['folderName'])
    song.duration = asNumber(record['duration'])
    song.addedTime = asNumber(record['addedTime'])
    song.isFavorite = asBoolean(record['isFavorite'])
    song.isAvailable = asBoolean(record['isAvailable'])
    song.lyricPath = asString(record['lyricPath'])
    return song
  }

  private parseFolderInfo(obj: object): FolderInfo {
    const folder: FolderInfo = new FolderInfo()
    const record = obj as Record<string, Object>
    folder.id = asString(record['id'])
    folder.name = asString(record['name'])
    folder.path = asString(record['path'])
    folder.songCount = asNumber(record['songCount'])
    folder.addedTime = asNumber(record['addedTime'])
    folder.isAvailable = asBoolean(record['isAvailable'])
    return folder
  }

  // ═══════════ Song CRUD ═══════════

  getSongs(): SongInfo[] {
    const json: string = this.getJsonFromPref(KEY_SONG_LIST)
    try {
      const arr: object[] = JSON.parse(json)
      const result: SongInfo[] = []
      for (let i = 0; i < arr.length; i++) {
        result.push(this.parseSongInfo(arr[i]))
      }
      return result
    } catch (e) {
      Logger.error(TAG, 'getSongs parse error')
      return []
    }
  }

  saveSongs(songs: SongInfo[]): void {
    this.setJsonToPref(KEY_SONG_LIST, songs)
    AppStorage.setOrCreate(KEY_SONG_LIST, songs)
  }

  addSong(song: SongInfo): void {
    const songs: SongInfo[] = this.getSongs()
    songs.push(song)
    this.saveSongs(songs)
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
    const json: string = this.getJsonFromPref(KEY_FOLDER_LIST)
    try {
      const arr: object[] = JSON.parse(json)
      const result: FolderInfo[] = []
      for (let i = 0; i < arr.length; i++) {
        result.push(this.parseFolderInfo(arr[i]))
      }
      return result
    } catch (e) {
      Logger.error(TAG, 'getFolders parse error')
      return []
    }
  }

  saveFolders(folders: FolderInfo[]): void {
    this.setJsonToPref(KEY_FOLDER_LIST, folders)
    AppStorage.setOrCreate(KEY_FOLDER_LIST, folders)
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

  // ═══════════ Settings ═══════════

  getSettings(): AppSettingsData {
    const raw = this.getPref().getValue(KEY_SETTINGS)
    if (raw !== undefined) {
      try {
        const parsed: Record<string, Object> = JSON.parse(raw as string)
        const settings: AppSettingsData = new AppSettingsData()
        settings.plusButtonVisible = asBoolean(parsed['plusButtonVisible'])
        settings.themeMode = asString(parsed['themeMode'])
        settings.primaryColor = asString(parsed['primaryColor'])
        settings.showLyrics = asBoolean(parsed['showLyrics'])
        settings.enableNotification = asBoolean(parsed['enableNotification'])
        settings.backgroundPlayback = asBoolean(parsed['backgroundPlayback'])
        settings.eqEnabled = asBoolean(parsed['eqEnabled'])
        settings.volumeGain = asNumber(parsed['volumeGain'])
        settings.playSpeed = asNumber(parsed['playSpeed'])
        settings.audioEffect = asString(parsed['audioEffect'])
        return settings
      } catch (e) {
        return new AppSettingsData()
      }
    }
    return new AppSettingsData()
  }

  saveSettings(settings: AppSettingsData): void {
    this.getPref().preferencesPut(KEY_SETTINGS, JSON.stringify(settings))
    AppStorage.setOrCreate(KEY_SETTINGS, settings)
  }

  // ═══════════ Active folder filter ═══════════

  getActiveFolderFilter(): string {
    const raw = this.getPref().getValue(KEY_ACTIVE_FOLDER)
    if (raw !== undefined) {
      return raw as string
    }
    return ''
  }

  setActiveFolderFilter(folderPath: string): void {
    this.getPref().preferencesPut(KEY_ACTIVE_FOLDER, folderPath)
    AppStorage.setOrCreate(KEY_ACTIVE_FOLDER, folderPath)
  }

  // ═══════════ Sort mode ═══════════

  getSortMode(): string {
    const raw = this.getPref().getValue(KEY_SORT_MODE)
    if (raw !== undefined) {
      return raw as string
    }
    return 'name'
  }

  setSortMode(mode: string): void {
    this.getPref().preferencesPut(KEY_SORT_MODE, mode)
    AppStorage.setOrCreate(KEY_SORT_MODE, mode)
  }

  // ═══════════ View mode ═══════════

  getViewMode(): string {
    const raw = this.getPref().getValue(KEY_VIEW_MODE)
    if (raw !== undefined) {
      return raw as string
    }
    return 'flat'
  }

  setViewMode(mode: string): void {
    this.getPref().preferencesPut(KEY_VIEW_MODE, mode)
    AppStorage.setOrCreate(KEY_VIEW_MODE, mode)
  }

  // ═══════════ List mode ═══════════

  getListMode(): string {
    const raw = this.getPref().getValue(KEY_LIST_MODE)
    if (raw !== undefined) {
      return raw as string
    }
    return 'all'
  }

  setListMode(mode: string): void {
    this.getPref().preferencesPut(KEY_LIST_MODE, mode)
    AppStorage.setOrCreate(KEY_LIST_MODE, mode)
  }

  // ═══════════ Initialize all from Preferences into AppStorage ═══════════

  initToAppStorage(): void {
    const songs: SongInfo[] = this.getSongs()
    AppStorage.setOrCreate(KEY_SONG_LIST, songs)
    const folders: FolderInfo[] = this.getFolders()
    AppStorage.setOrCreate(KEY_FOLDER_LIST, folders)
    const settings: AppSettingsData = this.getSettings()
    AppStorage.setOrCreate(KEY_SETTINGS, settings)
    const activeFolder: string = this.getActiveFolderFilter()
    AppStorage.setOrCreate(KEY_ACTIVE_FOLDER, activeFolder)
    const sortMode: string = this.getSortMode()
    AppStorage.setOrCreate(KEY_SORT_MODE, sortMode)
    const viewMode: string = this.getViewMode()
    AppStorage.setOrCreate(KEY_VIEW_MODE, viewMode)
    const listMode: string = this.getListMode()
    AppStorage.setOrCreate(KEY_LIST_MODE, listMode)
  }
}
