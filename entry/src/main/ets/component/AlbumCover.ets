// ArkUI 26 Beta1: 接口定义变更（误报，本项目已是Stage模型）+ UX视觉布局变更（Text默认开启沉浸式材质，系统行为）
import { image } from '@kit.ImageKit'
import { SongInfo } from '../model/SongInfo'
import { AlbumCoverLease, AlbumCoverSize, AudioMetadataService } from '../service/AudioMetadataService'

const COVER_RETRY_MAX: number = 2
const COVER_RETRY_BASE_MS: number = 200

@Component
export struct AlbumCover {
  @Prop @Watch('onSongChange') song: SongInfo = new SongInfo()
  @Prop coverWidth: Length = 48
  @Prop coverHeight: Length = 48
  @Prop coverRadius: Length = 0
  @Prop fit: ImageFit = ImageFit.Cover
  @Prop decodeSize: number = AlbumCoverSize.SMALL
  @State cover: image.PixelMap | undefined = undefined
  @State isCoverSettled: boolean = false
  private coverLease: AlbumCoverLease | undefined = undefined
  private requestId: number = 0
  private retryTimer: number = -1
  private retryCount: number = 0
  // 当前已上屏封面对应的歌曲标识（见 songKey）
  private loadedKey: string = ''

  aboutToAppear(): void {
    // 首帧必须同步定状态：播控条等场景切页签会反复销毁重建本组件，异步加载会让首帧空白，
    // 表现为封面/占位图闪一下。缓存已解码时同步上屏；已确认无封面时同步走占位
    if (!this.applyCachedCover()) {
      if (AudioMetadataService.getInstance().isCoverConfirmedAbsent(this.song)) {
        this.isCoverSettled = true
      }
      this.load()
    }
  }

  aboutToDisappear(): void {
    this.invalidate()
  }

  // 歌曲标识：id + 源路径 + 解码尺寸。@Prop 对对象做深拷贝，父组件重推同一首歌
  // 也会得到新对象引用，必须按业务标识判等，否则会被误判为换歌而清空重载
  private songKey(): string {
    const sourcePath: string = this.song.uri.length > 0 ? this.song.uri : this.song.filePath
    return `${this.song.id}|${sourcePath}|${this.decodeSize}`
  }

  private onSongChange(): void {
    if (this.songKey() === this.loadedKey && this.cover !== undefined) {
      // 同一首歌（父组件重渲染/深拷贝重推）：沿用已上屏的封面，不重载
      return
    }
    this.requestId++
    this.retryCount = 0
    this.isCoverSettled = false
    this.clearRetryTimer()
    if (!this.applyCachedCover()) {
      // 换歌且缓存未命中：先保留旧图，等新图就绪再替换，避免中间出现空白帧
      this.load()
    }
  }

  // 同步用缓存封面直接上屏；命中返回 true
  private applyCachedCover(): boolean {
    const lease: AlbumCoverLease | undefined =
      AudioMetadataService.getInstance().peekAlbumCover(this.song, this.decodeSize)
    if (lease === undefined) {
      return false
    }
    this.requestId++
    this.retryCount = 0
    this.clearRetryTimer()
    const previousLease: AlbumCoverLease | undefined = this.coverLease
    this.coverLease = lease
    this.cover = lease.pixelMap
    this.isCoverSettled = true
    this.loadedKey = this.songKey()
    previousLease?.release()
    return true
  }

  private invalidate(): void {
    this.requestId++
    this.retryCount = 0
    this.isCoverSettled = false
    this.loadedKey = ''
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
    const key: string = this.songKey()
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
        } else {
          // 确认无封面：清空旧图走占位（换歌等待期间不会走到这里，仍保留旧图）
          this.isCoverSettled = true
          this.loadedKey = key
          this.releaseCover()
        }
        return
      }
      this.retryCount = 0
      const previousLease: AlbumCoverLease | undefined = this.coverLease
      this.coverLease = loaded
      this.cover = loaded.pixelMap
      this.loadedKey = key
      this.isCoverSettled = true
      previousLease?.release()
    } catch (_) {
      if (requestId === this.requestId) {
        if (this.retryCount < COVER_RETRY_MAX) {
          this.scheduleRetry(requestId)
        } else {
          // 重试耗尽仍失败：清空旧图走占位，避免一直显示上一首的封面
          this.isCoverSettled = true
          this.loadedKey = key
          this.releaseCover()
        }
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
    Stack({ alignContent: Alignment.Center }) {
      if (this.cover !== undefined) {
        Image(this.cover)
          .width(this.coverWidth)
          .height(this.coverHeight)
          .objectFit(this.fit)
      } else if (this.isCoverSettled) {
        Image($r('app.media.ic_public_music'))
          .width('42%')
          .height('42%')
          .objectFit(ImageFit.Contain)
          .fillColor(this.song.isAvailable ? $r('app.color.player_icon_color') : $r('app.color.text_sixty_color'))
      }
    }
    .width(this.coverWidth)
    .height(this.coverHeight)
    .borderRadius(this.coverRadius)
    .clip(true)
  }
}
