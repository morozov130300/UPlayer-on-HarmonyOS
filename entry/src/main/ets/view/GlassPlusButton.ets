// 共用加号按钮：磨砂玻璃盘 + 加号字形 + 阴影层，带按压缩放动画与智感握姿贴边滑动。
// 由 Index 全局悬浮调用：Tab 级挂载/卸载走 Insert/Delete 过渡（由 Index 经 onSelected 提前触发，
// 与页面切换动画并行）；页面级可见性（滚动隐藏等）经 visible 在组件内部淡入淡出。
import { curves } from '@kit.ArkUI'
import { ColorHelper } from '../common/utils/ColorHelper'
import { StyleConstants } from '../common/constants/StyleConstants'
import { KEY_HOLDING_HAND_LEFT } from '../service/HoldingHandService'

@Component
export struct GlassPlusButton {
  // 加号底边位置：由页面传入（Index 计算为「紧贴播控条上沿」，跨断点自适应）
  bottomInset: number = 0
  onPlusClick: () => void = (): void => {}
  // 页面上报的可见性（滚动隐藏设置/多选/编辑态）：只在组件内部做淡入淡出，不参与挂载/卸载
  @Prop @Watch('onVisibleChange') visible: boolean = true
  // 淡入淡出透明度：只在动画闭包内跟随 visible 变化
  @State plusOpacity: number = 1
  // 智感握姿：左手握持 → 靠左；其余（右手/双手/无握持/未知即默认）→ 靠右。
  // 滤波与订阅由 HoldingHandService 统一持有，本组件只订阅它的广播结果
  @StorageLink(KEY_HOLDING_HAND_LEFT) @Watch('onHoldingHandLeftChange') holdingHandLeft: boolean = false
  // 真正参与布局的贴边状态：只在 animateTo 闭包里跟随 holdingHandLeft 变化，
  // 握姿切换时加号才会「滑」到另一侧（position 支持属性动画），而不是瞬移
  @State plusOnLeft: boolean = false
  @State plusBtnScale: number = 1.0
  // 握姿切换的滑动曲线：弹簧跟手，与设置页主题切换等动效保持一致的手感
  private readonly PLUS_SIDE_SPRING_RESPONSE: number = 0.4
  private readonly PLUS_SIDE_SPRING_DAMPING: number = 0.8
  @StorageLink('uplayer_primary_color') primaryColor: string = '#007DFF'
  @StorageLink('uplayer_display_size_scale') displaySizeScale: number = 1.0

  private scaledSize(size: number): number {
    return Math.round(size * this.displaySizeScale)
  }

  aboutToAppear(): void {
    // 首次进入按当前握姿直接落位，不做动画（避免首帧从默认侧滑过来）
    this.plusOnLeft = this.holdingHandLeft
    // 若挂载时页面就处于隐藏态（如歌单滚动中切回），直接透明，不放淡出动画
    this.plusOpacity = this.visible ? 1 : 0
  }

  // 页面级可见性变化：透明度放进动画闭包做淡入淡出；隐藏期间不响应点击
  onVisibleChange(): void {
    this.getUIContext()?.animateTo({ duration: 250, curve: Curve.EaseOut }, () => {
      this.plusOpacity = this.visible ? 1 : 0
    })
  }

  // 智感握姿切换：把贴边状态放进动画闭包，让加号从一侧滑到另一侧
  onHoldingHandLeftChange(): void {
    const isLeft: boolean = this.holdingHandLeft
    if (isLeft === this.plusOnLeft) {
      return
    }
    this.getUIContext()?.animateTo({
      curve: curves.springMotion(this.PLUS_SIDE_SPRING_RESPONSE, this.PLUS_SIDE_SPRING_DAMPING)
    }, () => {
      this.plusOnLeft = isLeft
    })
  }

  build() {
    // 加号组件：磨砂玻璃盘 + 加号字形。玻璃盘用「磨砂 backgroundEffect（背后内容模糊透出）
    // + 清亮玻璃描边」，加号字形用 ic_public_add_norm_filled（主题色，带圆圈）。
    Stack({ alignContent: Alignment.Center }) {
      // 阴影层：独立圆形，比底板略小避免阴影溢出
      Row()
        .width(this.scaledSize(44)).height(this.scaledSize(44))
        .borderRadius(this.scaledSize(22))
        .backgroundColor(Color.Transparent)
        .shadow({
          radius: this.scaledSize(20),
          color: ColorHelper.hexWithAlpha(this.primaryColor, 'AA'),
          offsetX: 0,
          offsetY: this.scaledSize(6)
        })
      Row()
        .width(this.scaledSize(44)).height(this.scaledSize(44))
        .borderRadius(this.scaledSize(22))
        .backgroundColor(Color.Transparent)
        .backgroundEffect({ radius: 2, saturation: 1.0, brightness: 1.0 })
        .border({ width: 1, color: 'rgba(255,255,255,0.35)' })
      Image($r('app.media.ic_public_add_norm_filled'))
        .width(this.scaledSize(48)).height(this.scaledSize(48))
        .fillColor(this.primaryColor)
    }
    .scale({ x: this.plusBtnScale, y: this.plusBtnScale })
    .opacity(this.plusOpacity)
    // 隐藏（含淡出过程中）不拦截触摸，点击穿透到下层列表
    .hitTestBehavior(this.visible ? HitTestMode.Default : HitTestMode.None)
    // 智感握姿：只切换贴边方向，不改变与底部的间距，避免握姿切换时按钮上下跳动。
    // 读 plusOnLeft（动画态）而不是 holdingHandLeft，切换才会走滑动动画
    .position({
      bottom: this.bottomInset,
      left: this.plusOnLeft ? this.scaledSize(20) : undefined,
      right: this.plusOnLeft ? undefined : this.scaledSize(20)
    })
    .transition({ type: TransitionType.Insert, opacity: 0, scale: { x: 0.5, y: 0.5 } })
    .transition({ type: TransitionType.Delete, opacity: 0, scale: { x: 0.5, y: 0.5 } })
    .onClick(() => {
      this.plusBtnScale = 0.85
      setTimeout(() => {
        this.plusBtnScale = 1.0
      }, StyleConstants.ANIMATION_PRESS_DELAY_SHORT)
      this.onPlusClick()
    })
  }
}
