// 聚光分步引导浮层：全屏半透明遮罩围绕目标控件挖洞 + 主题色描边高亮框 + 说明卡片。
// 目标控件在宿主页面上以 .id() 标记，浮层用 componentUtils 取窗口坐标定位高亮区，
// 点击遮罩/卡片任意处进入下一步，卡片右上角「跳过」直接结束（都回调宿主 onFinish）。
// 挖洞实现：上/下/左/右四块半透明矩形拼合围绕高亮区，中央留出真实控件。
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

@Component
export struct CoachMarkOverlay {
  // 当前步骤下标（0 起）；由宿主持有，-1 = 关闭（宿主条件渲染卸载本组件）
  @Link @Watch('onStepIndexChanged') stepIndex: number
  steps: CoachStep[] = []
  @Prop primaryColor: string = '#007DFF'
  @State private rectX: number = 0
  @State private rectY: number = 0
  @State private rectW: number = 0
  @State private rectH: number = 0
  @State private cardX: number = 0
  @State private cardY: number = 0
  @State private overlayW: number = 0
  @State private overlayH: number = 0
  private measureTimer: number = -1
  private busyRetries: number = 0
  // 「跳过」在卡片内部：点击事件会冒泡到卡片层的 advance，用标记让 advance 放行
  private skipTapped: boolean = false
  // 走完最后一步或跳过时回调：宿主负责落「已看过」标记并置 stepIndex = -1
  onFinish: () => void = () => {
  }
  // 宿主判定「当前不便弹引导」（如搜索态/多选态），首次触发前重试，全部重试耗尽则放弃
  isHostBusy: () => boolean = (): boolean => {
    return false
  }

  aboutToAppear(): void {
    this.busyRetries = 0
    this.scheduleMeasure()
  }

  aboutToDisappear(): void {
    if (this.measureTimer >= 0) {
      clearTimeout(this.measureTimer)
      this.measureTimer = -1
    }
  }

  onStepIndexChanged(): void {
    if (this.stepIndex >= 0) {
      this.busyRetries = 0
      this.scheduleMeasure()
    }
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
      Column()
        .width('100%')
        .height(Math.max(this.overlayH - this.rectY - this.rectH, 0))
        .position({ x: 0, y: this.rectY + this.rectH })
        .backgroundColor(MASK_COLOR)
        .onClick(() => {
          this.advance()
        })
      Column()
        .width(Math.max(this.rectX, 0))
        .height(this.rectH)
        .position({ x: 0, y: this.rectY })
        .backgroundColor(MASK_COLOR)
        .onClick(() => {
          this.advance()
        })
      Column()
        .width(Math.max(this.overlayW - this.rectX - this.rectW, 0))
        .height(this.rectH)
        .position({ x: this.rectX + this.rectW, y: this.rectY })
        .backgroundColor(MASK_COLOR)
        .onClick(() => {
          this.advance()
        })

      // ── 高亮框：主题色描边 + 轻微提亮，浮在挖洞中央 ──
      Column()
        .width(this.rectW)
        .height(this.rectH)
        .position({ x: this.rectX, y: this.rectY })
        .borderRadius(16)
        .border({ width: 2, color: this.primaryColor })
        .backgroundColor('rgba(255,255,255,0.04)')

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
      .width(Math.min(CARD_WIDTH_MAX, this.overlayW - 32))
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
    }
    .width('100%')
    .height('100%')
    .onAreaChange((_oldArea: Area, newArea: Area) => {
      const w: number = newArea.width as number
      const h: number = newArea.height as number
      if (w > 0 && h > 0 && (w !== this.overlayW || h !== this.overlayH)) {
        this.overlayW = w
        this.overlayH = h
        // 窗口尺寸变化（旋转/分栏/字体缩放）后重算高亮位置
        this.scheduleMeasure()
      }
    })
    .transition(TransitionEffect.OPACITY.animation({ duration: 220, curve: Curve.EaseOut }))
  }

  private currentStep(): CoachStep {
    if (this.stepIndex >= 0 && this.stepIndex < this.steps.length) {
      return this.steps[this.stepIndex]
    }
    return new CoachStep()
  }

  // 取目标组件窗口坐标（px）换算 vp，换算出四块遮罩与卡片位置；

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
    // 卡片放高亮下方，放不下翻到上方；水平跟随高亮左缘并夹在浮层内
    const cardW: number = Math.min(CARD_WIDTH_MAX, this.overlayW - 32)
    const below: boolean = y + h + 12 + CARD_EST_HEIGHT < this.overlayH - 16
    this.cardX = Math.min(Math.max(x, 16), this.overlayW - cardW - 16)
    this.cardY = below ? y + h + 12 : Math.max(y - 12 - CARD_EST_HEIGHT, 16)
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
}
