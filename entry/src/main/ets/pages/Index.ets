import display from '@ohos.display'
import { curves, window } from '@kit.ArkUI'
import { common, ConfigurationConstant } from '@kit.AbilityKit'
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
import Logger from '../common/utils/Logger'
import { LrcEntry } from '../viewmodel/LrcEntry'
import { parseKrcLyric, parseLrcLyric } from '../common/utils/LrcUtils'
import { LyricFile } from '../common/constants/LyricConst'
import { MusicPlayMode, PlayerConstants } from '../common/constants/PlayerConstants'
import { AlbumCover } from '../component/AlbumCover'
import { ColorConversion } from '../common/utils/ColorConversion'
import { StyleConstants } from '../common/constants/StyleConstants'

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
  @StorageLink('uplayer_theme_mode') themeMode: string = 'system'
  @StorageLink('uplayer_display_size_scale') @Watch('onDisplaySizeChange') displaySizeScale: number = 1.0
  @StorageLink('uplayer_font_size_scale') fontSizeScale: number = 1.0
  @StorageLink('uplayer_tab_style') tabStyle: string = 'classic'
  @StorageLink('uplayer_tab_indicator_depth') tabIndicatorDepth: number = 50
  @StorageLink('uplayer_glass_blur_strength') glassBlurStrength: number = 25
  @State albumArtFailed: boolean = false
  @State isTitleMarqueeRunning: boolean = true
  @State isArtistMarqueeRunning: boolean = true
  @State hoverTabIndex: number = -1
  @State currentLyricLine: string = ''
  @State nextLyricLine: string = ''
  @State lyricEntries: LrcEntry[] = []
  @StorageLink(AppStorageKeyConstants.KEY_PROGRESS) @Watch('onProgressChange') playProgress: number = 0
  @StorageLink(AppStorageKeyConstants.KEY_SELECT_INDEX) @Watch('onCurrentSongChange') selectedSongIndex: number = 0

  private swiperController: SwiperController = new SwiperController()
  private tabWidth: number = 72
  private tabGap: number = 6
  private indicatorInset: number = 4
  private rotationTimer: number = -1
  private dataService: DataService = DataService.getInstance()
  private avPlayerService: AVPlayerService = AVPlayerService.getInstance()
  private isPC: boolean = deviceInfo.deviceType === '2in1'
  private lyricLoadRequestId: number = 0
  private isDisplayListenerRegistered: boolean = false
  private displayChangeCallback = (): void => {
    try {
      const newDisplayInfo = display.getDefaultDisplaySync()
      this.updateBreakpoint(newDisplayInfo.width)
    } catch (err) {
      Logger.error(TAG, 'display change error')
    }
  }

  private isDarkTheme(): boolean {
    if (this.themeMode === 'dark') {
      return true
    }
    if (this.themeMode === 'system') {
      const context: common.UIAbilityContext | undefined = AppStorage.get<common.UIAbilityContext>(
        AppStorageKeyConstants.KEY_UI_ABILITY_CONTEXT)
      return context?.config.colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK
    }
    return false
  }

  private topContentInset(): number {
    return this.isPC ? Math.max(this.topSafeHeight, this.titleButtonHeight) : this.topSafeHeight
  }

  private homeHeaderHeight(): number {
    return this.isPC ? Math.max(76, this.topContentInset() + 56) : this.topContentInset() + 72
  }

  private scaledSize(size: number): number {
    return Math.round(size * this.displaySizeScale)
  }

  private bottomOverlayInset(): number {
    if (this.breakpoint === 'sm' || this.breakpoint === 'md') {
      return this.scaledSize(116) + this.bottomSafeHeight
    }
    return this.scaledSize(76) + this.bottomSafeHeight
  }

  private glassBlurRadius(): number {
    return this.glassBlurStrength * 0.5
  }

  private glassSaturation(): number {
    return 1 + this.glassBlurStrength * 0.0035
  }

  private glassBrightness(): number {
    return 1 + this.glassBlurStrength * 0.0008
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
    ColorConversion.setSysBarLightBackground(this.isDarkTheme())
    this.updateGreeting()
    this.initBreakpoint()
    this.loadCurrentLyrics()
    this.getUIContext()?.animateTo({ duration: StyleConstants.ANIMATION_GREETING_DURATION, curve: Curve.EaseOut }, () => {
      this.greetingOpacity = 1
      this.greetingOffset = 0
    })
  }

  private switchPage(index: number): void {
    if (index < 0 || index > 2 || index === this.currentIndex) {
      return
    }
    this.swiperController.changeIndex(index, true)
  }

  private onPageChange(index: number): void {
    this.currentIndex = index
    this.updateIndicatorOffset(index)
  }

  onFolderClick(): void {
    this.switchPage(0)
  }

  @Builder
  customTabBar() {
    Stack({ alignContent: Alignment.BottomStart }) {
      Row()
        .width(this.scaledSize(this.tabWidth * 3 + this.tabGap * 2))
        .height(this.scaledSize(40))
        .margin({ bottom: this.scaledSize(10) })
        .borderRadius(this.scaledSize(20))
        .backgroundColor(Color.Transparent)
        .backgroundEffect({
          radius: this.glassBlurRadius(),
          saturation: this.glassSaturation(),
          brightness: this.glassBrightness()
        })
        .border({ width: 1, color: 'rgba(255,255,255,0.22)' })
        .shadow({ radius: 18, color: ColorHelper.hexWithAlpha(this.primaryColor, '44'), offsetY: 5 })
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
      .backgroundColor(Color.Transparent)
      .backgroundEffect({
        radius: this.glassBlurRadius(),
        saturation: this.glassSaturation(),
        brightness: this.glassBrightness()
      })
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
    .animation({ duration: StyleConstants.ANIMATION_HOVER_DURATION, curve: Curve.EaseOut })
    .hoverEffect(HoverEffect.Scale)
    .onHover((isHover: boolean) => { this.hoverTabIndex = isHover ? index : -1 })
    .onClick(() => {
      this.switchPage(index)
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
    .animation({ duration: StyleConstants.ANIMATION_HOVER_DURATION, curve: Curve.EaseOut })
    .hoverEffect(HoverEffect.Scale)
    .onHover((isHover: boolean) => { this.hoverTabIndex = isHover ? index : -1 })
    .onClick(() => {
      this.switchPage(index)
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
      if (!this.isDisplayListenerRegistered) {
        display.on('change', this.displayChangeCallback)
        this.isDisplayListenerRegistered = true
      }
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
  }

  @Builder
  playerControl() {
    Row({ space: this.scaledSize(20) }) {
      if (this.currentSongTitle.length > 0) {
        AlbumCover({ song: this.currentSong(), coverWidth: this.scaledSize(32),
          coverHeight: this.scaledSize(32), coverRadius: this.scaledSize(16) })
          .width(this.scaledSize(32)).height(this.scaledSize(32))
          .rotate({ angle: this.rotationAngle })
          .onClick(() => { this.openPlayer() })
      } else {
        Stack() {
          Image($r('app.media.ic_public_music'))
            .width(this.scaledSize(24))
            .height(this.scaledSize(24))
            .fillColor($r('app.color.player_icon_color'))
        }
        .width(this.scaledSize(32))
        .height(this.scaledSize(32))
        .borderRadius(this.scaledSize(16))
        .rotate({ angle: this.rotationAngle })
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
    .backgroundColor(Color.Transparent)
    .backgroundEffect({
      radius: this.glassBlurRadius(),
      saturation: this.glassSaturation(),
      brightness: this.glassBrightness()
    })
    .border({
      width: 1,
      color: 'rgba(255,255,255,0.22)'
    })
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

  private currentSong(): SongInfo {
    const songs: SongInfo[] = this.dataService.getSongs()
    if (this.selectedSongIndex >= 0 && this.selectedSongIndex < songs.length) {
      return songs[this.selectedSongIndex]
    }
    return new SongInfo()
  }

  onCurrentSongChange(): void {
    this.loadCurrentLyrics()
  }

  onProgressChange(): void {
    let low: number = 0
    let high: number = this.lyricEntries.length - 1
    let currentIndex: number = -1
    while (low <= high) {
      const middle: number = Math.floor((low + high) / 2)
      if (this.lyricEntries[middle].lineStartTime <= this.playProgress) {
        currentIndex = middle
        low = middle + 1
      } else {
        high = middle - 1
      }
    }
    this.currentLyricLine = currentIndex >= 0 ? this.lyricEntries[currentIndex].lineWords : ''
    this.nextLyricLine = currentIndex >= 0 && currentIndex + 1 < this.lyricEntries.length ?
      this.lyricEntries[currentIndex + 1].lineWords : ''
  }

  async loadCurrentLyrics(): Promise<void> {
    const requestId: number = ++this.lyricLoadRequestId
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
      lyricFile = await fs.open(lyricPath, fs.OpenMode.READ_ONLY)
      const fileSize: number = (await fs.stat(lyricFile.fd)).size
      const lyricBuffer: ArrayBuffer = new ArrayBuffer(fileSize)
      await fs.read(lyricFile.fd, lyricBuffer)
      const decoder = util.TextDecoder.create(PlayerConstants.ENCODING, { ignoreBOM: true })
      const lyricText: string = decoder.decodeToString(new Uint8Array(lyricBuffer), { stream: false })
      const entries: LrcEntry[] = lyricPath.endsWith(LyricFile.KRC) ? parseKrcLyric(lyricText) : parseLrcLyric(lyricText)
      if (requestId !== this.lyricLoadRequestId || this.selectedSongIndex < 0 ||
        this.selectedSongIndex >= songs.length || songs[this.selectedSongIndex].id !== song.id) {
        return
      }
      this.lyricEntries = entries
      this.onProgressChange()
    } catch (err) {
      Logger.warn(TAG, `loadCurrentLyrics failed: ${JSON.stringify(err)}`)
    } finally {
      if (lyricFile !== undefined) {
        try {
          await fs.close(lyricFile)
        } catch (e) {
          Logger.warn(TAG, 'close lyric file failed')
        }
      }
    }
  }

  onPlayStateChange(): void {
    if (this.isPlaying) {
      this.getUIContext()?.animateTo({ duration: StyleConstants.ANIMATION_ROTATION_START_DURATION, curve: curves.springMotion(0.3, 0.7) }, () => {
        this.rotationAngle += 30
      })
      setTimeout(() => {
        this.startRotation()
      }, StyleConstants.ANIMATION_ROTATION_START_DURATION)
      this.getUIContext()?.animateTo({ duration: StyleConstants.ANIMATION_GLOW_ON_DURATION, curve: Curve.EaseInOut }, () => {
        this.isGlowing = true
      })
    } else {
      this.stopRotation()
      this.getUIContext()?.animateTo({ duration: StyleConstants.ANIMATION_GLOW_OFF_DURATION, curve: Curve.EaseInOut }, () => {
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

  private randomSongIndex(currentIndex: number, songCount: number): number {
    if (songCount <= 1) {
      return currentIndex
    }
    let nextIndex: number = currentIndex
    for (let i = 0; i < 5 && nextIndex === currentIndex; i++) {
      nextIndex = Math.floor(Math.random() * songCount)
    }
    return nextIndex === currentIndex ? (currentIndex + 1) % songCount : nextIndex
  }

  playPrevious(): void {
    const songList: SongInfo[] | undefined = AppStorage.get(AppStorageKeyConstants.KEY_SONG_LIST)
    if (!songList || songList.length === 0) {
      return
    }
    let idx: number = AppStorage.get<number>(AppStorageKeyConstants.KEY_SELECT_INDEX) ?? 0
    const mode: MusicPlayMode = AppStorage.get<MusicPlayMode>(AppStorageKeyConstants.KEY_PLAY_MODE) ??
      MusicPlayMode.ORDER
    if (mode === MusicPlayMode.RANDOM) {
      idx = this.randomSongIndex(idx, songList.length)
    } else if (mode === MusicPlayMode.ORDER) {
      idx = idx <= 0 ? songList.length - 1 : idx - 1
    }
    const song: SongInfo = songList[idx]
    this.avPlayerService.playSong(song, idx)
  }

  playNext(): void {
    const songList: SongInfo[] | undefined = AppStorage.get(AppStorageKeyConstants.KEY_SONG_LIST)
    if (!songList || songList.length === 0) {
      return
    }
    let idx: number = AppStorage.get<number>(AppStorageKeyConstants.KEY_SELECT_INDEX) ?? 0
    const mode: MusicPlayMode = AppStorage.get<MusicPlayMode>(AppStorageKeyConstants.KEY_PLAY_MODE) ??
      MusicPlayMode.ORDER
    if (mode === MusicPlayMode.RANDOM) {
      idx = this.randomSongIndex(idx, songList.length)
    } else if (mode === MusicPlayMode.ORDER) {
      idx = idx >= songList.length - 1 ? 0 : idx + 1
    }
    const song: SongInfo = songList[idx]
    this.avPlayerService.playSong(song, idx)
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
    if (this.isDisplayListenerRegistered) {
      display.off('change', this.displayChangeCallback)
      this.isDisplayListenerRegistered = false
    }
  }

  pageTransition() {
    PageTransitionEnter({ duration: StyleConstants.ANIMATION_PAGE_ENTER_DURATION, curve: curves.springMotion(0.6, 0.8) })
      .scale({ x: 0.92, y: 0.92 })
      .opacity(0.7)
    PageTransitionExit({ duration: StyleConstants.ANIMATION_PAGE_EXIT_DURATION, curve: curves.springMotion(0.7, 0.9) })
      .scale({ x: 0.92, y: 0.92 })
      .opacity(0.7)
  }

  build() {
    Stack() {
      Swiper(this.swiperController) {
        Column() {
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
              top: this.topContentInset(),
              left: 16,
              right: this.isPC ? this.titleButtonWidth + 12 : 8
            })
          }
          .width('100%')
          .height(this.homeHeaderHeight())

          HomeContent({ bottomContentPadding: this.bottomOverlayInset() })
            .layoutWeight(1)
        }
        .width('100%')
        .height('100%')

        PlaylistContent({
          topContentPadding: this.topContentInset(),
          bottomContentPadding: this.bottomOverlayInset(),
          onNavigateToHome: (): void => {
            this.onFolderClick()
          }
        })
          .width('100%')
          .height('100%')

        SettingsContent({
          topContentPadding: this.topContentInset(),
          bottomContentPadding: this.bottomOverlayInset()
        })
          .width('100%')
          .height('100%')
      }
      .index(this.currentIndex)
      .indicator(false)
      .loop(false)
      .disableSwipe(false)
      .cachedCount(3)
      .duration(StyleConstants.ANIMATION_SWIPER_DURATION)
      .curve(Curve.EaseInOut)
      .onChange((index: number) => {
        this.onPageChange(index)
      })
      .width('100%')
      .height('100%')

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
        .zIndex(10)
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
        .zIndex(10)
      }
    }
    .alignContent(Alignment.Bottom)
    .width('100%')
    .height('100%')
  }
}
