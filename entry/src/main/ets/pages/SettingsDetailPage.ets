import { router, curves } from '@kit.ArkUI'
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

@Entry
@Component
struct SettingsDetailPage {
  private context: common.UIAbilityContext | undefined = AppStorage.get<common.UIAbilityContext>(AppStorageKeyConstants.KEY_UI_ABILITY_CONTEXT)
  @State settings: AppSettingsData = new AppSettingsData()
  @StorageLink(KEY_PRIMARY_COLOR) primaryColor: string = '#007DFF'
  @StorageLink(AppStorageKeyConstants.KEY_TOP_HEIGHT) topSafeHeight: number = 0
  @State pageTitle: string = ''
  private dataService: DataService = DataService.getInstance()
  private avPlayerService: AVPlayerService = AVPlayerService.getInstance()
  private themeOptions: ThemeOption[] = [
    { label: '跟随系统', value: 'system' },
    { label: '深色模式', value: 'dark' },
    { label: '浅色模式', value: 'light' }
  ]
  private colorOptions: string[] = ['#007DFF', '#FF3B30', '#34C759', '#FF9500', '#AF52DE', '#5AC8FA']
  private eqBands: EqBandInfo[] = [
    { freq: '32', index: 0 }, { freq: '64', index: 1 }, { freq: '125', index: 2 },
    { freq: '250', index: 3 }, { freq: '500', index: 4 }, { freq: '1k', index: 5 },
    { freq: '2k', index: 6 }, { freq: '4k', index: 7 }, { freq: '8k', index: 8 },
    { freq: '16k', index: 9 }
  ]
  private titleMap: Record<string, string> = {
    'customize': '定制条目',
    'playback': '播放设置',
    'audio': '音效设置'
  }

  aboutToAppear(): void {
    this.settings = this.dataService.getSettings()
    const params = router.getParams() as Record<string, string>
    const route: string = params?.category ?? 'customize'
    this.pageTitle = this.titleMap[route] ?? '设置'
  }

  updateSetting(): void {
    this.dataService.saveSettings(this.settings)
  }

  setThemeMode(mode: string): void {
    this.settings.themeMode = mode
    this.updateSetting()
    AppStorage.setOrCreate('uplayer_theme_mode', mode)
    this.applyThemeMode(mode)
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
    Column() {
      Row() {
        Row() {
          SymbolGlyph($r('sys.symbol.chevron_left'))
            .fontSize(32)
            .fontColor([this.primaryColor])
            .opacity(0.9)
        }
        .width(48)
        .height(48)
        .justifyContent(FlexAlign.Center)
        .borderRadius(24)
        .hoverEffect(HoverEffect.Scale)
        .onClick(() => { router.back() })

        Text(this.pageTitle)
          .fontSize(17)
          .fontColor(ColorHelper.darken(this.primaryColor, 0.3))
          .fontWeight(FontWeight.Bold)
          .margin({ left: 4 })
      }
      .width('100%')
      .height(52)
      .padding({ left: 4, right: 16, top: this.topSafeHeight })
      .alignItems(VerticalAlign.Center)

      Scroll() {
        Column({ space: 10 }) {
          if (this.pageTitle === '定制条目') {
            this.buildCustomizeSection()
          } else if (this.pageTitle === '播放设置') {
            this.buildPlaybackSection()
          } else if (this.pageTitle === '音效设置') {
            this.buildAudioSection()
          }
        }
        .width('100%')
        .padding({ left: 12, right: 12, top: 16, bottom: 40 })
      }
      .width('100%')
      .layoutWeight(1)
      .align(Alignment.Top)
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_background_other'))
  }

  @Builder
  sectionTitle(title: string): void {
    Text(title)
      .fontSize(13)
      .fontColor(ColorHelper.hexWithAlpha(this.primaryColor, '99'))
      .fontWeight(FontWeight.Medium)
      .width('100%')
      .padding({ left: 4, top: 6, bottom: 2 })
  }

  @Builder
  buildCustomizeSection(): void {
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
              .fontSize(11)
              .fontColor(this.settings.themeMode === opt.value ? '#FFFFFF' : ColorHelper.darken(this.primaryColor, 0.4))
          }
          .padding({ left: 10, right: 10, top: 5, bottom: 5 })
          .backgroundColor(this.settings.themeMode === opt.value ? this.primaryColor : ColorHelper.hexToRgba(this.primaryColor, 0.08))
          .borderRadius(14)
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
      this.sectionTitle('主题色')
      Row() {
        ForEach(this.colorOptions, (color: string) => {
          Column()
            .width(26).height(26)
            .borderRadius(13)
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
  }

  @Builder
  buildPlaybackSection(): void {
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
          .fontSize(12)
          .fontColor(ColorHelper.darken(this.primaryColor, 0.35))
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 2 })
      Slider({
        value: (this.settings.playSpeed - 0.5) * 100,
        min: 0,
        max: 250,
        step: 10,
        style: SliderStyle.OutSet
      })
        .width('100%')
        .padding({ left: 12, right: 12, bottom: 8 })
        .selectedColor(this.primaryColor)
        .trackColor(ColorHelper.hexToRgba(this.primaryColor, 0.12))
        .onChange((value: number) => {
          this.onSpeedChange(value)
        })
    }
    .width('100%')
    .backgroundColor(ColorHelper.hexToRgba(this.primaryColor, 0.04))
    .borderRadius(10)
  }

  @Builder
  buildAudioSection(): void {
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
                .fontSize(9)
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
                  .width(6)
                  .height(110)
                  .selectedColor(this.primaryColor)
                  .trackColor(ColorHelper.hexToRgba(this.primaryColor, 0.1))
                  .blockColor(this.primaryColor)
                  .blockSize({ width: 14, height: 6 })
                  .onChange((value: number) => {
                    this.onEqBandChange(band.index, value)
                  })
              }
              .width(28)
              .height(110)
              .justifyContent(FlexAlign.End)
              .borderRadius(4)
              .clip(true)

              Text(band.freq)
                .fontSize(10)
                .fontColor(ColorHelper.darken(this.primaryColor, 0.3))
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

  @Builder
  toggleRow(label: string, checked: boolean, onChange: (val: boolean) => void): void {
    Row() {
      Text(label)
        .fontSize(14)
        .fontColor(ColorHelper.darken(this.primaryColor, 0.35))
        .maxLines(1)
      Blank()
      Toggle({ type: ToggleType.Switch, isOn: checked })
        .selectedColor(this.primaryColor)
        .onChange((isOn: boolean) => {
          onChange(isOn)
        })
    }
    .width('100%')
    .height(44)
    .padding({ left: 14, right: 14 })
    .alignItems(VerticalAlign.Center)
  }
}
