import { router } from '@kit.ArkUI'
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

  build() {
    Column() {
      Row() {
        SymbolGlyph($r('sys.symbol.chevron_left'))
          .fontSize(22)
          .fontColor([$r('app.color.text_primary')])
          .margin({ right: 8 })
          .onClick(() => { router.back() })
        Text(this.pageTitle)
          .fontSize(18)
          .fontColor($r('app.color.text_primary'))
          .fontWeight(FontWeight.Bold)
      }
      .width('100%')
      .height(56)
      .padding({ left: 12, right: 16, top: this.topSafeHeight })
      .alignItems(VerticalAlign.Center)

      Divider().color($r('app.color.list_divider'))

      Scroll() {
        Column({ space: 12 }) {
          if (this.pageTitle === '定制条目') {
            this.buildCustomizeSection()
          } else if (this.pageTitle === '播放设置') {
            this.buildPlaybackSection()
          } else if (this.pageTitle === '音效设置') {
            this.buildAudioSection()
          }
        }
        .width('100%')
        .padding({ left: 12, right: 12, top: 12, bottom: 40 })
      }
      .width('100%')
      .layoutWeight(1)
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  sectionTitle(title: string): void {
    Text(title)
      .fontSize(14)
      .fontColor(this.primaryColor)
      .fontWeight(FontWeight.Medium)
      .width('100%')
      .padding({ left: 4, top: 8, bottom: 4 })
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
    .backgroundColor($r('app.color.page_background_sm'))
    .borderRadius(12)

    Column() {
      this.sectionTitle('主题模式')
      Row() {
        ForEach(this.themeOptions, (opt: ThemeOption) => {
          Column() {
            Text(opt.label)
              .fontSize(12)
              .fontColor(this.settings.themeMode === opt.value ? this.primaryColor : $r('app.color.text_sixty_color'))
          }
          .padding({ left: 12, right: 12, top: 6, bottom: 6 })
          .backgroundColor(this.settings.themeMode === opt.value ? ColorHelper.hexToRgba(this.primaryColor, 0.12) : 'rgba(0,0,0,0.05)')
          .borderRadius(16)
          .onClick(() => { this.setThemeMode(opt.value) })
        }, (opt: ThemeOption) => opt.value)
      }
      .padding({ left: 12, right: 12, top: 4, bottom: 12 })
      .width('100%')
    }
    .width('100%')
    .backgroundColor($r('app.color.page_background_sm'))
    .borderRadius(12)

    Column() {
      this.sectionTitle('主题色')
      Row() {
        ForEach(this.colorOptions, (color: string) => {
          Column()
            .width(28).height(28)
            .borderRadius(14)
            .backgroundColor(color)
            .border({
              width: this.settings.primaryColor === color ? 3 : 1,
              color: this.settings.primaryColor === color ? this.primaryColor : $r('app.color.list_divider')
            })
            .margin({ right: 10 })
            .onClick(() => { this.setPrimaryColor(color) })
        }, (color: string) => color)
      }
      .padding({ left: 12, right: 12, top: 4, bottom: 12 })
      .width('100%')
    }
    .width('100%')
    .backgroundColor($r('app.color.page_background_sm'))
    .borderRadius(12)
  }

  @Builder
  buildPlaybackSection(): void {
    Column() {
      this.toggleRow('显示歌词', this.settings.showLyrics, (val: boolean) => {
        this.settings.showLyrics = val
        this.updateSetting()
        AppStorage.setOrCreate('uplayer_show_lyrics', val)
      })
      Divider().color($r('app.color.list_divider')).margin({ left: 16, right: 16 })
      this.toggleRow('通知栏控制', this.settings.enableNotification, (val: boolean) => {
        this.settings.enableNotification = val
        this.updateSetting()
        AppStorage.setOrCreate('uplayer_notification', val)
      })
      Divider().color($r('app.color.list_divider')).margin({ left: 16, right: 16 })
      this.toggleRow('淡入淡出', this.settings.fadeInOut, (val: boolean) => {
        this.settings.fadeInOut = val
        this.updateSetting()
        AppStorage.setOrCreate('uplayer_fade_in_out', val)
      })
    }
    .width('100%')
    .backgroundColor($r('app.color.page_background_sm'))
    .borderRadius(12)

    Column() {
      this.sectionTitle('播放速度')
      Row() {
        Text(this.settings.playSpeed.toFixed(1) + 'x')
          .fontSize(13)
          .fontColor($r('app.color.text_sixty_color'))
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 4 })
      Slider({
        value: (this.settings.playSpeed - 0.5) * 100,
        min: 0,
        max: 250,
        step: 10,
        style: SliderStyle.OutSet
      })
        .width('100%')
        .padding({ left: 12, right: 12, bottom: 12 })
        .selectedColor(this.primaryColor)
        .trackColor($r('app.color.list_divider'))
        .onChange((value: number) => {
          this.onSpeedChange(value)
        })
    }
    .width('100%')
    .backgroundColor($r('app.color.page_background_sm'))
    .borderRadius(12)
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
    .backgroundColor($r('app.color.page_background_sm'))
    .borderRadius(12)

    if (this.settings.eqEnabled) {
      Column() {
        this.sectionTitle('频段调节')
        Row() {
          ForEach(this.eqBands, (band: EqBandInfo) => {
            Column() {
              Slider({
                value: this.settings.eqBands[band.index] + 12,
                min: 0,
                max: 24,
                step: 1,
                style: SliderStyle.OutSet,
                direction: Axis.Vertical
              })
                .width(24)
                .height(140)
                .selectedColor(this.primaryColor)
                .trackColor($r('app.color.list_divider'))
                .showSteps(true)
                .onChange((value: number) => {
                  this.onEqBandChange(band.index, value)
                })
              Text(band.freq)
                .fontSize(9)
                .fontColor($r('app.color.text_sixty_color'))
                .margin({ top: 4 })
              Text((this.settings.eqBands[band.index] >= 0 ? '+' : '') + this.settings.eqBands[band.index] + 'dB')
                .fontSize(8)
                .fontColor($r('app.color.text_twenty_color'))
            }
            .alignItems(HorizontalAlign.Center)
          }, (band: EqBandInfo) => band.freq)
        }
        .width('100%')
        .padding({ left: 12, right: 12, top: 4, bottom: 12 })
        .justifyContent(FlexAlign.SpaceEvenly)
      }
      .width('100%')
      .backgroundColor($r('app.color.page_background_sm'))
      .borderRadius(12)
    }
  }

  @Builder
  toggleRow(label: string, checked: boolean, onChange: (val: boolean) => void): void {
    Row() {
      Text(label)
        .fontSize(14)
        .fontColor($r('app.color.text_sixty_color'))
      Blank()
      Toggle({ type: ToggleType.Switch, isOn: checked })
        .selectedColor(this.primaryColor)
        .onChange((isOn: boolean) => {
          onChange(isOn)
        })
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 12, bottom: 12 })
    .alignItems(VerticalAlign.Center)
  }
}
