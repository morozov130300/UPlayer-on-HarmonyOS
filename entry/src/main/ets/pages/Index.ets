@Entry
@Component
struct MainPage {
  @State currentIndex: number = 0
  private tabsController: TabsController = new TabsController()

  @Builder
  tabBuilder(index: number, name: string, icon: Resource) {
    Column() {
      Image(icon)
        .width(20)
        .height(20)
        .fillColor(this.currentIndex === index ? '#FFFFFF' : '#666666')

      Text(name)
        .fontSize(11)
        .fontColor(this.currentIndex === index ? '#FFFFFF' : '#666666')
        .margin({ top: 2 })
    }
    .width('100%')
    .height(40)
    .justifyContent(FlexAlign.Center)
    .borderRadius(20)
    .backgroundColor(this.currentIndex === index ? '#007DFF' : 'transparent')
    .margin({ left: 4, right: 4 })
  }

  build() {
    Column() {
      Tabs({ barPosition: BarPosition.End, controller: this.tabsController }) {
        TabContent() {
          Text('首页')
        }
        .tabBar(this.tabBuilder(0, '首页', $r('app.media.ic_public_home')))

        TabContent() {
          Text('列表')
        }
        .tabBar(this.tabBuilder(1, '列表', $r('app.media.ic_public_view_list')))

        TabContent() {
          Text('设置')
        }
        .tabBar(this.tabBuilder(2, '设置', $r('app.media.ic_public_settings')))
      }
      .width('75%')
      .padding({ left: 16, right: 16, bottom: 5 })
    }
    .width('100%')
    .height('100%')
  }
}
