import display from '@ohos.display'
import { curves } from '@kit.ArkUI'
import { AppStorageKeyConstants } from '../common/constants/AppStorageKeyConstants'

@Entry
@Component
struct MainPage {
  /** 当前选中的 Tab 索引（0-首页 1-歌单 2-设置） */
  @State currentIndex: number = 0
  /** 底部导航蓝色指示器的水平偏移量 */
  @State indicatorOffset: number = 4
  /** 顶部问候语文字 */
  @State greetingTitle: string = "加载中……"
  /** 问候语透明度（用于入场动画） */
  @State greetingOpacity: number = 0
  /** 问候语 Y 偏移（用于入场动画） */
  @State greetingOffset: number = 20
  /** 是否正在播放（仅控制主页播控条图标，不关联实际播放） */
  @State isPlaying: boolean = false
  /** 封面旋转角度 */
  @State rotationAngle: number = 0
  /** 是否显示播放光晕效果 */
  @State isGlowing: boolean = false
  @State hasAlbumCover: boolean = false
  /** 屏幕断点：sm/md/lg/xl/xxl，控制响应式布局 */
  @State breakpoint: string = 'md'
  /** 顶部安全区高度（状态栏），从 AppStorage 同步 */
  @StorageLink(AppStorageKeyConstants.KEY_TOP_HEIGHT) topSafeHeight: number = 0
  /** 底部安全区高度（导航指示器），从 AppStorage 同步 */
  @StorageLink(AppStorageKeyConstants.KEY_BOTTOM_HEIGHT) bottomSafeHeight: number = 0

  /** Tab 控制器 */
  private tabsController: TabsController = new TabsController()
  /** 每个 Tab 的宽度（vp） */
  private tabWidth: number = 100
  /** Tab 之间的间距（vp） */
  private tabGap: number = 8
  /** 蓝色指示器与 Tab 边缘的内间距 */
  private indicatorInset: number = 4
  /** 封面旋转定时器 ID */
  private rotationTimer: number = -1

  /** 自定义底部导航栏（居中胶囊式，含滑动蓝色指示器） */
  @Builder
  customTabBar() {
    Stack({ alignContent: Alignment.BottomStart }) {
      /** 蓝色指示器：径向渐变模拟中间凸起边缘凹陷的立体效果 */
      Row()
        .width(this.tabWidth - 2 * this.indicatorInset)
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
          center: ['50%', '50%'],
          radius: '75%',
          colors: [
            ['#ed007dff', 0.0],
            ['#007DFF', 0.5],
            ['#0044AA', 1.0],
          ]
        })

      /** 三个 Tab */
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

  /** 单个 Tab 项：图标 + 文字，选中时放大且变白 */
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

  /** 更新指示器偏移（带动画：springMotion 弹性曲线） */
  updateIndicatorOffset(index: number) {
    this.getUIContext()?.animateTo({
      curve: curves.springMotion(0.4, 0.8)
    }, () => {
      this.indicatorOffset = this.indicatorInset + index * (this.tabWidth + this.tabGap)
    })
  }

  /** 页面初始化：问候语 → 断点检测 → 问候语入场动画 */
  aboutToAppear(): void {
    this.updateGreeting()
    this.initBreakpoint()
    this.getUIContext()?.animateTo({ duration: 800, curve: Curve.EaseOut }, () => {
      this.greetingOpacity = 1
      this.greetingOffset = 0
    })
  }

  /** 初始化屏幕断点监听（根据物理像素宽度计算） */
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

  /** 根据物理像素宽度设置断点：sm(<320) md(<600) lg(<840) xl(<1280) xxl */
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

  /** 根据当前时段更新顶部问候语 */
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

  /** ✅ 主页底部播控条：封面缩略图 + 上一曲 + 播放/暂停 + 下一曲 */
  @Builder
  playerControl() {
    Row({ space: 20 }) {
      /** 专辑封面缩略图（点击跳转播放器全屏页） */
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
      /** 上一曲 */
      Image($r('app.media.ic_public_play_last'))
        .width(20)
        .height(20)
        .fillColor($r('app.color.player_icon_color'))
      /** ✅ 播放/暂停按钮：未播放时显示三角（play），播放时显示两竖线（pause） */
      Image(this.isPlaying ? $r('app.media.ic_public_play') : $r('app.media.ic_public_pause'))
        .width(20)
        .height(20)
        .fillColor($r('app.color.player_icon_color'))
        .onClick(() => {
          this.togglePlay()
        })
      /** 下一曲 */
      Image($r('app.media.ic_public_play_next'))
        .width(20)
        .height(20)
        .fillColor($r('app.color.player_icon_color'))
    }
    .height(40)
    .padding({ left: 6, right: 14, top: 4, bottom: 4 })
    .backgroundColor($r('app.color.player_bg_color'))
    .borderRadius(20)
    .shadow({
      radius: this.isGlowing ? 60 : 50,
      color: this.isGlowing ? '#66007DFF' : $r('app.color.shadow_color'),
      offsetY: 5
    })
  }

  /** 切换播放/暂停状态（仅主页动画，不涉及真实音频播放） */
  togglePlay() {
    this.isPlaying = !this.isPlaying
    if (this.isPlaying) {
      /** 播放：封面先弹簧加速转30°，再持续匀速旋转，同时开启光晕 */
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
      /** 暂停：停止旋转，光晕渐隐 */
      this.stopRotation()
      this.getUIContext()?.animateTo({ duration: 500, curve: Curve.EaseInOut }, () => {
        this.isGlowing = false
      })
    }
  }

  /** 开始封面旋转定时器（每 50ms 转 2.25°，约 8 秒一圈） */
  startRotation() {
    this.stopRotation()
    this.rotationTimer = setInterval(() => {
      this.rotationAngle = (this.rotationAngle + 2.25) % 360
    }, 50)
  }

  /** 停止封面旋转 */
  stopRotation() {
    if (this.rotationTimer !== -1) {
      clearInterval(this.rotationTimer)
      this.rotationTimer = -1
    }
  }

  aboutToDisappear(): void {
    this.stopRotation()
  }

  /** 页面转场：进入/退出时微微缩小并降透明度，制造景深感 */
  pageTransition() {
    PageTransitionEnter({ duration: 500, curve: curves.springMotion(0.6, 0.8) })
      .scale({ x: 0.92, y: 0.92 })
      .opacity(0.7)
    PageTransitionExit({ duration: 400, curve: curves.springMotion(0.7, 0.9) })
      .scale({ x: 0.92, y: 0.92 })
      .opacity(0.7)
  }

  build() {
    Stack() {
      Column() {
        Stack() {
          /** 顶部问候区：径向渐变环境光背景 + 问候语文字 */
          Stack() {
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

        /** ✅ 响应式布局：小屏（sm/md）竖排，大屏（lg+）横排 */
        if (this.breakpoint === 'sm' || this.breakpoint === 'md') {
          Column() {
            this.playerControl()
            this.customTabBar()
          }
          .alignItems(HorizontalAlign.Center)
          .width('100%')
          .padding({ bottom: this.bottomSafeHeight })
        } else {
          Row() {
            this.customTabBar()
            Blank()
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
