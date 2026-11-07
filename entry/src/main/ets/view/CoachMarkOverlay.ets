// 聚光分步引导浮层：全屏半透明遮罩围绕目标控件挖洞 + 主题色描边高亮框 + 说明卡片。
// 目标控件在宿主页面上以 .id() 标记，浮层用 componentUtils 取窗口坐标定位高亮区，
// 点击遮罩/卡片任意处进入下一步，卡片右上角「跳过」直接结束（都回调宿主 onFinish）。
//
// 挖洞实现：整块遮罩画在一张 Canvas 上——先整屏填遮罩色，再以 destination-out
// 合成模式填一个圆角矩形把洞抠掉，抗锯齿圆角一次成型，不存在多块拼图接缝；
// 高亮区位置/尺寸变化由本组件自驱动插值动画（每帧重绘 Canvas），步骤切换时
// 洞体、描边框、说明卡片同步平滑滑动而不是瞬移。
import { ScaleButton } from '../component/ScaleButton'
import { StyleConstants } from '../common/constants/StyleConstants'
import { AppStorageKeyConstants } from '../common/constants/AppStorageKeyConstants'

// 单步引导配置：targetId 为目标组件 .id()，maxHighlightHeight 用于把大容器
// （整页列表等）收敛成一条水平高亮带，0 表示不收敛；
// demoSong = true 时不依赖宿主锚点（targetId 留空走默认高亮带），改为在高亮带内
// 渲染一条「示例歌曲」模拟行，让用户在空库时也能真实体验左滑/长按手势
export class CoachStep {
  targetId: string = ''
  title: string = ''
  description: string = ''
  maxHighlightHeight: number = 0
  demoSong: boolean = false
}

const HIGHLIGHT_PAD: number = 10
const CARD_WIDTH_MAX: number = 340
// 卡片高度估算值（标题 + 两行描述 + 页脚），仅用于「放下方还是上方」的判断
const CARD_EST_HEIGHT: number = 118
const MEASURE_DELAY_MS: number = 100
const MASK_COLOR: string = 'rgba(0,0,0,0.5)'
// 高亮框圆角；挖孔与描边框共用该半径
const CORNER_RADIUS: number = 16
// 高亮区滑动/尺寸变化的插值动画时长
const MOVE_DURATION_MS: number = 240
// 插值动画帧间隔（约 60fps）
const ANIM_FRAME_MS: number = 16
// 演示提示气泡自动消失时长
const DEMO_BUBBLE_MS: number = 1500
// 模拟歌曲行的行高与左滑删除区宽度改为跟随显示缩放的方法（见 struct 内
// demoRowHeight / demoSwipeWidth），与首页 songItemRow / songSwipeDeleteButton 严格对齐

@Component
export struct CoachMarkOverlay {
  // 当前步骤下标（0 起）；由宿主持有，-1 = 关闭（宿主条件渲染卸载本组件）
  @Link @Watch('onStepIndexChanged') stepIndex: number
  steps: CoachStep[] = []
  @Prop primaryColor: string = '#007DFF'
  // 走完最后一步或跳过时回调：宿主负责落「已看过」标记并置 stepIndex = -1
  onFinish: () => void = () => {
  }
  // 宿主判定「当前不便弹引导」（如搜索态/多选态），首次触发前重试，全部重试耗尽则放弃
  isHostBusy: () => boolean = (): boolean => {
    return false
  }
  // 模拟歌曲行要跟真实 songItemRow 一起缩放：显示尺寸/字号两个全局档位都订阅
  @StorageLink('uplayer_display_size_scale') displaySizeScale: number = 1.0
  @StorageLink('uplayer_font_size_scale') fontSizeScale: number = 1.0
  @State private rectX: number = 0
  @State private rectY: number = 0
  @State private rectW: number = 0
  @State private rectH: number = 0
  @State private cardX: number = 0
  @State private cardY: number = 0
  // 卡片实际高度（onAreaChange 实测）：步骤描述行数不同会导致高度变化，
  // 放置位置按实测高度重算，避免卡片压住高亮区或越出屏幕
  @State private cardH: number = CARD_EST_HEIGHT
  @State private overlayW: number = 0
  @State private overlayH: number = 0
  private measureTimer: number = -1
  private busyRetries: number = 0
  // 「跳过」在卡片内部：点击事件会冒泡到卡片层的 advance，用标记让 advance 放行
  private skipTapped: boolean = false
  // 遮罩画布：整屏遮罩 + destination-out 挖圆角孔（见 drawMask）
  private canvasContext: CanvasRenderingContext2D =
    new CanvasRenderingContext2D(new RenderingContextSettings(true))
  // 插值动画：起止高亮区与时间戳，每帧重算 rect* 并重绘 Canvas
  private animFromX: number = 0
  private animFromY: number = 0
  private animFromW: number = 0
  private animFromH: number = 0
  private animToX: number = 0
  private animToY: number = 0
  private animToW: number = 0
  private animToH: number = 0
  private animStartMs: number = 0
  private animTimer: number = -1
  // 模拟歌曲行状态：左滑位移（px 由 translate 直接用 vp 值）、是否处于吸附动画、演示气泡文案
  @State private demoOffsetX: number = 0
  // 气泡文案为空串表示不显示；长按与右侧按钮点击复用同一气泡，文案不同
  @State private demoBubbleText: string = ''
  private demoBubbleTimer: number = -1
  private demoSnapAnimating: boolean = false
  // 本轮拖拽起点位移：PanGesture 的 offsetX 是相对手势起点的累计值，
  // 必须叠加手势开始时的已有位移（例如已吸附在露出删除位再拖）
  private demoPanBaseX: number = 0

  // 显示尺寸缩放（与首页 songItemRow 的 scaledSize 完全一致）
  private scaledSize(size: number): number {
    return Math.round(size * this.displaySizeScale)
  }

  // 模拟歌曲行行高：真实行 padding 上下 10 + 36 封面 = 56（最小约束 52）
  private demoRowHeight(): number {
    return this.scaledSize(56)
  }

  // 左滑露出宽度：与 songSwipeDeleteButton 的容器宽度一致（48vp）
  private demoSwipeWidth(): number {
    return this.scaledSize(48)
  }

  // 弹演示气泡（长按 / 右侧按钮点击共用），1.5s 自动消失
  private showDemoBubble(text: string): void {
    this.demoBubbleText = text
    this.clearDemoBubbleTimer()
    this.demoBubbleTimer = setTimeout((): void => {
      this.demoBubbleTimer = -1
      this.demoBubbleText = ''
    }, DEMO_BUBBLE_MS)
  }

  aboutToAppear(): void {
    this.busyRetries = 0
    // 浮层挂载即接管切页：Index 的 HdsTabs 订阅此计数关闭滑动切页并拦截点击切页，
    // 否则模拟歌曲行的横向左滑会被 Tabs 内置切页手势抢走，直接划到歌单页。
    // 用 +1/-1 计数：两个 TabContent 的浮层可能并存，避免先卸载者误放开
    const active: number = AppStorage.get<number>(AppStorageKeyConstants.KEY_GUIDE_ACTIVE) ?? 0
    AppStorage.setOrCreate<number>(AppStorageKeyConstants.KEY_GUIDE_ACTIVE, active + 1)
    this.scheduleMeasure()
  }

  aboutToDisappear(): void {
    // 浮层卸载恢复切页（走完/跳过/中途切页都会走到这里）
    const active: number = AppStorage.get<number>(AppStorageKeyConstants.KEY_GUIDE_ACTIVE) ?? 0
    AppStorage.setOrCreate<number>(AppStorageKeyConstants.KEY_GUIDE_ACTIVE, Math.max(active - 1, 0))
    this.stopAnim()
    this.clearDemoBubbleTimer()
    if (this.measureTimer >= 0) {
      clearTimeout(this.measureTimer)
      this.measureTimer = -1
    }
  }

  // 步骤切换时复位模拟歌曲行：位移归零、收起气泡
  private resetDemoRow(): void {
    this.demoOffsetX = 0
    this.demoSnapAnimating = false
    this.demoBubbleText = ''
    this.clearDemoBubbleTimer()
  }

  private clearDemoBubbleTimer(): void {
    if (this.demoBubbleTimer >= 0) {
      clearTimeout(this.demoBubbleTimer)
      this.demoBubbleTimer = -1
    }
  }

  // 左滑松手：过半吸附到露出删除按钮位，否则弹回；带 150ms 吸附动画
  private onDemoPanEnd(): void {
    const swipeWidth: number = this.demoSwipeWidth()
    this.demoSnapAnimating = true
    this.demoOffsetX = this.demoOffsetX < -swipeWidth / 2 ? -swipeWidth : 0
    setTimeout((): void => {
      this.demoSnapAnimating = false
    }, 150)
  }

  // 长按演示：行上方弹气泡
  private onDemoLongPress(): void {
    this.showDemoBubble('长按后松手即可进入批量管理（演示）')
  }

  onStepIndexChanged(): void {
    if (this.stepIndex < 0) {
      return
    }
    this.busyRetries = 0
    this.skipTapped = false
    this.resetDemoRow()
    // 后续步骤：目标组件已布局完成，同步测量并走插值动画平滑滑到新位置，
    // 避免「文字先刷新、挖孔延迟 100ms 才跳过去」的割裂感；仅首次挂载才延迟测量
    if (this.overlayW > 0 && this.overlayH > 0) {
      this.measureTarget()
    } else {
      this.scheduleMeasure()
    }
  }

  private currentStep(): CoachStep {
    if (this.stepIndex >= 0 && this.stepIndex < this.steps.length) {
      return this.steps[this.stepIndex]
    }
    return new CoachStep()
  }

  private scheduleMeasure(): void {
    if (this.measureTimer >= 0) {
      clearTimeout(this.measureTimer)
      this.measureTimer = -1
    }
    this.measureTimer = setTimeout((): void => {
      this.measureTimer = -1
      this.measureTarget()
    }, MEASURE_DELAY_MS)
  }

  // 取目标组件窗口坐标（px）换算 vp，确定挖孔位置并启动插值动画；
  // 目标未挂载（id 不存在）时退回屏幕中部默认高亮带
  private measureTarget(): void {
    if (this.stepIndex < 0 || this.stepIndex >= this.steps.length) {
      return
    }
    if (this.overlayW <= 0 || this.overlayH <= 0) {
      // 浮层自身尺寸还没量出来，等下一轮 onAreaChange 再测
      this.scheduleMeasure()
      return
    }
    if (this.isHostBusy()) {
      if (this.busyRetries < 6) {
        this.busyRetries++
        this.scheduleMeasure()
      } else {
        this.onFinish()
      }
      return
    }
    const ui: UIContext = this.getUIContext()
    const step: CoachStep = this.currentStep()
    let x: number = 24
    let y: number = this.overlayH * 0.3
    let w: number = this.overlayW - 48
    let h: number = 160
    if (!step.demoSong) {
      // 模拟演示步骤不依赖宿主锚点：直接用屏幕中部默认高亮带
      try {
        const info = ui.getComponentUtils().getRectangleById(step.targetId)
        x = ui.px2vp(info.windowOffset.x)
        y = ui.px2vp(info.windowOffset.y)
        w = ui.px2vp(info.size.width)
        h = ui.px2vp(info.size.height)
      } catch (e) {
        // 容器未挂载（如歌单页文件夹区为空）：保留默认高亮带
      }
    }
    if (step.maxHighlightHeight > 0 && h > step.maxHighlightHeight) {
      // 大容器收敛成水平高亮带：在容器内垂直居中
      const bandTop: number = y + (h - step.maxHighlightHeight) / 2
      y = Math.max(bandTop, 0)
      h = step.maxHighlightHeight
    }
    // 高亮呼吸边距：向四周各扩 HIGHLIGHT_PAD，夹在浮层范围内
    x = Math.max(x - HIGHLIGHT_PAD, 0)
    y = Math.max(y - HIGHLIGHT_PAD, 0)
    w = Math.min(w + HIGHLIGHT_PAD * 2, this.overlayW - x)
    h = Math.min(h + HIGHLIGHT_PAD * 2, this.overlayH - y)
    this.startRectAnim(x, y, w, h)
    this.updateCardPosition()
  }

  // 高亮区插值动画：从当前位置缓动到目标位置，逐帧重绘 Canvas 与描边框
  private startRectAnim(x: number, y: number, w: number, h: number): void {
    this.animFromX = this.rectX
    this.animFromY = this.rectY
    this.animFromW = this.rectW
    this.animFromH = this.rectH
    this.animToX = x
    this.animToY = y
    this.animToW = w
    this.animToH = h
    this.animStartMs = Date.now()
    this.stopAnim()
    this.animTimer = setInterval((): void => {
      const t: number = Math.min((Date.now() - this.animStartMs) / MOVE_DURATION_MS, 1)
      // easeInOutCubic：起步与收尾平滑，与原先隐式动画观感一致
      const eased: number = t < 0.5 ? 4 * t * t * t : 1 - Math.pow(-2 * t + 2, 3) / 2
      this.rectX = this.animFromX + (this.animToX - this.animFromX) * eased
      this.rectY = this.animFromY + (this.animToY - this.animFromY) * eased
      this.rectW = this.animFromW + (this.animToW - this.animFromW) * eased
      this.rectH = this.animFromH + (this.animToH - this.animFromH) * eased
      this.updateCardPosition()
      this.drawMask()
      if (t >= 1) {
        this.stopAnim()
      }
    }, ANIM_FRAME_MS)
  }

  private stopAnim(): void {
    if (this.animTimer >= 0) {
      clearInterval(this.animTimer)
      this.animTimer = -1
    }
  }

  // 遮罩绘制：整屏遮罩色 + destination-out 抠圆角孔（抗锯齿一次成型，无拼缝）
  private drawMask(): void {
    const w: number = this.overlayW
    const h: number = this.overlayH
    if (w <= 0 || h <= 0) {
      return
    }
    const ctx: CanvasRenderingContext2D = this.canvasContext
    ctx.clearRect(0, 0, w, h)
    ctx.fillStyle = MASK_COLOR
    ctx.fillRect(0, 0, w, h)
    const x: number = this.rectX
    const y: number = this.rectY
    const rw: number = Math.max(this.rectW, 0)
    const rh: number = Math.max(this.rectH, 0)
    if (rw <= 0 || rh <= 0) {
      return
    }
    const r: number = Math.min(CORNER_RADIUS, rw / 2, rh / 2)
    ctx.globalCompositeOperation = 'destination-out'
    ctx.fillStyle = '#000000'
    ctx.beginPath()
    ctx.moveTo(x + r, y)
    ctx.lineTo(x + rw - r, y)
    ctx.arc(x + rw - r, y + r, r, -Math.PI / 2, 0)
    ctx.lineTo(x + rw, y + rh - r)
    ctx.arc(x + rw - r, y + rh - r, r, 0, Math.PI / 2)
    ctx.lineTo(x + r, y + rh)
    ctx.arc(x + r, y + rh - r, r, Math.PI / 2, Math.PI)
    ctx.lineTo(x, y + r)
    ctx.arc(x + r, y + r, r, Math.PI, Math.PI * 1.5)
    ctx.closePath()
    ctx.fill()
    ctx.globalCompositeOperation = 'source-over'
  }

  // 卡片放置：优先放高亮下方，放不下翻到上方；水平跟随高亮左缘并整体夹在浮层内
  private updateCardPosition(): void {
    const cardW: number = this.cardWidth()
    const below: boolean = this.rectY + this.rectH + 12 + this.cardH < this.overlayH - 16
    const desired: number = below ? this.rectY + this.rectH + 12 : this.rectY - 12 - this.cardH
    this.cardX = Math.min(Math.max(this.rectX, 16), Math.max(this.overlayW - cardW - 16, 16))
    this.cardY = Math.min(Math.max(desired, 16), Math.max(this.overlayH - this.cardH - 16, 16))
  }

  private advance(): void {
    // 「跳过」的点击会先于卡片层触发，此处识别后放行，避免跳过又推进一步
    if (this.skipTapped) {
      this.skipTapped = false
      return
    }
    if (this.stepIndex >= this.steps.length - 1) {
      this.onFinish()
      return
    }
    this.stepIndex = this.stepIndex + 1
  }

  private cardWidth(): number {
    return Math.max(Math.min(CARD_WIDTH_MAX, this.overlayW - 32), 0)
  }

  build() {
    Stack() {
      // ── 挖洞遮罩：单张 Canvas，整屏遮罩 + destination-out 抠圆角孔 ──
      Canvas(this.canvasContext)
        .width('100%')
        .height('100%')
        .onReady((): void => {
          this.drawMask()
        })
        .onClick(() => {
          this.advance()
        })

      // ── 高亮框：主题色描边 + 轻微提亮，浮在挖孔中央（逐帧跟随插值位置）──
      Column()
        .width(this.rectW)
        .height(this.rectH)
        .position({ x: this.rectX, y: this.rectY })
        .borderRadius(CORNER_RADIUS)
        .border({ width: 2, color: this.primaryColor })
        .backgroundColor('rgba(255,255,255,0.04)')
        .hitTestBehavior(HitTestMode.Transparent)

      // ── 模拟歌曲行（demoSong 步骤）：几何/图标对齐首页 songItemRow 与 songSwipeDeleteButton，
      //    保留深色演示底；左滑露删除圆钮，长按/右侧按钮弹演示气泡 ──
      if (this.currentStep().demoSong) {
        Stack({ alignContent: Alignment.End }) {
          // 底层：左滑露出的删除区，48vp 容器 + 36vp 红圆钮 + 16vp 图标 + 右距 12vp，
          // 尺寸与 songSwipeDeleteButton 逐项对齐；仅作视觉演示，不可点击
          Row() {
            Row() {
              Image($r('app.media.ic_public_delete'))
                .width(this.scaledSize(16))
                .height(this.scaledSize(16))
                .fillColor(Color.White)
            }
            .width(this.scaledSize(36))
            .height(this.scaledSize(36))
            .borderRadius(this.scaledSize(18))
            .backgroundColor(StyleConstants.COLOR_DANGER_RED)
            .justifyContent(FlexAlign.Center)
            .alignItems(VerticalAlign.Center)
            .margin({ right: this.scaledSize(12) })
          }
          .width(this.demoSwipeWidth())
          .height('100%')
          .justifyContent(FlexAlign.End)
          .alignItems(VerticalAlign.Center)
          .hitTestBehavior(HitTestMode.Transparent)

          // 前景：示例歌曲行。padding 20/10、36vp 封面、15/12vp 主副标题、右侧两枚按钮，
          // 全部跟随 displaySizeScale / fontSizeScale，与 songItemRow 一致
          Row() {
            // 静态封面占位：对齐 AlbumCover 无封面时的 36vp 圆角块 + 42% music 图标
            Stack() {
              Image($r('app.media.ic_public_music'))
                .width('42%')
                .height('42%')
                .objectFit(ImageFit.Contain)
                .fillColor(this.primaryColor)
            }
            .width(this.scaledSize(36))
            .height(this.scaledSize(36))
            .borderRadius(this.scaledSize(6))
            .clip(true)
            .backgroundColor('rgba(255,255,255,0.08)')
            .margin({ right: this.scaledSize(10) })

            Column({ space: this.scaledSize(3) }) {
              Text('示例歌曲')
                .fontSize(Math.round(15 * this.fontSizeScale))
                .fontWeight(FontWeight.Medium)
                .fontColor('#FFFFFF')
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .width('100%')
              Text('演示用，不会真的删除')
                .fontSize(Math.round(12 * this.fontSizeScale))
                .fontColor('rgba(255,255,255,0.5)')
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .width('100%')
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)

            // 下一首播放（演示）：点击只弹提示，不触发真实播放
            Row() {
              ScaleButton({
                pressScale: StyleConstants.PRESS_SCALE,
                hoverScale: StyleConstants.HOVER_SCALE,
                blockHitTest: true,
                onButtonTap: () => {
                  this.showDemoBubble('「下一首播放」是演示按钮，不会加入播放队列')
                }
              }) {
                SymbolGlyph($r('sys.symbol.list_bullet'))
                  .fontSize(Math.round(22 * this.fontSizeScale))
                  .renderingStrategy(SymbolRenderingStrategy.SINGLE)
                  .fontColor(['rgba(255,255,255,0.6)'])
              }
            }
            .margin({ right: this.scaledSize(16) })

            // 收藏（演示）：点击只弹提示，不触发真实收藏
            ScaleButton({
              pressScale: StyleConstants.PRESS_SCALE,
              hoverScale: StyleConstants.HOVER_SCALE,
              blockHitTest: true,
              onButtonTap: () => {
                this.showDemoBubble('「收藏」是演示按钮，不会真的收藏')
              }
            }) {
              Image($r('app.media.ic_public_favor'))
                .width(this.scaledSize(22))
                .height(this.scaledSize(22))
                .fillColor('rgba(255,255,255,0.6)')
            }
          }
          .width('100%')
          .height(this.demoRowHeight())
          .padding({
            left: this.scaledSize(20), right: this.scaledSize(20),
            top: this.scaledSize(10), bottom: this.scaledSize(10)
          })
          .alignItems(VerticalAlign.Center)
          .borderRadius(this.scaledSize(12))
          .backgroundColor('rgba(48,48,52,0.98)')
          .translate({ x: this.demoOffsetX })
          .animation(this.demoSnapAnimating ? { duration: 150, curve: Curve.EaseOut } : undefined)
          .gesture(PanGesture({ fingers: 1, direction: PanDirection.Horizontal, distance: 5 })
            .onActionStart(() => {
              this.demoPanBaseX = this.demoOffsetX
            })
            .onActionUpdate((event: GestureEvent) => {
              this.demoOffsetX = Math.max(Math.min(this.demoPanBaseX + event.offsetX, 0), -this.demoSwipeWidth())
            })
            .onActionEnd(() => {
              this.onDemoPanEnd()
            }))

          // 演示气泡：长按 / 右侧按钮点击共用，文案由 showDemoBubble 决定
          if (this.demoBubbleText.length > 0) {
            Text(this.demoBubbleText)
              .fontSize(Math.round(12 * this.fontSizeScale))
              .fontColor('#FFFFFF')
              .padding({ left: 12, right: 12, top: 8, bottom: 8 })
              .borderRadius(10)
              .backgroundColor('rgba(30,30,32,0.95)')
              .position({ x: this.scaledSize(8), y: -this.scaledSize(40) })
              .transition(TransitionEffect.OPACITY)
          }
        }
        .width(this.rectW)
        .height(this.demoRowHeight())
        .alignSelf(ItemAlign.Center)
        .position({
          x: this.rectX,
          y: this.rectY + (this.rectH - this.demoRowHeight()) / 2
        })
        .parallelGesture(LongPressGesture({ repeat: false })
          .onAction(() => {
            this.onDemoLongPress()
          }))
      }

      // ── 说明卡片：步骤序号 + 跳过 / 标题 / 描述 / 底部提示 ──
      Column({ space: 10 }) {
        Row() {
          Text(`第 ${this.stepIndex + 1} / ${this.steps.length} 步`)
            .fontSize(11)
            .fontColor('rgba(255,255,255,0.55)')
          Blank()
          ScaleButton({
            pressScale: StyleConstants.PRESS_SCALE,
            hoverScale: StyleConstants.HOVER_SCALE,
            onButtonTap: () => {
              this.skipTapped = true
              this.onFinish()
            }
          }) {
            Text('跳过')
              .fontSize(12)
              .fontColor('rgba(255,255,255,0.6)')
              .padding({
                left: 8,
                right: 8,
                top: 2,
                bottom: 2
              })
          }
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)

        Text(this.currentStep().title)
          .fontSize(16)
          .fontWeight(FontWeight.Bold)
          .fontColor('#FFFFFF')
          .width('100%')

        Text(this.currentStep().description)
          .fontSize(13)
          .fontColor('rgba(255,255,255,0.75)')
          .width('100%')

        Text('点击任意处继续')
          .fontSize(11)
          .fontColor('rgba(255,255,255,0.45)')
          .width('100%')
          .textAlign(TextAlign.End)
      }
      .width(this.cardWidth())
      .padding(16)
      .borderRadius(18)
      .backgroundColor('rgba(30,30,32,0.92)')
      .shadow({
        radius: 24,
        color: 'rgba(0,0,0,0.3)',
        offsetX: 0,
        offsetY: 8
      })
      .position({ x: this.cardX, y: this.cardY })
      .onClick(() => {
        this.advance()
      })
      .onAreaChange((_oldArea: Area, newArea: Area) => {
        const h: number = newArea.height as number
        if (h > 0 && Math.abs(h - this.cardH) > 1) {
          // 描述行数变化导致卡片高度变化：按新高度重新选边/夹取位置
          this.cardH = h
          this.updateCardPosition()
        }
      })
    }
    .width('100%')
    .height('100%')
    .onAreaChange((_oldArea: Area, newArea: Area) => {
      const w: number = newArea.width as number
      const h: number = newArea.height as number
      if (w > 0 && h > 0 && (w !== this.overlayW || h !== this.overlayH)) {
        this.overlayW = w
        this.overlayH = h
        if (this.rectW <= 0) {
          // 首帧先给中部默认高亮带，测量完成后由插值动画滑到真实目标
          this.rectX = 24
          this.rectY = h * 0.3
          this.rectW = Math.max(w - 48, 0)
          this.rectH = 160
          this.cardX = 16
          this.cardY = this.rectY + this.rectH + 12
        }
        // 窗口尺寸变化（旋转/分栏/字体缩放）后重算高亮位置并重绘
        this.drawMask()
        this.scheduleMeasure()
      }
    })
    .transition(TransitionEffect.OPACITY.animation({ duration: 220, curve: Curve.EaseOut }))
  }
}
