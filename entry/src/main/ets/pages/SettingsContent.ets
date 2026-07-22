import { common } from '@kit.AbilityKit'
import { DataService, AppSettingsData } from '../service/DataService'
import Logger from '../common/utils/Logger'

const TAG = 'SettingsContent'

interface ThemeOption {
  label: string
  value: string
}

@Component
export struct SettingsContent {
  @State settings: AppSettingsData = new AppSettingsData()
  private dataService: DataService = DataService.getInstance()
  private themeOptions: ThemeOption[] = [
    { label: '跟随系统', value: 'system' },
    { label: '深色模式', value: 'dark' },
    { label: '浅色模式', value: 'light' },
    { label: '自定义', value: 'custom' }
  ]
  private colorOptions: string[] = ['#007DFF', '#FF3B30', '#34C759', '#FF9500', '#AF52DE', '#5AC8FA']

  aboutToAppear(): void {
    this.settings = this.dataService.getSettings()
  }

  updateSetting(): void {
    this.dataService.saveSettings(this.settings)
  }

  setThemeMode(mode: string): void {
    this.settings.themeMode = mode
    this.updateSetting()
  }

  setPrimaryColor(color: string): void {
    this.settings.primaryColor = color
    this.updateSetting()
  }

  build() {
    Column() {
      // Header
      Row() {
        Text('设置')
          .fontSize(18)
          .fontColor('#FFFFFF')
          .fontWeight(FontWeight.Bold)
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 8, bottom: 12 })

      Scroll() {
        Column() {
          // Section: 界面控制
          this.sectionHeader('界面控制')
          this.toggleRow('显示加号按钮', this.settings.plusButtonVisible, (val: boolean) => {
            this.settings.plusButtonVisible = val
            this.updateSetting()
          })

          // Divider
          this.divider()

          // Section: 主题与配色
          this.sectionHeader('主题与配色')
          Text('主题模式')
            .fontSize(14)
            .fontColor('rgba(255,255,255,0.7)')
            .padding({ left: 16, top: 8, bottom: 8 })
          Row() {
            ForEach(this.themeOptions, (opt: ThemeOption) => {
              Column() {
                Text(opt.label)
                  .fontSize(12)
                  .fontColor(this.settings.themeMode === opt.value ? '#007DFF' : 'rgba(255,255,255,0.6)')
              }
              .padding({ left: 12, right: 12, top: 6, bottom: 6 })
              .backgroundColor(this.settings.themeMode === opt.value ? 'rgba(0,125,255,0.2)' : 'rgba(255,255,255,0.06)')
              .borderRadius(16)
              .onClick(() => { this.setThemeMode(opt.value) })
            }, (opt: ThemeOption) => opt.value)
          }
          .padding({ left: 16, right: 16 })
          .width('100%')

          Text('主题色')
            .fontSize(14)
            .fontColor('rgba(255,255,255,0.7)')
            .padding({ left: 16, top: 12, bottom: 8 })
          Row() {
            ForEach(this.colorOptions, (color: string) => {
              Column()
                .width(28).height(28)
                .borderRadius(14)
                .backgroundColor(color)
                .border({
                  width: this.settings.primaryColor === color ? 3 : 1,
                  color: this.settings.primaryColor === color ? '#FFFFFF' : 'rgba(255,255,255,0.2)'
                })
                .margin({ right: 10 })
                .onClick(() => { this.setPrimaryColor(color) })
            }, (color: string) => color)
          }
          .padding({ left: 16, right: 16 })
          .width('100%')

          this.divider()

          // Section: 播放设置
          this.sectionHeader('播放设置')
          this.toggleRow('显示歌词', this.settings.showLyrics, (val: boolean) => {
            this.settings.showLyrics = val
            this.updateSetting()
          })
          this.toggleRow('通知栏控制', this.settings.enableNotification, (val: boolean) => {
            this.settings.enableNotification = val
            this.updateSetting()
          })
          this.toggleRow('后台播放', this.settings.backgroundPlayback, (val: boolean) => {
            this.settings.backgroundPlayback = val
            this.updateSetting()
          })

          this.divider()

          // Section: 音效设置
          this.sectionHeader('音效设置')
          this.toggleRow('均衡器', this.settings.eqEnabled, (val: boolean) => {
            this.settings.eqEnabled = val
            this.updateSetting()
          })

          Row() {
            Text('音量增益')
              .fontSize(14)
              .fontColor('rgba(255,255,255,0.7)')
            Blank()
            Text(this.settings.volumeGain + ' dB')
              .fontSize(13)
              .fontColor('rgba(255,255,255,0.4)')
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
            .selectedColor('#007DFF')
            .trackColor('rgba(255,255,255,0.15)')
            .onChange((value: number) => {
              this.settings.volumeGain = value - 20
              this.updateSetting()
            })

          Row() {
            Text('播放速度')
              .fontSize(14)
              .fontColor('rgba(255,255,255,0.7)')
            Blank()
            Text(this.settings.playSpeed + 'x')
              .fontSize(13)
              .fontColor('rgba(255,255,255,0.4)')
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
            .selectedColor('#007DFF')
            .trackColor('rgba(255,255,255,0.15)')
            .onChange((value: number) => {
              this.settings.playSpeed = 0.5 + value / 100
              this.updateSetting()
            })

          Row() {
            Text('音效增强')
              .fontSize(14)
              .fontColor('rgba(255,255,255,0.7)')
            Blank()
            Text(this.settings.audioEffect === 'none' ? '关闭' : this.settings.audioEffect)
              .fontSize(13)
              .fontColor('rgba(255,255,255,0.4)')
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 12, bottom: 8 })
          Flex({ wrap: FlexWrap.Wrap }) {
            ForEach(['none', 'pop', 'rock', 'classical', 'jazz', 'bass'], (effect: string) => {
              Column() {
                Text(this.getEffectLabel(effect))
                  .fontSize(11)
                  .fontColor(this.settings.audioEffect === effect ? '#007DFF' : 'rgba(255,255,255,0.5)')
              }
              .padding({ left: 8, right: 8, top: 4, bottom: 4 })
              .backgroundColor(this.settings.audioEffect === effect ? 'rgba(0,125,255,0.2)' : 'rgba(255,255,255,0.05)')
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

          // Bottom spacer
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
      .fontColor('rgba(0,125,255,0.7)')
      .fontWeight(FontWeight.Medium)
      .width('100%')
      .padding({ left: 16, right: 16, top: 16, bottom: 4 })
  }

  @Builder
  divider(): void {
    Column()
      .width('100%')
      .height(1)
      .backgroundColor('rgba(255,255,255,0.06)')
      .margin({ top: 8, bottom: 4 })
  }

  @Builder
  toggleRow(label: string, checked: boolean, onChange: (val: boolean) => void): void {
    Row() {
      Text(label)
        .fontSize(14)
        .fontColor('rgba(255,255,255,0.7)')
      Blank()
      Toggle({ type: ToggleType.Switch, isOn: checked })
        .onChange((isOn: boolean) => {
          onChange(isOn)
        })
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 8, bottom: 8 })
    .alignItems(VerticalAlign.Center)
  }
}
