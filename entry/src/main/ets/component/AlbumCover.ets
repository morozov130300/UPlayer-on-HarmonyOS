import { image } from '@kit.ImageKit'
import { SongInfo } from '../model/SongInfo'
import { AlbumCoverLease, AlbumCoverSize, AudioMetadataService } from '../service/AudioMetadataService'

@Component
export struct AlbumCover {
  @Prop @Watch('onSongChange') song: SongInfo = new SongInfo()
  @Prop coverWidth: Length = 48
  @Prop coverHeight: Length = 48
  @Prop coverRadius: Length = 0
  @Prop fit: ImageFit = ImageFit.Cover
  @Prop decodeSize: number = AlbumCoverSize.SMALL
  @State cover: image.PixelMap | undefined = undefined
  private coverLease: AlbumCoverLease | undefined = undefined
  private requestId: number = 0

  aboutToAppear(): void {
    this.load()
  }

  aboutToDisappear(): void {
    this.requestId++
    this.releaseCover()
  }

  private onSongChange(): void {
    this.requestId++
    this.releaseCover()
    this.load()
  }

  private async load(): Promise<void> {
    const requestId: number = ++this.requestId
    const songId: string = this.song.id
    const songPath: string = this.song.uri.length > 0 ? this.song.uri : this.song.filePath
    try {
      const loaded: AlbumCoverLease | undefined =
        await AudioMetadataService.getInstance().acquireAlbumCover(this.song, this.decodeSize)
      const currentPath: string = this.song.uri.length > 0 ? this.song.uri : this.song.filePath
      if (requestId !== this.requestId || songId !== this.song.id || songPath !== currentPath) {
        loaded?.release()
        return
      }
      const previousLease: AlbumCoverLease | undefined = this.coverLease
      this.coverLease = loaded
      this.cover = loaded?.pixelMap
      previousLease?.release()
    } catch (_) {
      if (requestId === this.requestId) {
        this.releaseCover()
      }
    }
  }

  private releaseCover(): void {
    this.cover = undefined
    this.coverLease?.release()
    this.coverLease = undefined
  }

  build() {
    Image(this.cover !== undefined ? this.cover : $r('app.media.ic_public_music'))
      .width(this.coverWidth)
      .height(this.coverHeight)
      .borderRadius(this.coverRadius)
      .objectFit(this.fit)
  }
}
