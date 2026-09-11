// 歌曲信息数据模型
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
    const pathDotIdx: number = decodedPath.lastIndexOf('.')
    song.lyricPath = pathDotIdx > 0 ? decodedPath.substring(0, pathDotIdx) + '.lrc' : ''
    song.lyricUri = pathDotIdx > 0 ? filePath.substring(0, pathDotIdx) + '.lrc' : ''
    return song
  }
}
