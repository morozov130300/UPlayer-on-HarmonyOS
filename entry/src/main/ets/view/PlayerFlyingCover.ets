import { SongInfo } from '../model/SongInfo'
import { AlbumCover } from '../component/AlbumCover'
import { DataService } from '../service/DataService'
import { AppStorageKeyConstants } from '../common/constants/AppStorageKeyConstants'
import { audioQualityBadgeDetail, audioQualityBadgeText, audioQualityTier } from '../common/utils/AudioQualityUtil'
import { AudioQualityBadge } from '../component/AudioQualityBadge'

// 大封面圆角（与 MusicInfoComponent.CoverInfo 内 AlbumCover 保持一致）
const ORIGIN_RADIUS: number = 8
// 歌词页小封面圆角（对应 app.float.label_border = 4vp）
const TARGET_RADIUS: number = 4
// 大封面阴影（与 CoverInfo 的 shadow 保持一致）
const ORIGIN_SHADOW_RADIUS: number = 12
const ORIGIN_SHADOW_OPACITY: number = 0.15
// 音质标签在进度越过该值时完全淡出：封面缩到小尺寸后标签已不可读，且会压住歌词页内容
const BADGE_FADE_END: number = 0.08
const COVER_DECODE_SIZE: number = 640

function clamp01(value: number): number {
  if (value < 0) {
    return 0
  }
  if (value > 1) {
    return 1
  }
  return value
}

function lerp(start: number, end: number, t: number): number {
  return start + (end - start) * t
}

/**
 * 跨页一镜到底的封面浮层。
 *
 * Swiper 两页各自被页边界裁剪、且同时挂载，封面无法物理跨页，因此把封面提升到
 * Swiper 父级 Stack 的顶层渲染，两页内只保留同尺寸透明占位。视觉结果与共享元素一致：
 * 同一张封面从第 0 页大图的位置/尺寸连续过渡到第 1 页小封面的位置/尺寸。
 *
 * 进度 progress（0=大封面页，1=歌词页）由 Swiper 逐帧回调驱动，几何量随手指实时插值。
 * 位移按中心点插值，保证缩放是围绕封面中心收缩而不是从左上角抽出。
 */
@Component
export struct PlayerFlyingCover {
  @Prop progress: number = 0
  @Prop originX: number = 0
  @Prop originY: number = 0
  @Prop originWidth: number = 0
  @Prop originHeight: number = 0
  @Prop targetX: number = 0
  @Prop targetY: number = 0
  @Prop targetWidth: number = 0
  @Prop targetHeight: number = 0
  @StorageLink(AppStorageKeyConstants.KEY_SONG_LIST) songList: SongInfo[] = []
  @StorageProp('uplayer_current_song_id') currentSongId: string = ''
  @StorageLink('uplayer_font_size_scale') fontSizeScale: number = 1.0

  private currentSong(): SongInfo {
    return DataService.currentSongFromList(this.songList, this.currentSongId)
  }

  private coverWidth(): number {
    return lerp(this.originWidth, this.targetWidth, clamp01(this.progress))
  }

  private coverHeight(): number {
    return lerp(this.originHeight, this.targetHeight, clamp01(this.progress))
  }

  private coverRadius(): number {
    return lerp(ORIGIN_RADIUS, TARGET_RADIUS, clamp01(this.progress))
  }

  // 中心点插值：直接插值左上角会让缩小过程贴向左上，中心插值才是「原地收缩并位移」的观感
  private coverLeft(): number {
    const t: number = clamp01(this.progress)
    const centerX: number = lerp(this.originX + this.originWidth / 2, this.targetX + this.targetWidth / 2, t)
    return centerX - this.coverWidth() / 2
  }

  private coverTop(): number {
    const t: number = clamp01(this.progress)
    const centerY: number = lerp(this.originY + this.originHeight / 2, this.targetY + this.targetHeight / 2, t)
    return centerY - this.coverHeight() / 2
  }

  private shadowRadius(): number {
    return ORIGIN_SHADOW_RADIUS * (1 - clamp01(this.progress))
  }

  private shadowOffsetY(): number {
    return 4 * (1 - clamp01(this.progress))
  }

  private shadowColor(): string {
    const alpha: number = ORIGIN_SHADOW_OPACITY * (1 - clamp01(this.progress))
    return `rgba(0, 0, 0, ${alpha.toFixed(3)})`
  }

  private badgeOpacity(): number {
    const p: number = clamp01(this.progress)
    if (p >= BADGE_FADE_END) {
      return 0
    }
    return 1 - p / BADGE_FADE_END
  }

  build() {
    Stack({ alignContent: Alignment.BottomStart }) {
      AlbumCover({
        song: this.currentSong(),
        coverWidth: this.coverWidth(),
        coverHeight: this.coverHeight(),
        coverRadius: this.coverRadius(),
        decodeSize: COVER_DECODE_SIZE
      })
        .shadow({
          radius: this.shadowRadius(),
          color: this.shadowColor(),
          offsetX: 0,
          offsetY: this.shadowOffsetY()
        })

      // 音质标签随封面一起搬运：浮层盖在页面内封面之上，若标签仍留在页面里会被浮层遮住
      if (this.badgeOpacity() > 0.01 && audioQualityBadgeText(this.currentSong()).length > 0) {
        AudioQualityBadge({
          tier: audioQualityTier(this.currentSong()),
          detail: audioQualityBadgeDetail(this.currentSong()),
          fontSizeScale: this.fontSizeScale
        })
          .opacity(this.badgeOpacity())
          .hitTestBehavior(HitTestMode.None)
      }
    }
    .width(this.coverWidth())
    .height(this.coverHeight())
    .position({ x: this.coverLeft(), y: this.coverTop() })
    // 浮层盖在 Swiper 之上且其子组件（封面图）会命中触摸测试：
    // None 无法让被盖住的下层 Swiper 触发触摸测试（手指落在封面上时滑动手势失效），
    // 必须用 Transparent 才能把触摸透传给下层，封面图片上起手才能左右翻页
    .hitTestBehavior(HitTestMode.Transparent)
    .zIndex(2)
  }
}
