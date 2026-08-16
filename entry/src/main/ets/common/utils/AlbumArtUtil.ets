import { fileIo as fs } from '@kit.CoreFileKit'

export class AlbumArtUtil {
  static toUri(path: string): string {
    if (path.length === 0) {
      return ''
    }
    if (path.startsWith('file://')) {
      return path
    }
    return 'file://' + path
  }

  static isReadable(path: string): boolean {
    if (path.length === 0) {
      return false
    }
    try {
      fs.accessSync(path)
      return true
    } catch (err) {
      return false
    }
  }
}
