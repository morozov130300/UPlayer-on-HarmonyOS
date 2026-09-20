// 歌曲信息数据模型
import { LyricFile } from '../common/constants/LyricConst'

export class SongInfo {
  id: string = ''
  name: string = ''
  title: string = ''
  artist: string = ''
  album: string = ''
  filePath: string = ''
  uri: string = ''
  fileName: string = ''
  folderPath: string = ''
  folderName: string = ''
  duration: number = 0
  bitrate: number = 0
  sampleRate: number = 0
  addedTime: number = Date.now()
  sortOrder: number = 0
  isFavorite: boolean = false
  isAvailable: boolean = true
  lyricPath: string = ''
  lyricUri: string = ''

  // 扩展元数据字段（从 AVMetadata 读取）
  genre: string = ''
  year: string = ''
  track: string = ''
  disc: string = ''
  comment: string = ''
  composer: string = ''
  conductor: string = ''
  albumArtist: string = ''
  author: string = ''
  language: string = ''
  mimeType: string = ''
  dateTime: string = ''
  encoder: string = ''
  description: string = ''
  hasAudio: string = ''
  hasVideo: string = ''
  videoWidth: string = ''
  videoHeight: string = ''

  static createId(): string {
    return 'song_' + Date.now() + '_' + Math.floor(Math.random() * 1000000)
  }

  static fromFile(filePath: string, fileName: string): SongInfo {
    const song: SongInfo = new SongInfo()
    song.id = SongInfo.createId()
    song.uri = filePath
    const decodedPath: string = decodeURIComponent(filePath)
    const decodedName: string = decodeURIComponent(fileName)
    song.filePath = decodedPath
    song.fileName = decodedName
    const dotIdx: number = decodedName.lastIndexOf('.')
    const baseName: string = dotIdx > 0 ? decodedName.substring(0, dotIdx) : decodedName
    song.name = baseName
    song.title = baseName
    song.duration = 0
    song.bitrate = 0
    song.sampleRate = 0
    song.addedTime = Date.now()
    song.isFavorite = false
    song.isAvailable = true
    const lastSlash: number = decodedPath.lastIndexOf('/')
    const lastBackslash: number = decodedPath.lastIndexOf('\\')
    const sepIdx: number = lastSlash > lastBackslash ? lastSlash : lastBackslash
    if (sepIdx >= 0) {
      song.folderPath = decodedPath.substring(0, sepIdx)
      const folderLastSlash: number = song.folderPath.lastIndexOf('/')
      const folderLastBackslash: number = song.folderPath.lastIndexOf('\\')
      const folderSepIdx: number = folderLastSlash > folderLastBackslash ? folderLastSlash : folderLastBackslash
      song.folderName = folderSepIdx >= 0 ? song.folderPath.substring(folderSepIdx + 1) : song.folderPath
    }
    song.lyricPath = SongInfo.withLyricExtension(decodedPath, LyricFile.LRC)
    // lyricUri 基于未解码 URI 单独计算索引：解码/未编码路径长度可能不同（中文、空格等会被 percent-encode），
    // 混用两边的索引会拼出错误路径导致歌词文件永远找不到（ENOENT）
    song.lyricUri = SongInfo.withLyricExtension(filePath, LyricFile.LRC)
    return song
  }

  // 把音频路径替换成同名兄弟歌词文件的路径（扩展名可指定 .lrc / .krc）。
  // 派生规则集中在此，避免 fromFile 与自愈回填两处各写一套索引逻辑而再次分叉。
  static withLyricExtension(basePath: string, ext: string): string {
    if (basePath.length === 0) {
      return ''
    }
    const lastSlash: number = basePath.lastIndexOf('/')
    const lastBackslash: number = basePath.lastIndexOf('\\')
    const sepIdx: number = lastSlash > lastBackslash ? lastSlash : lastBackslash
    const dotIdx: number = basePath.lastIndexOf('.')
    // 点必须位于最后一个路径分隔符之后，否则形如 ".hidden" 或无扩展名路径会派生出错误结果
    if (dotIdx <= 0 || dotIdx <= sepIdx) {
      return ''
    }
    return basePath.substring(0, dotIdx) + ext
  }
}
