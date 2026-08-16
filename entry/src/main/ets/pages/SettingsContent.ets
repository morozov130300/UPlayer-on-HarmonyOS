import { common, ConfigurationConstant } from '@kit.AbilityKit'
import { DataService, AppSettingsData } from '../service/DataService'
import { AVPlayerService } from '../service/AVPlayerService'
import { AppStorageKeyConstants } from '../common/constants/AppStorageKeyConstants'
import { ColorHelper } from '../common/utils/ColorHelper'
import Logger from '../common/utils/Logger'

const TAG = 'SettingsContent'
const KEY_PRIMARY_COLOR = 'uplayer_primary_color'

interface ThemeOption {
  label: string
  value: string
}

@Component
export struct SettingsContent {
  private context: common.UIAbilityContext | undefined = AppStorage.get<common.UIAbilityContext>(AppStorageKeyConstants.KEY_UI_ABILITY_CONTEXT)
  @State settings: AppSettingsData = new AppSettingsData()
  @StorageLink(KEY_PRIMARY_COLOR) primaryColor: string = '#007DFF'
  @StorageLink(AppStorageKeyConstants.KEY_TOP_HEIGHT) topSafeHeight: number = 0
  private dataService: DataService = DataService.getInstance()
  private themeOptions: ThemeOption[] = [
    { label: '跟随系统', value: 'system' },
    { label: '深色模式', value: 'dark' },
    { label: '浅色模式', value: 'light' }
  ]
  private colorOptions: string[] = ['#007DFF', '#FF3B30', '#34C759', '#FF9500', '#AF52DE', '#5AC8FA']
  private avPlayerService: AVPlayerService = AVPlayerService.getInstance()

  aboutToAppear(): void {
    this.settings = this.dataService.getSettings()
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

  onVolumeGainChange(value: number): void {
    this.settings.volumeGain = value - 20
    this.updateSetting()
    const vol: number = Math.max(0, Math.min(1, (value - 20 + 20) / 40))
    try {
      this.avPlayerService.setVolume(vol)
    } catch (e) {
      Logger.error(TAG, 'setVolume failed: ' + JSON.stringify(e))
    }
  }

  onShowLyricsChange(val: boolean): void {
    this.settings.showLyrics = val
    this.updateSetting()
    AppStorage.setOrCreate('uplayer_show_lyrics', val)
  }

  onNotificationChange(val: boolean): void {
    this.settings.enableNotification = val
    this.updateSetting()
    AppStorage.setOrCreate('uplayer_notification', val)
  }

  build() {
    Column() {
      Row() {
        Text('设置')
          .fontSize(18)
          .fontColor($r('app.color.text_primary'))
          .fontWeight(FontWeight.Bold)
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: this.topSafeHeight + 8, bottom: 12 })

      Scroll() {
        Column() {
          this.sectionHeader('界面控制')
          this.toggleRow('滚动隐藏加号按钮', this.settings.plusButtonScrollHide, (val: boolean) => {
            this.settings.plusButtonScrollHide = val
            this.updateSetting()
          })

          this.divider()

          this.sectionHeader('主题与配色')
          Text('主题模式')
            .fontSize(14)
            .fontColor($r('app.color.text_sixty_color'))
            .padding({ left: 16, top: 8, bottom: 8 })
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
          .padding({ left: 16, right: 16 })
          .width('100%')

          Text('主题色')
            .fontSize(14)
            .fontColor($r('app.color.text_sixty_color'))
            .padding({ left: 16, top: 12, bottom: 8 })
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
          .padding({ left: 16, right: 16 })
          .width('100%')

          this.divider()

          this.sectionHeader('播放设置')
          this.toggleRow('显示歌词', this.settings.showLyrics, (val: boolean) => {
            this.onShowLyricsChange(val)
          })
          this.toggleRow('通知栏控制', this.settings.enableNotification, (val: boolean) => {
            this.onNotificationChange(val)
          })

          this.divider()

          this.sectionHeader('音效设置')
          this.toggleRow('均衡器', this.settings.eqEnabled, (val: boolean) => {
            this.settings.eqEnabled = val
            this.updateSetting()
          })

          Row() {
            Text('音量增益')
              .fontSize(14)
              .fontColor($r('app.color.text_sixty_color'))
            Blank()
            Text(this.settings.volumeGain + ' dB')
              .fontSize(13)
              .fontColor($r('app.color.text_sixty_color'))
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 8, bottom: 8 })
          Slider({
            value: this.settings.volumeGain + 20,
            min: 0,
            max: 40,
            step: 1,
            style: SliderStyle.OutSet
          })
            .width('100%')
            .padding({ left: 16, right: 16 })
            .selectedColor(this.primaryColor)
            .trackColor($r('app.color.list_divider'))
            .onChange((value: number) => {
              this.onVolumeGainChange(value)
            })

          Row() {
            Text('播放速度')
              .fontSize(14)
              .fontColor($r('app.color.text_sixty_color'))
            Blank()
            Text(this.settings.playSpeed + 'x')
              .fontSize(13)
              .fontColor($r('app.color.text_sixty_color'))
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 8, bottom: 8 })
          Slider({
            value: (this.settings.playSpeed - 0.5) * 100,
            min: 0,
            max: 250,
            step: 10,
            style: SliderStyle.OutSet
          })
            .width('100%')
            .padding({ left: 16, right: 16 })
            .selectedColor(this.primaryColor)
            .trackColor($r('app.color.list_divider'))
            .onChange((value: number) => {
              this.onSpeedChange(value)
            })

          Row() {
            Text('音效增强')
              .fontSize(14)
              .fontColor($r('app.color.text_sixty_color'))
            Blank()
            Text(this.settings.audioEffect === 'none' ? '关闭' : this.settings.audioEffect)
              .fontSize(13)
              .fontColor($r('app.color.text_sixty_color'))
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 12, bottom: 8 })
          Flex({ wrap: FlexWrap.Wrap }) {
            ForEach(['none', 'pop', 'rock', 'classical', 'jazz', 'bass'], (effect: string) => {
              Column() {
                Text(this.getEffectLabel(effect))
                  .fontSize(11)
                  .fontColor(this.settings.audioEffect === effect ? this.primaryColor : $r('app.color.text_sixty_color'))
              }
              .padding({ left: 8, right: 8, top: 4, bottom: 4 })
              .backgroundColor(this.settings.audioEffect === effect ? ColorHelper.hexToRgba(this.primaryColor, 0.12) : 'rgba(0,0,0,0.03)')
              .borderRadius(12)
              .margin({ right: 6 })
              .onClick(() => {
                this.settings.audioEffect = effect
                this.updateSetting()
              })
            }, (effect: string) => effect)
          }
          .padding({ left: 16, right: 16 })
          .width('100%')

          Column().height(40)
        }
        .width('100%')
      }
      .width('100%')
      .layoutWeight(1)
    }
    .width('100%')
    .height('100%')
  }

  getEffectLabel(effect: string): string {
    const map: Record<string, string> = {
      'none': '关闭',
      'pop': '流行',
      'rock': '摇滚',
      'classical': '古典',
      'jazz': '爵士',
      'bass': '重低音'
    }
    return map[effect] || effect
  }

  @Builder
  sectionHeader(title: string): void {
    Text(title)
      .fontSize(13)
      .fontColor(this.primaryColor)
      .fontWeight(FontWeight.Medium)
      .width('100%')
      .padding({ left: 16, right: 16, top: 16, bottom: 4 })
  }

  @Builder
  divider(): void {
    Column()
      .width('100%')
      .height(1)
      .backgroundColor($r('app.color.list_divider'))
      .margin({ top: 8, bottom: 4 })
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
    .padding({ left: 16, right: 16, top: 8, bottom: 8 })
    .alignItems(VerticalAlign.Center)
  }
}
