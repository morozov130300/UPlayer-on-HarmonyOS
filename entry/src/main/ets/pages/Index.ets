import display from '@ohos.display'

@Entry
@Component
struct MainPage {
  // 状态变量
  @State currentIndex: number = 0
  @State indicatorOffset: number = 4
  @State greetingTitle: string = "加载中……"
  @State isPlaying: boolean = false
  @State rotationAngle: number = 0
  @State hasAlbumCover: boolean = false
  @State breakpoint: string = 'md' // 屏幕断点：sm/md/lg/xl/xxl
  // 私有属性
  private tabsController: TabsController = new TabsController()
  private tabWidth: number = 100
  private tabGap: number = 8
  private indicatorInset: number = 4
  private rotationTimer: number = -1

  // 自定义底部导航栏（居中）
  @Builder
  customTabBar() {
    Stack({ alignContent: Alignment.BottomStart }) {
      // 滑动的蓝色指示器（比Tab窄，与胶囊边缘保留间距）
      // 使用径向渐变模拟中间凸起、四周凹陷的立体效果
      Row()
        .width(this.tabWidth - 2 * this.indicatorInset) // 指示器宽度 = 标签宽度 - 两侧内边距
        .height(36)
        .borderRadius(18)
        .alignItems(VerticalAlign.Center)
        .margin({ left: this.indicatorOffset, bottom: 12, })
        .shadow({
          radius: 6,
          color: $r('app.color.shadow_color'),
          offsetY: 4,
          offsetX: 0
        })
        .radialGradient({
          center: ['50%', '50%'], // 径向渐变中心
          radius: '75%', // 渐变半径覆盖整体
          colors: [
            ['#ed007dff', 0.0], // 中心高亮 → 凸起感
            ['#007DFF', 0.5], // 主体蓝色
            ['#0044AA', 1.0],// 边缘加深 → 凹陷感
          ]
        })

      // Tab
      Row({ space: this.tabGap }) {
        this.tabItem(0, '首页', $r('app.media.ic_public_home'))
        this.tabItem(1, '歌单', $r('app.media.ic_public_view_list'))
        this.tabItem(2, '设置', $r('app.media.ic_public_settings'))
      }
      .margin({ bottom: 10 })
      .height(40)
      .borderRadius(20)
      .shadow({ radius: 50, color: $r('app.color.shadow_color'), offsetY: 10 })

    }
    .alignSelf(ItemAlign.Center)
    .height(60)
  }

  // 单个Tab项（图标 + 文字）
  @Builder
  tabItem(index: number, name: string, icon: Resource) {
    Column() {
      Image(icon)
        .height(18)
        .fillColor(this.currentIndex === index ? '#FFFFFF' : '#666666')

      Text(name)
        .fontSize(9)
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

  // 更新指示器偏移量（带动画）
  updateIndicatorOffset(index: number) {
    this.getUIContext()?.animateTo({
      duration: 300,
      curve: Curve.EaseInOut
    }, () => {
      this.indicatorOffset = this.indicatorInset + index * (this.tabWidth + this.tabGap)
    })
  }

  // 页面即将显示时的初始化
  aboutToAppear(): void {
    this.updateGreeting()
    this.initBreakpoint()
  }

  // 获取屏幕宽度（vp）并计算断点
  initBreakpoint() {
    try {
      const displayInfo = display.getDefaultDisplaySync()
      this.updateBreakpoint(displayInfo.width)

      display.on('change', () => {
        try {
          const newDisplayInfo = display.getDefaultDisplaySync()
          this.updateBreakpoint(newDisplayInfo.width)
        } catch (err) {
          console.error('Failed to get display info', JSON.stringify(err))
        }
      })
    } catch (err) {
      console.error('Failed to init breakpoint', JSON.stringify(err))
    }
  }

  // 根据屏幕像素宽度计算断点
  updateBreakpoint(pxWidth: number) {
    const vpWidth = this.getUIContext().px2vp(pxWidth)
    if (vpWidth < 320) {
      this.breakpoint = 'sm'
    } else if (vpWidth < 600) {
      this.breakpoint = 'md'
    } else if (vpWidth < 840) {
      this.breakpoint = 'lg'
    } else if (vpWidth < 1280) {
      this.breakpoint = 'xl'
    } else {
      this.breakpoint = 'xxl'
    }
    console.log('breakpoint:', this.breakpoint)
  }

  // 根据时段更新问候语
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

  //播控条
  @Builder
  playerControl() {
    Row({ space: 20 }) {
      // 专辑封面缩略图（圆形，播放时缓慢旋转）
      Image($r('app.media.ic_public_music'))
        .width(25)
        .height(25)
        .borderRadius(16)
        .rotate({ angle: this.rotationAngle })
        .backgroundColor('#00ffffff')
        .fillColor($r('app.color.player_icon_color'))

      Blank()

      // 上一曲
      Image($r('app.media.ic_public_play_last'))
        .width(20)
        .height(20)
        .fillColor($r('app.color.player_icon_color'))

      // 播放/暂停
      Image(this.isPlaying ? $r('app.media.ic_public_pause') : $r('app.media.ic_public_play'))
        .width(20)
        .height(20)
        .fillColor($r('app.color.player_icon_color'))
        .onClick(() => {
          this.togglePlay()
        })

      // 下一曲
      Image($r('app.media.ic_public_play_next'))
        .width(20)
        .height(20)
        .fillColor($r('app.color.player_icon_color'))
    }
    .height(40)
    .padding({
      left: 6,
      right: 14,
      top: 4,
      bottom: 4
    })
    .backgroundColor($r('app.color.player_bg_color'))
    .borderRadius(20)
    .shadow({ radius: 50, color: $r('app.color.shadow_color'), offsetY: 5 })
  }

  // 切换播放/暂停状态
  togglePlay() {
    this.isPlaying = !this.isPlaying
    if (this.isPlaying) {
      this.startRotation()
    } else {
      this.stopRotation()
    }
  }

  // 开始旋转动画（每8秒一圈）
  startRotation() {
    this.stopRotation()
    this.rotationTimer = setInterval(() => {
      this.rotationAngle = (this.rotationAngle + 2.25) % 360
    }, 50)
  }

  // 停止旋转动画（清理定时器）
  stopRotation() {
    if (this.rotationTimer !== -1) {
      clearInterval(this.rotationTimer)
      this.rotationTimer = -1
    }
  }

  // 页面销毁前的清理
  aboutToDisappear(): void {
    this.stopRotation()
  }

  // 主页面布局
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
                .fontColor($r('app.color.text_primary'))
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

        if (this.breakpoint === 'sm' || this.breakpoint === 'md') {

          // 小屏：播控条 + 导航栏，竖直居中摞起来
          Column() {
            // 播控条
            this.playerControl()

            // 自定义底部导航栏
            this.customTabBar()
          }
          .alignItems(HorizontalAlign.Center)
          .width('100%')
          .padding({ bottom: 8 })
        } else {

          // 大屏：播控条 + 导航栏，水平横排
          Row() {
            // 自定义底部导航栏
            this.customTabBar()

            Blank()

            // 播控条
            this.playerControl()

          }
          .width("100%")
          .padding({ left: 16, right: 16, bottom: 8 })
          .alignItems(VerticalAlign.Center)

        }

      }
      .width('100%')
      .height('100%')

    }
    .width('100%')
    .height('100%')
  }
}
