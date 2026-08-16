import display from '@ohos.display'
import { curves } from '@kit.ArkUI'
import { AppStorageKeyConstants } from '../common/constants/AppStorageKeyConstants'
import { SongInfo } from '../model/SongInfo'
import { AVPlayerService } from '../service/AVPlayerService'
import { HomeContent } from './HomeContent'
import { PlaylistContent } from './PlaylistContent'
import { SettingsContent } from './SettingsContent'
import { DataService } from '../service/DataService'
import { FolderInfo } from '../model/FolderInfo'
import { ColorHelper } from '../common/utils/ColorHelper'

@Entry
@Component
struct MainPage {
  @State currentIndex: number = 0
  @State indicatorOffset: number = 4
  @State greetingTitle: string = '加载中……'
  @State greetingOpacity: number = 0
  @State greetingOffset: number = 20
  @StorageLink(AppStorageKeyConstants.KEY_IS_PLAY) @Watch('onPlayStateChange') isPlaying: boolean = false
  @State rotationAngle: number = 0
  @State isGlowing: boolean = false
  @State hasAlbumCover: boolean = false
  @State breakpoint: string = 'md'
  @StorageLink(AppStorageKeyConstants.KEY_TOP_HEIGHT) topSafeHeight: number = 0
  @StorageLink(AppStorageKeyConstants.KEY_BOTTOM_HEIGHT) bottomSafeHeight: number = 0
  @StorageLink('uplayer_current_title') currentSongTitle: string = ''
  @StorageLink('uplayer_current_artist') currentSongArtist: string = ''
  @StorageLink('uplayer_current_album_art') currentSongAlbumArt: string = ''
  @StorageLink('uplayer_primary_color') primaryColor: string = '#007DFF'
  @State albumArtFailed: boolean = false
  @State isTitleMarqueeRunning: boolean = true
  @State isArtistMarqueeRunning: boolean = true

  private tabsController: TabsController = new TabsController()
  private tabWidth: number = 72
  private tabGap: number = 6
  private indicatorInset: number = 4
  private rotationTimer: number = -1
  private dataService: DataService = DataService.getInstance()
  private avPlayerService: AVPlayerService = AVPlayerService.getInstance()

  aboutToAppear(): void {
    this.dataService.initToAppStorage()
    this.updateGreeting()
    this.initBreakpoint()
    this.getUIContext()?.animateTo({ duration: 800, curve: Curve.EaseOut }, () => {
      this.greetingOpacity = 1
      this.greetingOffset = 0
    })
  }

  onFolderClick(folder: FolderInfo): void {
    this.getUIContext()?.animateTo({ duration: 200, curve: Curve.EaseInOut }, () => {
      this.currentIndex = 0
      this.updateIndicatorOffset(0)
    })
  }

  @Builder
  customTabBar() {
    Stack({ alignContent: Alignment.BottomStart }) {
      Row()
        .width(this.tabWidth - 2 * this.indicatorInset)
        .height(36)
        .borderRadius(18)
        .alignItems(VerticalAlign.Center)
        .margin({ left: this.indicatorOffset, bottom: 12 })
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
            [ColorHelper.hexWithAlpha(this.primaryColor, 'ED'), 0.0],
            [this.primaryColor, 0.5],
            [ColorHelper.darken(this.primaryColor, 0.35), 1.0],
          ]
        })

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

  updateIndicatorOffset(index: number) {
    this.getUIContext()?.animateTo({
      curve: curves.springMotion(0.4, 0.8)
    }, () => {
      this.indicatorOffset = this.indicatorInset + index * (this.tabWidth + this.tabGap)
    })
  }

  updateGreeting() {
    const now = new Date()
    const hour = now.getHours()
    if (hour >= 5 && hour < 9) {
      this.greetingTitle = '早上好'
    } else if (hour >= 9 && hour < 12) {
      this.greetingTitle = '上午好'
    } else if (hour >= 12 && hour < 14) {
      this.greetingTitle = '中午好'
    } else if (hour >= 14 && hour < 18) {
      this.greetingTitle = '下午好'
    } else if (hour >= 18 && hour < 24) {
      this.greetingTitle = '晚上好'
    } else {
      this.greetingTitle = '夜深了'
    }
  }

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

  @Builder
  playerControl() {
    Row({ space: 20 }) {
      if (this.currentSongAlbumArt.length > 0 && !this.albumArtFailed) {
        Image('file://' + this.currentSongAlbumArt)
          .width(25).height(25)
          .borderRadius(16)
          .objectFit(ImageFit.Cover)
          .rotate({ angle: this.rotationAngle })
          .onError(() => { this.albumArtFailed = true })
          .onClick(() => {
            this.getUIContext().getRouter().pushUrl({ url: 'pages/MusicPlayer' })
          })
      } else {
        Image($r('app.media.ic_public_music'))
          .width(25).height(25)
          .borderRadius(16)
          .rotate({ angle: this.rotationAngle })
          .fillColor($r('app.color.player_icon_color'))
          .onClick(() => {
            this.getUIContext().getRouter().pushUrl({ url: 'pages/MusicPlayer' })
          })
      }

      if (this.currentSongTitle.length > 0) {
        Column() {
          Marquee({ start: this.isTitleMarqueeRunning, step: 4, loop: -1, fromStart: true, src: this.currentSongTitle })
            .fontSize(13)
            .fontColor($r('app.color.text_primary'))
            .fontWeight(FontWeight.Medium)
            .width('100%')
            .onFinish(() => { this.isTitleMarqueeRunning = false })
          Marquee({ start: this.isArtistMarqueeRunning, step: 3, loop: -1, fromStart: true,
            src: this.currentSongArtist.length > 0 ? this.currentSongArtist : '未知歌手' })
            .fontSize(10)
            .fontColor($r('app.color.text_sixty_color'))
            .width('100%')
            .onFinish(() => { this.isArtistMarqueeRunning = false })
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        .margin({ left: 8, right: 8 })
      } else {
        Column() {
          Text('未播放')
            .fontSize(11)
            .fontColor($r('app.color.text_twenty_color'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        .margin({ left: 8 })
      }
      Image($r('app.media.ic_public_play_last'))
        .width(20)
        .height(20)
        .fillColor($r('app.color.player_icon_color'))
      Image(this.isPlaying ? $r('app.media.ic_public_play') : $r('app.media.ic_public_pause'))
        .width(20)
        .height(20)
        .fillColor($r('app.color.player_icon_color'))
        .onClick(() => {
          this.togglePlay()
        })
      Image($r('app.media.ic_public_play_next'))
        .width(20)
        .height(20)
        .fillColor($r('app.color.player_icon_color'))
    }
    .constraintSize({ maxWidth: this.breakpoint === 'sm' || this.breakpoint === 'md' ? '85%' : '42%' })
    .height(40)
    .alignSelf(ItemAlign.Center)
    .padding({ left: 12, right: 16, top: 4, bottom: 4 })
    .backgroundColor($r('app.color.player_bg_color'))
    .borderRadius(20)
    .shadow({
      radius: this.isGlowing ? 60 : 50,
      color: this.isGlowing ? ColorHelper.hexWithAlpha(this.primaryColor, '66') : $r('app.color.shadow_color'),
      offsetY: 5
    })
  }

  onPlayStateChange(): void {
    if (this.isPlaying) {
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
      this.stopRotation()
      this.getUIContext()?.animateTo({ duration: 500, curve: Curve.EaseInOut }, () => {
        this.isGlowing = false
      })
    }
  }

  togglePlay(): void {
    if (this.isPlaying) {
      this.avPlayerService.pause()
    } else {
      this.avPlayerService.resume()
    }
  }

  startRotation() {
    this.stopRotation()
    this.rotationTimer = setInterval(() => {
      this.rotationAngle = (this.rotationAngle + 2.25) % 360
    }, 50)
  }

  stopRotation() {
    if (this.rotationTimer !== -1) {
      clearInterval(this.rotationTimer)
      this.rotationTimer = -1
    }
  }

  aboutToDisappear(): void {
    this.stopRotation()
  }

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
        if (this.currentIndex === 0) {
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
                  [ColorHelper.hexToRgba(this.primaryColor, 0.04), 0.0],
                  [ColorHelper.hexToRgba(this.primaryColor, 0.01), 0.6],
                  [ColorHelper.hexToRgba(this.primaryColor, 0), 1.0],
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
          }
          .width('100%')
          .height(80)
          .transition({ type: TransitionType.Insert, opacity: 0, translate: { y: -20 } })
          .transition({ type: TransitionType.Delete, opacity: 0, translate: { y: -20 } })
        }

        if (this.currentIndex === 0) {
          HomeContent()
            .layoutWeight(1)
        } else if (this.currentIndex === 1) {
          PlaylistContent({ onNavigateToHome: (folder: FolderInfo): void => {
            this.onFolderClick(folder)
          }})
            .layoutWeight(1)
        } else {
          SettingsContent()
            .layoutWeight(1)
        }

        if (this.breakpoint === 'sm' || this.breakpoint === 'md') {
          Column({ space: 8 }) {
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
          .width('100%')
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
