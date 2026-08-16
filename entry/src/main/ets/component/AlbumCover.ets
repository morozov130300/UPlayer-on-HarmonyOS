import { image } from '@kit.ImageKit'
import { SongInfo } from '../model/SongInfo'
import { AudioMetadataService } from '../service/AudioMetadataService'

@Component
export struct AlbumCover {
  @Prop @Watch('onSongChange') song: SongInfo = new SongInfo()
  @Prop coverWidth: Length = 48
  @Prop coverHeight: Length = 48
  @Prop coverRadius: Length = 0
  @Prop fit: ImageFit = ImageFit.Cover
  @State cover: image.PixelMap | undefined = undefined
  private requestId: number = 0

  aboutToAppear(): void {
    this.load()
  }

  aboutToDisappear(): void {
    this.requestId++
    this.releaseCover()
  }

  private onSongChange(): void {
    this.load()
  }

  private async load(): Promise<void> {
    const requestId: number = ++this.requestId
    const songId: string = this.song.id
    const songPath: string = this.song.uri.length > 0 ? this.song.uri : this.song.filePath
    this.releaseCover()
    const loaded: image.PixelMap | undefined = await AudioMetadataService.getInstance().fetchAlbumCover(this.song)
    const currentPath: string = this.song.uri.length > 0 ? this.song.uri : this.song.filePath
    if (requestId !== this.requestId || songId !== this.song.id || songPath !== currentPath) {
      if (loaded !== undefined) {
        loaded.release()
      }
      return
    }
    this.cover = loaded
  }

  private releaseCover(): void {
    if (this.cover !== undefined) {
      this.cover.release()
      this.cover = undefined
    }
  }

  build() {
    Image(this.cover !== undefined ? this.cover : $r('app.media.ic_public_music'))
      .width(this.coverWidth)
      .height(this.coverHeight)
      .borderRadius(this.coverRadius)
      .objectFit(this.fit)
  }
}
