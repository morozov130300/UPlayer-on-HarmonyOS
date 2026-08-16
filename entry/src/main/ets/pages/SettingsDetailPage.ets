import { curves, uiAppearance } from '@kit.ArkUI'
import { common, ConfigurationConstant } from '@kit.AbilityKit'
import { DataService, AppSettingsData } from '../service/DataService'
import { AVPlayerService } from '../service/AVPlayerService'
import { AppStorageKeyConstants } from '../common/constants/AppStorageKeyConstants'
import { ColorHelper } from '../common/utils/ColorHelper'
import Logger from '../common/utils/Logger'

const TAG = 'SettingsDetailPage'
const KEY_PRIMARY_COLOR = 'uplayer_primary_color'

class EqBandInfo {
  freq: string = ''
  index: number = 0
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
  @StorageLink('uplayer_display_size_scale') displaySizeScale: number = 1.0
  @StorageLink('uplayer_font_size_scale') fontSizeScale: number = 1.0
  @StorageLink('uplayer_tab_indicator_depth') tabIndicatorDepth: number = 50
  @State pageTitle: string = ''
  private dataService: DataService = DataService.getInstance()
  private avPlayerService: AVPlayerService = AVPlayerService.getInstance()
  private themeOptions: ThemeOption[] = [
    { label: '跟随系统', value: 'system' },
    { label: '深色模式', value: 'dark' },
    { label: '浅色模式', value: 'light' }
  ]
  private tabStyleOptions: TabStyleOption[] = [
    { label: '经典', value: 'classic' },
    { label: '沉浸', value: 'immersive' }
  ]
  private colorOptions: string[] = ['#007DFF', '#FF3B30', '#34C759', '#FF9500', '#AF52DE', '#5AC8FA']
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

  onSpeedChange(value: number): void {
    this.settings.playSpeed = 0.5 + value / 100
    this.updateSetting()
    try {
      this.avPlayerService.setSpeed(this.settings.playSpeed)
    } catch (e) {
      Logger.error(TAG, 'setSpeed failed: ' + JSON.stringify(e))
    }
  }

  onEqBandChange(bandIndex: number, value: number): void {
    this.settings.eqBands[bandIndex] = value - 12
    this.updateSetting()
  }

  pageTransition() {
    PageTransitionEnter({ duration: 300, curve: Curve.EaseOut })
      .slide(SlideEffect.Right)
      .opacity(1)
    PageTransitionExit({ duration: 250, curve: Curve.EaseIn })
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
        .height(Math.max(56, this.titleButtonHeight))
        .padding({ left: 4, right: this.titleButtonWidth + 12 })
        .alignItems(VerticalAlign.Center)

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
        this.sectionTitle('经典 Tab 指示器深浅')
        Row() {
          Text('浅')
            .fontSize(this.scaledFont(11))
            .fontColor(this.settingTextColor())
            .margin({ right: this.scaledSize(8) })
          Slider({
            value: this.settings.tabIndicatorDepth,
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
              this.settings.tabIndicatorDepth = value
              this.tabIndicatorDepth = value
              if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) {
                this.updateSetting()
              }
            })
          Text('深')
            .fontSize(this.scaledFont(11))
            .fontColor(this.settingTextColor())
            .margin({ left: this.scaledSize(8) })
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
        Row() {
          ForEach(this.colorOptions, (color: string) => {
            Column()
              .width(this.scaledSize(26)).height(this.scaledSize(26))
              .borderRadius(this.scaledSize(13))
              .backgroundColor(color)
              .border({
                width: this.settings.primaryColor === color ? 2.5 : 0.5,
                color: this.settings.primaryColor === color ? this.primaryColor : ColorHelper.hexToRgba(this.primaryColor, 0.25)
              })
              .margin({ left: 8 })
              .onClick(() => { this.setPrimaryColor(color) })
          }, (color: string) => color)
        }
        .padding({ left: 12, right: 12, top: 2, bottom: 10 })
        .width('100%')
        .justifyContent(FlexAlign.End)
      }
      .width('100%')
      .backgroundColor(ColorHelper.hexToRgba(this.primaryColor, 0.04))
      .borderRadius(10)

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
  buildPlaybackSection(): void {
    Column({ space: 10 }) {
      Column() {
        this.toggleRow('显示歌词', this.settings.showLyrics, (val: boolean) => {
          this.settings.showLyrics = val
          this.updateSetting()
          AppStorage.setOrCreate('uplayer_show_lyrics', val)
        })
        Divider().color(ColorHelper.hexToRgba(this.primaryColor, 0.08)).margin({ left: 14, right: 14 })
        this.toggleRow('通知栏控制', this.settings.enableNotification, (val: boolean) => {
          this.settings.enableNotification = val
          this.updateSetting()
          AppStorage.setOrCreate('uplayer_notification', val)
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
        })
      }
      .width('100%')
      .backgroundColor(ColorHelper.hexToRgba(this.primaryColor, 0.04))
      .borderRadius(10)

      if (this.settings.eqEnabled) {
        Column() {
          Row() {
            ForEach(this.eqBands, (band: EqBandInfo) => {
              Column() {
                Text((this.settings.eqBands[band.index] >= 0 ? '+' : '') + this.settings.eqBands[band.index] + 'dB')
                  .fontSize(this.scaledFont(9))
                  .fontColor(ColorHelper.hexWithAlpha(this.primaryColor, '88'))
                  .margin({ bottom: 4 })
                Column() {
                  Slider({
                    value: this.settings.eqBands[band.index] + 12,
                    min: 0,
                    max: 24,
                    step: 1,
                    style: SliderStyle.InSet,
                    direction: Axis.Vertical,
                    reverse: true
                  })
                    .width(this.scaledSize(6))
                    .height(this.scaledSize(110))
                    .selectedColor(this.primaryColor)
                    .trackColor(ColorHelper.hexToRgba(this.primaryColor, 0.1))
                    .blockColor('#FFFFFF')
                    .blockSize({ width: this.scaledSize(14), height: this.scaledSize(6) })
                    .blockBorderColor(this.primaryColor)
                    .blockBorderWidth(1)
                    .onChange((value: number) => {
                      this.onEqBandChange(band.index, value)
                    })
                }
                .width(this.scaledSize(28))
                .height(this.scaledSize(110))
                .justifyContent(FlexAlign.End)
                .borderRadius(4)
                .clip(true)

                Text(band.freq)
                  .fontSize(this.scaledFont(10))
                  .fontColor(this.settingSubTextColor())
                  .fontWeight(FontWeight.Medium)
                  .margin({ top: 6 })
              }
              .alignItems(HorizontalAlign.Center)
            }, (band: EqBandInfo) => band.freq)
          }
          .width('100%')
          .padding({ left: 8, right: 8, top: 12, bottom: 12 })
          .justifyContent(FlexAlign.SpaceEvenly)
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
