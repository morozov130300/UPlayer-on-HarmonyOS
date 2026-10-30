// 聚光分步引导浮层：全屏半透明遮罩围绕目标控件挖洞 + 主题色描边高亮框 + 说明卡片。
// 目标控件在宿主页面上以 .id() 标记，浮层用 componentUtils 取窗口坐标定位高亮区，
// 点击遮罩/卡片任意处进入下一步，卡片右上角「跳过」直接结束（都回调宿主 onFinish）。
//
// 挖洞实现：上/下/左/右四块半透明矩形拼出方形洞，再用四块 1/4 圆角「补角」
// （Path 弯月形，同遮罩色）把方角填成与描边框一致的圆角，消除圆角处的亮缝；
// 高亮区位置/尺寸变化走隐式动画，步骤切换时框体平滑滑动而不是瞬移。
import { ScaleButton } from '../component/ScaleButton'
import { StyleConstants } from '../common/constants/StyleConstants'

// 单步引导配置：targetId 为目标组件 .id()，maxHighlightHeight 用于把大容器
// （整页列表等）收敛成一条水平高亮带，0 表示不收敛
export class CoachStep {
  targetId: string = ''
  title: string = ''
  description: string = ''
  maxHighlightHeight: number = 0
}

const HIGHLIGHT_PAD: number = 10
const CARD_WIDTH_MAX: number = 340
// 卡片高度估算值（标题 + 两行描述 + 页脚），仅用于「放下方还是上方」的判断
const CARD_EST_HEIGHT: number = 118
const MEASURE_DELAY_MS: number = 100
const MASK_COLOR: string = 'rgba(0,0,0,0.5)'
// 高亮框圆角；补角弯月形与描边框共用该半径
const CORNER_RADIUS: number = 16
// 高亮区滑动/尺寸变化的隐式动画时长
const MOVE_DURATION_MS: number = 240

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
  // 四块补角弯月形的路径命令。Path.commands 的单位是 px（官方文档：单位为px），
  // 而路径盒是按 vp 布局的，必须用 vp2px(圆角) 生成命令，否则命令只画到盒子的
  // 1/density（16 只等于约 5vp），补角几乎看不见、圆角处照样漏亮缝。
  private cornerRadiusPx: number = 0
  private cornerPaths: string[] = ['', '', '', '']

  aboutToAppear(): void {
    this.busyRetries = 0
    this.buildCornerPaths()
    this.scheduleMeasure()
  }

  // 按当前屏幕密度换算 px，生成 TL / TR / BL / BR 四块弯月形（方角内、圆角弧外，
  // 弧线与描边框圆角同心同径）；密度未就绪时留空，由 onAreaChange 兜底重建
  private buildCornerPaths(): void {
    let r: number = 0
    try {
      r = this.getUIContext().vp2px(CORNER_RADIUS)
    } catch (e) {
      r = 0
    }
    if (r <= 0 || Math.abs(r - this.cornerRadiusPx) < 0.01) {
      return
    }
    this.cornerRadiusPx = r
    this.cornerPaths[0] = `M0 0 L${r} 0 A${r} ${r} 0 0 0 0 ${r} Z`
    this.cornerPaths[1] = `M${r} 0 L0 0 A${r} ${r} 0 0 1 ${r} ${r} Z`
    this.cornerPaths[2] = `M0 ${r} L0 0 A${r} ${r} 0 0 0 ${r} ${r} Z`
    this.cornerPaths[3] = `M${r} ${r} L${r} 0 A${r} ${r} 0 0 1 0 ${r} Z`
  }

  aboutToDisappear(): void {
    if (this.measureTimer >= 0) {
      clearTimeout(this.measureTimer)
      this.measureTimer = -1
    }
  }

  onStepIndexChanged(): void {
    if (this.stepIndex < 0) {
      return
    }
    this.busyRetries = 0
    this.skipTapped = false
    // 后续步骤：目标组件已布局完成，同步测量并借隐式动画平滑滑到新位置，
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

  // 取目标组件窗口坐标（px）换算 vp，换算出四块遮罩、补角与卡片位置；
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
    try {
      const info = ui.getComponentUtils().getRectangleById(step.targetId)
      x = ui.px2vp(info.windowOffset.x)
      y = ui.px2vp(info.windowOffset.y)
      w = ui.px2vp(info.size.width)
      h = ui.px2vp(info.size.height)
    } catch (e) {
      // 容器未挂载（如歌单页文件夹区为空）：保留默认高亮带
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
    this.rectX = x
    this.rectY = y
    this.rectW = w
    this.rectH = h
    this.updateCardPosition()
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

  // 四块补角弯月形的水平/垂直位置（与描边框同一圆角半径）
  private cornerX(right: boolean): number {
    return right ? Math.max(this.rectX + this.rectW - CORNER_RADIUS, 0) : this.rectX
  }

  private cornerY(bottom: boolean): number {
    return bottom ? Math.max(this.rectY + this.rectH - CORNER_RADIUS, 0) : this.rectY
  }

  build() {
    Stack() {
      // ── 挖洞遮罩：上 / 下 / 左 / 右四块拼合 ──
      Column()
        .width('100%')
        .height(Math.max(this.rectY, 0))
        .position({ x: 0, y: 0 })
        .backgroundColor(MASK_COLOR)
        .onClick(() => {
          this.advance()
        })
        .animation({ duration: MOVE_DURATION_MS, curve: Curve.EaseInOut })
      Column()
        .width('100%')
        .height(Math.max(this.overlayH - this.rectY - this.rectH, 0))
        .position({ x: 0, y: this.rectY + this.rectH })
        .backgroundColor(MASK_COLOR)
        .onClick(() => {
          this.advance()
        })
        .animation({ duration: MOVE_DURATION_MS, curve: Curve.EaseInOut })
      Column()
        .width(Math.max(this.rectX, 0))
        .height(this.rectH)
        .position({ x: 0, y: this.rectY })
        .backgroundColor(MASK_COLOR)
        .onClick(() => {
          this.advance()
        })
        .animation({ duration: MOVE_DURATION_MS, curve: Curve.EaseInOut })
      Column()
        .width(Math.max(this.overlayW - this.rectX - this.rectW, 0))
        .height(this.rectH)
        .position({ x: this.rectX + this.rectW, y: this.rectY })
        .backgroundColor(MASK_COLOR)
        .onClick(() => {
          this.advance()
        })
        .animation({ duration: MOVE_DURATION_MS, curve: Curve.EaseInOut })

      // ── 四块补角：命令按 px 生成（见 buildCornerPaths），盒尺寸按 vp，
      //    与描边框 16vp 圆角同心同径，圆角处不再漏亮缝 ──
      Path()
        .width(CORNER_RADIUS)
        .height(CORNER_RADIUS)
        .commands(this.cornerPaths[0])
        .fill(MASK_COLOR)
        .position({ x: this.cornerX(false), y: this.cornerY(false) })
        .animation({ duration: MOVE_DURATION_MS, curve: Curve.EaseInOut })
      Path()
        .width(CORNER_RADIUS)
        .height(CORNER_RADIUS)
        .commands(this.cornerPaths[1])
        .fill(MASK_COLOR)
        .position({ x: this.cornerX(true), y: this.cornerY(false) })
        .animation({ duration: MOVE_DURATION_MS, curve: Curve.EaseInOut })
      Path()
        .width(CORNER_RADIUS)
        .height(CORNER_RADIUS)
        .commands(this.cornerPaths[2])
        .fill(MASK_COLOR)
        .position({ x: this.cornerX(false), y: this.cornerY(true) })
        .animation({ duration: MOVE_DURATION_MS, curve: Curve.EaseInOut })
      Path()
        .width(CORNER_RADIUS)
        .height(CORNER_RADIUS)
        .commands(this.cornerPaths[3])
        .fill(MASK_COLOR)
        .position({ x: this.cornerX(true), y: this.cornerY(true) })
        .animation({ duration: MOVE_DURATION_MS, curve: Curve.EaseInOut })

      // ── 高亮框：主题色描边 + 轻微提亮，浮在挖洞中央 ──
      Column()
        .width(this.rectW)
        .height(this.rectH)
        .position({ x: this.rectX, y: this.rectY })
        .borderRadius(CORNER_RADIUS)
        .border({ width: 2, color: this.primaryColor })
        .backgroundColor('rgba(255,255,255,0.04)')
        .animation({ duration: MOVE_DURATION_MS, curve: Curve.EaseInOut })

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
      .animation({ duration: MOVE_DURATION_MS, curve: Curve.EaseInOut })
    }
    .width('100%')
    .height('100%')
    .onAreaChange((_oldArea: Area, newArea: Area) => {
      const w: number = newArea.width as number
      const h: number = newArea.height as number
      if (w > 0 && h > 0 && (w !== this.overlayW || h !== this.overlayH)) {
        this.overlayW = w
        this.overlayH = h
        // 兜底重建补角路径：aboutToAppear 时 UIContext 可能还没就绪，
        // 且窗口换屏/缩放后 px 换算是另一套值
        this.buildCornerPaths()
        if (this.rectW <= 0) {
          // 首帧先给中部默认高亮带，测量完成后由隐式动画滑到真实目标
          this.rectX = 24
          this.rectY = h * 0.3
          this.rectW = Math.max(w - 48, 0)
          this.rectH = 160
          this.cardX = 16
          this.cardY = this.rectY + this.rectH + 12
        }
        // 窗口尺寸变化（旋转/分栏/字体缩放）后重算高亮位置
        this.scheduleMeasure()
      }
    })
    .transition(TransitionEffect.OPACITY.animation({ duration: 220, curve: Curve.EaseOut }))
  }
}
