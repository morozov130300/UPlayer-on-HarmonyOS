import { router } from '@kit.ArkUI'
import { DataService, AppSettingsData } from '../service/DataService'
import { AppStorageKeyConstants } from '../common/constants/AppStorageKeyConstants'
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
  private categories: SettingCategory[] = [
    { title: '定制条目', description: '界面布局、主题配色等个性化选项', route: 'customize' },
    { title: '播放设置', description: '播放速度、歌词显示、通知栏控制', route: 'playback' },
    { title: '音效设置', description: '均衡器开关与频段调节', route: 'audio' }
  ]

  aboutToAppear(): void {
    this.settings = this.dataService.getSettings()
  }

  onCategoryClick(category: SettingCategory): void {
    router.pushUrl({
      url: 'pages/SettingsDetailPage',
      params: { category: category.route }
    })
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

      Column({ space: 12 }) {
        ForEach(this.categories, (cat: SettingCategory) => {
          Column() {
            Text(cat.title)
              .fontSize(17)
              .fontColor($r('app.color.text_primary'))
              .fontWeight(FontWeight.Medium)
              .width('100%')
            Text(cat.description)
              .fontSize(13)
              .fontColor($r('app.color.text_twenty_color'))
              .width('100%')
              .margin({ top: 4 })
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 18, bottom: 18 })
          .backgroundColor($r('app.color.page_background_sm'))
          .borderRadius(12)
          .shadow({ radius: 4, color: $r('app.color.shadow_color'), offsetY: 1 })
          .alignItems(HorizontalAlign.Start)
          .onClick(() => { this.onCategoryClick(cat) })
        }, (cat: SettingCategory) => cat.route)
      }
      .width('100%')
      .padding({ left: 12, right: 12 })
    }
    .width('100%')
    .height('100%')
  }
}
