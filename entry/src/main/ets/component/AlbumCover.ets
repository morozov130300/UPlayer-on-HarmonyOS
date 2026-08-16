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
    const loaded: image.PixelMap | undefined = await AudioMetadataService.getInstance().fetchAlbumCover(this.song)
    if (requestId !== this.requestId) {
      if (loaded !== undefined) {
        loaded.release()
      }
      return
    }
    this.releaseCover()
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
