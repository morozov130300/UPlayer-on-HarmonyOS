import { curves, uiAppearance } from '@kit.ArkUI'
import { common, ConfigurationConstant } from '@kit.AbilityKit'
import { DataService, AppSettingsData } from '../service/DataService'
import { AVPlayerService } from '../service/AVPlayerService'
import { AppStorageKeyConstants } from '../common/constants/AppStorageKeyConstants'
import { ColorHelper } from '../common/utils/ColorHelper'
import Logger from '../common/utils/Logger'
import { deviceInfo } from '@kit.BasicServicesKit'
import { motion } from '@kit.MultimodalAwarenessKit'
import { ColorConversion } from '../common/utils/ColorConversion'
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
  private context: common.UIAbilityContext | undefined = AppStorage.get<common.UIAbilityContext>(AppStorageKeyConstants.KEY_UI_ABILITY_CONTEXT)
  @State settings: AppSettingsData = new AppSettingsData()
  @StorageLink(KEY_PRIMARY_COLOR) primaryColor: string = '#007DFF'
  @StorageLink(AppStorageKeyConstants.KEY_TITLE_BUTTON_WIDTH) titleButtonWidth: number = 0
  @StorageLink(AppStorageKeyConstants.KEY_TITLE_BUTTON_HEIGHT) titleButtonHeight: number = 0
  @StorageLink(AppStorageKeyConstants.KEY_TOP_HEIGHT) topSafeHeight: number = 0
  @StorageLink('uplayer_display_size_scale') displaySizeScale: number = 1.0
  @StorageLink('uplayer_font_size_scale') fontSizeScale: number = 1.0
  @StorageLink('uplayer_glass_blur_strength') glassBlurStrength: number = 25
  @State pageTitle: string = ''
  @State previewOnRight: boolean = false
  @State showColorPicker: boolean = false
  @State pickerHue: number = 210
  @State pickerSaturation: number = 1
  @State pickerValue: number = 1
  @State pickerOriginalColor: string = '#007DFF'
  private dataService: DataService = DataService.getInstance()
  private avPlayerService: AVPlayerService = AVPlayerService.getInstance()
  private isPC: boolean = deviceInfo.deviceType === '2in1'
  private holdingHandCallback: (status: motion.HoldingHandStatus) => void =
    (status: motion.HoldingHandStatus): void => {
      this.previewOnRight = status === motion.HoldingHandStatus.LEFT_HAND_HELD
    }
  private themeOptions: ThemeOption[] = [
    { label: '跟随系统', value: 'system' },
    { label: '深色模式', value: 'dark' },
    { label: '浅色模式', value: 'light' }
  ]
  private tabStyleOptions: TabStyleOption[] = [
    { label: '经典', value: 'classic' },
    { label: '沉浸', value: 'immersive' }
  ]
  private colorOptions: ThemeColorOption[] = [
    { name: '鸿蒙蓝', value: '#007DFF' },
    { name: '经典红', value: '#FF3B30' },
    { name: '经典绿', value: '#34C759' },
    { name: '经典橙', value: '#FF9500' },
    { name: '经典紫', value: '#AF52DE' },
    { name: '经典青', value: '#5AC8FA' },
    { name: '典雅金', value: '#C79A3B' },
    { name: '沉浸靛', value: '#5856D6' }
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
    const params = this.getUIContext()?.getRouter().getParams() as Record<string, string>
    const route: string = params?.category ?? 'customize'
    this.pageTitle = this.titleMap[route] ?? '设置'
    ColorConversion.setSysBarLightBackground(this.isDark())
    this.registerHoldingHandListener()
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
    if (this.isPC || !canIUse('SystemCapability.MultimodalAwareness.Motion')) {
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
  }

  private glassBlurRadius(): number {
    return this.glassBlurStrength * 0.5
  }

  private glassSaturation(): number {
    return 1 + this.glassBlurStrength * 0.0035
  }

  private glassBrightness(): number {
    return 1 + this.glassBlurStrength * 0.0008
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
          saturation: this.glassSaturation(),
          brightness: this.glassBrightness()
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
      .width(this.scaledSize(68))
      .height(this.scaledSize(36))
      .borderRadius(this.scaledSize(18))
      .backgroundColor(this.primaryColor)
      .shadow({
        radius: 14,
        color: ColorHelper.hexWithAlpha(this.primaryColor, 'CC')
      })
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

  onSpeedChange(value: number): void {
    this.settings.playSpeed = 0.5 + value / 100
    this.updateSetting()
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
        Row() {
          Row() {
            SymbolGlyph($r('sys.symbol.chevron_left'))
              .fontSize(this.scaledFont(32))
              .fontColor([this.primaryColor])
              .opacity(0.9)
          }
          .width(this.scaledSize(48))
          .height(this.scaledSize(48))
          .justifyContent(FlexAlign.Center)
          .borderRadius(this.scaledSize(24))
          .hoverEffect(HoverEffect.Scale)
          .onClick(() => { this.getUIContext()?.getRouter().back() })

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
        }
        .width('100%')
        .layoutWeight(1)
      }
      .width('100%')
      .height('100%')
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_background_other'))
  }

  @Builder
  sectionTitle(title: string): void {
    Text(title)
      .fontSize(this.scaledFont(13))
      .fontColor(this.isDark() ? ColorHelper.hexWithAlpha('#FFFFFF', '99') : ColorHelper.hexWithAlpha(this.primaryColor, '99'))
      .fontWeight(FontWeight.Medium)
      .width('100%')
      .padding({ left: this.scaledSize(4), top: this.scaledSize(6), bottom: this.scaledSize(2) })
  }

  @Builder
  buildCustomizeSection(): void {
    Column({ space: 10 }) {
      Column() {
        this.sectionTitle('界面控制')
        this.toggleRow('滚动隐藏加号按钮', this.settings.plusButtonScrollHide, (val: boolean) => {
          this.settings.plusButtonScrollHide = val
          this.updateSetting()
        })
      }
      .width('100%')
      .backgroundColor(ColorHelper.hexToRgba(this.primaryColor, 0.04))
      .borderRadius(10)

      Column() {
        this.sectionTitle('主题模式')
        Row() {
          ForEach(this.themeOptions, (opt: ThemeOption) => {
            Column() {
              Text(opt.label)
                .fontSize(this.scaledFont(11))
                .fontColor(this.settings.themeMode === opt.value ? '#FFFFFF' : this.settingInactiveTextColor())
            }
            .padding({ left: this.scaledSize(10), right: this.scaledSize(10), top: this.scaledSize(5), bottom: this.scaledSize(5) })
            .backgroundColor(this.settings.themeMode === opt.value ? this.primaryColor : ColorHelper.hexToRgba(this.primaryColor, 0.08))
            .borderRadius(this.scaledSize(14))
            .onClick(() => { this.setThemeMode(opt.value) })
          }, (opt: ThemeOption) => opt.value)
        }
        .padding({ left: 12, right: 12, top: 2, bottom: 10 })
        .width('100%')
        .justifyContent(FlexAlign.End)
      }
      .width('100%')
      .backgroundColor(ColorHelper.hexToRgba(this.primaryColor, 0.04))
      .borderRadius(10)

      Column() {
        this.sectionTitle('Tab栏样式')
        Row() {
          ForEach(this.tabStyleOptions, (opt: TabStyleOption) => {
            Column() {
              Text(opt.label)
                .fontSize(this.scaledFont(11))
                .fontColor(this.settings.tabStyle === opt.value ? '#FFFFFF' : this.settingInactiveTextColor())
            }
            .padding({ left: this.scaledSize(10), right: this.scaledSize(10), top: this.scaledSize(5), bottom: this.scaledSize(5) })
            .backgroundColor(this.settings.tabStyle === opt.value ? this.primaryColor : ColorHelper.hexToRgba(this.primaryColor, 0.08))
            .borderRadius(this.scaledSize(14))
            .onClick(() => {
              this.setTabStyle(opt.value)
            })
          }, (opt: TabStyleOption) => opt.value)
        }
        .padding({ left: 12, right: 12, top: 2, bottom: 10 })
        .width('100%')
        .justifyContent(FlexAlign.End)
      }
      .width('100%')
      .backgroundColor(ColorHelper.hexToRgba(this.primaryColor, 0.04))
      .borderRadius(10)

      Column() {
        this.sectionTitle('Tab栏与播控条玻璃模糊强度')
        Row() {
          if (!this.previewOnRight) {
            this.glassBlurPreview()
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
            Blank().width(this.scaledSize(14))
            this.glassBlurPreview()
          }
        }
        .padding({
          left: this.scaledSize(12), right: this.scaledSize(12),
          top: this.scaledSize(2), bottom: this.scaledSize(10)
        })
        .width('100%')
        .alignItems(VerticalAlign.Center)
      }
      .width('100%')
      .backgroundColor(ColorHelper.hexToRgba(this.primaryColor, 0.04))
      .borderRadius(this.scaledSize(10))

      Column() {
        this.sectionTitle('经典 Tab 指示器')
        Row() {
          if (!this.previewOnRight) {
            this.tabIndicatorPreview()
          }
          Text('指示器始终使用纯主题色，不叠加黑白蒙版或深浅渐变')
            .fontSize(this.scaledFont(11))
            .fontColor(this.settingSubTextColor())
            .layoutWeight(1)
            .margin({
              left: this.previewOnRight ? 0 : this.scaledSize(14),
              right: this.scaledSize(8)
            })
          if (this.previewOnRight) {
            Blank().width(this.scaledSize(14))
            this.tabIndicatorPreview()
          }
        }
        .padding({
          left: this.scaledSize(12), right: this.scaledSize(12),
          top: this.scaledSize(2), bottom: this.scaledSize(10)
        })
        .width('100%')
        .alignItems(VerticalAlign.Center)
      }
      .width('100%')
      .backgroundColor(ColorHelper.hexToRgba(this.primaryColor, 0.04))
      .borderRadius(this.scaledSize(10))

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
              .onClick(() => { this.setPrimaryColor(option.value) })
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
        .onClick(() => { this.openColorPicker() })
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
          Text(this.currentPickerColor().toUpperCase())
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
            .onClick(() => { this.cancelColorPicker() })
          Button('确定')
            .layoutWeight(1)
            .height(this.scaledSize(38))
            .fontColor('#FFFFFF')
            .backgroundColor(this.currentPickerColor())
            .onClick(() => { this.confirmColorPicker() })
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
        Divider().color(ColorHelper.hexToRgba(this.primaryColor, 0.08)).margin({ left: 14, right: 14 })
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
            .onChange((value: number) => {
              this.onSpeedChange(value)
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
        Column() {
          Scroll() {
            Row({ space: this.scaledSize(4) }) {
              ForEach(this.eqBands, (band: EqBandInfo) => {
                Column() {
                  Text((this.settings.eqBands[band.index] >= 0 ? '+' : '') + this.settings.eqBands[band.index] + 'dB')
                  .fontSize(this.scaledFont(9))
                  .fontColor(ColorHelper.hexWithAlpha(this.primaryColor, '88'))
                  .margin({ bottom: 4 })
                Stack({ alignContent: Alignment.Center }) {
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
                .height(this.scaledSize(180))

                Text(band.freq)
                  .fontSize(this.scaledFont(10))
                  .fontColor(this.settingSubTextColor())
                  .fontWeight(FontWeight.Medium)
                  .margin({ top: 6 })
              }
              .alignItems(HorizontalAlign.Center)
            }, (band: EqBandInfo) => band.freq)
            }
            .padding({ left: 8, right: 8, top: 12, bottom: 12 })
          }
          .width('100%')
          .scrollable(ScrollDirection.Horizontal)
          .scrollBar(BarState.Auto)
        }
        .width('100%')
        .backgroundColor(ColorHelper.hexToRgba(this.primaryColor, 0.04))
        .borderRadius(10)
      }
    }
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
