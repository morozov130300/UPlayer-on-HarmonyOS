// 聚光分步引导浮层：全屏半透明遮罩围绕目标控件挖洞 + 主题色描边高亮框 + 说明卡片。
// 目标控件在宿主页面上以 .id() 标记，浮层用 componentUtils 取窗口坐标定位高亮区，
// 点击遮罩/卡片任意处进入下一步，卡片右上角「跳过」直接结束（都回调宿主 onFinish）。
//
// 挖洞实现：整块遮罩画在一张 Canvas 上——先整屏填遮罩色，再以 destination-out
// 合成模式填一个圆角矩形把洞抠掉，抗锯齿圆角一次成型，不存在多块拼图接缝；
// 高亮区位置/尺寸变化由本组件自驱动插值动画（每帧重绘 Canvas），步骤切换时
// 洞体、描边框、说明卡片同步平滑滑动而不是瞬移。
//
// 演示内容一律由宿主以 @BuilderParam 注入（真实组件/真实几何/真实手势/真实交互反馈），
// 浮层只负责遮罩、挖洞、描边与说明卡片，内部不渲染任何模拟组件：
// - demoSong 步骤：高亮带锚定宿主 targetId（真实列表容器），宿主 builder 渲染的
//   演示歌曲行摆进高亮带垂直居中，与真实列表容器严格对齐；
// - demoPlaylist 步骤：宿主 builder 渲染演示卡片，浮层实测内容高度后把高亮带
//   调整为内容尺寸并垂直居中，挖洞框住真实几何的演示卡片。
import { ScaleButton } from '../component/ScaleButton'
import { StyleConstants } from '../common/constants/StyleConstants'

// 单步引导配置：targetId 为目标组件 .id()，maxHighlightHeight 用于把大容器
// （整页列表等）收敛成一条水平高亮带，0 表示不收敛；
// demoSong / demoPlaylist 标记演示步骤：内容由宿主 builder 注入，渲染进高亮带内
export class CoachStep {
  targetId: string = ''
  title: string = ''
  description: string = ''
  maxHighlightHeight: number = 0
  demoSong: boolean = false
  demoPlaylist: boolean = false
  // 大容器收敛成水平高亮带时，带中心在容器高度中的比例（默认垂直居中 0.5）；
  // demoSong 步骤用 0.35 把演示带放到容器上部，避开空态提示文字（容器 50% 处）
  bandCenterRatio: number = 0.5
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
// demoPlaylist 内容高度未实测前的兜底值（首帧先按它居中，实测后动画滑到准确位置）
const DEMO_PLAYLIST_EST_HEIGHT: number = 240

@Component
export struct CoachMarkOverlay {
  // 当前步骤下标（0 起）；由宿主持有，-1 = 关闭（宿主条件渲染卸载本组件）
  @Link @Watch('onStepIndexChanged') stepIndex: number
  steps: CoachStep[] = []
  @Prop primaryColor: string = '#007DFF'
  // 走完最后一步或跳过时回调：宿主负责落「已看过」标记并置 stepIndex = -1
  onFinish: () => void = () => {
  }
  // 返回键/侧滑触发的「上一步」请求由宿主 @Watch 转发到本方法；
  // 第 0 步回退无效果，由宿主决定是否吞掉该次返回
  stepBack: () => void = () => {
  }
  // 宿主判定「当前不便弹引导」（如搜索态/多选态），首次触发前重试，全部重试耗尽则放弃
  isHostBusy: () => boolean = (): boolean => {
    return false
  }
  // ── 宿主注入的演示内容（真实组件 + 真实几何 + 真实交互），状态绑定宿主 ──
  @Builder
  emptyContent() {
  }
  @BuilderParam demoSongContent: () => void = this.emptyContent
  @BuilderParam demoPlaylistContent: () => void = this.emptyContent
  // 演示歌曲行行高（宿主按 displaySizeScale 算好传入）：用于把行垂直居中进高亮带
  @Prop demoRowHeight: number = 56
  @State private rectX: number = 0
  @State private rectY: number = 0
  @State private rectW: number = 0
  @State private rectH: number = 0
  @State private cardX: number = 0
  @State private cardY: number = 0
  // 卡片实际高度（onAreaChange 实测）：步骤描述行数不同会导致高度变化，
  // 放置位置按实测高度重算，避免卡片压住高亮区或越出屏幕
  @State private cardH: number = CARD_EST_HEIGHT
  // demoPlaylist 演示内容实测高度（宿主 builder 容器 onAreaChange 上报）
  @State private demoPlaylistH: number = 0
  // 演示卡片首帧兜底高度：首帧用它与 Grid 固定行高撑出真实内容尺寸，
  // 避免高度未实测时 onAreaChange 上报 0 把挖孔/卡片定位推错
  @State private demoPlaylistMeasured: boolean = false
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

  aboutToAppear(): void {
    this.busyRetries = 0
    // 引导期间接管切页的开关由宿主页在开始/结束时显式写入（不再依赖本组件的生命周期计数：
    // 计数在「先卸再挂」或两页浮层并存时会泄漏，导致跳过之后整页永久点不动）
    this.scheduleMeasure()
  }

  aboutToDisappear(): void {
    this.stopAnim()
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
    // 非演示卡片步骤挂载期间清测量标记：回退到演示卡片步骤时重新首测，
    // 避免沿用上一轮的实测高度把挖孔定位在旧内容尺寸上
    if (!this.currentStep().demoPlaylist && this.demoPlaylistMeasured) {
      this.demoPlaylistMeasured = false
      this.demoPlaylistH = 0
    }
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

  // 确定挖孔位置并启动插值动画；目标未挂载（id 不存在）时退回屏幕中部默认高亮带
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
    if (step.demoPlaylist) {
      // 演示卡片步骤：不依赖宿主锚点，高亮带 = 宿主 builder 内容区
      // （内容容器 x=16、宽=overlayW-32，与真实页面左右 padding 16 对齐）。
      // 内容未实测（首帧/刚切步骤）时先按估算值占位，onAreaChange 上报后重测滑正
      const contentH: number = this.demoPlaylistMeasured && this.demoPlaylistH > 0 ?
        this.demoPlaylistH : DEMO_PLAYLIST_EST_HEIGHT
      x = 16
      w = Math.max(this.overlayW - 32, 0)
      h = Math.min(contentH, Math.max(this.overlayH - 32, 100))
      y = Math.max((this.overlayH - h) / 2, 16)
      // 首次进入演示卡片步骤：标记已测量并按估算值先行测量
      if (!this.demoPlaylistMeasured) {
        this.demoPlaylistMeasured = true
        this.demoPlaylistH = DEMO_PLAYLIST_EST_HEIGHT
      }
    } else if (step.targetId.length > 0) {
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
      // 大容器收敛成水平高亮带：按 bandCenterRatio 在容器内定位带中心
      const bandTop: number = y + (h - step.maxHighlightHeight) * step.bandCenterRatio
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
    // 已关闭（走完/跳过）后迟到的点击事件一律忽略：把 -1 推成 0 会让引导重新弹出
    if (this.stepIndex < 0) {
      return
    }
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
          // 演示卡片步骤只能走卡片内「下一步/完成体验」按钮，点遮罩不推进
          if (!this.currentStep().demoPlaylist) {
            this.advance()
          }
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

      // ── 演示歌曲行：宿主 builder 注入（真实组件几何与手势），
      //    摆进高亮带垂直居中，与真实列表容器对齐 ──
      if (this.currentStep().demoSong) {
        Column() {
          this.demoSongContent()
        }
        .width(this.rectW)
        .position({
          x: this.rectX,
          y: this.rectY + (this.rectH - this.demoRowHeight) / 2
        })
      }

      // ── 演示卡片：宿主 builder 注入（真实歌单卡/文件夹卡组件与真实 Grid 几何），
      //    实测内容高度后垂直居中摆放，挖洞框住内容；
      //    高度未实测前不渲染（避免内容以错误位置首帧闪现，实测后挂载并测挖孔）──
      if (this.currentStep().demoPlaylist && this.demoPlaylistMeasured) {
        Column() {
          this.demoPlaylistContent()
        }
        .width(this.overlayW > 0 ? Math.max(this.overlayW - 32, 0) : 320)
        .position({
          x: 16,
          y: Math.max((this.overlayH - this.demoPlaylistH) / 2, 16)
        })
        .onAreaChange((_oldArea: Area, newArea: Area) => {
          const h: number = newArea.height as number
          if (h > 0 && Math.abs(h - this.demoPlaylistH) > 1) {
            this.demoPlaylistH = h
            this.scheduleMeasure()
          }
        })
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

        if (this.currentStep().demoPlaylist) {
          Row({ space: 10 }) {
            // 上一步：第 1 步不可回退，占位保持「下一步」按钮不跳动
            if (this.stepIndex > 0) {
              Text('上一步')
                .fontSize(13)
                .fontColor('rgba(255,255,255,0.75)')
                .layoutWeight(1)
                .height(44)
                .borderRadius(12)
                .backgroundColor('rgba(255,255,255,0.12)')
                .textAlign(TextAlign.Center)
                .onClick((): void => {
                  this.skipTapped = true
                  if (this.stepIndex > 0) {
                    this.stepIndex = this.stepIndex - 1
                  }
                })
            } else {
              Column()
                .layoutWeight(1)
            }
            Text(this.stepIndex >= this.steps.length - 1 ? '完成体验' : '下一步')
              .fontSize(13)
              .fontColor('#FFFFFF')
              .layoutWeight(1)
              .height(44)
              .borderRadius(12)
              .backgroundColor(this.primaryColor)
              .textAlign(TextAlign.Center)
              .onClick((): void => {
                this.advance()
              })
          }
          .width('100%')
        } else {
          Text('点击任意处继续 · 返回键可回退上一步')
            .fontSize(11)
            .fontColor('rgba(255,255,255,0.45)')
            .width('100%')
            .textAlign(TextAlign.End)
        }
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
        // 演示卡片步骤的说明卡片不响应点击推进（卡片内按钮负责推进）
        if (!this.currentStep().demoPlaylist) {
          this.advance()
        }
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
