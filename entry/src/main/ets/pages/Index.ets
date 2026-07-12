@Entry
@Component
struct MainPage {
  @State currentIndex: number = 0
  private tabsController: TabsController = new TabsController()

  @Builder
  tabBuilder(index: number, name: string, icon: Resource) {
    Column() {
      Image(icon)
        .width(24)
        .height(24)
        .fillColor(this.currentIndex === index ? '#007DFF' : '#999999')

      Text(name)
        .fontSize(12)
        .fontColor(this.currentIndex === index ? '#007DFF' : '#999999')
        .margin({ top: 4 })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
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
    }
  }
}
