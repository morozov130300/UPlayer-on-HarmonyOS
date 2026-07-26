// 歌曲信息数据模型
export class SongInfo {
  id: string = ''
  name: string = ''           // 文件名（不含扩展名）
  title: string = ''          // 歌曲标题（优先使用元数据，回退到文件名）
  artist: string = ''         // 歌手
  album: string = ''          // 专辑
  filePath: string = ''       // 文件URI路径
  fileName: string = ''       // 完整文件名
  folderPath: string = ''     // 所在文件夹路径
  folderName: string = ''     // 所在文件夹名称
  duration: number = 0        // 时长(ms)
  bitrate: number = 0         // 比特率(bps)
  sampleRate: number = 0      // 采样率(Hz)
  albumArtPath: string = ''   // 专辑封面缓存路径
  addedTime: number = Date.now()  // 添加时间戳
  isFavorite: boolean = false // 是否收藏
  isAvailable: boolean = true // 文件是否可用
  lyricPath: string = ''      // 歌词文件路径

  // 生成唯一ID
  static createId(): string {
    return 'song_' + Date.now() + '_' + Math.floor(Math.random() * 1000000)
  }

  // 从文件路径和文件名创建SongInfo，元数据需后续提取
  static fromFile(filePath: string, fileName: string): SongInfo {
    const song: SongInfo = new SongInfo();
    song.id = SongInfo.createId();
    song.filePath = filePath;
    song.fileName = fileName;
    const dotIdx: number = fileName.lastIndexOf('.')
    const baseName: string = dotIdx > 0 ? fileName.substring(0, dotIdx) : fileName
    song.name = baseName
    song.title = baseName
    song.artist = ''
    song.album = ''
    song.duration = 0
    song.bitrate = 0
    song.sampleRate = 0
    song.albumArtPath = ''
    song.addedTime = Date.now()
    song.isFavorite = false
    song.isAvailable = true
    // 提取文件夹路径：filePath 最后一个 / 之前的部分
    const lastSlash: number = filePath.lastIndexOf('/')
    const lastBackslash: number = filePath.lastIndexOf('\\')
    const sepIdx: number = lastSlash > lastBackslash ? lastSlash : lastBackslash
    if (sepIdx >= 0) {
      song.folderPath = filePath.substring(0, sepIdx)
      // 从 folderPath 中提取文件夹名（folderPath 的最后一段）
      const folderLastSlash: number = song.folderPath.lastIndexOf('/')
      const folderLastBackslash: number = song.folderPath.lastIndexOf('\\')
      const folderSepIdx: number = folderLastSlash > folderLastBackslash ? folderLastSlash : folderLastBackslash
      song.folderName = folderSepIdx >= 0 ? song.folderPath.substring(folderSepIdx + 1) : song.folderPath
    }
    const lyricPath: string = filePath.substring(0, dotIdx) + '.lrc'
    song.lyricPath = lyricPath
    return song
  }
}
