import { common, ConfigurationConstant } from '@kit.AbilityKit'
import { uiMaterial } from '@kit.ArkUI'
import { AppStorageKeyConstants } from '../common/constants/AppStorageKeyConstants'
import { ColorHelper } from '../common/utils/ColorHelper'
import { createBarGlassMaterial, createTabGlassMaterial, isLiquidGlassAvailable } from '../common/utils/GlassUtil'
import { KEY_HAS_POINTER_DEVICE } from '../common/utils/InputDeviceUtil'

// 返回按钮统一组件：可点击区域维持原尺寸，内部套一层「可点击区域 × 0.7」的内切圆形，
// 圆形的液态玻璃/磨砂/描边/阴影完全与底部 Tab 栏同源同参（同一批 AppStorage 配置驱动），
// 保证风格切换时返回按钮与 Tab 栏同步变化。
@Component
export struct GlassBackButton {
  // 可点击区域直径（由调用方按各页原有缩放规则算好）
  clickSize: number = 48
  // 图标直径（按与圆形相同的比例缩放后显示）
  iconSize: number = 15
  iconColor: ResourceColor = $r('app.color.text_primary')
  iconOpacity: number = 0.9
  onBack: () => void = () => {}

  @StorageLink('uplayer_tab_style') tabStyle: string = 'classic'
  @StorageLink('uplayer_glass_thickness') glassThickness: number = 50
  @StorageLink('uplayer_glass_blur_strength') glassBlurStrength: number = 25
  @StorageLink('uplayer_interactive') interactive: boolean = true
  @StorageLink('uplayer_color_invert') colorInvert: boolean = false
  @StorageLink('uplayer_apply_shadow') applyShadow: boolean = true
  @StorageLink('uplayer_light_color_mode') lightColorMode: string = 'theme'
  @StorageLink('uplayer_tab_touch_indicator') tabTouchIndicator: string = 'light'
  @StorageLink(KEY_HAS_POINTER_DEVICE) hasPointerDevice: boolean = false
  @StorageLink('uplayer_primary_color') primaryColor: string = '#007DFF'
  @StorageLink('uplayer_theme_mode') themeMode: string = 'system'

  // 圆形相对可点击区的直径比例：可点击区不变，视觉圆更小
  private static readonly CIRCLE_RATIO: number = 0.7

  // 内切圆直径 = 可点击区 × 0.7，随调用方传入的 clickSize（含显示大小缩放）同步变化
  private circleSize(): number {
    return Math.round(this.clickSize * GlassBackButton.CIRCLE_RATIO)
  }

  // 图标与圆形同比例缩小
  private visualIconSize(): number {
    return Math.round(this.iconSize * GlassBackButton.CIRCLE_RATIO)
  }

  private isDarkTheme(): boolean {
    if (this.themeMode === 'dark') {
      return true
    }
    if (this.themeMode === 'system') {
      const context: common.UIAbilityContext | undefined = AppStorage.get<common.UIAbilityContext>(
        AppStorageKeyConstants.KEY_UI_ABILITY_CONTEXT)
      return context?.config.colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK
    }
    return false
  }

  // 与 Index.effectiveTouchIndicator 同逻辑：无指针设备时「白色蒙版」降级为关闭
  private effectiveTouchIndicator(): string {
    if (this.tabTouchIndicator === 'mask' && !this.hasPointerDevice) {
      return 'off'
    }
    return this.tabTouchIndicator
  }

  // 与底部 Tab 栏完全同源的材质选择：
  // 玻璃风格(immersive) → createTabGlassMaterial 全参工厂（含 lightEffect/colorInvert/applyShadow）；
  // 经典风格(classic) → createBarGlassMaterial。能力不足/玻璃关断返回 undefined，由磨砂兜底。
  private backMaterial(): uiMaterial.Material | undefined {
    if (this.tabStyle === 'immersive') {
      if (!isLiquidGlassAvailable() || this.glassThickness <= 0) {
        return undefined
      }
      const useLight: boolean = this.effectiveTouchIndicator() === 'light'
      const lightColor: string | undefined = useLight
        ? (this.lightColorMode === 'white' ? '#FFFFFF' : this.primaryColor)
        : undefined
      return createTabGlassMaterial(this.glassThickness, this.interactive, lightColor, this.colorInvert, this.applyShadow)
    }
    if (this.tabStyle === 'classic') {
      return createBarGlassMaterial(this.glassThickness, this.interactive)
    }
    return undefined
  }

  build() {
    Row() {
      Row() {
        Image($r('app.media.ic_public_arrow_left'))
          .width(this.visualIconSize())
          .height(this.visualIconSize())
          .fillColor(this.iconColor)
          .opacity(this.iconOpacity)
      }
      .width(this.circleSize())
      .height(this.circleSize())
      .borderRadius(this.circleSize() / 2)
      .justifyContent(FlexAlign.Center)
      .alignItems(VerticalAlign.Center)
      .backgroundColor(Color.Transparent)
      // 磨砂层只由「模糊强度」控制（0 关闭），暗黑模式不挂，与 Tab 栏策略一致
      .backgroundEffect(this.isDarkTheme() || this.glassBlurStrength <= 0
        ? undefined : { radius: this.glassBlurStrength * 0.5 })
      .systemMaterial(this.backMaterial())
      .border({ width: 1, color: 'rgba(255,255,255,0.22)' })
      // 阴影照搬 Tab 栏观感，按圆形直径等比缩小
      .shadow({
        radius: Math.round(this.circleSize() * 0.35),
        color: ColorHelper.hexWithAlpha(this.primaryColor, '44'),
        offsetY: Math.round(this.circleSize() * 0.1)
      })
    }
    .width(this.clickSize)
    .height(this.clickSize)
    .justifyContent(FlexAlign.Center)
    .alignItems(VerticalAlign.Center)
    .borderRadius(this.clickSize / 2)
    .hoverEffect(HoverEffect.Scale)
    .onClick(() => { this.onBack() })
  }
}