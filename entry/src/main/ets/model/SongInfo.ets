export class SongInfo {
  id: string = '';
  name: string = '';
  artist: string = '';
  album: string = '';
  filePath: string = '';
  fileName: string = '';
  folderPath: string = '';
  folderName: string = '';
  duration: number = 0;
  addedTime: number = Date.now();
  isFavorite: boolean = false;
  isAvailable: boolean = true;
  lyricPath: string = '';

  static createId(): string {
    return 'song_' + Date.now() + '_' + Math.floor(Math.random() * 1000000)
  }

  static fromFile(filePath: string, fileName: string): SongInfo {
    const song: SongInfo = new SongInfo();
    song.id = SongInfo.createId();
    song.filePath = filePath;
    song.fileName = fileName;
    const dotIdx: number = fileName.lastIndexOf('.')
    song.name = dotIdx > 0 ? fileName.substring(0, dotIdx) : fileName
    song.artist = ''
    song.album = ''
    song.duration = 0
    song.addedTime = Date.now()
    song.isFavorite = false
    song.isAvailable = true
    const lastSlash: number = filePath.lastIndexOf('/')
    const lastBackslash: number = filePath.lastIndexOf('\\')
    const sepIdx: number = lastSlash > lastBackslash ? lastSlash : lastBackslash
    if (sepIdx >= 0) {
      song.folderPath = filePath.substring(0, sepIdx)
      song.folderName = filePath.substring(sepIdx + 1, sepIdx > 0 ? filePath.length : filePath.length)
    }
    const lyricPath: string = filePath.substring(0, dotIdx) + '.lrc'
    song.lyricPath = lyricPath
    return song
  }
}
