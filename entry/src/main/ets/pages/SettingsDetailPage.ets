import { curves, uiAppearance, TransitionEffect, TransitionEdge } from '@kit.ArkUI'
import { common, ConfigurationConstant } from '@kit.AbilityKit'
import { DataService, AppSettingsData } from '../service/DataService'
import { AVPlayerService } from '../service/AVPlayerService'
import { AppStorageKeyConstants } from '../common/constants/AppStorageKeyConstants'
import { ColorHelper } from '../common/utils/ColorHelper'
import Logger from '../common/utils/Logger'
import { deviceInfo } from '@kit.BasicServicesKit'
import { motion } from '@kit.MultimodalAwarenessKit'
import { ColorConversion } from '../common/utils/ColorConversion'
import {
  createPageGlassMaterial,
  isLiquidGlassAvailable
} from '../common/utils/GlassUtil'
import { StyleConstants } from '../common/constants/StyleConstants'

const TAG = 'SettingsDetailPage'
const KEY_PRIMARY_COLOR = 'uplayer_primary_color'

class EqBandInfo {
  freq: string = ''
  index: number = 0
}

class ThemeColorOption {
  name: string = ''
  value: string = ''
}

interface ThemeOption {
  label: string
  value: string
}

interface TabStyleOption {
  label: string
  value: string
}

@Entry
@Component
struct SettingsDetailPage {
  private context: common.UIAbilityContext
    | undefined = AppStorage.get<common.UIAbilityContext>(AppStorageKeyConstants.KEY_UI_ABILITY_CONTEXT)
  @State settings: AppSettingsData = new AppSettingsData()
  @StorageLink(KEY_PRIMARY_COLOR) primaryColor: string = '#007DFF'
  @StorageLink(AppStorageKeyConstants.KEY_TITLE_BUTTON_WIDTH) titleButtonWidth: number = 0
  @StorageLink(AppStorageKeyConstants.KEY_TITLE_BUTTON_HEIGHT) titleButtonHeight: number = 0
  @StorageLink(AppStorageKeyConstants.KEY_TOP_HEIGHT) topSafeHeight: number = 0
  @StorageLink('uplayer_display_size_scale') displaySizeScale: number = 1.0
  @StorageLink('uplayer_font_size_scale') fontSizeScale: number = 1.0
  @StorageLink('uplayer_glass_blur_strength') glassBlurStrength: number = 25
  @StorageLink('uplayer_home_top_blur_strength') homeTopBlurStrength: number = 25
  @StorageLink('uplayer_tab_indicator_opacity') tabIndicatorOpacity: number = 50
  @StorageLink('uplayer_glass_saturation') glassSaturation: number = 1.4
  @StorageLink('uplayer_glass_brightness') glassBrightness: number = 1.02
  @StorageLink('uplayer_glass_style') glassStyle: number = 50
  @StorageLink('uplayer_light_color_mode') lightColorMode: string = 'theme'
  @StorageLink('uplayer_tab_touch_indicator') tabTouchIndicator: string = 'light'
  @StorageLink('uplayer_holding_hand_layout_animation') holdingHandLayoutAnimation: boolean = true
  @State pageTitle: string = ''
  @State previewOnRight: boolean = false
  @State showColorPicker: boolean = false
  @State showGlassScope: boolean = false
  // 经典 / 玻璃切换的淡入淡出：0=完全隐藏，1=完全显示
  @State classicGroupOpacity: number = 1
  @State glassGroupOpacity: number = 0
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
  // 智感握姿：开关 + 置信度滤波（连续 N 帧同向才翻转，避免短暂切换造成的"跳变"）
  @StorageLink('uplayer_holding_hand_enabled') @Watch('onHoldingHandEnabledChange') holdingHandEnabled: boolean = true
  private holdLastStatus: motion.HoldingHandStatus | undefined = undefined
  private holdStreakCount: number = 0
  // 要求连续 HOLD_STREAK_REQUIRED 次同向事件才允许翻转（经验值：原值 1 太敏感，3 较稳）
  private static readonly HOLD_STREAK_REQUIRED: number = 3
  private holdingHandCallback: (status: motion.HoldingHandStatus) => void =
    (status: motion.HoldingHandStatus): void => {
      // 置信度滤波：连续 N 次同向才允许翻转，避免传感器抖动引起频繁切边
      if (status === this.holdLastStatus) {
        this.holdStreakCount = this.holdStreakCount + 1
      } else {
        this.holdLastStatus = status
        this.holdStreakCount = 1
      }
      if (this.holdStreakCount < SettingsDetailPage.HOLD_STREAK_REQUIRED) {
        return
      }
      const targetOnRight: boolean = status === motion.HoldingHandStatus.LEFT_HAND_HELD
      if (this.previewOnRight !== targetOnRight) {
        this.previewOnRight = targetOnRight
      }
    }
  private themeOptions: ThemeOption[] = [
    { label: '跟随系统', value: 'system' },
    { label: '深色模式', value: 'dark' },
    { label: '浅色模式', value: 'light' }
  ]
  private tabStyleOptions: TabStyleOption[] = [
    { label: '经典', value: 'classic' },
    { label: '玻璃', value: 'immersive' }
  ]
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
    'audio': '音效'
  }

  aboutToAppear(): void {
    this.settings = this.dataService.getSettings()
    const params = this.getUIContext()?.getRouter()
      .getParams() as Record<string, string>
    const route: string = params?.category ?? 'customize'
    this.pageTitle = this.titleMap[route] ?? '设置'
    ColorConversion.setSysBarLightBackground(this.isDark())
    // 切到"定制"页时按当前底部栏样式设置组可见度的初值（避免首次进入看到两边都/都不显示）
    this.syncTabStyleGroups(this.settings.tabStyle, false)
    this.registerHoldingHandListener()
  }

  private syncTabStyleGroups(style: string, animate: boolean): void {
    if (!animate) {
      this.classicGroupOpacity = style === 'classic' ? 1 : 0
      this.glassGroupOpacity = style === 'immersive' ? 1 : 0
      return
    }
    const targetClassic: number = style === 'classic' ? 1 : 0
    const targetGlass: number = style === 'immersive' ? 1 : 0
    this.getUIContext()?.animateTo({ duration: 280, curve: Curve.EaseInOut }, () => {
      this.classicGroupOpacity = targetClassic
      this.glassGroupOpacity = targetGlass
    })
  }

  aboutToDisappear(): void {
    if (this.showColorPicker) {
      this.previewPrimaryColor(this.pickerOriginalColor)
      this.showColorPicker = false
    }
    this.unregisterHoldingHandListener()
  }

  private registerHoldingHandListener(): void {
    this.previewOnRight = false
    this.holdLastStatus = undefined
    this.holdStreakCount = 0
    // 开关关闭、PC、能力不足时一律不订阅
    if (!this.holdingHandEnabled || this.isPC || !canIUse('SystemCapability.MultimodalAwareness.Motion')) {
      return
    }
    try {
      motion.on('holdingHandChanged', this.holdingHandCallback)
    } catch (err) {
      Logger.warn(TAG, `holdingHandChanged register failed: ${JSON.stringify(err)}`)
    }
  }

  private unregisterHoldingHandListener(): void {
    if (this.isPC || !canIUse('SystemCapability.MultimodalAwareness.Motion')) {
      return
    }
    try {
      motion.off('holdingHandChanged', this.holdingHandCallback)
    } catch (err) {
      Logger.warn(TAG, `holdingHandChanged unregister failed: ${JSON.stringify(err)}`)
    }
    this.holdLastStatus = undefined
    this.holdStreakCount = 0
  }

  // 用户在设置页切换开关时调用：开→注册监听并重置 streak；关→注销并复位 previewOnRight
  private refreshHoldingHandListener(): void {
    this.unregisterHoldingHandListener()
    this.registerHoldingHandListener()
  }

  // @Watch 回调：握姿开关被用户切换时重新绑定监听；只有当前在 customize 页时回调才生效（避免页面间冲突）
  onHoldingHandEnabledChange(): void {
    if (this.pageTitle !== '定制') {
      return
    }
    this.refreshHoldingHandListener()
  }

  private glassBlurRadius(): number {
    return this.glassBlurStrength * 0.5
  }

  private homeTopBlurRadius(): number {
    return this.homeTopBlurStrength *
      (1.6 - this.homeTopBlurStrength * 0.004)
  }

  // 统一预览方块规范：64×40 圆角方块，红→黄→绿→蓝渐变底 + 文字标签 + 1px 边框，
  // 与设置页其他预览器（玻璃档位/饱和度/亮度/智感握姿）共用同尺寸同风格。
  // 不同的是内部叠层：
  //   - homeTopBlurPreview：渐变模糊 (linearGradientBlur) 强度随首页上端模糊强度变化
  //   - glassStylePreview：模糊半径 + 液态玻璃材质叠加
  //   - glassSaturationPreview：饱和度变化
  //   - glassBrightnessPreview：亮度变化
  //   - holdingHandPreview：左右切手示意
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
        .linearGradientBlur(this.homeTopBlurRadius(), {
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

  @Builder
  glassBlurPreview(): void {
    Stack({ alignContent: Alignment.Center }) {
      Text('沉浸光感')
        .fontSize(this.scaledFont(12))
        .fontWeight(FontWeight.Bold)
        .fontColor(this.primaryColor)
        .letterSpacing(this.scaledSize(1))
      Row()
        .width('100%')
        .height('100%')
        .borderRadius(this.scaledSize(18))
        .backgroundColor(Color.Transparent)
        .backgroundEffect({
          radius: this.glassBlurRadius(),
          saturation: this.glassSaturation,
          brightness: this.glassBrightness
        })
        .border({ width: 1, color: 'rgba(255,255,255,0.28)' })
        .shadow({ radius: 12, color: ColorHelper.hexWithAlpha(this.primaryColor, '44') })
    }
    .width(this.scaledSize(82))
    .height(this.scaledSize(36))
    .borderRadius(this.scaledSize(18))
    .clip(true)
  }

  @Builder
  tabIndicatorPreview(): void {
    Row()
      .width(this.scaledSize(82))
      .height(this.scaledSize(36))
      .borderRadius(this.scaledSize(18))
      .shadow({
        radius: 14,
        color: ColorHelper.hexWithAlpha(this.primaryColor, this.indicatorAlpha(0.8)
          .toString(16)
          .padStart(2, '0'))
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
    if (this.settings.themeMode === 'dark') {
      return true
    }
    if (this.settings.themeMode === 'system') {
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
    // 触发经典/玻璃卡片组的淡入淡出
    this.syncTabStyleGroups(style, true)
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

  private previewPrimaryColor(color: string): void {
    this.settings.primaryColor = color
    this.primaryColor = color
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
    this.previewPrimaryColor(this.currentPickerColor())
  }

  private cancelColorPicker(): void {
    this.previewPrimaryColor(this.pickerOriginalColor)
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

  // "高级样式"三档（厚度/饱和度/亮度）共用一个预览方块，根据当前聚焦项在内部切换标签
  // 修复了原先 0-15 无反应 / 16 突变的阈值问题：backgroundEffect 始终启用，radius 线性映射，
  // 使滑轨从 0 到 100 的每一档都有渐变；预览与系统实际渲染比例一致。
  @Builder
  glassAdvancedPreview(focusLabel: string): void {
    Stack({ alignContent: Alignment.Center }) {
      Text(focusLabel)
        .fontSize(this.scaledFont(12))
        .fontWeight(FontWeight.Bold)
        .fontColor(this.primaryColor)
        .letterSpacing(this.scaledSize(1))
      Row()
        .width('100%')
        .height('100%')
        .borderRadius(this.scaledSize(18))
        .backgroundColor(Color.Transparent)
        .backgroundEffect({
          radius: this.settings.glassStyle * 0.5,
          saturation: this.settings.glassSaturation,
          brightness: this.settings.glassBrightness
        })
        .systemMaterial(this.settings.glassStyle > 30 && isLiquidGlassAvailable()
          ? createPageGlassMaterial(this.settings.glassStyle) : undefined)
        .border({ width: 1, color: 'rgba(255,255,255,0.28)' })
        .shadow({ radius: 12, color: ColorHelper.hexWithAlpha(this.primaryColor, '44') })
    }
    .width(this.scaledSize(82))
    .height(this.scaledSize(36))
    .borderRadius(this.scaledSize(18))
    .clip(true)
  }

    build() {
    Stack() {
      Column() {
        Row() {
          Row() {
            SymbolGlyph($r('sys.symbol.chevron_left'))
              .fontSize(this.scaledFont(32))
              .fontColor([this.settingTextColor()])
              .opacity(0.9)
          }
          .width(this.scaledSize(48))
          .height(this.scaledSize(48))
          .justifyContent(FlexAlign.Center)
          .borderRadius(this.scaledSize(24))
          .hoverEffect(HoverEffect.Scale)
          .onClick(() => {
            this.getUIContext()?.getRouter()
              .back()
          })

          Text(this.pageTitle)
            .fontSize(this.scaledFont(17))
            .fontColor(this.settingTextColor())
            .fontWeight(FontWeight.Bold)
            .margin({ left: 4 })
        }
        .width('100%')
        .height(Math.max(56, this.titleButtonHeight) + (this.isPC ? 0 : this.topSafeHeight))
        .padding({
          left: 4,
          right: this.titleButtonWidth + 12,
          top: this.isPC ? 0 : this.topSafeHeight
        })
        .alignItems(VerticalAlign.Center)

        Stack({ alignContent: Alignment.Center }) {
          Column() {
            Scroll() {
              Column({ space: 10 }) {
                if (this.pageTitle === '定制') {
                  this.buildCustomizeSection()
                } else if (this.pageTitle === '播放') {
                  this.buildPlaybackSection()
                } else if (this.pageTitle === '音效') {
                  this.buildAudioSection()
                }
              }
              .width('100%')
              .padding({
                left: this.scaledSize(12), right: this.scaledSize(12),
                top: this.scaledSize(16), bottom: this.scaledSize(40)
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
          if (this.showGlassScope) {
            this.glassScopeOverlay()
          }
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
  }

  @Builder
  sectionTitle(title: string): void {
    Text(title)
      .fontSize(this.scaledFont(13))
      .fontColor(this.isDark() ? ColorHelper.hexWithAlpha('#FFFFFF', '99') : ColorHelper.hexWithAlpha(this.primaryColor,
        '99'))
      .fontWeight(FontWeight.Medium)
      .width('100%')
      .padding({ left: this.scaledSize(4), top: this.scaledSize(6), bottom: this.scaledSize(2) })
  }

  // 一级标题（用于把同类设置项聚合在一起，可选带右上角「叹号」角标以引出说明弹窗）
  @Builder
  groupTitle(title: string, hasHelpIcon: boolean): void {
    Row() {
      Text(title)
        .fontSize(this.scaledFont(11))
        .fontColor(this.isDark() ? ColorHelper.hexWithAlpha('#FFFFFF', '66')
          : ColorHelper.hexWithAlpha(this.primaryColor, '77'))
        .fontWeight(FontWeight.Bold)
        .letterSpacing(this.scaledSize(2))
      Blank()
      if (hasHelpIcon) {
        Stack({ alignContent: Alignment.Center }) {
          Circle()
            .width(this.scaledSize(18))
            .height(this.scaledSize(18))
            .fill(ColorHelper.hexToRgba(this.primaryColor, 0.12))
          SymbolGlyph($r('sys.symbol.questionmark_circle'))
            .fontSize(this.scaledFont(13))
            .fontColor([this.primaryColor])
        }
        .width(this.scaledSize(18))
        .height(this.scaledSize(18))
        .onClick(() => {
          this.showGlassScope = true
        })
      }
    }
    .width('100%')
    .padding({ left: this.scaledSize(8), top: this.scaledSize(14), bottom: this.scaledSize(4) })
    .alignItems(VerticalAlign.Center)
  }

  // 二级标题（卡片组的子标题，紧贴在卡片上方）
  @Builder
  subTitle(title: string): void {
    Text(title)
      .fontSize(this.scaledFont(13))
      .fontColor(this.isDark() ? ColorHelper.hexWithAlpha('#FFFFFF', '99') : ColorHelper.hexWithAlpha(this.primaryColor,
        '99'))
      .fontWeight(FontWeight.Medium)
      .width('100%')
      .padding({ left: this.scaledSize(4), bottom: this.scaledSize(4) })
  }

  // 玻璃效果生效范围说明弹窗
  @Builder
  glassScopeOverlay(): void {
    Stack({ alignContent: Alignment.Center }) {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor('rgba(0,0,0,0.55)')
        .onClick(() => {
          this.showGlassScope = false
        })

      Column({ space: this.scaledSize(10) }) {
        Row() {
          Text('玻璃效果生效范围')
            .fontSize(this.scaledFont(16))
            .fontColor(this.settingTextColor())
            .fontWeight(FontWeight.Bold)
          Blank()
          SymbolGlyph($r('sys.symbol.xmark'))
            .fontSize(this.scaledFont(20))
            .fontColor([this.settingTextColor()])
            .onClick(() => {
              this.showGlassScope = false
            })
        }
        .width('100%')

        Text('以下位置会使用玻璃效果：')
          .fontSize(this.scaledFont(12))
          .fontColor(this.settingSubTextColor())
          .width('100%')
          .padding({ top: this.scaledSize(2) })
        this.scopeLine('• 底部 Tab 栏（沉浸式玻璃，带光效跟手 + 按压 Q 弹形变）')
        this.scopeLine('• 右下角播控条')
        this.scopeLine('• 顶部的模糊层（首页顶部标题区，覆盖首页第一屏）')
        this.scopeLine('• 首页 / 歌单 / 设置 / 设置详情 四个一级页面的顶层背景（仅档位与材质在此生效）')

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
            .height(this.scaledSize(38))
            .fontColor('#FFFFFF')
            .backgroundColor(this.primaryColor)
            .borderRadius(this.scaledSize(10))
            .onClick(() => {
              this.showGlassScope = false
            })
        }
        .width('100%')
        .padding({ top: this.scaledSize(8) })
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
    .zIndex(60)
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
    Column({ space: 10 }) {
      Column() {
        this.toggleRow('向下滑动时隐藏加号按钮', this.settings.plusButtonScrollHide, (val: boolean) => {
          this.settings.plusButtonScrollHide = val
          this.updateSetting()
        })
      }
      .width('100%')
      .backgroundColor(ColorHelper.hexToRgba(this.primaryColor, 0.04))
      .borderRadius(10)

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
      .borderRadius(10)

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
      .borderRadius(10)

      // ─── 一级标题「高级样式」（玻璃模式下显示） + 右上角叹号角标 ───
      // 点击叹号弹窗说明玻璃效果所影响的所有位置
      Column() {
        this.groupTitle('高级样式', true)
        // 三个滑块共享同一预览器（焦点标签由当前激活滑轨决定）
        Column({ space: this.scaledSize(6) }) {
          this.subTitle('玻璃厚度')
          Text('控制玻璃材质的模糊强度：值越大越模糊。调节时预览方块会实时反映效果。')
            .fontSize(this.scaledFont(12))
            .fontColor(this.settingSubTextColor())
            .width('100%')
          Row({ space: this.scaledSize(12) }) {
            Slider({
              value: this.settings.glassStyle,
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
                this.settings.glassStyle = value
                this.glassStyle = value
                if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) {
                  this.updateSetting()
                }
              })
            this.glassAdvancedPreview('玻璃厚度')
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
        .backgroundColor(this.isDark() ? ColorHelper.hexToRgba('#FFFFFF', 0.06) : ColorHelper.hexToRgba(this.primaryColor,
          0.04))
        .borderRadius(this.scaledSize(10))

        // 玻璃饱和度 / 亮度 共用同一预览器，预览标题根据最近一次滑动切换
        Column({ space: this.scaledSize(6) }) {
          this.subTitle('玻璃饱和度')
          Text('控制玻璃背后透出的颜色鲜艳程度。值越高越鲜艳。')
            .fontSize(this.scaledFont(12))
            .fontColor(this.settingSubTextColor())
            .width('100%')
          Row({ space: this.scaledSize(12) }) {
            Text('淡')
              .fontSize(this.scaledFont(11))
              .fontColor(this.settingTextColor())
            Slider({
              value: this.settings.glassSaturation * 100,
              min: 100,
              max: 200,
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
                this.settings.glassSaturation = value / 100
                this.glassSaturation = this.settings.glassSaturation
                if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) {
                  this.updateSetting()
                }
              })
            this.glassAdvancedPreview('玻璃饱和')
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)
          .padding({ top: this.scaledSize(2), bottom: this.scaledSize(2) })

          this.subTitle('玻璃亮度')
          Text('控制玻璃模糊层的明暗调整。值越高越亮。')
            .fontSize(this.scaledFont(12))
            .fontColor(this.settingSubTextColor())
            .width('100%')
          Row({ space: this.scaledSize(12) }) {
            Text('暗')
              .fontSize(this.scaledFont(11))
              .fontColor(this.settingTextColor())
            Slider({
              value: this.settings.glassBrightness * 100,
              min: 80,
              max: 130,
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
                this.settings.glassBrightness = value / 100
                this.glassBrightness = this.settings.glassBrightness
                if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) {
                  this.updateSetting()
                }
              })
            this.glassAdvancedPreview('玻璃亮度')
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
        .backgroundColor(this.isDark() ? ColorHelper.hexToRgba('#FFFFFF', 0.06) : ColorHelper.hexToRgba(this.primaryColor,
          0.04))
        .borderRadius(this.scaledSize(10))

        // 玻璃效果生效范围：已通过一级标题右上角的小叹号引出弹窗说明
      }
      .width('100%')
      .opacity(this.glassGroupOpacity)
      .animation({ duration: 280, curve: Curve.EaseInOut })
      .visibility(this.settings.tabStyle === 'immersive' ? Visibility.Visible : Visibility.None)
      // 去掉玻璃卡片之间默认的 10vp 间隔间距，由内部 padding 自己控制
      // ——已通过 groupTitle 与 .padding 处理

      // 智感握姿：只涉及组件位置，不涉及样式，所以右侧放开关 + 关闭预览方块
      Column({ space: this.scaledSize(6) }) {
        Row() {
          Column({ space: this.scaledSize(2) }) {
            Text('智感握姿')
              .fontSize(this.scaledFont(17))
              .fontWeight(FontWeight.Bold)
              .fontColor(this.settingTextColor())
            Text('根据单手握持方向自动调整首页顶部预览与控件靠左/靠右。')
              .fontSize(this.scaledFont(12))
              .fontColor(this.settingSubTextColor())
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)
          Toggle({ type: ToggleType.Switch, isOn: this.settings.holdingHandEnabled })
            .selectedColor(this.primaryColor)
            .onChange((isOn: boolean) => {
              this.settings.holdingHandEnabled = isOn
              this.holdingHandEnabled = isOn
              this.updateSetting()
              this.refreshHoldingHandListener()
            })
            .flexShrink(0)
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
        .padding({ top: this.scaledSize(4), bottom: this.scaledSize(4) })
        // 左右切换动画开启开关（仅放在感应开之后可选）
        Row() {
          Text('左右切换动画')
            .fontSize(this.scaledFont(14))
            .fontColor(this.settingTextColor())
          Blank()
          Toggle({ type: ToggleType.Switch, isOn: this.settings.holdingHandLayoutAnimation })
            .selectedColor(this.primaryColor)
            .onChange((isOn: boolean) => {
              this.settings.holdingHandLayoutAnimation = isOn
              AppStorage.setOrCreate('uplayer_holding_hand_layout_animation', isOn)
              this.updateSetting()
            })
        }
        .width('100%')
        .height(this.scaledSize(40))
        .padding({ left: this.scaledSize(2), right: this.scaledSize(2), top: this.scaledSize(2) })
        .alignItems(VerticalAlign.Center)
      }
      .width('100%')
      .padding({
        top: this.scaledSize(12),
        left: this.scaledSize(14),
        right: this.scaledSize(14),
        bottom: this.scaledSize(12)
      })
      .backgroundColor(this.isDark() ? ColorHelper.hexToRgba('#FFFFFF', 0.06) : ColorHelper.hexToRgba(this.primaryColor,
        0.04))
      .borderRadius(this.scaledSize(10))

      // ─── 一级标题「经典模糊」（经典模式下显示）───
      Column() {
        this.groupTitle('经典模糊', false)

        // 跟手光效颜色（仅经典模式展示，原先属于玻璃模式下的设计调色）
        Column() {
          Row() {
            this.subTitle('跟手光效颜色')
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
            .margin({ right: this.scaledSize(8) })
            .onClick(() => {
              this.settings.lightColorMode = 'white'
              this.updateSetting()
              AppStorage.setOrCreate('uplayer_light_color_mode', 'white')
            })
            Column() {
              Text('主题色')
                .fontSize(this.scaledFont(11))
                .fontColor(this.settings.lightColorMode === 'theme'
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
            .onClick(() => {
              this.settings.lightColorMode = 'theme'
              this.updateSetting()
              AppStorage.setOrCreate('uplayer_light_color_mode', 'theme')
            })
          }
          .width('100%')
          .padding({ left: this.scaledSize(2), right: this.scaledSize(2), top: this.scaledSize(2), bottom: this.scaledSize(6) })
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

        // 底部栏触摸反馈指示（经典模式下也可生效）：跟手光效 / 白色蒙版
        Column() {
          Row() {
            this.subTitle('底部栏触摸指示')
            Blank()
            Column() {
              Text('跟手光效')
                .fontSize(this.scaledFont(11))
                .fontColor(this.settings.tabTouchIndicator === 'light'
                  ? '#FFFFFF' : this.settingInactiveTextColor())
            }
            .padding({
              left: this.scaledSize(10),
              right: this.scaledSize(10),
              top: this.scaledSize(5),
              bottom: this.scaledSize(5)
            })
            .backgroundColor(this.settings.tabTouchIndicator === 'light'
              ? this.primaryColor : ColorHelper.hexToRgba(this.primaryColor, 0.08))
            .borderRadius(this.scaledSize(14))
            .margin({ right: this.scaledSize(8) })
            .onClick(() => {
              this.settings.tabTouchIndicator = 'light'
              this.updateSetting()
              AppStorage.setOrCreate('uplayer_tab_touch_indicator', 'light')
            })
            Column() {
              Text('白色蒙版')
                .fontSize(this.scaledFont(11))
                .fontColor(this.settings.tabTouchIndicator === 'mask'
                  ? '#FFFFFF' : this.settingInactiveTextColor())
            }
            .padding({
              left: this.scaledSize(10),
              right: this.scaledSize(10),
              top: this.scaledSize(5),
              bottom: this.scaledSize(5)
            })
            .backgroundColor(this.settings.tabTouchIndicator === 'mask'
              ? this.primaryColor : ColorHelper.hexToRgba(this.primaryColor, 0.08))
            .borderRadius(this.scaledSize(14))
            .onClick(() => {
              this.settings.tabTouchIndicator = 'mask'
              this.updateSetting()
              AppStorage.setOrCreate('uplayer_tab_touch_indicator', 'mask')
            })
          }
          .width('100%')
          .padding({ left: this.scaledSize(2), right: this.scaledSize(2), top: this.scaledSize(2), bottom: this.scaledSize(6) })
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

        // 首页上端模糊强度
        Column({ space: this.scaledSize(6) }) {
          this.subTitle('首页上端模糊强度')
          Text('控制首页顶部标题区玻璃模糊的渐变强度。')
            .fontSize(this.scaledFont(12))
            .fontColor(this.settingSubTextColor())
            .width('100%')
          Row({ space: this.scaledSize(12) }) {
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
            this.homeTopBlurPreview()
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

        Column() {
          this.subTitle('Tab栏与播控条模糊强度')
          Row() {
            if (!this.previewOnRight) {
              this.glassBlurPreview()
                .transition(TransitionEffect.asymmetric(
                  TransitionEffect.OPACITY.combine(TransitionEffect.move(TransitionEdge.START))
                    .animation({ duration: 320, curve: Curve.EaseInOut }),
                  TransitionEffect.OPACITY.combine(TransitionEffect.move(TransitionEdge.START))
                    .animation({ duration: 320, curve: Curve.EaseInOut })
                ))
            }
            Text('弱')
              .fontSize(this.scaledFont(11))
              .fontColor(this.settingTextColor())
              .margin({
                left: this.previewOnRight ? 0 : this.scaledSize(14),
                right: this.scaledSize(8)
              })
            Slider({
              value: this.settings.glassBlurStrength,
              min: 0,
              max: 100,
              step: 1,
              style: SliderStyle.OutSet
            })
              .width('55%')
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
              .margin({ left: this.scaledSize(8) })
            if (this.previewOnRight) {
              Blank()
                .width(this.scaledSize(14))
              this.glassBlurPreview()
                .transition(TransitionEffect.asymmetric(
                  TransitionEffect.OPACITY.combine(TransitionEffect.move(TransitionEdge.END))
                    .animation({ duration: 320, curve: Curve.EaseInOut }),
                  TransitionEffect.OPACITY.combine(TransitionEffect.move(TransitionEdge.END))
                    .animation({ duration: 320, curve: Curve.EaseInOut })
                ))
            }
          }
          .padding({
            left: this.scaledSize(12), right: this.scaledSize(12),
            top: this.scaledSize(2), bottom: this.scaledSize(6)
          })
          .width('100%')
          .alignItems(VerticalAlign.Center)
        }
        .width('100%')
        .backgroundColor(ColorHelper.hexToRgba(this.primaryColor, 0.04))
        .borderRadius(this.scaledSize(10))

        Column() {
          this.subTitle('经典 Tab 指示器')
          Row() {
            if (!this.previewOnRight) {
              this.tabIndicatorPreview()
                .transition(TransitionEffect.asymmetric(
                  TransitionEffect.OPACITY.combine(TransitionEffect.move(TransitionEdge.START))
                    .animation({ duration: 320, curve: Curve.EaseInOut }),
                  TransitionEffect.OPACITY.combine(TransitionEffect.move(TransitionEdge.START))
                    .animation({ duration: 320, curve: Curve.EaseInOut })
                ))
            }
            Text('浅')
              .fontSize(this.scaledFont(11))
              .fontColor(this.settingTextColor())
              .margin({
                left: this.previewOnRight ? 0 : this.scaledSize(14),
                right: this.scaledSize(8)
              })
            Slider({
              value: this.settings.tabIndicatorOpacity,
              min: 0,
              max: 100,
              step: 1,
              style: SliderStyle.OutSet
            })
              .width('55%')
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
              .margin({ left: this.scaledSize(8) })
            if (this.previewOnRight) {
              Blank()
                .width(this.scaledSize(14))
              this.tabIndicatorPreview()
                .transition(TransitionEffect.asymmetric(
                  TransitionEffect.OPACITY.combine(TransitionEffect.move(TransitionEdge.END))
                    .animation({ duration: 320, curve: Curve.EaseInOut }),
                  TransitionEffect.OPACITY.combine(TransitionEffect.move(TransitionEdge.END))
                    .animation({ duration: 320, curve: Curve.EaseInOut })
                ))
            }
          }
          .padding({
            left: this.scaledSize(12), right: this.scaledSize(12),
            top: this.scaledSize(2), bottom: this.scaledSize(6)
          })
          .width('100%')
          .alignItems(VerticalAlign.Center)
        }
        .width('100%')
        .backgroundColor(ColorHelper.hexToRgba(this.primaryColor, 0.04))
        .borderRadius(this.scaledSize(10))
      }
      .width('100%')
      .opacity(this.classicGroupOpacity)
      .animation({ duration: 280, curve: Curve.EaseInOut })
      .visibility(this.settings.tabStyle === 'classic' ? Visibility.Visible : Visibility.None)

      Column() {
        this.sectionTitle('主题色')
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
                    width: this.settings.primaryColor === option.value ? 3 : 1,
                    color: this.settings.primaryColor === option.value ? '#FFFFFF' :
                      ColorHelper.hexToRgba(this.primaryColor, 0.25)
                  })
                Text(option.name)
                  .fontSize(this.scaledFont(11))
                  .fontColor(this.settingTextColor())
                  .maxLines(1)
              }
              .width('100%')
              .height(this.scaledSize(42))
              .padding({ left: this.scaledSize(8), right: this.scaledSize(8) })
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
        .padding({ left: this.scaledSize(12), right: this.scaledSize(12), top: 4 })
        .width('100%')

        Row({ space: this.scaledSize(10) }) {
          Column()
            .width(this.scaledSize(28))
            .height(this.scaledSize(28))
            .borderRadius(this.scaledSize(14))
            .backgroundColor(this.primaryColor)
            .border({ width: 2, color: '#FFFFFF' })
          Column() {
            Text('自定义颜色')
              .fontSize(this.scaledFont(12))
              .fontColor(this.settingTextColor())
              .fontWeight(FontWeight.Medium)
            Text(this.primaryColor.toUpperCase())
              .fontSize(this.scaledFont(10))
              .fontColor(this.settingSubTextColor())
          }
          .alignItems(HorizontalAlign.Start)
          Blank()
          SymbolGlyph($r('sys.symbol.paintpalette'))
            .fontSize(this.scaledFont(22))
            .fontColor([this.primaryColor])
        }
        .width('100%')
        .height(this.scaledSize(48))
        .padding({ left: this.scaledSize(12), right: this.scaledSize(12) })
        .margin({ top: this.scaledSize(8), bottom: this.scaledSize(10) })
        .borderRadius(this.scaledSize(10))
        .backgroundColor(ColorHelper.hexToRgba(this.primaryColor, 0.08))
        .onClick(() => {
          this.openColorPicker()
        })
      }
      .width('100%')
      .backgroundColor(ColorHelper.hexToRgba(this.primaryColor, 0.04))
      .borderRadius(this.scaledSize(10))

      Column() {
        this.sectionTitle('字体大小')
        Row() {
          Text('A')
            .fontSize(this.scaledFont(11))
            .fontColor(this.settingTextColor())
            .margin({ right: 8 })
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
          .width('100%')
          .layoutWeight(1)
          .height(40)
          Text('A')
            .fontSize(this.scaledFont(20))
            .fontColor(this.settingTextColor())
            .margin({ left: 8 })
        }
        .padding({ left: 12, right: 12, top: 2, bottom: 10 })
        .width('100%')
        .alignItems(VerticalAlign.Center)
      }
      .width('100%')
      .backgroundColor(ColorHelper.hexToRgba(this.primaryColor, 0.04))
      .borderRadius(10)

      Column() {
        this.sectionTitle('显示大小')
        Row() {
          Text('小')
            .fontSize(this.scaledFont(11))
            .fontColor(this.settingTextColor())
            .margin({ right: 8 })
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
          .width('100%')
          .layoutWeight(1)
          .height(40)
          Text('大')
            .fontSize(this.scaledFont(14))
            .fontColor(this.settingTextColor())
            .margin({ left: 8 })
        }
        .padding({ left: 12, right: 12, top: 2, bottom: 10 })
        .width('100%')
        .alignItems(VerticalAlign.Center)
      }
      .width('100%')
      .backgroundColor(ColorHelper.hexToRgba(this.primaryColor, 0.04))
      .borderRadius(10)
    }
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
        this.toggleRow('显示歌词', this.settings.showLyrics, (val: boolean) => {
          this.settings.showLyrics = val
          this.updateSetting()
          AppStorage.setOrCreate('uplayer_show_lyrics', val)
        })
        Divider()
          .color(ColorHelper.hexToRgba(this.primaryColor, 0.08))
          .margin({ left: 14, right: 14 })
        this.toggleRow('淡入淡出', this.settings.fadeInOut, (val: boolean) => {
          this.settings.fadeInOut = val
          this.updateSetting()
          AppStorage.setOrCreate('uplayer_fade_in_out', val)
        })
      }
      .width('100%')
      .backgroundColor(ColorHelper.hexToRgba(this.primaryColor, 0.04))
      .borderRadius(10)

      Column() {
        this.sectionTitle('播放速度')
        Row() {
          Text(this.settings.playSpeed.toFixed(1) + 'x')
            .fontSize(this.scaledFont(12))
            .fontColor(this.settingTextColor())
        }
        .width('100%')
        .padding({ left: 12, right: 12, top: 2 })
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
        .height(40)
        .padding({ left: 12, right: 12, bottom: 8 })
      }
      .width('100%')
      .backgroundColor(ColorHelper.hexToRgba(this.primaryColor, 0.04))
      .borderRadius(10)
    }
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
      .backgroundColor(ColorHelper.hexToRgba(this.primaryColor, 0.04))
      .borderRadius(10)

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
        .borderRadius(10)
      }
    }
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
    // 弦长参数化 Catmull-Rom → Cubic Bezier
    // 使用实际 x 距离作为参数，适应非均匀间距
    ctx.beginPath()
    ctx.moveTo(xs[0], ys[0])
    for (let i = 0; i < total - 1; i++) {
      const p0x: number = xs[i]
      const p0y: number = ys[i]
      const p1x: number = xs[i + 1]
      const p1y: number = ys[i + 1]
      // 前一点和后一点（边界处使用自身）
      const prevX: number = i > 0 ? xs[i - 1] : xs[i]
      const prevY: number = i > 0 ? ys[i - 1] : ys[i]
      const nextX: number = i + 2 < total ? xs[i + 2] : xs[i + 1]
      const nextY: number = i + 2 < total ? ys[i + 2] : ys[i + 1]
      // 弦长参数化 Catmull-Rom：
      // CP1 = P0 + (P1 - P_{i-1}) * (x_{i+1} - x_i) / (2 * (x_{i+1} - x_{i-1}))
      // CP2 = P1 - (P_{i+2} - P_i) * (x_{i+1} - x_i) / (2 * (x_{i+2} - x_i))
      const dx: number = p1x - p0x
      const dPrev: number = p1x - prevX
      const dNext: number = nextX - p0x
      const cp1x: number = p0x + (p1x - prevX) * dx / (2 * dPrev)
      const cp1y: number = p0y + (p1y - prevY) * dx / (2 * dPrev)
      const cp2x: number = p1x - (nextX - p0x) * dx / (2 * dNext)
      const cp2y: number = p1y - (nextY - p0y) * dx / (2 * dNext)
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
    .padding({ left: this.scaledSize(14), right: this.scaledSize(14) })
    .alignItems(VerticalAlign.Center)
  }
}
