import { curves, uiMaterial } from '@kit.ArkUI'
import { ColorHelper } from '../common/utils/ColorHelper'
import { createTabGlassMaterial, DEFAULT_GLASS_STYLE, isLiquidGlassAvailable } from '../common/utils/GlassUtil'

// 返回按钮统一组件：可点击区域维持原尺寸，内部套一层「可点击区域 × 0.6」的内切圆形，
// 圆形的液态玻璃/磨砂/描边/阴影完全与底部 Tab 栏同源同参（同一批 AppStorage 配置驱动），
// 保证风格切换时返回按钮与 Tab 栏同步变化。
// 交互：不做跟手光效（材质固定不传 lightColor），改为与播放器 ScaleButton 完全一致的
// 按压手感——按下缩小、松手/取消弹簧回弹、悬停放大。
@Component
export struct GlassBackButton {
  // 可点击区域直径（由调用方按各页原有缩放规则算好）：
  // 必须 @Prop——普通成员只在创建时赋值一次，调节显示大小后父组件重算的 scaledSize 新值收不到
  @Prop clickSize: number = 48
  // 图标直径（按与圆形相同的比例缩放后显示）
  @Prop iconSize: number = 15
  iconColor: ResourceColor = $r('app.color.text_primary')
  iconOpacity: number = 0.9
  onBack: () => void = () => {}

  @StorageLink('uplayer_tab_style') tabStyle: string = 'classic'
  @StorageLink('uplayer_glass_blur_strength') glassBlurStrength: number = 25

  // 按压动画状态（与 ScaleButton 同款手感）：参与渲染的缩放值用 @State，
  // 按压/悬停标志只做逻辑判断，用普通 private 成员
  @State btnScale: number = 1.0
  private isPressed: boolean = false
  private isHovered: boolean = false
  private pressScale: number = 0.8
  private hoverScale: number = 1.1

  // 圆形相对可点击区的直径比例：可点击区不变，视觉圆更小
  private static readonly CIRCLE_RATIO: number = 0.6

  // 内切圆直径 = 可点击区 × 0.6，随调用方传入的 clickSize（含显示大小缩放）同步变化
  private circleSize(): number {
    return Math.round(this.clickSize * GlassBackButton.CIRCLE_RATIO)
  }

  // 图标与圆形同比例缩小
  private visualIconSize(): number {
    return Math.round(this.iconSize * GlassBackButton.CIRCLE_RATIO)
  }

  // 与底部 Tab 栏同源的材质选择（返回按钮固定不跟手：不传 lightColor，无 lightEffect 光效，
  // 观感上的按压反馈由外层的 scale 动画提供）：
  // 玻璃风格(immersive) → createTabGlassMaterial 工厂（含 colorInvert/applyShadow）；
  // 经典风格(classic) → 不挂任何材质（systemMaterial=undefined），仅由 backgroundEffect（高斯模糊）提供背景。
  private backMaterial(): uiMaterial.Material | undefined {
    if (this.tabStyle === 'immersive') {
      if (!isLiquidGlassAvailable()) {
        return undefined
      }
      return createTabGlassMaterial(DEFAULT_GLASS_STYLE, false, undefined, true, true)
    }
    // 经典样式：不挂任何玻璃材质，仅靠磨砂层（backgroundEffect）
    return undefined
  }

  // 按压优先于悬停：按压中返回 pressScale，否则悬停返回 hoverScale，都不满足回 1.0
  private targetScale(): number {
    if (this.isPressed) {
      return this.pressScale
    }
    return this.isHovered ? this.hoverScale : 1.0
  }

  build() {
    Row() {
      Row() {
        // 图标源为 12×24（1:2 竖长 chevron）：渲染框必须保持 1:2，
        // 否则默认 Cover 会把 chevron 上下臂的尖端裁掉
        Image($r('app.media.ic_public_arrow_left_filled'))
          .width(this.visualIconSize())
          .height(this.visualIconSize() * 2)
          .fillColor(this.iconColor)
          .opacity(this.iconOpacity)
      }
      .width(this.circleSize())
      .height(this.circleSize())
      .borderRadius(this.circleSize() / 2)
      .justifyContent(FlexAlign.Center)
      .alignItems(VerticalAlign.Center)
      .backgroundColor(Color.Transparent)
      // 磨砂层只由「模糊强度」控制（0 关闭），明暗模式均挂载，与 Tab 栏策略一致
      .backgroundEffect(this.glassBlurStrength <= 0
        ? undefined : { radius: this.glassBlurStrength * 0.5 })
      .systemMaterial(this.backMaterial())
      .border({ width: 1, color: 'rgba(255,255,255,0.22)' })
      // 阴影照搬 Tab 栏观感，按圆形直径等比缩小；颜色固定白色（不用主题色）
      .shadow({
        radius: Math.round(this.circleSize() * 0.35),
        color: ColorHelper.hexWithAlpha('#FFFFFF', '44'),
        offsetY: Math.round(this.circleSize() * 0.1)
      })
    }
    .width(this.clickSize)
    .height(this.clickSize)
    .justifyContent(FlexAlign.Center)
    .alignItems(VerticalAlign.Center)
    .borderRadius(this.clickSize / 2)
    .scale({ x: this.btnScale, y: this.btnScale })
    .onTouch((event: TouchEvent) => {
      if (event.type === TouchType.Down) {
        this.isPressed = true;
        this.getUIContext()?.animateTo({ duration: 100, curve: Curve.EaseOut }, () => {
          this.btnScale = this.pressScale;
        });
      } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
        this.isPressed = false;
        this.getUIContext()?.animateTo({ curve: curves.springMotion() }, () => {
          this.btnScale = this.targetScale();
        });
      }
    })
    .onHover((isHover: boolean) => {
      if (this.isHovered === isHover) {
        return;
      }
      this.isHovered = isHover;
      if (!this.isPressed) {
        this.getUIContext()?.animateTo({ curve: curves.springMotion() }, () => {
          this.btnScale = this.targetScale();
        });
      }
    })
    .onClick(() => { this.onBack() })
  }
}