import display from '@ohos.display'
import { curves } from '@kit.ArkUI'
import { AppStorageKeyConstants } from '../common/constants/AppStorageKeyConstants'

@Entry
@Component
struct MainPage {
  // 状态变量
  @State currentIndex: number = 0
  @State indicatorOffset: number = 4
  @State greetingTitle: string = "加载中……"
  @State greetingOpacity: number = 0
  @State greetingOffset: number = 20
  @State isPlaying: boolean = false
  @State rotationAngle: number = 0
  @State isGlowing: boolean = false
  @State hasAlbumCover: boolean = false
  @State breakpoint: string = 'md' // 屏幕断点：sm/md/lg/xl/xxl
  @StorageLink(AppStorageKeyConstants.KEY_TOP_HEIGHT) topSafeHeight: number = 0
  @StorageLink(AppStorageKeyConstants.KEY_BOTTOM_HEIGHT) bottomSafeHeight: number = 0
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
      .backgroundColor('rgba(255,255,255,0.06)')
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
        .scale({
          x: this.currentIndex === index ? 1.15 : 1.0,
          y: this.currentIndex === index ? 1.15 : 1.0
        })

      Text(name)
        .fontSize(9)
        .fontColor(this.currentIndex === index ? '#FFFFFF' : '#666666')
        .margin({ top: 2 })
    }
    .width(this.tabWidth)
    .height(40)
    .justifyContent(FlexAlign.Center)
    .onClick(() => {
      this.getUIContext()?.animateTo({ duration: 200, curve: Curve.EaseInOut }, () => {
        this.currentIndex = index
      })
      this.tabsController.changeIndex(index)
      this.updateIndicatorOffset(index)
    })
  }

  // 更新指示器偏移量（带动画）
  updateIndicatorOffset(index: number) {
    this.getUIContext()?.animateTo({
      curve: curves.springMotion(0.4, 0.8)
    }, () => {
      this.indicatorOffset = this.indicatorInset + index * (this.tabWidth + this.tabGap)
    })
  }

  // 页面即将显示时的初始化
  aboutToAppear(): void {
    this.updateGreeting()
    this.initBreakpoint()
    this.getUIContext()?.animateTo({ duration: 800, curve: Curve.EaseOut }, () => {
      this.greetingOpacity = 1
      this.greetingOffset = 0
    })
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
        .onClick(() => {
          this.getUIContext().getRouter().pushUrl({ url: 'pages/MusicPlayer' })
        })

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
    .shadow({
      radius: this.isGlowing ? 60 : 50,
      color: this.isGlowing ? '#66007DFF' : $r('app.color.shadow_color'),
      offsetY: 5
    })
  }

  // 切换播放/暂停状态
  togglePlay() {
    this.isPlaying = !this.isPlaying
    if (this.isPlaying) {
      // 播放：封面弹簧加速启动
      this.getUIContext()?.animateTo({ duration: 400, curve: curves.springMotion(0.3, 0.7) }, () => {
        this.rotationAngle += 30
      })
      setTimeout(() => {
        this.startRotation()
      }, 400)
      this.getUIContext()?.animateTo({ duration: 800, curve: Curve.EaseInOut }, () => {
        this.isGlowing = true
      })
    } else {
      // 暂停：封面减速停止 + 光晕消失
      this.stopRotation()
      this.getUIContext()?.animateTo({ duration: 500, curve: Curve.EaseInOut }, () => {
        this.isGlowing = false
      })
    }
  }

  // 开始旋转动画（每8秒一圈，平滑连续）
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

  // 页面转场动画：保持静止并微微缩小，制造景深感
  pageTransition() {
    PageTransitionEnter({ duration: 400 })
      .translate({ x: 0, y: 0 })
      .scale({ x: 0.92, y: 0.92 })
      .opacity(0.6)
    PageTransitionExit({ duration: 400 })
      .translate({ x: 0, y: 0 })
      .scale({ x: 0.92, y: 0.92 })
      .opacity(0.6)
  }

  // 主页面布局
  build() {
    Stack() {
      Column() {
        // 内容区域
        Stack() {
          //主页标题栏问候语
          Stack() {
            // 动态环境光背景
            Column()
              .width('140%')
              .aspectRatio(1)
              .borderRadius('50%')
              .position({ top: -80, left: -60 })
              .radialGradient({
                center: ['50%', '50%'],
                radius: '80%',
                colors: [
                  ['rgba(0,125,255,0.04)', 0.0],
                  ['rgba(0,125,255,0.01)', 0.6],
                  ['rgba(0,125,255,0)', 1.0],
                ]
              })

            Column() {
              Text(this.greetingTitle)
                .fontWeight(FontWeight.Bolder)
                .fontSize(28)
                .fontColor($r('app.color.text_primary'))
                .opacity(this.greetingOpacity)
                .translate({ y: this.greetingOffset })
            }
            .width('100%')
            .height('100%')
            .justifyContent(FlexAlign.Start)
            .alignItems(HorizontalAlign.Start)
            .padding({ top: 16 + this.topSafeHeight, left: 16 })
            .opacity(this.currentIndex === 0 ? 1.0 : 0)
            .animation({ duration: 250, curve: Curve.EaseInOut })
          }
          .width('100%')
          .height('100%')

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
          .padding({ bottom: this.bottomSafeHeight })
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
          .padding({ left: 16, right: 16, bottom: this.bottomSafeHeight })
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
