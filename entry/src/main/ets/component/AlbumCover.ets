import { image } from '@kit.ImageKit'
import { SongInfo } from '../model/SongInfo'
import { AlbumCoverLease, AlbumCoverSize, AudioMetadataService } from '../service/AudioMetadataService'

const COVER_RETRY_MAX: number = 2
const COVER_RETRY_BASE_MS: number = 800

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
  private retryTimer: number = -1
  private retryCount: number = 0

  aboutToAppear(): void {
    this.load()
  }

  aboutToDisappear(): void {
    this.invalidate()
  }

  private onSongChange(): void {
    this.invalidate()
    this.load()
  }

  private invalidate(): void {
    this.requestId++
    this.retryCount = 0
    this.clearRetryTimer()
    this.releaseCover()
  }

  private clearRetryTimer(): void {
    if (this.retryTimer !== -1) {
      clearTimeout(this.retryTimer)
      this.retryTimer = -1
    }
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
      if (loaded === undefined) {
        // 确认无封面则不重试；否则按有限次数退避重试可恢复失败
        if (!AudioMetadataService.getInstance().isCoverConfirmedAbsent(this.song) &&
          this.retryCount < COVER_RETRY_MAX) {
          this.scheduleRetry(requestId)
        }
        return
      }
      this.retryCount = 0
      const previousLease: AlbumCoverLease | undefined = this.coverLease
      this.coverLease = loaded
      this.cover = loaded.pixelMap
      previousLease?.release()
    } catch (_) {
      if (requestId === this.requestId && this.retryCount < COVER_RETRY_MAX) {
        this.scheduleRetry(requestId)
      }
    }
  }

  private scheduleRetry(requestId: number): void {
    this.clearRetryTimer()
    this.retryCount++
    const delay: number = COVER_RETRY_BASE_MS * Math.pow(2, this.retryCount - 1)
    this.retryTimer = setTimeout(() => {
      this.retryTimer = -1
      if (requestId === this.requestId) {
        this.load()
      }
    }, delay)
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
