@Entry
@Component
struct MainPage {
  @State currentIndex: number = 0
  @State indicatorOffset: number = 16
  @State greetingTitle: string = "加载中……"
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
        this.tabItem(1, '歌单', $r('app.media.ic_public_view_list'))
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

  aboutToAppear(): void {
    this.updateGreeting()
  }

  updateGreeting() {
    const now = new Date()
    const hour = now.getHours()
    if (hour >= 5 && hour < 9) {
      this.greetingTitle = "早上好"
    } else if (hour >= 9 && hour < 12) {
      this.greetingTitle = "上午好"
    } else if (hour >= 12 && hour < 14) {
      this.greetingTitle = "中午好"
    } else if (hour >= 14 && hour < 18) {
      this.greetingTitle = "下午好"
    } else if (hour >= 18 && hour < 24) {
      this.greetingTitle = "晚上好"
    } else {
      this.greetingTitle = "夜深了"
    }
  }

  @Builder
  playControlButton() {
    Row() {
      Text('▶')
        .fontSize(14)
        .fontColor('#FFFFFF')
      Text('播控中心')
        .fontSize(14)
        .fontColor('#FFFFFF')
        .margin({ left: 6 })
    }
    .height(40)
    .borderRadius(20)
    .backgroundColor('#007DFF')
    .padding({ left: 16, right: 16 })
    .position({ bottom: 10, right: 16 })
    .onClick(() => {
      // TODO: 跳转播控页面
    })
  }

  build() {
    Stack() {
      Column() {
        // 内容区域
        Stack() {
          //主页标题栏问候语
          if (this.currentIndex === 0) {
            Column() {
              Text(this.greetingTitle)
                .fontWeight(FontWeight.Bolder)
                .fontSize(28)
                .fontColor('#FF000000')
            }
            .width('100%')
            .height('100%')
            .justifyContent(FlexAlign.Start)
            .alignItems(HorizontalAlign.Start)
            .padding({ top: 24, left: 16 })

          } else if (this.currentIndex === 1) {
            //歌单页内容
          } else {
            //设置页内容
          }
        }
        .layoutWeight(1)

        // 自定义底部导航栏
        this.customTabBar()
      }
      .width('100%')
      .height('100%')

      // 浮动播控中心
      this.playControlButton()
    }
    .width('100%')
    .height('100%')
  }
}
