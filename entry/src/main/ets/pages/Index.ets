@Entry
@Component
struct MainPage {
  @State currentIndex: number = 0
  @State indicatorOffset: number = 16
  private tabsController: TabsController = new TabsController()
  private tabWidth: number = 100
  private tabGap: number = 8

  @Builder
  customTabBar() {
    Stack({ alignContent: Alignment.BottomStart }) {
      // 滑动的蓝色指示器
      Row()
        .width(this.tabWidth)
        .height(40)
        .borderRadius(20)
        .backgroundColor('#007DFF')
        .margin({ left: this.indicatorOffset, bottom: 10 })

      // Tab项
      Row({ space: this.tabGap }) {
        this.tabItem(0, '首页', $r('app.media.ic_public_home'))
        this.tabItem(1, '列表', $r('app.media.ic_public_view_list'))
        this.tabItem(2, '设置', $r('app.media.ic_public_settings'))
      }
      .margin({ left: 16, right: 16, bottom: 10 })
    }
    .width('100%')
    .height(60)
  }

  @Builder
  tabItem(index: number, name: string, icon: Resource) {
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
    .width(this.tabWidth)
    .height(40)
    .justifyContent(FlexAlign.Center)
    .onClick(() => {
      this.currentIndex = index
      this.tabsController.changeIndex(index)
      this.updateIndicatorOffset(index)
    })
  }

  updateIndicatorOffset(index: number) {
    animateTo({
      duration: 300,
      curve: Curve.EaseInOut
    }, () => {
      this.indicatorOffset = 16 + index * (this.tabWidth + this.tabGap)
    })
  }

  build() {
    Column() {
      // 内容区域
      Stack() {
        if (this.currentIndex === 0) {
          Text('首页内容')
        } else if (this.currentIndex === 1) {
          Text('列表内容')
        } else {
          Text('设置内容')
        }
      }
      .layoutWeight(1)

      // 自定义底部导航栏
      this.customTabBar()
    }
    .width('100%')
    .height('100%')
  }
}
