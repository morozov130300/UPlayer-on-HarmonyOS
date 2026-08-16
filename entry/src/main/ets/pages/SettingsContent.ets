import { curves, uiAppearance } from '@kit.ArkUI'
import { DataService, AppSettingsData } from '../service/DataService'
import { AppStorageKeyConstants } from '../common/constants/AppStorageKeyConstants'
import { ColorHelper } from '../common/utils/ColorHelper'
import { WindowControlsComponent } from '../view/WindowControlsComponent'
import { deviceInfo } from '@kit.BasicServicesKit'
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
  @StorageLink(AppStorageKeyConstants.KEY_TOP_HEIGHT) topSafeHeight: number = 0
  private dataService: DataService = DataService.getInstance()
  private isPC: boolean = deviceInfo.deviceType === '2in1'
  private categories: SettingCategory[] = [
    { title: '定制条目', description: '界面布局、主题配色等个性化选项', route: 'customize' },
    { title: '播放设置', description: '播放速度、歌词显示、通知栏控制', route: 'playback' },
    { title: '音效设置', description: '均衡器开关与频段调节', route: 'audio' }
  ]

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
          .fontSize(18)
          .fontColor(this.settingTextColor())
          .fontWeight(FontWeight.Bold)
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: this.topSafeHeight + 8, bottom: 10 })

      Column({ space: 8 }) {
        ForEach(this.categories, (cat: SettingCategory) => {
          Column() {
            Text(cat.title)
              .fontSize(16)
              .fontColor(this.settingTextColor())
              .fontWeight(FontWeight.Medium)
              .width('100%')
            Text(cat.description)
              .fontSize(12)
              .fontColor(this.settingSubTextColor())
              .width('100%')
              .margin({ top: 3 })
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 13, bottom: 13 })
          .backgroundColor(ColorHelper.hexToRgba(this.primaryColor, 0.04))
          .borderRadius(10)
          .alignItems(HorizontalAlign.Start)
          .onClick(() => { this.onCategoryClick(cat) })
        }, (cat: SettingCategory) => cat.route)
      }
      .width('100%')
      .padding({ left: 12, right: 12 })
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_background_other'))
  }
}
