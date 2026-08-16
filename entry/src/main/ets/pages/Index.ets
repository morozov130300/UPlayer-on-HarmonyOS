import display from '@ohos.display'
import { curves, window } from '@kit.ArkUI'
import { common } from '@kit.AbilityKit'
import { fileIo as fs } from '@kit.CoreFileKit'
import { util } from '@kit.ArkTS'
import { deviceInfo } from '@kit.BasicServicesKit'
import { AppStorageKeyConstants } from '../common/constants/AppStorageKeyConstants'
import { SongInfo } from '../model/SongInfo'
import { AVPlayerService } from '../service/AVPlayerService'
import { HomeContent } from './HomeContent'
import { PlaylistContent } from './PlaylistContent'
import { SettingsContent } from './SettingsContent'
import { DataService } from '../service/DataService'
import { ColorHelper } from '../common/utils/ColorHelper'
import { ShareService } from '../service/ShareService'
import Logger from '../common/utils/Logger'
import { LrcEntry } from '../viewmodel/LrcEntry'
import { parseKrcLyric, parseLrcLyric } from '../common/utils/LrcUtils'
import { LyricFile } from '../common/constants/LyricConst'
import { PlayerConstants } from '../common/constants/PlayerConstants'

const TAG = 'Index'

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
  @State breakpoint: string = 'md'
  @StorageLink(AppStorageKeyConstants.KEY_TOP_HEIGHT) topSafeHeight: number = 0
  @StorageLink(AppStorageKeyConstants.KEY_BOTTOM_HEIGHT) bottomSafeHeight: number = 0
  @StorageLink(AppStorageKeyConstants.KEY_TITLE_BUTTON_WIDTH) titleButtonWidth: number = 0
  @StorageLink(AppStorageKeyConstants.KEY_TITLE_BUTTON_HEIGHT) titleButtonHeight: number = 0
  @StorageLink('uplayer_current_title') currentSongTitle: string = ''
  @StorageLink('uplayer_current_artist') currentSongArtist: string = ''
  @StorageLink('uplayer_current_album_art') @Watch('onAlbumArtChange') currentSongAlbumArt: string = ''
  @StorageLink('uplayer_primary_color') primaryColor: string = '#007DFF'
  @StorageLink('uplayer_display_size_scale') @Watch('onDisplaySizeChange') displaySizeScale: number = 1.0
  @StorageLink('uplayer_font_size_scale') fontSizeScale: number = 1.0
  @StorageLink('uplayer_tab_style') tabStyle: string = 'classic'
  @StorageLink('uplayer_tab_indicator_depth') tabIndicatorDepth: number = 50
  @State albumArtFailed: boolean = false
  @State isTitleMarqueeRunning: boolean = true
  @State isArtistMarqueeRunning: boolean = true
  @State hoverTabIndex: number = -1
  @State currentLyricLine: string = ''
  @State nextLyricLine: string = ''
  @State lyricEntries: LrcEntry[] = []
  @StorageLink(AppStorageKeyConstants.KEY_PROGRESS) @Watch('onProgressChange') playProgress: number = 0
  @StorageLink(AppStorageKeyConstants.KEY_SELECT_INDEX) @Watch('onCurrentSongChange') selectedSongIndex: number = 0

  private tabsController: TabsController = new TabsController()
  private tabWidth: number = 72
  private tabGap: number = 6
  private indicatorInset: number = 4
  private rotationTimer: number = -1
  private dataService: DataService = DataService.getInstance()
  private avPlayerService: AVPlayerService = AVPlayerService.getInstance()
  private shareService: ShareService = ShareService.getInstance()
  private isPC: boolean = deviceInfo.deviceType === '2in1'

  private scaledSize(size: number): number {
    return Math.round(size * this.displaySizeScale)
  }

  private isSongInfoShort(): boolean {
    const artistLength: number = this.currentSongArtist.length > 0 ? this.currentSongArtist.length : 4
    return this.currentSongTitle.length + artistLength <= 16
  }

  private songInfoWeight(): number {
    return this.isPC && this.isSongInfoShort() ? 2 : 3
  }

  private lyricInfoWeight(): number {
    return this.isSongInfoShort() ? 4 : 3
  }

  private indicatorDarken(base: number, range: number): number {
    const depth: number = 100 - this.tabIndicatorDepth
    return Math.min(0.75, base + range * depth / 100)
  }

  onDisplaySizeChange(): void {
    this.updateIndicatorOffset(this.currentIndex)
  }

  aboutToAppear(): void {
    this.dataService.initToAppStorage()
    this.updateGreeting()
    this.initBreakpoint()
    this.shareService.registerListeners('home')
    this.loadCurrentLyrics()
    this.getUIContext()?.animateTo({ duration: 800, curve: Curve.EaseOut }, () => {
      this.greetingOpacity = 1
      this.greetingOffset = 0
    })
  }

  onFolderClick(): void {
    this.getUIContext()?.animateTo({ duration: 200, curve: Curve.EaseInOut }, () => {
      this.currentIndex = 0
      this.updateIndicatorOffset(0)
    })
  }

  @Builder
  customTabBar() {
    Stack({ alignContent: Alignment.BottomStart }) {
      Row()
        .width(this.scaledSize(this.tabWidth * 3 + this.tabGap * 2))
        .height(this.scaledSize(40))
        .margin({ bottom: this.scaledSize(10) })
        .borderRadius(this.scaledSize(20))
        .backgroundColor('rgba(255,255,255,0.06)')
        .backgroundBlurStyle(BlurStyle.COMPONENT_ULTRA_THICK)
        .border({ width: 1, color: 'rgba(255,255,255,0.18)' })
        .shadow({ radius: 50, color: $r('app.color.shadow_color'), offsetX: 0, offsetY: 0 })
        .zIndex(0)

      Row()
        .width(this.scaledSize(this.tabWidth - 2 * this.indicatorInset))
        .height(this.scaledSize(36))
        .borderRadius(this.scaledSize(18))
        .alignItems(VerticalAlign.Center)
        .margin({ left: this.indicatorOffset, bottom: this.scaledSize(12) })
        .shadow({
          radius: 14,
          color: ColorHelper.hexWithAlpha(
            ColorHelper.darken(this.primaryColor, this.indicatorDarken(0.12, 0.4)), 'CC'),
          offsetX: 0,
          offsetY: 0
        })
        .radialGradient({
          center: ['50%', '50%'],
          radius: '75%',
          colors: [
            [ColorHelper.darken(this.primaryColor, this.indicatorDarken(0.02, 0.32)), 0.0],
            [ColorHelper.darken(this.primaryColor, this.indicatorDarken(0.12, 0.48)), 0.58],
            [ColorHelper.darken(this.primaryColor, this.indicatorDarken(0.25, 0.5)), 1.0],
          ]
        })
        .zIndex(1)

      Row({ space: this.scaledSize(this.tabGap) }) {
        this.tabItem(0, '首页', $r('app.media.ic_public_home'))
        this.tabItem(1, '歌单', $r('app.media.ic_public_view_list'))
        this.tabItem(2, '设置', $r('app.media.ic_public_settings'))
      }
      .margin({ bottom: this.scaledSize(10) })
      .height(this.scaledSize(40))
      .borderRadius(this.scaledSize(20))
      .zIndex(2)
    }
    .alignSelf(ItemAlign.Center)
    .height(this.scaledSize(60))
  }

  @Builder
  immersiveTabBar() {
    Stack({ alignContent: Alignment.BottomStart }) {
      Row()
        .width(this.scaledSize(this.tabWidth - 2 * this.indicatorInset))
        .height(this.scaledSize(36))
        .borderRadius(this.scaledSize(18))
        .alignItems(VerticalAlign.Center)
        .margin({ left: this.indicatorOffset, bottom: this.scaledSize(12) })
        .backgroundColor(ColorHelper.hexWithAlpha(this.primaryColor, '33'))

      Row({ space: this.scaledSize(this.tabGap) }) {
        this.immersiveTabItem(0, '首页', $r('app.media.ic_public_home'))
        this.immersiveTabItem(1, '歌单', $r('app.media.ic_public_view_list'))
        this.immersiveTabItem(2, '设置', $r('app.media.ic_public_settings'))
      }
      .margin({ bottom: this.scaledSize(10) })
      .height(this.scaledSize(40))
      .borderRadius(this.scaledSize(20))
      .backgroundColor('rgba(255,255,255,0.08)')
      .backgroundBlurStyle(BlurStyle.COMPONENT_ULTRA_THICK)
      .border({ width: 1, color: 'rgba(255,255,255,0.22)' })
      .shadow({ radius: 18, color: ColorHelper.hexWithAlpha(this.primaryColor, '44'), offsetY: 5 })
    }
    .alignSelf(ItemAlign.Center)
    .height(this.scaledSize(60))
  }

  @Builder
  tabItem(index: number, name: string, icon: Resource) {
    Column() {
      Image(icon)
        .height(this.scaledSize(18))
        .fillColor(this.currentIndex === index ? '#FFFFFF' : '#666666')
        .scale({
          x: this.currentIndex === index ? 1.15 : 1.0,
          y: this.currentIndex === index ? 1.15 : 1.0
        })
      Text(name)
        .fontSize(9)
        .fontColor(this.currentIndex === index ? '#FFFFFF' : '#666666')
        .margin({ top: this.scaledSize(2) })
    }
    .width(this.scaledSize(this.tabWidth))
    .height(this.scaledSize(40))
    .justifyContent(FlexAlign.Center)
    .backgroundColor(this.hoverTabIndex === index ? 'rgba(255,255,255,0.16)' : Color.Transparent)
    .borderRadius(this.scaledSize(18))
    .shadow({
      radius: this.hoverTabIndex === index ? 14 : 0,
      color: this.hoverTabIndex === index ? ColorHelper.hexWithAlpha(this.primaryColor, '66') : Color.Transparent
    })
    .scale({ x: this.hoverTabIndex === index ? 1.06 : 1, y: this.hoverTabIndex === index ? 1.06 : 1 })
    .animation({ duration: 180, curve: Curve.EaseOut })
    .hoverEffect(HoverEffect.Scale)
    .onHover((isHover: boolean) => { this.hoverTabIndex = isHover ? index : -1 })
    .onClick(() => {
      this.getUIContext()?.animateTo({ duration: 200, curve: Curve.EaseInOut }, () => {
        this.currentIndex = index
      })
      this.tabsController.changeIndex(index)
      this.updateIndicatorOffset(index)
    })
  }

  @Builder
  immersiveTabItem(index: number, name: string, icon: Resource) {
    Column() {
      Image(icon)
        .height(this.scaledSize(18))
        .fillColor(this.currentIndex === index ? '#FFFFFF' : 'rgba(255,255,255,0.45)')
        .scale({
          x: this.currentIndex === index ? 1.15 : 1.0,
          y: this.currentIndex === index ? 1.15 : 1.0
        })
      Text(name)
        .fontSize(9)
        .fontColor(this.currentIndex === index ? '#FFFFFF' : 'rgba(255,255,255,0.45)')
        .margin({ top: this.scaledSize(2) })
    }
    .width(this.scaledSize(this.tabWidth))
    .height(this.scaledSize(40))
    .justifyContent(FlexAlign.Center)
    .backgroundColor(this.hoverTabIndex === index ? 'rgba(255,255,255,0.18)' : Color.Transparent)
    .borderRadius(this.scaledSize(18))
    .shadow({
      radius: this.hoverTabIndex === index ? 16 : 0,
      color: this.hoverTabIndex === index ? ColorHelper.hexWithAlpha(this.primaryColor, '77') : Color.Transparent
    })
    .scale({ x: this.hoverTabIndex === index ? 1.06 : 1, y: this.hoverTabIndex === index ? 1.06 : 1 })
    .animation({ duration: 180, curve: Curve.EaseOut })
    .hoverEffect(HoverEffect.Scale)
    .onHover((isHover: boolean) => { this.hoverTabIndex = isHover ? index : -1 })
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
      this.indicatorOffset = this.scaledSize(this.indicatorInset + index * (this.tabWidth + this.tabGap))
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
          Logger.error(TAG, 'display change error')
        }
      })
    } catch (err) {
      Logger.error(TAG, 'init breakpoint error')
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
    Row({ space: this.scaledSize(20) }) {
      if (this.currentSongAlbumArt.length > 0 && !this.albumArtFailed) {
        Image('file://' + this.currentSongAlbumArt)
          .width(this.scaledSize(32)).height(this.scaledSize(32))
          .borderRadius(this.scaledSize(16))
          .objectFit(ImageFit.Cover)
          .rotate({ angle: this.rotationAngle })
          .onError(() => { this.albumArtFailed = true })
          .onClick(() => { this.openPlayer() })
      } else {
        Image($r('app.media.ic_public_music'))
          .width(this.scaledSize(32)).height(this.scaledSize(32))
          .borderRadius(this.scaledSize(16))
          .rotate({ angle: this.rotationAngle })
          .fillColor($r('app.color.player_icon_color'))
          .onClick(() => { this.openPlayer() })
      }

      Column() {
        if (this.currentSongTitle.length > 0) {
          Column() {
            Marquee({ start: this.isTitleMarqueeRunning, step: 2, loop: -1, fromStart: true, src: this.currentSongTitle })
              .fontSize(Math.round(13 * this.fontSizeScale))
              .fontColor($r('app.color.text_primary'))
              .fontWeight(FontWeight.Medium)
              .width('100%')
              .onFinish(() => { this.isTitleMarqueeRunning = false })
            Marquee({ start: this.isArtistMarqueeRunning, step: 1, loop: -1, fromStart: true,
              src: this.currentSongArtist.length > 0 ? this.currentSongArtist : '未知歌手' })
              .fontSize(Math.round(10 * this.fontSizeScale))
              .fontColor($r('app.color.text_sixty_color'))
              .width('100%')
              .onFinish(() => { this.isArtistMarqueeRunning = false })
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
        } else {
          Column() {
            Text('未播放')
              .fontSize(Math.round(11 * this.fontSizeScale))
              .fontColor($r('app.color.text_twenty_color'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
        }
      }
      .layoutWeight(this.songInfoWeight())
      .margin({ left: this.scaledSize(8), right: this.scaledSize(8) })
      .onClick(() => {
        this.openPlayer()
      })
      if (this.isPC && this.currentSongTitle.length > 0 &&
        (this.currentLyricLine.length > 0 || this.nextLyricLine.length > 0)) {
        Column() {
          Text(this.currentLyricLine)
            .fontSize(Math.round(12 * this.fontSizeScale))
            .fontColor($r('app.color.text_primary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(this.nextLyricLine)
            .fontSize(Math.round(11 * this.fontSizeScale))
            .fontColor($r('app.color.text_sixty_color'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .margin({ top: this.scaledSize(2) })
        }
        .layoutWeight(this.lyricInfoWeight())
        .alignItems(HorizontalAlign.Start)
        .onClick(() => { this.openPlayer() })
      }
      Image($r('app.media.ic_public_play_last'))
        .width(this.scaledSize(20))
        .height(this.scaledSize(20))
        .fillColor($r('app.color.player_icon_color'))
        .onClick(() => { this.playPrevious() })
      Image(this.isPlaying ? $r('app.media.ic_public_play') : $r('app.media.ic_public_pause'))
        .width(this.scaledSize(20))
        .height(this.scaledSize(20))
        .fillColor($r('app.color.player_icon_color'))
        .onClick(() => {
          this.togglePlay()
        })
      Image($r('app.media.ic_public_play_next'))
        .width(this.scaledSize(20))
        .height(this.scaledSize(20))
        .fillColor($r('app.color.player_icon_color'))
        .onClick(() => { this.playNext() })
    }
    .constraintSize({ maxWidth: this.breakpoint === 'sm' || this.breakpoint === 'md' ? '85%' : '42%' })
    .height(this.scaledSize(40))
    .alignSelf(ItemAlign.Center)
    .padding({
      left: this.scaledSize(12), right: this.scaledSize(16),
      top: this.scaledSize(4), bottom: this.scaledSize(4)
    })
    .backgroundColor($r('app.color.player_bg_color'))
    .borderRadius(this.scaledSize(20))
    .shadow({
      radius: this.isGlowing ? 60 : 50,
      color: this.isGlowing ? ColorHelper.hexWithAlpha(this.primaryColor, '66') : $r('app.color.shadow_color'),
      offsetY: 5
    })
  }

  openPlayer(): void {
    if (this.currentSongTitle.length === 0) {
      return
    }
    this.getUIContext().getRouter().pushUrl({ url: 'pages/MusicPlayer' })
  }

  onAlbumArtChange(): void {
    this.albumArtFailed = false
  }

  onCurrentSongChange(): void {
    this.loadCurrentLyrics()
  }

  onProgressChange(): void {
    let currentIndex: number = -1
    for (let i = 0; i < this.lyricEntries.length; i++) {
      if (this.lyricEntries[i].lineStartTime <= this.playProgress) {
        currentIndex = i
      } else {
        break
      }
    }
    this.currentLyricLine = currentIndex >= 0 ? this.lyricEntries[currentIndex].lineWords : ''
    this.nextLyricLine = currentIndex >= 0 && currentIndex + 1 < this.lyricEntries.length ?
      this.lyricEntries[currentIndex + 1].lineWords : ''
  }

  loadCurrentLyrics(): void {
    this.lyricEntries = []
    this.currentLyricLine = ''
    this.nextLyricLine = ''
    if (this.currentSongTitle.length === 0) {
      return
    }
    const songs: SongInfo[] = this.dataService.getSongs()
    if (this.selectedSongIndex < 0 || this.selectedSongIndex >= songs.length) {
      return
    }
    const song: SongInfo = songs[this.selectedSongIndex]
    const lyricPath: string = song.lyricUri.length > 0 ? song.lyricUri : song.lyricPath
    if (lyricPath.length === 0) {
      return
    }
    let lyricFile: fs.File | undefined = undefined
    try {
      lyricFile = fs.openSync(lyricPath, fs.OpenMode.READ_ONLY)
      const fileSize: number = fs.statSync(lyricFile.fd).size
      const lyricBuffer: ArrayBuffer = new ArrayBuffer(fileSize)
      fs.readSync(lyricFile.fd, lyricBuffer)
      const decoder = util.TextDecoder.create(PlayerConstants.ENCODING, { ignoreBOM: true })
      const lyricText: string = decoder.decodeToString(new Uint8Array(lyricBuffer), { stream: false })
      this.lyricEntries = lyricPath.endsWith(LyricFile.KRC) ? parseKrcLyric(lyricText) : parseLrcLyric(lyricText)
      this.onProgressChange()
    } catch (err) {
      Logger.warn(TAG, `loadCurrentLyrics failed: ${JSON.stringify(err)}`)
    } finally {
      if (lyricFile !== undefined) {
        fs.closeSync(lyricFile)
      }
    }
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

  playPrevious(): void {
    const songList: SongInfo[] | undefined = AppStorage.get(AppStorageKeyConstants.KEY_SONG_LIST)
    if (!songList || songList.length === 0) {
      return
    }
    let idx: number = this.currentIndex >= 0 ? (AppStorage.get<number>(AppStorageKeyConstants.KEY_SELECT_INDEX) ?? 0) : 0
    idx = idx <= 0 ? songList.length - 1 : idx - 1
    AppStorage.setOrCreate(AppStorageKeyConstants.KEY_SELECT_INDEX, idx)
    const song: SongInfo = songList[idx]
    AppStorage.setOrCreate('uplayer_current_title', song.title.length > 0 ? song.title : song.name)
    AppStorage.setOrCreate('uplayer_current_artist', song.artist)
    AppStorage.setOrCreate('uplayer_current_album_art', song.albumArtPath)
    this.avPlayerService.play(song.uri.length > 0 ? song.uri : song.filePath)
  }

  playNext(): void {
    const songList: SongInfo[] | undefined = AppStorage.get(AppStorageKeyConstants.KEY_SONG_LIST)
    if (!songList || songList.length === 0) {
      return
    }
    let idx: number = AppStorage.get<number>(AppStorageKeyConstants.KEY_SELECT_INDEX) ?? 0
    idx = idx >= songList.length - 1 ? 0 : idx + 1
    AppStorage.setOrCreate(AppStorageKeyConstants.KEY_SELECT_INDEX, idx)
    const song: SongInfo = songList[idx]
    AppStorage.setOrCreate('uplayer_current_title', song.title.length > 0 ? song.title : song.name)
    AppStorage.setOrCreate('uplayer_current_artist', song.artist)
    AppStorage.setOrCreate('uplayer_current_album_art', song.albumArtPath)
    this.avPlayerService.play(song.uri.length > 0 ? song.uri : song.filePath)
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
    this.shareService.unregisterListeners()
  }

  onPageHide(): void {
    this.shareService.unregisterListeners()
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
            Row() {
              Text(this.greetingTitle)
                .fontWeight(FontWeight.Bolder)
                .fontSize(Math.round(28 * this.fontSizeScale))
                .fontColor($r('app.color.text_primary'))
                .opacity(this.greetingOpacity)
                .translate({ y: this.greetingOffset })
              Blank()
            }
            .width('100%')
            .height('100%')
            .justifyContent(FlexAlign.Start)
            .alignItems(VerticalAlign.Center)
            .padding({
              top: this.isPC ? 12 : 16 + this.topSafeHeight,
              left: 16,
              right: this.isPC ? this.titleButtonWidth + 12 : 8
            })
          }
          .width('100%')
          .height(this.isPC ? Math.max(76, this.titleButtonHeight + 20) : 96)
          .transition({ type: TransitionType.Insert, opacity: 0, translate: { y: -20 } })
          .transition({ type: TransitionType.Delete, opacity: 0, translate: { y: -20 } })
        }

        if (this.currentIndex === 0) {
          HomeContent()
            .layoutWeight(1)
        } else if (this.currentIndex === 1) {
          PlaylistContent({ onNavigateToHome: (): void => {
            this.onFolderClick()
          }})
            .layoutWeight(1)
        } else {
          SettingsContent()
            .layoutWeight(1)
        }

        if (this.breakpoint === 'sm' || this.breakpoint === 'md') {
          Column({ space: 8 }) {
            this.playerControl()
            if (this.tabStyle === 'immersive') {
              this.immersiveTabBar()
            } else {
              this.customTabBar()
            }
          }
          .alignItems(HorizontalAlign.Center)
          .width('100%')
          .padding({ bottom: this.bottomSafeHeight })
        } else {
          Row() {
            if (this.tabStyle === 'immersive') {
              this.immersiveTabBar()
            } else {
              this.customTabBar()
            }
            Blank()
            this.playerControl()
          }
          .width('100%')
          .padding({ left: 16, right: 16, bottom: this.bottomSafeHeight + 16 })
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
