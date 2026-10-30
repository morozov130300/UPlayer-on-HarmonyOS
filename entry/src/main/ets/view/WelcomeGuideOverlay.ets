// 首次启动欢迎页浮层：全屏覆盖在主界面之上（主界面已在底下完成加载），
// Swiper 轮播 2 页（欢迎 / 导库引导），点「开始使用」或右上角「跳过」结束，
// 由宿主（Index）落「已看过」标记并卸载本浮层。
import { ColorHelper } from '../common/utils/ColorHelper'

// 单页配置：icon 为图标资源，title/description 为文案
class WelcomePage {
  icon: Resource = $r('app.media.ic_public_music')
  title: string = ''
  description: string = ''
}

@Component
export struct WelcomeGuideOverlay {
  @Prop primaryColor: string = '#007DFF'
  @StorageLink('uplayer_font_size_scale') fontSizeScale: number = 1.0
  @StorageLink('uplayer_display_size_scale') displaySizeScale: number = 1.0
  @State currentIndex: number = 0
  // 走完最后一步或跳过时回调：宿主负责落「已看过」标记并卸载浮层
  onFinish: () => void = () => {
  }
  private pages: WelcomePage[] = []
  private swiperController: SwiperController = new SwiperController()

  aboutToAppear(): void {
    const p1: WelcomePage = new WelcomePage()
    p1.icon = $r('app.media.ic_public_music')
    p1.title = '欢迎使用 UPlayer'
    p1.description = '一款简洁的本地音乐播放器，专注播放、歌单与音效体验。'
    const p2: WelcomePage = new WelcomePage()
    p2.icon = $r('app.media.ic_public_upload')
    p2.title = '导入你的音乐'
    p2.description = '点击主界面的加号即可导入本地歌曲，导入后支持自动匹配歌词、自定义歌单与多种排序方式。'
    this.pages = [p1, p2]
  }

  private scaledFont(size: number): number {
    return Math.round(size * this.fontSizeScale)
  }

  private scaledSize(size: number): number {
    return Math.round(size * this.displaySizeScale)
  }

  private isLastPage(): boolean {
    return this.currentIndex >= this.pages.length - 1
  }

  private goNext(): void {
    if (this.isLastPage()) {
      this.onFinish()
      return
    }
    this.swiperController.showNext()
  }

  build() {
    Stack({ alignContent: Alignment.TopEnd }) {
      Column() {
        Swiper(this.swiperController) {
          ForEach(this.pages, (page: WelcomePage) => {
            Column({ space: this.scaledSize(20) }) {
              Column() {
                Image(page.icon)
                  .width(this.scaledSize(56))
                  .height(this.scaledSize(56))
                  .fillColor(this.primaryColor)
              }
              .width(this.scaledSize(112))
              .height(this.scaledSize(112))
              .justifyContent(FlexAlign.Center)
              .borderRadius(this.scaledSize(56))
              .backgroundColor(ColorHelper.hexToRgba(this.primaryColor, 0.1))

              Text(page.title)
                .fontSize(this.scaledFont(24))
                .fontWeight(FontWeight.Bold)
                .fontColor($r('app.color.text_primary'))
                .textAlign(TextAlign.Center)

              Text(page.description)
                .fontSize(this.scaledFont(14))
                .fontColor($r('app.color.text_sixty_color'))
                .textAlign(TextAlign.Center)
                .lineHeight(this.scaledFont(22))
                .padding({
                  left: this.scaledSize(32),
                  right: this.scaledSize(32)
                })
            }
            .width('100%')
            .layoutWeight(1)
            .justifyContent(FlexAlign.Center)
          }, (page: WelcomePage, index: number) => index.toString())
        }
        .index($$this.currentIndex)
        .loop(false)
        .indicator(false)
        .layoutWeight(1)

        // 底部：圆点指示器 + 下一步/开始使用按钮
        Row({ space: this.scaledSize(8) }) {
          ForEach(this.pages, (page: WelcomePage, index: number) => {
            Circle()
              .width(this.scaledSize(index === this.currentIndex ? 8 : 6))
              .height(this.scaledSize(index === this.currentIndex ? 8 : 6))
              .fill(index === this.currentIndex ? this.primaryColor : $r('app.color.list_divider'))
          }, (page: WelcomePage, index: number) => index.toString())
        }
        .margin({ bottom: this.scaledSize(24) })

        Button(this.isLastPage() ? '开始使用' : '下一步')
          .fontSize(this.scaledFont(16))
          .fontColor(Color.White)
          .fontWeight(FontWeight.Medium)
          .height(this.scaledSize(44))
          .padding({
            left: this.scaledSize(48),
            right: this.scaledSize(48)
          })
          .backgroundColor(this.primaryColor)
          .borderRadius(this.scaledSize(22))
          .margin({ bottom: this.scaledSize(48) })
          .onClick((): void => {
            this.goNext()
          })
      }
      .width('100%')
      .height('100%')

      // 右上角跳过
      Button('跳过')
        .fontSize(this.scaledFont(14))
        .fontColor($r('app.color.text_sixty_color'))
        .backgroundColor(Color.Transparent)
        .margin(this.scaledSize(16))
        .onClick((): void => {
          this.onFinish()
        })
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_background_sm'))
  }
}
