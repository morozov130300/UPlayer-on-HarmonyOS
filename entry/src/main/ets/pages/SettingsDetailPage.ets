// ArkUI 26 Beta1: 接口定义变更（误报，本项目已是Stage模型）+ UX视觉布局变更（Text默认开启沉浸式材质，系统行为）
import { curves, uiAppearance, uiMaterial } from '@kit.ArkUI'
import { common, ConfigurationConstant } from '@kit.AbilityKit'
import { DataService, AppSettingsData } from '../service/DataService'
import { AVPlayerService } from '../service/AVPlayerService'
import { AppStorageKeyConstants } from '../common/constants/AppStorageKeyConstants'
import { ColorHelper } from '../common/utils/ColorHelper'
import Logger from '../common/utils/Logger'
import { deviceInfo, SuppressWarnings, SuppressWarningsType, pasteboard } from '@kit.BasicServicesKit'
import {
  HoldingHandService,
  KEY_HOLDING_HAND_ENABLED,
  KEY_HOLDING_HAND_LEFT
} from '../service/HoldingHandService'
import { ColorConversion } from '../common/utils/ColorConversion'
import {
  createBarGlassMaterial,
  createTabGlassMaterial,
  GLASS_THICKNESS_STEPS,
  glassThicknessLabel,
  isLiquidGlassAvailable,
  topBlurRadiusFromStrength
} from '../common/utils/GlassUtil'
import { StyleConstants } from '../common/constants/StyleConstants'
import { KEY_HAS_POINTER_DEVICE, refreshPointerDeviceState } from '../common/utils/InputDeviceUtil'
import { GlassBackButton } from '../view/GlassBackButton'

const TAG = 'SettingsDetailPage'
const KEY_PRIMARY_COLOR = 'uplayer_primary_color'

class EqBandInfo {
  freq: string = ''
  index: number = 0
}


interface ThemeColorOption {
  name: string
  value: string
}

interface ThemeOption {
  label: string
  value: string
}

interface TabStyleOption {
  label: string
  value: string
}

interface TouchIndicatorOption {
  label: string
  value: string
}

@Entry
@Component
@SuppressWarnings({rules: [SuppressWarningsType.SYSCAP]})
struct SettingsDetailPage {
  private context: common.UIAbilityContext
    | undefined = AppStorage.get<common.UIAbilityContext>(AppStorageKeyConstants.KEY_UI_ABILITY_CONTEXT)
  @State settings: AppSettingsData = new AppSettingsData()
  @StorageLink(KEY_PRIMARY_COLOR) primaryColor: string = '#007DFF'
  @StorageLink('uplayer_theme_mode') themeMode: string = 'system'
  @StorageLink(AppStorageKeyConstants.KEY_TITLE_BUTTON_WIDTH) titleButtonWidth: number = 0
  @StorageLink(AppStorageKeyConstants.KEY_TITLE_BUTTON_HEIGHT) titleButtonHeight: number = 0
  @StorageLink(AppStorageKeyConstants.KEY_TOP_HEIGHT) topSafeHeight: number = 0
  @StorageLink('uplayer_display_size_scale') displaySizeScale: number = 1.0
  @StorageLink('uplayer_font_size_scale') fontSizeScale: number = 1.0
  @StorageLink('uplayer_glass_blur_strength') glassBlurStrength: number = 25
  @StorageLink('uplayer_home_top_blur_strength') homeTopBlurStrength: number = 25
  @StorageLink('uplayer_tab_indicator_opacity') tabIndicatorOpacity: number = 50
  @StorageLink('uplayer_interactive') interactive: boolean = true
  @StorageLink('uplayer_glass_thickness') glassThickness: number = 50
  @StorageLink('uplayer_color_invert') colorInvert: boolean = false
  @StorageLink('uplayer_apply_shadow') applyShadow: boolean = true
  @StorageLink('uplayer_system_component_glass') systemComponentGlass: boolean = true
  // 是否存在鼠标/触控板设备（决定「白色蒙版」开关是否显示）
  @StorageLink(KEY_HAS_POINTER_DEVICE) hasPointerDevice: boolean = false
  @State pageTitle: string = ''
  // 顶部模糊预览的靠边方向：左手握持 → 靠右（沿用原有映射，由 HoldingHandService 统一滤波后广播）
  @StorageLink(KEY_HOLDING_HAND_LEFT) previewOnRight: boolean = false
  // Tab 栏实时预览态：复刻 Index 真实 Tab 栏（可点击切换、悬停高亮、指示器弹簧动画）
  @State previewTabIndex: number = 0
  @State previewIndicatorOffset: number = 4
  @State previewHoverTabIndex: number = -1
  private previewTabWidth: number = 72
  private previewTabGap: number = 6
  private previewIndicatorInset: number = 4
  @State showColorPicker: boolean = false
  @State showGlassScope: boolean = false
  @State pickerHue: number = 210
  @State pickerSaturation: number = 1
  @State pickerValue: number = 1
  @State pickerOriginalColor: string = '#007DFF'
  private eqCurveSettings: RenderingContextSettings = new RenderingContextSettings(true)
  private eqCurveCtx: CanvasRenderingContext2D = new CanvasRenderingContext2D(this.eqCurveSettings)
  private eqCanvasWidth: number = 0
  private eqCanvasHeight: number = 0
  private dataService: DataService = DataService.getInstance()
  private avPlayerService: AVPlayerService = AVPlayerService.getInstance()
  private isPC: boolean = deviceInfo.deviceType === '2in1'
  // 智感握姿开关：写穿到 AppStorage（HoldingHandService 在页面外也要读开关），
  // 滤波与订阅统一交给 HoldingHandService，本页不再自行订阅 holdingHandChanged
  @StorageLink(KEY_HOLDING_HAND_ENABLED) holdingHandEnabled: boolean = true
  private themeOptions: ThemeOption[] = [
    { label: '跟随系统', value: 'system' },
    { label: '深色模式', value: 'dark' },
    { label: '浅色模式', value: 'light' }
  ]
  private tabStyleOptions: TabStyleOption[] = [
    { label: '经典', value: 'classic' },
    { label: '玻璃', value: 'immersive' }
  ]
  // 底部栏触摸指示选项：关 / 白色蒙版 / 跟手光效
  // 「白色蒙版」仅在检测到鼠标/触控板设备（鸿蒙 PC、外接鼠标）时才显示
  private touchIndicatorOptions: TouchIndicatorOption[] = [
    { label: '关', value: 'off' },
    { label: '白色蒙版', value: 'mask' },
    { label: '跟手光效', value: 'light' }
  ]

  // 根据鼠标检测结果过滤选项：无鼠标/触控板设备时隐藏「白色蒙版」
  private visibleTouchIndicatorOptions(): TouchIndicatorOption[] {
    if (this.hasPointerDevice) {
      return this.touchIndicatorOptions
    }
    return [this.touchIndicatorOptions[0], this.touchIndicatorOptions[2]]
  }
  private colorOptions: ThemeColorOption[] = [
    { name: '鸿蒙蓝', value: '#007DFF' },
    { name: '绯霞红', value: '#FF3B30' },
    { name: '琥珀橙', value: '#FF9500' },
    { name: '典雅金', value: '#C79A3B' },
    { name: '翠微绿', value: '#34C759' },
    { name: '天青蓝', value: '#5AC8FA' },
    { name: '沉浸靛', value: '#5856D6' },
    { name: '紫罗兰', value: '#AF52DE' }
  ]
  private eqBands: EqBandInfo[] = [
    { freq: '32', index: 0 }, { freq: '64', index: 1 }, { freq: '125', index: 2 },
    { freq: '250', index: 3 }, { freq: '500', index: 4 }, { freq: '1k', index: 5 },
    { freq: '2k', index: 6 }, { freq: '4k', index: 7 }, { freq: '8k', index: 8 },
    { freq: '16k', index: 9 }
  ]
  private titleMap: Record<string, string> = {
    'customize': '定制',
    'playback': '播放',
    'audio': '音效',
    'about': '关于'
  }

  aboutToAppear(): void {
    this.settings = this.dataService.getSettings()
    // 进入设置页时刷新鼠标/触控板状态，决定「白色蒙版」开关是否显示
    refreshPointerDeviceState()
    const params = this.getUIContext()?.getRouter()
      .getParams() as Record<string, string>
    const route: string = params?.category ?? 'customize'
    this.pageTitle = this.titleMap[route] ?? '设置'
    ColorConversion.setSysBarLightBackground(this.isDark())
    // 智感握姿监听由 HoldingHandService 统一持有（首页加号与本页预览共用同一份滤波结果）
    HoldingHandService.getInstance().syncWithSetting()
    // 按明暗模式初始化 lightColorMode：未手动设置过时，暗黑默认白光，明亮默认主题色
    const existingLightMode: string = this.settings.lightColorMode
    if (existingLightMode === undefined || existingLightMode === '') {
      if (this.isDark()) {
        this.settings.lightColorMode = 'white'
      } else {
        this.settings.lightColorMode = 'theme'
        AppStorage.setOrCreate('uplayer_light_color_mode', 'theme')
      }
      this.updateSetting()
    }
  }

  aboutToDisappear(): void {
    if (this.showColorPicker) {
      this.settings.primaryColor = this.pickerOriginalColor
      this.primaryColor = this.pickerOriginalColor
      this.showColorPicker = false
    }
    // 监听不随本页销毁而退订：首页加号仍在用同一份握姿结果（由 EntryAbility 按前后台与开关同步订阅）
  }

  // 预览器说明：
  //   - homeTopBlurPreview：渐变模糊 (linearGradientBlur) 方块，随「首页上端模糊强度」变化
  //   - tabBarLivePreview：真实 Tab 栏实时预览（复刻 Index），随玻璃厚度/模糊强度/指示器深浅变化
  @Builder
  homeTopBlurPreview(): void {
    Stack({ alignContent: Alignment.Center }) {
      Text('首页上端')
        .fontSize(this.scaledFont(12))
        .fontWeight(FontWeight.Bold)
        .fontColor(this.primaryColor)
        .letterSpacing(this.scaledSize(1))
      Row()
        .width('100%')
        .height('100%')
        .backgroundColor(Color.Transparent)
        .linearGradientBlur(this.topBlurRadius(), {
          fractionStops: [[1, 0], [1, 0.5], [0, 1]],
          direction: GradientDirection.Bottom
        })
      Row()
        .width('100%')
        .height('100%')
        .borderRadius(this.scaledSize(18))
        .linearGradient({
          angle: 180,
          colors: [
            [ColorHelper.hexToRgba(this.primaryColor, 0.16), 0],
            [ColorHelper.hexToRgba(this.primaryColor, 0.04), 0.55],
            ['rgba(0,0,0,0)', 1]
          ]
        })
        .border({ width: 1, color: 'rgba(255,255,255,0.28)' })
        .shadow({ radius: 12, color: ColorHelper.hexWithAlpha(this.primaryColor, '44') })
    }
    .width(this.scaledSize(82))
    .height(this.scaledSize(36))
    .borderRadius(this.scaledSize(18))
    .clip(true)
  }

  // ═══ 底部 Tab 栏实时预览：原封不动复刻 Index 真实 Tab 栏 ═══
  // 结构/尺寸/材质/指示器/悬停/点击行为与 Index.customTabBar、Index.immersiveTabBar 完全一致，
  // 仅把页面级状态（currentIndex/indicatorOffset/hoverTabIndex）替换为预览态，
  // 玻璃厚度、模糊强度、指示器深浅三个滑块调节时可实时看到真实透视与磨砂效果。

  // 预览用 Tab 材质：经典样式走 createBarGlassMaterial（与 Index.classicTabBarMaterial 同参），
  // 玻璃样式走 createTabGlassMaterial 全参工厂（与 Index.liquidGlassMaterial 同参）
  private previewClassicBarMaterial(): uiMaterial.Material | undefined {
    return createBarGlassMaterial(this.glassThickness, this.interactive)
  }

  // 解析「底部栏触摸指示」实际生效值：
  // 设备无鼠标/触控板时「白色蒙版」功能不存在，mask 值降级为 off（开关本身已隐藏）
  private effectiveTouchIndicator(): string {
    if (this.settings.tabTouchIndicator === 'mask' && !this.hasPointerDevice) {
      return 'off'
    }
    return this.settings.tabTouchIndicator
  }

  private previewImmersiveBarMaterial(): uiMaterial.Material | undefined {
    const useLight: boolean = this.effectiveTouchIndicator() === 'light'
    const lightColor: string | undefined = useLight
      ? (this.settings.lightColorMode === 'white' ? '#FFFFFF' : this.primaryColor)
      : undefined
    return createTabGlassMaterial(this.glassThickness, this.interactive, lightColor, this.colorInvert, this.applyShadow)
  }

  // 与 Index.glassBlurRadius 同公式：模糊强度 × 0.5
  private previewGlassBlurRadius(): number {
    return this.glassBlurStrength * 0.5
  }

  // 设置页顶部带模糊半径：统一走 GlassUtil 的分段函数（先正比例、到 60 后恒定，临界处无缝相接），
  // 与首页上端 glassBlurRadius 是同一个函数、同一份取值，禁止在本文件重写公式
  private topBlurRadius(): number {
    return topBlurRadiusFromStrength(this.homeTopBlurStrength)
  }

  // 顶部标题带高度：与本页标题栏（返回按钮 + 页面标题）等高
  private titleBandHeight(): number {
    return Math.max(56, this.titleButtonHeight) + (this.isPC ? 0 : this.topSafeHeight)
  }

  // 与 Index.selectedTabContentColor 同逻辑
  private previewTabContentColor(): ResourceColor {
    return this.isDark() ? '#FFFFFF' : ColorHelper.darken(this.primaryColor, 0.35)
  }

  // 与 Index.bottomHoverEffect 同逻辑：白色蒙版模式下才有按压高亮
  private previewBottomHoverEffect(): HoverEffect {
    return this.effectiveTouchIndicator() === 'mask' ? HoverEffect.Highlight : HoverEffect.None
  }

  // 预览内点击 Tab：与 Index.switchPage/updateIndicatorOffset 一致的弹簧动画
  private switchPreviewTab(index: number): void {
    if (index === this.previewTabIndex) {
      return
    }
    this.getUIContext()?.animateTo({ curve: curves.springMotion(0.4, 0.8) }, () => {
      this.previewTabIndex = index
      this.previewIndicatorOffset =
        this.scaledSize(this.previewIndicatorInset + index * (this.previewTabWidth + this.previewTabGap))
    })
  }

  @Builder
  previewClassicTabBar(): void {
    Stack({ alignContent: Alignment.BottomStart }) {
      Row()
        .width(this.scaledSize(this.previewTabWidth * 3 + this.previewTabGap * 2))
        .height(this.scaledSize(40))
        .margin({ bottom: this.scaledSize(10) })
        .borderRadius(this.scaledSize(20))
        .backgroundColor(Color.Transparent)
        // 磨砂层只由「模糊强度」控制（0 关闭），暗黑模式不挂；
        // 液态玻璃启用时磨砂层作为材质底层兜底保留（与 Index 经典 Tab 栏一致）
        .backgroundEffect(!this.isDark() && this.glassBlurStrength > 0 ? {
          radius: this.previewGlassBlurRadius()
        } : undefined)
        .systemMaterial(this.previewClassicBarMaterial())
        .border({ width: 1, color: 'rgba(255,255,255,0.22)' })
        .shadow({ radius: 18, color: ColorHelper.hexWithAlpha(this.primaryColor, '44'), offsetY: 5 })
        .zIndex(0)

      Row()
        .width(this.scaledSize(this.previewTabWidth - 2 * this.previewIndicatorInset))
        .height(this.scaledSize(36))
        .borderRadius(this.scaledSize(18))
        .alignItems(VerticalAlign.Center)
        .margin({ left: this.previewIndicatorOffset, bottom: this.scaledSize(12) })
        .shadow({
          radius: 14,
          color: ColorHelper.hexWithAlpha(this.primaryColor, this.indicatorAlpha(0.8)
            .toString(16)
            .padStart(2, '0')),
          offsetX: 0,
          offsetY: 0
        })
        .radialGradient({
          center: ['50%', '50%'],
          radius: '75%',
          colors: [
            [this.indicatorGradientColor(0.95), 0.0],
            [this.indicatorGradientColor(0.75), 0.58],
            [this.indicatorGradientColor(0.55), 1.0],
          ]
        })
        .zIndex(1)

      Row({ space: this.scaledSize(this.previewTabGap) }) {
        this.previewTabItem(0, '首页', $r('app.media.ic_public_home'))
        this.previewTabItem(1, '歌单', $r('app.media.ic_public_view_list'))
        this.previewTabItem(2, '设置', $r('app.media.ic_public_settings'))
      }
      .margin({ bottom: this.scaledSize(10) })
      .height(this.scaledSize(40))
      .borderRadius(this.scaledSize(20))
      .zIndex(2)
    }
    .alignSelf(ItemAlign.Center)
    .height(this.scaledSize(60))
  }

  @Builder
  previewImmersiveTabBar(): void {
    Stack({ alignContent: Alignment.BottomStart }) {
      Row()
        .width(this.scaledSize(this.previewTabWidth - 2 * this.previewIndicatorInset))
        .height(this.scaledSize(36))
        .borderRadius(this.scaledSize(18))
        .alignItems(VerticalAlign.Center)
        .margin({ left: this.previewIndicatorOffset, bottom: this.scaledSize(12) })
        // 指示器深浅接入：alpha 基准 0.4，深浅 50 时等效原 '33'（与 Index 玻璃样式一致）
        .backgroundColor(ColorHelper.hexWithAlpha(this.primaryColor,
          this.indicatorAlpha(0.4).toString(16).padStart(2, '0')))

      Row({ space: this.scaledSize(this.previewTabGap) }) {
        this.previewImmersiveTabItem(0, '首页', $r('app.media.ic_public_home'))
        this.previewImmersiveTabItem(1, '歌单', $r('app.media.ic_public_view_list'))
        this.previewImmersiveTabItem(2, '设置', $r('app.media.ic_public_settings'))
      }
      .margin({ bottom: this.scaledSize(10) })
      .height(this.scaledSize(40))
      .borderRadius(this.scaledSize(20))
      .backgroundColor(Color.Transparent)
      // 磨砂层只由「模糊强度」控制（0 关闭），暗黑模式不挂；液态玻璃启用时作为材质底层兜底保留
      // （与 Index 玻璃样式 Tab 栏一致）
      .backgroundEffect(this.isDark() || this.glassBlurStrength <= 0 ? undefined : {
        radius: this.previewGlassBlurRadius()
      })
      .systemMaterial(this.previewImmersiveBarMaterial())
      .border({ width: 1, color: 'rgba(255,255,255,0.22)' })
      .shadow({ radius: 18, color: ColorHelper.hexWithAlpha(this.primaryColor, '44'), offsetY: 5 })
    }
    .alignSelf(ItemAlign.Center)
    .height(this.scaledSize(60))
  }

  @Builder
  previewTabItem(index: number, name: string, icon: Resource) {
    Column() {
      Image(icon)
        .height(this.scaledSize(18))
        .fillColor(this.previewTabIndex === index ? this.previewTabContentColor() :
          $r('app.color.tab_content_secondary'))
        .scale({
          x: this.previewTabIndex === index ? 1.15 : 1.0,
          y: this.previewTabIndex === index ? 1.15 : 1.0
        })
      Text(name)
        .fontSize(9)
        .fontColor(this.previewTabIndex === index ? this.previewTabContentColor() :
          $r('app.color.tab_content_secondary'))
        .margin({ top: this.scaledSize(2) })
    }
    .width(this.scaledSize(this.previewTabWidth))
    .height(this.scaledSize(40))
    .justifyContent(FlexAlign.Center)
    .backgroundColor(this.previewHoverTabIndex === index && this.effectiveTouchIndicator() === 'mask'
      ? 'rgba(255,255,255,0.16)' : Color.Transparent)
    .borderRadius(this.scaledSize(18))
    .shadow({
      radius: this.previewHoverTabIndex === index && this.effectiveTouchIndicator() === 'mask' ? 14 : 0,
      color: this.previewHoverTabIndex === index && this.effectiveTouchIndicator() === 'mask'
        ? ColorHelper.hexWithAlpha(this.primaryColor, '66') : Color.Transparent
    })
    .scale({
      x: this.previewHoverTabIndex === index ? 1.06 : 1,
      y: this.previewHoverTabIndex === index ? 1.06 : 1
    })
    .animation({ duration: StyleConstants.ANIMATION_HOVER_DURATION, curve: Curve.EaseOut })
    .hoverEffect(this.previewBottomHoverEffect())
    .onHover((isHover: boolean) => { this.previewHoverTabIndex = isHover ? index : -1 })
    .onClick(() => {
      this.switchPreviewTab(index)
    })
  }

  @Builder
  previewImmersiveTabItem(index: number, name: string, icon: Resource) {
    Column() {
      Image(icon)
        .height(this.scaledSize(18))
        .fillColor(this.previewTabIndex === index ? this.previewTabContentColor() :
          $r('app.color.tab_content_secondary'))
        .scale({
          x: this.previewTabIndex === index ? 1.15 : 1.0,
          y: this.previewTabIndex === index ? 1.15 : 1.0
        })
      Text(name)
        .fontSize(9)
        .fontColor(this.previewTabIndex === index ? this.previewTabContentColor() :
          $r('app.color.tab_content_secondary'))
        .margin({ top: this.scaledSize(2) })
    }
    .width(this.scaledSize(this.previewTabWidth))
    .height(this.scaledSize(40))
    .justifyContent(FlexAlign.Center)
    .backgroundColor(this.previewHoverTabIndex === index && this.effectiveTouchIndicator() === 'mask'
      ? 'rgba(255,255,255,0.18)' : Color.Transparent)
    .borderRadius(this.scaledSize(18))
    .shadow({
      radius: this.previewHoverTabIndex === index && this.effectiveTouchIndicator() === 'mask' ? 16 : 0,
      color: this.previewHoverTabIndex === index && this.effectiveTouchIndicator() === 'mask'
        ? ColorHelper.hexWithAlpha(this.primaryColor, '77') : Color.Transparent
    })
    .scale({
      x: this.previewHoverTabIndex === index ? 1.06 : 1,
      y: this.previewHoverTabIndex === index ? 1.06 : 1
    })
    .animation({ duration: StyleConstants.ANIMATION_HOVER_DURATION, curve: Curve.EaseOut })
    .hoverEffect(this.previewBottomHoverEffect())
    .onHover((isHover: boolean) => { this.previewHoverTabIndex = isHover ? index : -1 })
    .onClick(() => {
      this.switchPreviewTab(index)
    })
  }

  // 预览容器：彩色渐变底衬 + 示例文字（模拟页面内容，让磨砂/液态玻璃的透视效果可见），
  // Tab 栏居中悬浮其上；随底部栏样式设置切换经典/玻璃两种真实形态
  @Builder
  tabBarLivePreview(): void {
    Stack({ alignContent: Alignment.Center }) {
      Column({ space: this.scaledSize(4) }) {
        Text('UPlayer')
          .fontSize(this.scaledFont(16))
          .fontWeight(FontWeight.Bold)
          .fontColor('rgba(255,255,255,0.95)')
          .letterSpacing(this.scaledSize(1))
        Text('音乐 · 歌单 · 均衡器 · Aa 你好')
          .fontSize(this.scaledFont(11))
          .fontColor('rgba(255,255,255,0.75)')
      }
      .alignItems(HorizontalAlign.Center)

      if (this.settings.tabStyle === 'immersive') {
        this.previewImmersiveTabBar()
      } else {
        this.previewClassicTabBar()
      }
    }
    .width('100%')
    .height(this.scaledSize(104))
    .borderRadius(this.scaledSize(12))
    .linearGradient({
      angle: 135,
      colors: [
        ['#FF5A5F', 0.0],
        ['#FF9500', 0.35],
        ['#34C759', 0.65],
        ['#5AC8FA', 1.0]
      ]
    })
    .clip(true)
  }

  private indicatorAlpha(base: number): number {
    const opacity: number = this.tabIndicatorOpacity / 100
    return Math.round(base * opacity * 255)
  }

  private indicatorGradientColor(base: number): ResourceColor {
    return ColorHelper.hexWithAlpha(this.primaryColor, this.indicatorAlpha(base)
      .toString(16)
      .padStart(2, '0'))
  }

  private isDark(): boolean {
    if (this.themeMode === 'dark') {
      return true
    }
    if (this.themeMode === 'system') {
      try {
        return uiAppearance.getDarkMode() === uiAppearance.DarkMode.ALWAYS_DARK
      } catch (e) {
        return false
      }
    }
    return false
  }

  private settingTextColor(): ResourceColor {
    return this.isDark() ? '#FFFFFF' : ColorHelper.darken(this.primaryColor, 0.35)
  }

  private settingSubTextColor(): ResourceColor {
    return this.isDark() ? ColorHelper.hexWithAlpha('#FFFFFF', '88') : ColorHelper.darken(this.primaryColor, 0.3)
  }

  private settingInactiveTextColor(): ResourceColor {
    return this.isDark() ? ColorHelper.hexWithAlpha('#FFFFFF', '99') : ColorHelper.darken(this.primaryColor, 0.4)
  }

  private scaledFont(size: number): number {
    return Math.round(size * this.fontSizeScale)
  }

  private scaledSize(size: number): number {
    return Math.round(size * this.displaySizeScale)
  }

  updateSetting(): void {
    this.dataService.saveSettings(this.settings)
  }

  setThemeMode(mode: string): void {
    this.getUIContext()?.animateTo({ curve: curves.springMotion(0.4, 0.8) }, () => {
      this.settings.themeMode = mode
      this.settings = this.settings
    })
    this.updateSetting()
    AppStorage.setOrCreate('uplayer_theme_mode', mode)
    this.applyThemeMode(mode)
    ColorConversion.setSysBarLightBackground(this.isDark())
  }

  setTabStyle(style: string): void {
    this.getUIContext()?.animateTo({ curve: curves.springMotion(0.4, 0.8) }, () => {
      this.settings.tabStyle = style
      this.settings = this.settings
    })
    this.updateSetting()
    AppStorage.setOrCreate('uplayer_tab_style', style)
  }

  applyThemeMode(mode: string): void {
    if (this.context === undefined) {
      return
    }
    const appCtx = this.context.getApplicationContext()
    try {
      if (mode === 'light') {
        appCtx.setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT)
      } else if (mode === 'dark') {
        appCtx.setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_DARK)
      } else {
        appCtx.setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET)
      }
    } catch (e) {
      Logger.error(TAG, 'setColorMode failed: ' + JSON.stringify(e))
    }
  }

  setPrimaryColor(color: string): void {
    this.settings.primaryColor = color
    this.updateSetting()
    AppStorage.setOrCreate(KEY_PRIMARY_COLOR, color)
  }

  private currentPickerColor(): string {
    return ColorHelper.hsvToHex(this.pickerHue, this.pickerSaturation, this.pickerValue)
  }

  private hueColor(): string {
    return ColorHelper.hsvToHex(this.pickerHue, 1, 1)
  }

  private openColorPicker(): void {
    const hsv = ColorHelper.hexToHsv(this.settings.primaryColor)
    this.pickerOriginalColor = this.settings.primaryColor
    this.pickerHue = hsv.h
    this.pickerSaturation = hsv.s
    this.pickerValue = hsv.v
    this.showColorPicker = true
  }

  private updatePickerColor(): void {
    this.settings.primaryColor = this.currentPickerColor()
    this.primaryColor = this.currentPickerColor()
  }

  private cancelColorPicker(): void {
    this.settings.primaryColor = this.pickerOriginalColor
    this.primaryColor = this.pickerOriginalColor
    this.showColorPicker = false
  }

  private confirmColorPicker(): void {
    this.setPrimaryColor(this.currentPickerColor())
    this.showColorPicker = false
  }

  onSpeedChange(value: number, mode: SliderChangeMode): void {
    this.settings.playSpeed = 0.5 + value / 100
    if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) {
      this.updateSetting()
    }
    try {
      this.avPlayerService.setSpeed(this.settings.playSpeed)
    } catch (e) {
      Logger.error(TAG, 'setSpeed failed: ' + JSON.stringify(e))
    }
  }

  onEqBandChange(bandIndex: number, value: number, mode: SliderChangeMode): void {
    const bands: number[] = this.settings.eqBands.slice()
    bands[bandIndex] = Math.round(value) - 10
    this.settings.eqBands = bands
    this.settings = this.settings
    this.drawEqCurve()
    const applied: boolean = this.avPlayerService.updateEqualizerBands(bands)
    if (!applied && (mode === SliderChangeMode.End || mode === SliderChangeMode.Click)) {
      Logger.error(TAG, `equalizer change not applied by native backend index=${bandIndex} value=${bands[bandIndex]}`)
    }
    if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) {
      this.updateSetting()
    }
  }

  pageTransition() {
    PageTransitionEnter({ duration: StyleConstants.ANIMATION_SETTINGS_ENTER_DURATION, curve: Curve.EaseOut })
      .slide(SlideEffect.Right)
      .opacity(1)
    PageTransitionExit({ duration: StyleConstants.ANIMATION_SETTINGS_EXIT_DURATION, curve: Curve.EaseIn })
      .slide(SlideEffect.Right)
      .opacity(0)
  }

    build() {
    Stack() {
      Column() {
        // 沉浸式顶部：滚动内容从页面顶部开始（顶部空出标题带高度），
        // 内容向上滚动时从标题带下方穿过，被标题带上的渐变模糊层模糊（与首页上端一致）
        Stack({ alignContent: Alignment.Center }) {
          Column() {
            Scroll() {
              Column({ space: this.scaledSize(10) }) {
                if (this.pageTitle === '定制') {
                  this.buildCustomizeSection()
                } else if (this.pageTitle === '播放') {
                  this.buildPlaybackSection()
                } else if (this.pageTitle === '音效') {
                  this.buildAudioSection()
                } else if (this.pageTitle === '关于') {
                  this.buildAboutSection()
                }
              }
              .width('100%')
              .constraintSize({ minWidth: 0, maxWidth: '100%' })
              .padding({
                left: this.scaledSize(12), right: this.scaledSize(12),
                top: this.scaledSize(5) + this.titleBandHeight(), bottom: this.scaledSize(40)
              })
            }
            .width('100%')
            .layoutWeight(1)
            .align(Alignment.Top)
            .edgeEffect(EdgeEffect.Spring)
          }
          .width('100%')
          .height('100%')

          if (this.showColorPicker) {
            this.colorPickerOverlay()
          }

          // 标题带最后声明：浮在滚动内容与取色遮罩之上，返回按钮保持可点、标题文字保持清晰
          this.titleBand()
        }
        .width('100%')
        .layoutWeight(1)
      }
      .width('100%')
      .height('100%')
    }
    .width('100%')
    .height('100%')
    // 背景使用预设纯色（明暗自适应），不应用任何玻璃/模糊/透明度效果
    .backgroundColor($r('app.color.page_background_sm'))
    .bindSheet($$this.showGlassScope, this.glassScopeSheetBuilder(), {
      height: SheetSize.FIT_CONTENT,
      dragBar: false,
      preferType: SheetType.CENTER,
      showClose: true,
      backgroundColor: $r('app.color.page_background_other')
    })
  }

  // 顶部标题带：与首页上端完全同款的渐变模糊层（先正比例后恒定）+ 主题色渐变着色层，
  // 标题带浮在滚动内容之上，内容滚动到其下方时被模糊；经典/玻璃两种 Tab 风格下均启用
  @Builder
  titleBand(): void {
    Stack({ alignContent: Alignment.Top }) {
      Row()
        .width('100%')
        .height('100%')
        .backgroundColor(Color.Transparent)
        .linearGradientBlur(this.topBlurRadius(), {
          fractionStops: [[1, 0], [1, 0.5], [0, 1]],
          direction: GradientDirection.Bottom
        })

      Row()
        .width('100%')
        .height('100%')
        .linearGradient({
          angle: 180,
          colors: [
            [ColorHelper.hexToRgba(this.primaryColor, 0.04), 0],
            [ColorHelper.hexToRgba(this.primaryColor, 0.02), 0.5],
            ['rgba(0,0,0,0)', 1]
          ]
        })

      Row() {
        GlassBackButton({
          clickSize: this.scaledSize(48),
          iconSize: this.scaledSize(15),
          iconColor: this.settingTextColor(),
          iconOpacity: 0.9,
          onBack: () => {
            this.getUIContext()?.getRouter()
              .back()
          }
        })

        Text(this.pageTitle)
          .fontSize(this.scaledFont(17))
          .fontColor(this.settingTextColor())
          .fontWeight(FontWeight.Bold)
          .margin({ left: 4 })
      }
      .width('100%')
      .height('100%')
      .padding({
        left: 4,
        right: this.titleButtonWidth + 12,
        top: this.isPC ? 0 : this.topSafeHeight
      })
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .height(this.titleBandHeight())
    .position({ top: 0 })
    .clip(true)
    .hitTestBehavior(HitTestMode.Transparent)
    .zIndex(2)
  }

  @Builder
  sectionTitle(title: string): void {
    Text(title)
      .fontSize(this.scaledFont(13))
      .fontColor(this.settingTextColor())
      .fontWeight(FontWeight.Medium)
      .width('100%')
      .padding({ left: this.scaledSize(4), top: this.scaledSize(6), bottom: this.scaledSize(2) })
  }

  // 一级标题（用于把同类设置项聚合在一起，可选带右上角「问号」角标以引出说明弹窗）
  // helpIconLabel 非空时，问号图标紧跟文字；为空时通过 Blank() 撑到行尾（兼容旧调用）
  @Builder
  groupTitle(title: string, hasHelpIcon: boolean, helpIconLabel?: string): void {
    Row() {
      Text(title)
        .fontSize(this.scaledFont(11))
        .fontColor(this.settingTextColor())
        .fontWeight(FontWeight.Bold)
      if (helpIconLabel !== undefined) {
        Stack({ alignContent: Alignment.Center }) {
          Circle()
            .width(this.scaledSize(18))
            .height(this.scaledSize(18))
            .fill(ColorHelper.hexToRgba(this.primaryColor, 0.12))
          Image($r('app.media.ic_public_help'))
            .width(this.scaledSize(13))
            .height(this.scaledSize(13))
            .fillColor(this.primaryColor)
        }
        .width(this.scaledSize(18))
        .height(this.scaledSize(18))
        .margin({ left: this.scaledSize(4) })
        .onClick(() => {
          this.showGlassScope = true
        })
      }
      if (hasHelpIcon && helpIconLabel === undefined) {
        Blank()
        Stack({ alignContent: Alignment.Center }) {
          Circle()
            .width(this.scaledSize(18))
            .height(this.scaledSize(18))
            .fill(ColorHelper.hexToRgba(this.primaryColor, 0.12))
          Image($r('app.media.ic_public_help'))
            .width(this.scaledSize(13))
            .height(this.scaledSize(13))
            .fillColor(this.primaryColor)
        }
        .width(this.scaledSize(18))
        .height(this.scaledSize(18))
        .onClick(() => {
          this.showGlassScope = true
        })
      }
    }
    .width('100%')
    .padding({ left: this.scaledSize(8), top: this.scaledSize(1), bottom: this.scaledSize(4) })
    .alignItems(VerticalAlign.Center)
  }

  // 行内二级标题（用于 Row 内，不带 width 约束，避免溢出）
  @Builder
  subTitleRow(title: string): void {
    Text(title)
      .fontSize(this.scaledFont(14))
      .fontColor(this.settingTextColor())
      .fontWeight(FontWeight.Medium)
      .padding({ right: this.scaledSize(4) })
  }

  // 玻璃效果生效范围说明弹窗（bindSheet 半模态内容）
  @Builder
  glassScopeSheetBuilder(): void {
    Column({ space: this.scaledSize(10) }) {
      Text('玻璃效果生效范围')
        .fontSize(this.scaledFont(16))
        .fontColor(this.settingTextColor())
        .fontWeight(FontWeight.Bold)
        .width('100%')
        .textAlign(TextAlign.Start)

      Text('以下位置会使用玻璃效果：')
        .fontSize(this.scaledFont(12))
        .fontColor(this.settingSubTextColor())
        .width('100%')
        .padding({ top: this.scaledSize(2) })
      this.scopeLine('• 底部 Tab 栏（沉浸式玻璃，带光效跟手 + 按压 Q 弹形变）')
      this.scopeLine('• 右下角播控条')
      this.scopeLine('• 顶部的模糊层（首页顶部标题区，覆盖首页第一屏）')
      this.scopeLine('• 首页 / 歌单 / 设置 / 设置详情 四个一级页面的顶层背景（仅档位与材质在此生效）')
      this.scopeLine('• 操作时屏幕底部短暂弹出的文字提示浮层（如切换播放模式时的"随机播放"）——单独由「系统组件液态玻璃」开关控制')

      Text('以下位置不使用玻璃效果：')
        .fontSize(this.scaledFont(12))
        .fontColor(this.settingSubTextColor())
        .width('100%')
        .padding({ top: this.scaledSize(6) })
      this.scopeLine('• 音乐播放器页面')
      this.scopeLine('• 系统API ≤ 26 （液态玻璃材质降级为背景模糊）')

      Row() {
        Button('知道了')
          .layoutWeight(1)
          .height(this.scaledSize(30))
          .fontColor('#FFFFFF')
          .backgroundColor(this.primaryColor)
          .borderRadius(this.scaledSize(15))
          .onClick(() => {
            this.showGlassScope = false
          })
      }
      .width('100%')
      .padding({ top: this.scaledSize(8), bottom: this.scaledSize(10) })
    }
    .width('100%')
    .padding({ left: this.scaledSize(20), right: this.scaledSize(20), top: this.scaledSize(14) })
  }

  @Builder
  scopeLine(text: string): void {
    Text(text)
      .fontSize(this.scaledFont(12))
      .fontColor(this.settingSubTextColor())
      .width('100%')
      .padding({ top: this.scaledSize(2) })
  }

  @Builder
  buildCustomizeSection(): void {
    Column({ space: this.scaledSize(10) }) {
      Row(){
        this.groupTitle('全局', false)
      }
      Column() {
        this.toggleRow('向下滑动时隐藏加号按钮', this.settings.plusButtonScrollHide, (val: boolean) => {
          this.settings.plusButtonScrollHide = val
          this.updateSetting()
        })
      }
      .width('100%')
      .padding({ left: this.scaledSize(14), right: this.scaledSize(14) })
      .backgroundColor(ColorHelper.hexToRgba(this.primaryColor, 0.04))
      .borderRadius(this.scaledSize(10))

      Column() {
        Row() {
          Text('主题模式')
            .fontSize(this.scaledFont(14))
            .fontColor(this.settingTextColor())
          Blank()
          ForEach(this.themeOptions, (opt: ThemeOption) => {
            Column() {
              Text(opt.label)
                .fontSize(this.scaledFont(11))
                .fontColor(this.settings.themeMode === opt.value ? '#FFFFFF' : this.settingInactiveTextColor())
            }
            .padding({
              left: this.scaledSize(10),
              right: this.scaledSize(10),
              top: this.scaledSize(5),
              bottom: this.scaledSize(5)
            })
            .backgroundColor(this.settings.themeMode === opt.value ? this.primaryColor : ColorHelper.hexToRgba(this.primaryColor, 0.08))
            .borderRadius(this.scaledSize(14))
            .animation({ duration: 200, curve: Curve.EaseInOut })
            .onClick(() => {
              this.setThemeMode(opt.value)
            })
          }, (opt: ThemeOption) => opt.value)
        }
        .padding({ left: this.scaledSize(14), right: this.scaledSize(14) })
        .width('100%')
        .height(this.scaledSize(44))
        .alignItems(VerticalAlign.Center)
      }
      .width('100%')
      .backgroundColor(ColorHelper.hexToRgba(this.primaryColor, 0.04))
      .borderRadius(this.scaledSize(10))

      Column() {
        Row() {
          Text('底部栏样式')
            .fontSize(this.scaledFont(14))
            .fontColor(this.settingTextColor())
          Blank()
          ForEach(this.tabStyleOptions, (opt: TabStyleOption) => {
            Column() {
              Text(opt.label)
                .fontSize(this.scaledFont(11))
                .fontColor(this.settings.tabStyle === opt.value ? '#FFFFFF' : this.settingInactiveTextColor())
            }
            .padding({
              left: this.scaledSize(10),
              right: this.scaledSize(10),
              top: this.scaledSize(5),
              bottom: this.scaledSize(5)
            })
            .backgroundColor(this.settings.tabStyle === opt.value ? this.primaryColor : ColorHelper.hexToRgba(this.primaryColor, 0.08))
            .borderRadius(this.scaledSize(14))
            .animation({ duration: 200, curve: Curve.EaseInOut })
            .onClick(() => {
              this.setTabStyle(opt.value)
            })
          }, (opt: TabStyleOption) => opt.value)
        }
        .padding({ left: this.scaledSize(14), right: this.scaledSize(14) })
        .width('100%')
        .height(this.scaledSize(44))
        .alignItems(VerticalAlign.Center)
      }
      .width('100%')
      .backgroundColor(ColorHelper.hexToRgba(this.primaryColor, 0.04))
      .borderRadius(this.scaledSize(10))

      // ─── 一级标题「交互」（底部栏交互设置）───
      Column() {
        this.groupTitle('交互', false)
      }
      .width('100%')

      // 跟手光效颜色：白光 / 主题色（仅暗黑模式显示，明亮模式固定主题色并隐藏此设置项）
      if (this.isDark()) {
        Column() {
          Row() {
            this.subTitleRow('跟手光效颜色')
            Blank()
            Column() {
              Text('白光')
                .fontSize(this.scaledFont(11))
                .fontColor(this.settings.lightColorMode === 'white'
                  ? '#FFFFFF' : this.settingInactiveTextColor())
            }
            .padding({
              left: this.scaledSize(10),
              right: this.scaledSize(10),
              top: this.scaledSize(5),
              bottom: this.scaledSize(5)
            })
            .backgroundColor(this.settings.lightColorMode === 'white'
              ? this.primaryColor : ColorHelper.hexToRgba(this.primaryColor, 0.08))
            .borderRadius(this.scaledSize(14))
            .animation({ duration: 200, curve: Curve.EaseInOut })
            .onClick(() => {
              this.settings.lightColorMode = 'white'
              this.updateSetting()
              AppStorage.setOrCreate('uplayer_light_color_mode', 'white')
            })
            Column() {
              Text('主题色')
                .fontSize(this.scaledFont(11))
                .fontColor( this.settings.lightColorMode === 'theme'
                  ? '#FFFFFF' : this.settingInactiveTextColor())
            }
            .padding({
              left: this.scaledSize(10),
              right: this.scaledSize(10),
              top: this.scaledSize(5),
              bottom: this.scaledSize(5)
            })
            .backgroundColor(this.settings.lightColorMode === 'theme'
              ? this.primaryColor : ColorHelper.hexToRgba(this.primaryColor, 0.08))
            .borderRadius(this.scaledSize(14))
            .animation({ duration: 200, curve: Curve.EaseInOut })
            .onClick(() => {
              this.settings.lightColorMode = 'theme'
              this.updateSetting()
              AppStorage.setOrCreate('uplayer_light_color_mode', 'theme')
            })
          }
          .width('100%')
          .constraintSize({ minWidth: 0, maxWidth: '100%' })
          .alignItems(VerticalAlign.Center)
          .padding({ left: this.scaledSize(14), right: this.scaledSize(14), top: this.scaledSize(10), bottom: this.scaledSize(10) })
        }
        .width('100%')
        .backgroundColor(ColorHelper.hexToRgba(this.primaryColor, 0.04))
        .borderRadius(this.scaledSize(10))
      }

      // 底部栏触摸指示：关 / 白色蒙版 / 跟手光效
      // 白色蒙版开关按鼠标检测结果动态显示/隐藏（见 visibleTouchIndicatorOptions）
      Column() {
        Row() {
          this.subTitleRow('底部栏触摸指示')
          Blank()
          ForEach(this.visibleTouchIndicatorOptions(), (opt: TouchIndicatorOption) => {
            Column() {
              Text(opt.label)
                .fontSize(this.scaledFont(11))
                .fontColor(this.settings.tabTouchIndicator === opt.value
                  ? '#FFFFFF' : this.settingInactiveTextColor())
            }
            .padding({
              left: this.scaledSize(10),
              right: this.scaledSize(10),
              top: this.scaledSize(5),
              bottom: this.scaledSize(5)
            })
            .backgroundColor(this.settings.tabTouchIndicator === opt.value
              ? this.primaryColor : ColorHelper.hexToRgba(this.primaryColor, 0.08))
            .borderRadius(this.scaledSize(14))
            .animation({ duration: 200, curve: Curve.EaseInOut })
            .onClick(() => {
              this.settings.tabTouchIndicator = opt.value
              this.updateSetting()
              AppStorage.setOrCreate('uplayer_tab_touch_indicator', opt.value)
            })
          }, (opt: TouchIndicatorOption) => opt.value)
        }
        .width('100%')
        .constraintSize({ minWidth: 0, maxWidth: '100%' })
        .alignItems(VerticalAlign.Center)
        .padding({ left: this.scaledSize(14), right: this.scaledSize(14), top: this.scaledSize(10), bottom: this.scaledSize(10) })
      }
      .width('100%')
      .backgroundColor(ColorHelper.hexToRgba(this.primaryColor, 0.04))
      .borderRadius(this.scaledSize(10))

      // 智感握姿
      Row() {
        Column({ space: this.scaledSize(6) }) {
          Text('智感握姿')
            .fontSize(this.scaledFont(14))
            .fontColor(this.settingTextColor())
            .fontWeight(FontWeight.Medium)
          Text('根据单手握持方向自动调整首页顶部预览与控件靠左/靠右。')
            .fontSize(this.scaledFont(12))
            .fontColor(this.settingSubTextColor())
        }
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Start)
        Toggle({ type: ToggleType.Switch, isOn: this.settings.holdingHandEnabled })
          .selectedColor(this.primaryColor)
          .alignSelf(ItemAlign.Center)
          .onChange((isOn: boolean) => {
            this.settings.holdingHandEnabled = isOn
            // 写穿到 AppStorage 后由共享服务按新开关重新订阅/退订
            this.holdingHandEnabled = isOn
            this.updateSetting()
            HoldingHandService.getInstance().syncWithSetting()
          })
      }
      .width('100%')
      .height(this.scaledSize(52))
      .padding({ left: this.scaledSize(14), right: this.scaledSize(14) })

      // ─── 一级标题「高级样式」（玻璃模式下显示） + 右上角叹号角标 ───
      // 点击叹号弹窗说明玻璃效果所影响的所有位置
      Column() {
        this.groupTitle('高级样式', true, 'glass')
        // 玻璃厚度 / 模糊强度 / 指示器深浅三合一卡片：
        // 顶部为真实 Tab 栏实时预览（复刻 Index，可点击/悬停），三个滑块调节时实时反映透视与磨砂效果
        Column({ space: this.scaledSize(10) }) {
          this.tabBarLivePreview()

          Column({ space: this.scaledSize(6) }) {
            Row() {
              this.subTitleRow('玻璃厚度')
              Blank()
            }
            .width('100%')
            Text('控制玻璃材质的模糊强度，共五档（极薄/薄/常规/厚/极厚），0 为关闭玻璃。')
              .fontSize(this.scaledFont(12))
              .fontColor(this.settingSubTextColor())
              .width('100%')
            Row() {
              Slider({
                value: this.settings.glassThickness,
                min: 0,
                max: 100,
                step: 20,
                style: SliderStyle.OutSet
              })
                .layoutWeight(1)
                .selectedColor(this.primaryColor)
                .trackColor(ColorHelper.hexToRgba(this.primaryColor, 0.12))
                .blockColor('#FFFFFF')
                .blockSize({ width: this.scaledSize(20), height: this.scaledSize(20) })
                .blockBorderColor(this.primaryColor)
                .blockBorderWidth(3)
                .onChange((value: number, mode: SliderChangeMode) => {
                  this.settings.glassThickness = value
                  this.glassThickness = value
                  if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) {
                    this.updateSetting()
                  }
                })
            }
            .width('100%')
            .alignItems(VerticalAlign.Center)
            .padding({ top: this.scaledSize(2), bottom: this.scaledSize(2) })
            // 滑轨下方 6 档位刻度标注：按档位点定位（0/20/40/60/80/100 → 轨道 0%~100%），
            // 与 OutSet 滑块中心两端内缩半个滑块宽（scaledSize(10)）对齐；当前档主题色高亮
            Row() {
              Stack() {
                ForEach(GLASS_THICKNESS_STEPS, (step: number, idx: number) => {
                  Text(glassThicknessLabel(step))
                    .fontSize(this.scaledFont(10))
                    .fontColor(this.settings.glassThickness === step ? this.primaryColor : this.settingSubTextColor())
                    .position({ x: `${idx * 20}%`, y: 0 })
                    .markAnchor({ x: '50%', y: 0 })
                }, (step: number, idx: number) => `${idx}_${step}`)
              }
              .layoutWeight(1)
              .height(this.scaledSize(14))
              .alignContent(Alignment.TopStart)
            }
            .width('100%')
            .padding({ left: this.scaledSize(10), right: this.scaledSize(10) })
          }
          .width('100%')

          // 磨砂兜底模糊强度：仅在不支持液态玻璃的老设备上显示（新设备材质接管背景，该项无可见效果）
          if (!isLiquidGlassAvailable()) {
            Column({ space: this.scaledSize(6) }) {
              Row() {
                this.subTitleRow('Tab栏与播控条模糊强度')
                Blank()
              }
              .width('100%')
              Text('控制底部 Tab 栏与迷你播控条的磨砂模糊半径；暗黑模式下磨砂层不启用。')
                .fontSize(this.scaledFont(12))
                .fontColor(this.settingSubTextColor())
                .width('100%')
              Row({ space: this.scaledSize(12) }) {
                Text('弱')
                  .fontSize(this.scaledFont(11))
                  .fontColor(this.settingTextColor())
                Slider({
                  value: this.settings.glassBlurStrength,
                  min: 0,
                  max: 100,
                  step: 1,
                  style: SliderStyle.OutSet
                })
                  .layoutWeight(1)
                  .selectedColor(this.primaryColor)
                  .trackColor(ColorHelper.hexToRgba(this.primaryColor, 0.12))
                  .blockColor('#FFFFFF')
                  .blockSize({ width: this.scaledSize(20), height: this.scaledSize(20) })
                  .blockBorderColor(this.primaryColor)
                  .blockBorderWidth(3)
                  .onChange((value: number, mode: SliderChangeMode) => {
                    this.settings.glassBlurStrength = value
                    this.glassBlurStrength = value
                    if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) {
                      this.updateSetting()
                    }
                  })
                Text('强')
                  .fontSize(this.scaledFont(11))
                  .fontColor(this.settingTextColor())
              }
              .width('100%')
              .alignItems(VerticalAlign.Center)
              .padding({ top: this.scaledSize(2), bottom: this.scaledSize(2) })
            }
            .width('100%')
          }

          Column({ space: this.scaledSize(6) }) {
            Row() {
              this.subTitleRow('经典 Tab 指示器')
              Blank()
            }
            .width('100%')
            Row({ space: this.scaledSize(12) }) {
              Text('浅')
                .fontSize(this.scaledFont(11))
                .fontColor(this.settingTextColor())
              Slider({
                value: this.settings.tabIndicatorOpacity,
                min: 0,
                max: 100,
                step: 1,
                style: SliderStyle.OutSet
              })
                .layoutWeight(1)
                .selectedColor(this.primaryColor)
                .trackColor(ColorHelper.hexToRgba(this.primaryColor, 0.12))
                .blockColor('#FFFFFF')
                .blockSize({ width: this.scaledSize(20), height: this.scaledSize(20) })
                .blockBorderColor(this.primaryColor)
                .blockBorderWidth(3)
                .onChange((value: number, mode: SliderChangeMode) => {
                  this.settings.tabIndicatorOpacity = value
                  this.tabIndicatorOpacity = value
                  if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) {
                    this.updateSetting()
                  }
                })
              Text('深')
                .fontSize(this.scaledFont(11))
                .fontColor(this.settingTextColor())
            }
            .width('100%')
            .alignItems(VerticalAlign.Center)
            .padding({ top: this.scaledSize(2), bottom: this.scaledSize(2) })
          }
          .width('100%')
        }
        .width('100%')
        .padding({
          top: this.scaledSize(10),
          left: this.scaledSize(14),
          right: this.scaledSize(14),
          bottom: this.scaledSize(10)
        })
        .backgroundColor(ColorHelper.hexToRgba(this.primaryColor, 0.04))
        .borderRadius(this.scaledSize(10))

        // 交互形变：按压/拖动时液态玻璃产生 Q 弹反馈
        Column({ space: this.scaledSize(10) }) {
          Row() {
            Column({ space: this.scaledSize(6) }) {
              Text('交互形变')
                .fontSize(this.scaledFont(14))
                .fontColor(this.settingTextColor())
                .fontWeight(FontWeight.Medium)
              Text('按压或拖动时，材质表面产生弹性形变反馈。')
                .fontSize(this.scaledFont(12))
                .fontColor(this.settingSubTextColor())
            }
            .layoutWeight(1)
            .justifyContent(FlexAlign.Center)
            .alignItems(HorizontalAlign.Start)
            Toggle({ type: ToggleType.Switch, isOn: this.settings.interactive })
              .selectedColor(this.primaryColor)
              .alignSelf(ItemAlign.Center)
              .onChange((isOn: boolean) => {
                this.settings.interactive = isOn
                this.interactive = isOn
                this.updateSetting()
              })
          }
          .width('100%')
          .height(this.scaledSize(52))
          .padding({ left: this.scaledSize(14), right: this.scaledSize(14) })

          Row() {
            Column({ space: this.scaledSize(6) }) {
              Text('自动反色')
                .fontSize(this.scaledFont(14))
                .fontColor(this.settingTextColor())
                .fontWeight(FontWeight.Medium)
              Text('材质足够薄时，子元素文字/图标颜色自动适配背景，确保可读性。')
                .fontSize(this.scaledFont(12))
                .fontColor(this.settingSubTextColor())
            }
            .layoutWeight(1)
            .justifyContent(FlexAlign.Center)
            .alignItems(HorizontalAlign.Start)
            Toggle({ type: ToggleType.Switch, isOn: this.settings.colorInvert })
              .selectedColor(this.primaryColor)
              .alignSelf(ItemAlign.Center)
              .onChange((isOn: boolean) => {
                this.settings.colorInvert = isOn
                this.colorInvert = isOn
                this.updateSetting()
              })
          }
          .width('100%')
          .height(this.scaledSize(52))
          .padding({ left: this.scaledSize(14), right: this.scaledSize(14) })

          Row() {
            Column({ space: this.scaledSize(6) }) {
              Text('材质阴影')
                .fontSize(this.scaledFont(14))
                .fontColor(this.settingTextColor())
                .fontWeight(FontWeight.Medium)
              Text('材质自带阴影效果，优先于手动设置的 shadow 属性。')
                .fontSize(this.scaledFont(12))
                .fontColor(this.settingSubTextColor())
            }
            .layoutWeight(1)
            .justifyContent(FlexAlign.Center)
            .alignItems(HorizontalAlign.Start)
            Toggle({ type: ToggleType.Switch, isOn: this.settings.applyShadow })
              .selectedColor(this.primaryColor)
              .alignSelf(ItemAlign.Center)
              .onChange((isOn: boolean) => {
                this.settings.applyShadow = isOn
                this.applyShadow = isOn
                this.updateSetting()
              })
          }
          .width('100%')
          .height(this.scaledSize(52))
          .padding({ left: this.scaledSize(14), right: this.scaledSize(14) })

          Row() {
            Column({ space: this.scaledSize(6) }) {
              Text('系统组件液态玻璃')
                .fontSize(this.scaledFont(14))
                .fontColor(this.settingTextColor())
                .fontWeight(FontWeight.Medium)
              Text('切换播放模式等操作时，屏幕底部短暂弹出的文字提示浮层（如"随机播放"）使用液态玻璃材质；需设备支持（API 26+）。')
                .fontSize(this.scaledFont(12))
                .fontColor(this.settingSubTextColor())
            }
            .layoutWeight(1)
            .justifyContent(FlexAlign.Center)
            .alignItems(HorizontalAlign.Start)
            Toggle({ type: ToggleType.Switch, isOn: this.settings.systemComponentGlass })
              .selectedColor(this.primaryColor)
              .alignSelf(ItemAlign.Center)
              .onChange((isOn: boolean) => {
                this.settings.systemComponentGlass = isOn
                this.systemComponentGlass = isOn
                this.updateSetting()
              })
          }
          .width('100%')
          .height(this.scaledSize(52))
          .padding({ left: this.scaledSize(14), right: this.scaledSize(14) })
        }
        .width('100%')
        .padding({ top: this.scaledSize(10) })
        .backgroundColor(ColorHelper.hexToRgba(this.primaryColor, 0.04))
        .borderRadius(this.scaledSize(10))

        // 玻璃效果生效范围：已通过一级标题右上角的小叹号引出弹窗说明
      }
      .width('100%')
      // 经典/玻璃两种 Tab 样式均使用液态玻璃材质，高级样式组常显
      // 去掉玻璃卡片之间默认的 10vp 间隔间距，由内部 padding 自己控制
      // ——已通过 groupTitle 与 .padding 处理

      // ─── 一级标题「背景模糊」（两种 Tab 风格下均显示）───
      Column() {
        this.groupTitle('背景模糊', false)

        // 首页上端模糊强度
        Column({ space: this.scaledSize(6) }) {
          Row() {
            this.subTitleRow('首页上端模糊强度')
            Blank()
          }
          .width('100%')
          Text('控制首页顶部标题区玻璃模糊的渐变强度。')
            .fontSize(this.scaledFont(12))
            .fontColor(this.settingSubTextColor())
            .width('100%')
          Row({ space: this.scaledSize(12) }) {
            if (!this.previewOnRight) {
              this.homeTopBlurPreview()
            }
            Text('浅')
              .fontSize(this.scaledFont(11))
              .fontColor(this.settingTextColor())
              .margin({
                left: this.previewOnRight ? 0 : this.scaledSize(14),
                right: this.scaledSize(8)
              })
            Slider({
              value: this.settings.homeTopBlurStrength,
              min: 0,
              max: 100,
              step: 1,
              style: SliderStyle.OutSet
            })
              .layoutWeight(1)
              .selectedColor(this.primaryColor)
              .trackColor(ColorHelper.hexToRgba(this.primaryColor, 0.12))
              .blockColor('#FFFFFF')
              .blockSize({ width: this.scaledSize(20), height: this.scaledSize(20) })
              .blockBorderColor(this.primaryColor)
              .blockBorderWidth(3)
              .onChange((value: number, mode: SliderChangeMode) => {
                this.settings.homeTopBlurStrength = value
                this.homeTopBlurStrength = value
                if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) {
                  this.updateSetting()
                }
              })
            Text('深')
              .fontSize(this.scaledFont(11))
              .fontColor(this.settingTextColor())
              .margin({ left: this.scaledSize(8) })
            if (this.previewOnRight) {
              Blank().width(this.scaledSize(14))
              this.homeTopBlurPreview()
            }
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)
          .padding({ top: this.scaledSize(2), bottom: this.scaledSize(2) })
        }
        .width('100%')
        .padding({
          top: this.scaledSize(10),
          left: this.scaledSize(14),
          right: this.scaledSize(14),
          bottom: this.scaledSize(10)
        })
        .backgroundColor(ColorHelper.hexToRgba(this.primaryColor, 0.04))
        .borderRadius(this.scaledSize(10))
        // 「Tab栏与播控条模糊强度」「经典 Tab 指示器」已并入上方「高级样式」组的 Tab 实时预览卡片
      }
      .width('100%')

      Column({ space: this.scaledSize(8) }) {
        Row() {
          this.subTitleRow('主题色')
          Blank()
        }
        .width('100%')
        Grid() {
          ForEach(this.colorOptions, (option: ThemeColorOption) => {
            GridItem() {
              Row({ space: this.scaledSize(8) }) {
                Column()
                  .width(this.scaledSize(24))
                  .height(this.scaledSize(24))
                  .borderRadius(this.scaledSize(12))
                  .backgroundColor(option.value)
                  .border({
                    width: this.settings.primaryColor === option.value ? 3 : 0,
                    color: '#FFFFFF'
                  })
                Text(option.name)
                  .fontSize(this.scaledFont(11))
                  .fontColor(this.settingTextColor())
                  .maxLines(1)
              }
              .width('100%')
              .height(this.scaledSize(42))
              .padding({ left: this.scaledSize(8), right: this.scaledSize(8), top: this.scaledSize(4), bottom: this.scaledSize(4) })
              .margin({ bottom: this.scaledSize(4) })
              .borderRadius(this.scaledSize(10))
              .backgroundColor(this.settings.primaryColor === option.value ?
                ColorHelper.hexToRgba(option.value, 0.18) : ColorHelper.hexToRgba(this.primaryColor, 0.04))
              .onClick(() => {
                this.setPrimaryColor(option.value)
              })
            }
          }, (option: ThemeColorOption) => option.value)
        }
        .columnsTemplate(this.isPC ? '1fr 1fr 1fr 1fr' : '1fr 1fr')
        .columnsGap(this.scaledSize(8))
        .rowsGap(this.scaledSize(8))
        .width('100%')

        Row({ space: this.scaledSize(8) }) {
          Column()
            .width(this.scaledSize(24))
            .height(this.scaledSize(24))
            .borderRadius(this.scaledSize(12))
            .backgroundColor(this.settings.primaryColor)
            .border({
              width: !this.colorOptions.some((opt: ThemeColorOption) => opt.value === this.settings.primaryColor) ? 3 : 0,
              color: '#FFFFFF'
            })
          Text('自定义颜色')
            .fontSize(this.scaledFont(11))
            .fontColor(this.settingTextColor())
            .maxLines(1)
          Blank()
          Image($r('app.media.ic_public_themes'))
            .width(this.scaledSize(16))
            .height(this.scaledSize(16))
            .fillColor(this.settings.primaryColor)
        }
        .width('100%')
        .height(this.scaledSize(42))
        .padding({ left: this.scaledSize(14), right: this.scaledSize(14) })
        .borderRadius(this.scaledSize(10))
        .backgroundColor(ColorHelper.hexToRgba(this.primaryColor, 0.04))
        .alignItems(VerticalAlign.Center)
        .onClick(() => {
          this.openColorPicker()
        })
      }
      .width('100%')
      .padding({
        top: this.scaledSize(10),
        left: this.scaledSize(14),
        right: this.scaledSize(14),
        bottom: this.scaledSize(10)
      })
      .backgroundColor(ColorHelper.hexToRgba(this.primaryColor, 0.04))
      .borderRadius(this.scaledSize(10))

      Column({ space: this.scaledSize(6) }) {
        Row() {
          this.subTitleRow('字体大小')
          Blank()
        }
        .width('100%')
        Row() {
          Text('A')
            .fontSize(this.scaledFont(11))
            .fontColor(this.settingTextColor())
          Stack() {
            Slider({
              value: this.settings.fontSizeScale * 100,
              min: 80,
              max: 150,
              step: 1,
              style: SliderStyle.OutSet
            })
              .layoutWeight(1)
              .selectedColor(this.primaryColor)
              .trackColor(ColorHelper.hexToRgba(this.primaryColor, 0.12))
              .blockColor('#FFFFFF')
              .blockSize({ width: this.scaledSize(20), height: this.scaledSize(20) })
              .blockBorderColor(this.primaryColor)
              .blockBorderWidth(3)
              .onChange((value: number, mode: SliderChangeMode) => {
                this.settings.fontSizeScale = value / 100
                this.fontSizeScale = this.settings.fontSizeScale
                if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) {
                  this.updateSetting()
                }
              })
          }
          .layoutWeight(1)
          .height(this.scaledSize(36))
          Text('A')
            .fontSize(this.scaledFont(20))
            .fontColor(this.settingTextColor())
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
      }
      .width('100%')
      .padding({
        top: this.scaledSize(10),
        left: this.scaledSize(14),
        right: this.scaledSize(14),
        bottom: this.scaledSize(10)
      })
      .backgroundColor(ColorHelper.hexToRgba(this.primaryColor, 0.04))
      .borderRadius(this.scaledSize(10))

      Column({ space: this.scaledSize(6) }) {
        Row() {
          this.subTitleRow('显示大小')
          Blank()
        }
        .width('100%')
        Row() {
          Text('小')
            .fontSize(this.scaledFont(11))
            .fontColor(this.settingTextColor())
          Stack() {
            Slider({
              value: this.settings.displaySizeScale * 100,
              min: 80,
              max: 150,
              step: 1,
              style: SliderStyle.OutSet
            })
              .layoutWeight(1)
              .selectedColor(this.primaryColor)
              .trackColor(ColorHelper.hexToRgba(this.primaryColor, 0.12))
              .blockColor('#FFFFFF')
              .blockSize({ width: this.scaledSize(20), height: this.scaledSize(20) })
              .blockBorderColor(this.primaryColor)
              .blockBorderWidth(3)
              .onChange((value: number, mode: SliderChangeMode) => {
                this.settings.displaySizeScale = value / 100
                this.displaySizeScale = this.settings.displaySizeScale
                if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) {
                  this.updateSetting()
                }
              })
          }
          .layoutWeight(1)
          .height(this.scaledSize(36))
          Text('大')
            .fontSize(this.scaledFont(14))
            .fontColor(this.settingTextColor())
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
      }
      .width('100%')
      .padding({
        top: this.scaledSize(10),
        left: this.scaledSize(14),
        right: this.scaledSize(14),
        bottom: this.scaledSize(10)
      })
      .backgroundColor(ColorHelper.hexToRgba(this.primaryColor, 0.04))
      .borderRadius(this.scaledSize(10))
    }
    .width('100%')
    .constraintSize({ minWidth: 0, maxWidth: '100%' })
  }

  @Builder
  colorPickerOverlay(): void {
    Stack({ alignContent: Alignment.Center }) {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor('rgba(0,0,0,0.45)')

      Column({ space: this.scaledSize(12) }) {
        Row() {
          Text('自定义主题色')
            .fontSize(this.scaledFont(16))
            .fontColor(this.settingTextColor())
            .fontWeight(FontWeight.Bold)
          Blank()
          Column()
            .width(this.scaledSize(34))
            .height(this.scaledSize(34))
            .borderRadius(this.scaledSize(17))
            .backgroundColor(this.currentPickerColor())
            .border({ width: 2, color: '#FFFFFF' })
        }
        .width('100%')

        Stack({ alignContent: Alignment.TopStart }) {
          Row()
            .width('100%')
            .height('100%')
            .linearGradient({
              angle: 90,
              colors: [['#FFFFFF', 0], [this.hueColor(), 1]]
            })
          Row()
            .width('100%')
            .height('100%')
            .linearGradient({
              angle: 180,
              colors: [['rgba(0,0,0,0)', 0], ['#000000', 1]]
            })
          Column()
            .width(this.scaledSize(18))
            .height(this.scaledSize(18))
            .borderRadius(this.scaledSize(9))
            .border({ width: 3, color: '#FFFFFF' })
            .shadow({ radius: 5, color: '#88000000' })
            .position({
              x: this.pickerSaturation * this.scaledSize(264) - this.scaledSize(9),
              y: (1 - this.pickerValue) * this.scaledSize(150) - this.scaledSize(9)
            })
        }
        .width(this.scaledSize(264))
        .height(this.scaledSize(150))
        .borderRadius(this.scaledSize(12))
        .clip(true)
        .gesture(
          PanGesture()
            .onActionStart((event: GestureEvent) => {
              if (event.fingerList.length > 0) {
                this.updateColorBoard(event.fingerList[0].localX, event.fingerList[0].localY)
              }
            })
            .onActionUpdate((event: GestureEvent) => {
              if (event.fingerList.length > 0) {
                this.updateColorBoard(event.fingerList[0].localX, event.fingerList[0].localY)
              }
            })
        )

        Text('色相')
          .fontSize(this.scaledFont(11))
          .fontColor(this.settingSubTextColor())
          .width('100%')
        Slider({
          value: this.pickerHue,
          min: 0,
          max: 360,
          step: 1,
          style: SliderStyle.OutSet
        })
          .width('100%')
          .selectedColor(this.hueColor())
          .trackColor(ColorHelper.hexToRgba(this.hueColor(), 0.2))
          .blockColor(this.hueColor())
          .blockBorderColor('#FFFFFF')
          .blockBorderWidth(2)
          .onChange((value: number) => {
            this.pickerHue = value
            this.updatePickerColor()
          })

        Row() {
          Text(this.currentPickerColor()
            .toUpperCase())
            .fontSize(this.scaledFont(12))
            .fontColor(this.settingTextColor())
            .fontWeight(FontWeight.Medium)
          Blank()
          Text('S ' + Math.round(this.pickerSaturation * 100) + '%  V ' +
            Math.round(this.pickerValue * 100) + '%')
            .fontSize(this.scaledFont(10))
            .fontColor(this.settingSubTextColor())
        }
        .width('100%')

        Row({ space: this.scaledSize(10) }) {
          Button('取消')
            .layoutWeight(1)
            .height(this.scaledSize(38))
            .fontColor(this.settingTextColor())
            .backgroundColor(ColorHelper.hexToRgba(this.primaryColor, 0.08))
            .onClick(() => {
              this.cancelColorPicker()
            })
          Button('确定')
            .layoutWeight(1)
            .height(this.scaledSize(38))
            .fontColor('#FFFFFF')
            .backgroundColor(this.currentPickerColor())
            .onClick(() => {
              this.confirmColorPicker()
            })
        }
        .width('100%')
      }
      .width(this.scaledSize(304))
      .padding(this.scaledSize(20))
      .borderRadius(this.scaledSize(22))
      .backgroundColor($r('app.color.page_background_other'))
      .border({ width: 1, color: ColorHelper.hexToRgba(this.primaryColor, 0.2) })
      .shadow({ radius: 28, color: '#66000000' })
    }
    .width('100%')
    .height('100%')
    .zIndex(50)
  }

  private updateColorBoard(localX: number, localY: number): void {
    const width: number = this.scaledSize(264)
    const height: number = this.scaledSize(150)
    this.pickerSaturation = Math.max(0, Math.min(1, localX / width))
    this.pickerValue = 1 - Math.max(0, Math.min(1, localY / height))
    this.updatePickerColor()
  }

  @Builder
  buildPlaybackSection(): void {
    Column({ space: 10 }) {
      Column() {
        this.toggleRow('淡入淡出', this.settings.fadeInOut, (val: boolean) => {
          this.settings.fadeInOut = val
          this.updateSetting()
          AppStorage.setOrCreate('uplayer_fade_in_out', val)
        })
      }
      .width('100%')
      .padding({ left: this.scaledSize(14), right: this.scaledSize(14) })
      .backgroundColor(ColorHelper.hexToRgba(this.primaryColor, 0.04))
      .borderRadius(this.scaledSize(10))

      Column() {
        this.sectionTitle('播放速度')
        Row() {
          Text(this.settings.playSpeed.toFixed(1) + 'x')
            .fontSize(this.scaledFont(12))
            .fontColor(this.settingTextColor())
        }
        .width('100%')
        .padding({ left: this.scaledSize(12), right: this.scaledSize(12), top: this.scaledSize(2) })
        Stack() {
          Slider({
            value: (this.settings.playSpeed - 0.5) * 100,
            min: 0,
            max: 250,
            step: 10,
            style: SliderStyle.OutSet
          })
            .width('100%')
            .selectedColor(this.primaryColor)
            .trackColor(ColorHelper.hexToRgba(this.primaryColor, 0.12))
            .blockColor('#FFFFFF')
            .blockSize({ width: this.scaledSize(20), height: this.scaledSize(20) })
            .blockBorderColor(this.primaryColor)
            .blockBorderWidth(3)
            .onChange((value: number, mode: SliderChangeMode) => {
              this.onSpeedChange(value, mode)
            })
        }
        .width('100%')
        .height(this.scaledSize(40))
        .padding({ left: this.scaledSize(12), right: this.scaledSize(12), bottom: this.scaledSize(8) })
      }
      .width('100%')
      .backgroundColor(ColorHelper.hexToRgba(this.primaryColor, 0.04))
      .borderRadius(this.scaledSize(10))
    }
    .width('100%')
    .constraintSize({ minWidth: 0, maxWidth: '100%' })
  }

  @Builder
  buildAudioSection(): void {
    Column({ space: 10 }) {
      Column() {
        this.toggleRow('均衡器', this.settings.eqEnabled, (val: boolean) => {
          this.settings.eqEnabled = val
          this.updateSetting()
          this.avPlayerService.applyEqualizer(val, this.settings.eqBands)
        })
      }
      .width('100%')
      .padding({ left: this.scaledSize(14), right: this.scaledSize(14) })
      .backgroundColor(ColorHelper.hexToRgba(this.primaryColor, 0.04))
      .borderRadius(this.scaledSize(10))

      if (this.settings.eqEnabled) {
        Stack({ alignContent: Alignment.Bottom }) {
          Column() {
            Row({ space: this.scaledSize(4) }) {
              ForEach(this.eqBands, (band: EqBandInfo) => {
                Column() {
                  Text((this.settings.eqBands[band.index] >= 0 ? '+' : '') + this.settings.eqBands[band.index] + 'dB')
                    .fontSize(this.scaledFont(9))
                    .fontColor(ColorHelper.hexWithAlpha(this.primaryColor, '88'))
                    .margin({ bottom: 4 })
                }
                .width(this.scaledSize(44))
                .alignItems(HorizontalAlign.Center)
              }, (band: EqBandInfo) => band.freq)
            }
            .width('100%')
            .justifyContent(FlexAlign.Center)

            Stack({ alignContent: Alignment.Start }) {
              Canvas(this.eqCurveCtx)
                .width('100%')
                .height(this.scaledSize(180))
                .hitTestBehavior(HitTestMode.None)
                .onAreaChange((_oldVal: Area, newVal: Area) => {
                  this.eqCanvasWidth = newVal.width as number
                  this.eqCanvasHeight = newVal.height as number
                  this.drawEqCurve()
                })
                .onReady(() => {
                  this.drawEqCurve()
                })

              Row({ space: this.scaledSize(4) }) {
                ForEach(this.eqBands, (band: EqBandInfo) => {
                  Column() {
                    Slider({
                      value: this.settings.eqBands[band.index] + 10,
                      min: 0,
                      max: 20,
                      step: 1,
                      style: SliderStyle.OutSet,
                      direction: Axis.Vertical,
                      reverse: true
                    })
                      .width(this.scaledSize(40))
                      .height(this.scaledSize(180))
                      .selectedColor(this.primaryColor)
                      .trackColor(ColorHelper.hexToRgba(this.primaryColor, 0.16))
                      .blockColor('#FFFFFF')
                      .blockSize({ width: this.scaledSize(26), height: this.scaledSize(14) })
                      .blockBorderColor(this.primaryColor)
                      .blockBorderWidth(2)
                      .onChange((value: number, mode: SliderChangeMode) => {
                        this.onEqBandChange(band.index, value, mode)
                      })
                  }
                  .width(this.scaledSize(44))
                  .alignItems(HorizontalAlign.Center)
                }, (band: EqBandInfo) => band.freq)
              }
              .width('100%')
              .justifyContent(FlexAlign.Center)
            }
            .height(this.scaledSize(180))

            Row({ space: this.scaledSize(4) }) {
              ForEach(this.eqBands, (band: EqBandInfo) => {
                Column() {
                  Text(band.freq)
                    .fontSize(this.scaledFont(10))
                    .fontColor(this.settingSubTextColor())
                    .fontWeight(FontWeight.Medium)
                    .margin({ top: 6 })
                }
                .width(this.scaledSize(44))
                .alignItems(HorizontalAlign.Center)
              }, (band: EqBandInfo) => band.freq)
            }
            .width('100%')
            .justifyContent(FlexAlign.Center)
          }
          .padding({ left: 8, right: 8, top: 12, bottom: 12 })
        }
        .width('100%')
        .height(this.scaledSize(230))
        .backgroundColor(ColorHelper.hexToRgba(this.primaryColor, 0.04))
        .borderRadius(this.scaledSize(10))
      }
    }
    .width('100%')
    .constraintSize({ minWidth: 0, maxWidth: '100%' })
  }

  private drawEqCurve(): void {
    const ctx: CanvasRenderingContext2D = this.eqCurveCtx
    if (!ctx) {
      return
    }
    // 优先使用 onAreaChange 提供的 vp 尺寸，后备使用 ctx.width/ctx.height（物理像素，除以 2 估算 vp）
    const dpr: number = 2
    const canvasW: number = this.eqCanvasWidth > 0 ? this.eqCanvasWidth : ctx.width / dpr
    const canvasH: number = this.eqCanvasHeight > 0 ? this.eqCanvasHeight : ctx.height / dpr
    if (canvasW <= 0 || canvasH <= 0) {
      return
    }
    const bands: number[] = this.settings.eqBands
    const color: string = this.primaryColor
    ctx.clearRect(0, 0, ctx.width, ctx.height)
    // Canvas 与滑轨 Row 同处内层 Stack：
    // Canvas 从 x=0 到 x=canvasW 填充整个 Stack
    // 滑轨 Row 使用 width('100%') + justifyContent(Center)，内容在 Stack 中居中
    // bandW 为每个频段 Column 的宽度，Slider(40) 在 Column(44) 中居中
    const bandW: number = this.scaledSize(44)
    const bandGap: number = this.scaledSize(4)
    const sliderH: number = canvasH
    const sliderMidY: number = sliderH / 2
    const bandCount: number = bands.length
    // Row 内容总宽度 = 所有 Column 宽度 + 间距总和
    const totalRowWidth: number = bandCount * bandW + (bandCount - 1) * bandGap
    // Row 内容在 Stack 中居中，起始 x 偏移
    const rowOffset: number = Math.max(0, (canvasW - totalRowWidth) / 2)
    // 每个频段滑块的中心 x 坐标
    const bandXs: number[] = []
    for (let i = 0; i < bandCount; i++) {
      bandXs.push(rowOffset + i * (bandW + bandGap) + bandW / 2)
    }
    // 构建数据点：左端点(0 db) + 10 个频段 + 右端点(0 db)
    const points: number[] = []
    points.push(0)
    for (let i = 0; i < bandCount; i++) {
      points.push(bands[i])
    }
    points.push(0)
    // 对应的 x 坐标：左端点在第一个滑块左侧，右端点在最后一个滑块右侧
    const xs: number[] = []
    xs.push(bandXs[0] - bandW / 2)
    for (let i = 0; i < bandCount; i++) {
      xs.push(bandXs[i])
    }
    xs.push(bandXs[bandCount - 1] + bandW / 2)
    const total: number = points.length
    // db → y：+10dB → 0(顶)，-10dB → sliderH(底)，0dB → sliderMidY
    const ys: number[] = []
    for (let i = 0; i < total; i++) {
      ys.push(sliderMidY - (points[i] / 10) * (sliderH / 2))
    }
    // 逐段独立平滑曲线（分段三次 Hermite，两端切线斜率恒为 0）：
    // 每两个相邻点之间单独生成一条平滑曲线，且在点的两侧斜率均为 0，
    // 保证曲线精确穿过每个数据点，且不会因相邻点差异产生过冲。
    // 控制点取水平方向 1/3 处，即 CP1=(x0+dx/3, y0)、CP2=(x1-dx/3, y1)
    ctx.beginPath()
    ctx.moveTo(xs[0], ys[0])
    for (let i = 0; i < total - 1; i++) {
      const p0x: number = xs[i]
      const p0y: number = ys[i]
      const p1x: number = xs[i + 1]
      const p1y: number = ys[i + 1]
      const dx: number = p1x - p0x
      const cp1x: number = p0x + dx / 3
      const cp1y: number = p0y
      const cp2x: number = p1x - dx / 3
      const cp2y: number = p1y
      ctx.bezierCurveTo(cp1x, cp1y, cp2x, cp2y, p1x, p1y)
    }
    ctx.strokeStyle = color
    ctx.lineWidth = 2
    ctx.lineJoin = 'round'
    ctx.lineCap = 'round'
    ctx.stroke()
    // 曲线下方半透明填充
    ctx.lineTo(xs[total - 1], sliderH)
    ctx.lineTo(xs[0], sliderH)
    ctx.closePath()
    ctx.fillStyle = ColorHelper.hexToRgba(color, 0.1)
    ctx.fill()
  }

  // ═══ 关于页面：居中的软件图标 + 软件名/版本 + 仓库地址 + 联系方式，点击复制 ═══
  // 仓库地址由 SSH 地址 git@github.com:morozov130300/UPlayer-on-HarmonyOS.git 转出的 HTTPS 网址
  private aboutRepoUrl: string = 'https://github.com/morozov130300/UPlayer-on-HarmonyOS'
  private aboutEmail: string = 'jhy130300@126.com'
  private aboutQq: string = '3500873394'
  private aboutVersionName: string = '0.0.1'

  private copyToClipboard(label: string, content: string): void {
    try {
      const pasteData: pasteboard.PasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, content)
      const systemPasteboard: pasteboard.SystemPasteboard = pasteboard.getSystemPasteboard()
      systemPasteboard.setDataSync(pasteData)
      this.getUIContext()?.getPromptAction().showToast({ message: label + '已复制' })
    } catch (e) {
      Logger.error(TAG, 'copyToClipboard failed: ' + JSON.stringify(e))
    }
  }

  @Builder
  aboutInfoRow(label: string, value: string): void {
    Row() {
      Text(label)
        .fontSize(this.scaledFont(13))
        .fontColor(this.settingTextColor())
        .width(this.scaledSize(56))
        .textAlign(TextAlign.Start)
      Text(value)
        .fontSize(this.scaledFont(13))
        .fontColor(this.settingTextColor())
        .layoutWeight(1)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .constraintSize({ minWidth: 0, maxWidth: '100%' })
    .height(this.scaledSize(40))
    .alignItems(VerticalAlign.Center)
    .padding({ left: this.scaledSize(14), right: this.scaledSize(14) })
    .backgroundColor(ColorHelper.hexToRgba(this.primaryColor, 0.04))
    .borderRadius(this.scaledSize(10))
    .onClick(() => {
      this.copyToClipboard(label, value)
    })
  }

  @Builder
  buildAboutSection(): void {
    Column({ space: this.scaledSize(10) }) {
      // 居中的软件图标 + 软件名 + 版本号
      Column({ space: this.scaledSize(8) }) {
        Image($r('app.media.foreground'))
          .width(this.scaledSize(72))
          .height(this.scaledSize(72))
          .borderRadius(this.scaledSize(20))
        Text('UPlayer')
          .fontSize(this.scaledFont(18))
          .fontColor(this.settingTextColor())
          .fontWeight(FontWeight.Bold)
        Text('v' + this.aboutVersionName)
          .fontSize(this.scaledFont(12))
          .fontColor(this.settingTextColor())
      }
      .width('100%')
      .alignItems(HorizontalAlign.Center)
      .padding({ top: this.scaledSize(24), bottom: this.scaledSize(8) })

      Column({ space: this.scaledSize(6) }) {
        Text('仓库地址')
          .fontSize(this.scaledFont(13))
          .fontColor(this.settingTextColor())
          .fontWeight(FontWeight.Bold)
          .width('100%')
          .padding({ left: this.scaledSize(4) })
        this.aboutInfoRow('仓库', this.aboutRepoUrl)
      }
      .width('100%')

      Column({ space: this.scaledSize(6) }) {
        Text('联系方式')
          .fontSize(this.scaledFont(13))
          .fontColor(this.settingTextColor())
          .fontWeight(FontWeight.Bold)
          .width('100%')
          .padding({ left: this.scaledSize(4) })
        this.aboutInfoRow('邮箱', this.aboutEmail)
        this.aboutInfoRow('QQ', this.aboutQq)
      }
      .width('100%')

      Text('本地音乐播放器 · 为鸿蒙打造')
        .fontSize(this.scaledFont(11))
        .fontColor(this.settingTextColor())
        .width('100%')
        .textAlign(TextAlign.Center)
        .margin({ top: this.scaledSize(8) })
    }
    .width('100%')
    .constraintSize({ minWidth: 0, maxWidth: '100%' })
  }

  @Builder
  toggleRow(toggleLabel: string, isChecked: boolean, onToggleChange: (val: boolean) => void): void {
    Row() {
      Text(toggleLabel)
        .fontSize(this.scaledFont(14))
        .fontColor(this.settingTextColor())
        .maxLines(1)
      Blank()
      Toggle({ type: ToggleType.Switch, isOn: isChecked })
        .selectedColor(this.primaryColor)
        .onChange((isOn: boolean) => {
          onToggleChange(isOn)
        })
    }
    .width('100%')
    .height(this.scaledSize(44))
    .alignItems(VerticalAlign.Center)
  }
}
