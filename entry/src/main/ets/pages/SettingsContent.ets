import { curves, uiAppearance } from '@kit.ArkUI'
import { DataService, AppSettingsData } from '../service/DataService'
import { AppStorageKeyConstants } from '../common/constants/AppStorageKeyConstants'
import { ColorHelper } from '../common/utils/ColorHelper'
import Logger from '../common/utils/Logger'

const TAG = 'SettingsContent'
const KEY_PRIMARY_COLOR = 'uplayer_primary_color'

interface SettingCategory {
  title: string
  description: string
  route: string
}

@Component
export struct SettingsContent {
  @State settings: AppSettingsData = new AppSettingsData()
  @StorageLink(KEY_PRIMARY_COLOR) primaryColor: string = '#007DFF'
  @StorageLink(AppStorageKeyConstants.KEY_TITLE_BUTTON_WIDTH) titleButtonWidth: number = 0
  @StorageLink('uplayer_font_size_scale') fontSizeScale: number = 1.0
  @StorageLink('uplayer_display_size_scale') displaySizeScale: number = 1.0
  private dataService: DataService = DataService.getInstance()
  private categories: SettingCategory[] = [
    { title: '定制', description: '界面布局、主题配色等个性化选项', route: 'customize' },
    { title: '播放', description: '播放速度、歌词显示、淡入淡出', route: 'playback' },
    { title: '音效', description: '均衡器开关与频段调节', route: 'audio' }
  ]

  private scaledSize(size: number): number {
    return Math.round(size * this.displaySizeScale)
  }

  aboutToAppear(): void {
    this.settings = this.dataService.getSettings()
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
    return this.isDark() ? '#FFFFFF' : ColorHelper.darken(this.primaryColor, 0.3)
  }

  private settingSubTextColor(): ResourceColor {
    return this.isDark() ? ColorHelper.hexWithAlpha('#FFFFFF', '88') : ColorHelper.hexWithAlpha(this.primaryColor, '80')
  }

  onCategoryClick(category: SettingCategory): void {
    this.getUIContext()?.getRouter().pushUrl({
      url: 'pages/SettingsDetailPage',
      params: { category: category.route }
    })
  }

  build() {
    Column() {
      Row() {
        Text('设置')
          .fontSize(Math.round(18 * this.fontSizeScale))
          .fontColor(this.settingTextColor())
          .fontWeight(FontWeight.Bold)
      }
      .width('100%')
      .padding({
        left: this.scaledSize(16), right: this.titleButtonWidth + this.scaledSize(12),
        top: this.scaledSize(8), bottom: this.scaledSize(10)
      })

      Column({ space: this.scaledSize(8) }) {
        ForEach(this.categories, (cat: SettingCategory) => {
          Column() {
            Text(cat.title)
              .fontSize(Math.round(16 * this.fontSizeScale))
              .fontColor(this.settingTextColor())
              .fontWeight(FontWeight.Medium)
              .width('100%')
            Text(cat.description)
              .fontSize(Math.round(12 * this.fontSizeScale))
              .fontColor(this.settingSubTextColor())
              .width('100%')
              .margin({ top: this.scaledSize(3) })
          }
          .width('100%')
          .padding({
            left: this.scaledSize(16), right: this.scaledSize(16),
            top: this.scaledSize(13), bottom: this.scaledSize(13)
          })
          .backgroundColor(ColorHelper.hexToRgba(this.primaryColor, 0.04))
          .borderRadius(this.scaledSize(10))
          .constraintSize({ minHeight: this.scaledSize(64), maxHeight: this.scaledSize(120) })
          .alignItems(HorizontalAlign.Start)
          .onClick(() => { this.onCategoryClick(cat) })
        }, (cat: SettingCategory) => cat.route)
      }
      .width('100%')
      .padding({ left: this.scaledSize(12), right: this.scaledSize(12) })
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_background_other'))
  }
}
