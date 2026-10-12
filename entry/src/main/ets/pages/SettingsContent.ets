import { deviceInfo } from '@kit.BasicServicesKit'
import { AppStorageKeyConstants } from '../common/constants/AppStorageKeyConstants'
import { ColorHelper } from '../common/utils/ColorHelper'
import { isDarkThemeEffective } from '../common/utils/ThemeUtil'

const KEY_PRIMARY_COLOR = 'uplayer_primary_color'

interface SettingCategory {
  title: string
  description: string
  route: string
}

@Component
export struct SettingsContent {
  topContentPadding: number = 0
  // 顶部标题带高度（Index 传入，与主页问候语带同源）：标题在带内垂直居中，几何与主页一致
  topBandHeight: number = 72
  // 底部让位原始输入（Index 传入），页内自算 bottomOverlayInset() 以实时跟随显示大小
  bottomSafeHeight: number = 0
  smallBreakpoint: boolean = false
  private isPC: boolean = deviceInfo.deviceType === '2in1'
  @StorageLink('uplayer_theme_mode') themeMode: string = 'system'
  @StorageLink(KEY_PRIMARY_COLOR) primaryColor: string = '#007DFF'
  @StorageLink(AppStorageKeyConstants.KEY_TITLE_BUTTON_WIDTH) titleButtonWidth: number = 0
  @StorageLink('uplayer_font_size_scale') fontSizeScale: number = 1.0
  @StorageLink('uplayer_display_size_scale') displaySizeScale: number = 1.0
  private categories: SettingCategory[] = [
    { title: '定制', description: '界面布局、主题配色等个性化选项', route: 'customize' },
    { title: '播放', description: '播放速度、歌词显示、淡入淡出', route: 'playback' },
    { title: '音效', description: '均衡器开关与频段调节', route: 'audio' },
    { title: '关于', description: '软件信息、仓库地址与联系方式', route: 'about' }
  ]

  private scaledSize(size: number): number {
    return Math.round(size * this.displaySizeScale)
  }

  // 底部让位（原由 Index 算好传入，改为页内自算跟随显示大小）：
  // 小屏 128≈56(tab)+28(margin)+40(播控)+4；大屏 88≈28+56+4
  private bottomOverlayInset(): number {
    return this.scaledSize(this.smallBreakpoint ? 128 : 88) + this.bottomSafeHeight
  }

  private isDark(): boolean {
    return isDarkThemeEffective(this.themeMode)
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
      .height(this.topContentPadding + this.topBandHeight)
      .padding({
        left: 20,
        right: this.isPC ? Math.max(this.titleButtonWidth, 140) + 12 : 8,
        top: this.topContentPadding
      })
      .alignItems(VerticalAlign.Center)

      Column({ space: this.scaledSize(6) }) {
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
            top: this.scaledSize(10), bottom: this.scaledSize(10)
          })
          .backgroundColor(ColorHelper.hexToRgba(this.primaryColor, 0.04))
          .borderRadius(this.scaledSize(10))
          .constraintSize({ minHeight: this.scaledSize(52), maxHeight: this.scaledSize(120) })
          .alignItems(HorizontalAlign.Start)
          .onClick(() => { this.onCategoryClick(cat) })
        }, (cat: SettingCategory) => cat.route)
      }
      .width('100%')
      .margin({ top: this.scaledSize(6) })
      .padding({
        left: this.scaledSize(12), right: this.scaledSize(12),
        bottom: this.bottomOverlayInset()
      })
    }
    .width('100%')
    .height('100%')
    // 背景使用预设纯色（明暗自适应），不应用任何玻璃/模糊/透明度效果
    .backgroundColor($r('app.color.page_background_sm'))
  }
}
