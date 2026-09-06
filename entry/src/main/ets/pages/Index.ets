import display from '@ohos.display'
import { curves, window, uiMaterial } from '@kit.ArkUI'
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
import { PoetryService } from '../service/PoetryService'
import { ColorHelper } from '../common/utils/ColorHelper'
import { createPageGlassMaterial, DEFAULT_GLASS_STYLE, glassBlurStyleFromStrength, glassImmersiveStyleFromStrengthSmooth, isLiquidGlassAvailable } from '../common/utils/GlassUtil'
import Logger from '../common/utils/Logger'
import { LrcEntry } from '../viewmodel/LrcEntry'
import { parseKrcLyric, parseLrcLyric } from '../common/utils/LrcUtils'
import { LyricFile } from '../common/constants/LyricConst'
import { PlayerConstants } from '../common/constants/PlayerConstants'
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
  @State poetryLine: string = ''
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
  @StorageLink('uplayer_glass_blur_strength') glassBlurStrength: number = 25
  @StorageLink('uplayer_tab_indicator_opacity') tabIndicatorOpacity: number = 50
  @StorageLink('uplayer_glass_thickness') glassThickness: number = DEFAULT_GLASS_STYLE
  @StorageLink('uplayer_glass_saturation') glassSaturation: number = 1.4
  @StorageLink('uplayer_glass_brightness') glassBrightness: number = 1.02
  @StorageLink('uplayer_light_color_mode') lightColorMode: string = 'theme'
  @StorageLink('uplayer_tab_touch_indicator') tabTouchIndicator: string = 'light'
  @StorageLink('uplayer_interactive') interactive: boolean = true
  @StorageLink('uplayer_color_invert') colorInvert: boolean = false
  @StorageLink('uplayer_apply_shadow') applyShadow: boolean = true
  @StorageLink('uplayer_show_lyrics') showLyrics: boolean = true
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
  private poetryService: PoetryService = PoetryService.getInstance()
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

  private selectedTabContentColor(): ResourceColor {
    return this.isDarkTheme() ? '#FFFFFF' : ColorHelper.darken(this.primaryColor, 0.35)
  }

  private indicatorAlpha(base: number): number {
    const opacity: number = this.tabIndicatorOpacity / 100
    return Math.round(base * opacity * 255)
  }

  private indicatorGradientColor(base: number): ResourceColor {
    return ColorHelper.hexWithAlpha(this.primaryColor, this.indicatorAlpha(base).toString(16).padStart(2, '0'))
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

  // 当前 GlassStyle 字符串对应的 BlurStyle 枚举（用于 backgroundBlurStyle 通用属性）
  private glassBlurStyle(): BlurStyle {
    return glassBlurStyleFromStrength(this.glassThickness)
  }

  // 当前 GlassThickness 对应的 ImmersiveStyle 枚举（用于 uiMaterial 沉浸材质）
  private liquidGlassImmersiveStyle(): uiMaterial.ImmersiveStyle {
    return glassImmersiveStyleFromStrengthSmooth(this.glassThickness)
  }

  // ── 液态玻璃（沉浸式系统材质，HarmonyOS API 26+）──
  // THICK：官方推荐用于底部悬浮组件的材质档位；用户在设置里可切换薄/常规/厚。
  // interactive: true 开启交互形变（按压/拖动时 Q 弹反馈），
  // lightEffect 开启光效反馈（明亮光芒跟手流动），color 传 undefined 跟随系统默认光色。
  // 颜色由 lightColorMode 控制（白/主题），仅在 tabTouchIndicator='light' 时开启，
  // 否则传 undefined 让 lightEffect 完全关闭，便于外层使用系统自带的按压白色蒙版。
  private liquidGlassMaterial(): uiMaterial.Material {
    const useLight: boolean = this.tabTouchIndicator === 'light'
    const lightColor: string | undefined = useLight
      ? (this.lightColorMode === 'white' ? '#FFFFFF' : this.primaryColor)
      : undefined
    return new uiMaterial.ImmersiveMaterial({
      style: this.liquidGlassImmersiveStyle(),
      interactive: this.interactive,
      lightEffect: lightColor !== undefined ? { color: lightColor } : undefined,
      colorInvert: this.colorInvert,
      applyShadow: this.applyShadow
    })
  }

  // 开启白色蒙版（按下雾蒙蒙的发白指示器）时返回 HoverEffect.Highlight，否则返回 None
  // mask 模式下仅 Tab item 显示白色蒙版；light 模式下不做任何 hover 效果（避免白色蒙版）
  private bottomHoverEffect(): HoverEffect {
    return this.tabTouchIndicator === 'mask' ? HoverEffect.Highlight : HoverEffect.None
  }

  // 仅当「玻璃样式 + 设备系统达到 API 26」时启用真·液态玻璃；
  // 其余情况（经典样式、老系统）回退到原有 backgroundEffect 玻璃模糊。
  private liquidGlassEnabled(): boolean {
    return this.tabStyle === 'immersive' && isLiquidGlassAvailable()
  }

  private liquidGlassTabMaterial(): uiMaterial.Material | undefined {
    return this.liquidGlassEnabled() ? this.liquidGlassMaterial() : undefined
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

  onDisplaySizeChange(): void {
    this.updateIndicatorOffset(this.currentIndex)
  }

  aboutToAppear(): void {
    this.dataService.initToAppStorage()
    ColorConversion.setSysBarLightBackground(this.isDarkTheme())
    this.updateGreeting()
    this.loadPoetryLine()
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
          saturation: this.glassSaturation,
          brightness: this.glassBrightness
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
          color: ColorHelper.hexWithAlpha(this.primaryColor, this.indicatorAlpha(0.8).toString(16).padStart(2, '0')),
          offsetX: 0,
          offsetY: 0
        })
        .radialGradient({
          center: ['50%', '50%'],
          radius: '75%',
          colors: [
            [this.indicatorGradientColor(0.95), 0.0],
            [this.indicatorGradientColor(0.75), 0.58],
            [this.indicatorGradientColor(0.55), 1.0],
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
      // 液态玻璃启用时 systemMaterial 接管渲染；backgroundEffect 作为兜底模糊保留，
      // 确保 systemMaterial 低档位时 Tab 栏仍有半透明磨砂背景
      .backgroundEffect(this.isDarkTheme() ? undefined : {
        radius: this.glassBlurRadius(),
        saturation: this.glassSaturation,
        brightness: this.glassBrightness
      })
      // 液态玻璃：沉浸式系统材质 + 光效跟手 + 交互形变；能力不足时传 undefined 关闭
      .systemMaterial(this.liquidGlassTabMaterial())
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
        .fillColor(this.currentIndex === index ? this.selectedTabContentColor() :
          $r('app.color.tab_content_secondary'))
        .scale({
          x: this.currentIndex === index ? 1.15 : 1.0,
          y: this.currentIndex === index ? 1.15 : 1.0
        })
      Text(name)
        .fontSize(9)
        .fontColor(this.currentIndex === index ? this.selectedTabContentColor() :
          $r('app.color.tab_content_secondary'))
        .margin({ top: this.scaledSize(2) })
    }
    .width(this.scaledSize(this.tabWidth))
    .height(this.scaledSize(40))
    .justifyContent(FlexAlign.Center)
    .backgroundColor(this.hoverTabIndex === index && this.tabTouchIndicator === 'mask' ? 'rgba(255,255,255,0.16)' : Color.Transparent)
    .borderRadius(this.scaledSize(18))
    .shadow({
      radius: this.hoverTabIndex === index ? 14 : 0,
      color: this.hoverTabIndex === index ? ColorHelper.hexWithAlpha(this.primaryColor, '66') : Color.Transparent
    })
    .scale({ x: this.hoverTabIndex === index ? 1.06 : 1, y: this.hoverTabIndex === index ? 1.06 : 1 })
    .animation({ duration: StyleConstants.ANIMATION_HOVER_DURATION, curve: Curve.EaseOut })
    .hoverEffect(this.bottomHoverEffect())
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
        .fillColor(this.currentIndex === index ? this.selectedTabContentColor() :
          $r('app.color.tab_content_secondary'))
        .scale({
          x: this.currentIndex === index ? 1.15 : 1.0,
          y: this.currentIndex === index ? 1.15 : 1.0
        })
      Text(name)
        .fontSize(9)
        .fontColor(this.currentIndex === index ? this.selectedTabContentColor() :
          $r('app.color.tab_content_secondary'))
        .margin({ top: this.scaledSize(2) })
    }
    .width(this.scaledSize(this.tabWidth))
    .height(this.scaledSize(40))
    .justifyContent(FlexAlign.Center)
    .backgroundColor(this.hoverTabIndex === index && this.tabTouchIndicator === 'mask' ? 'rgba(255,255,255,0.18)' : Color.Transparent)
    .borderRadius(this.scaledSize(18))
    .shadow({
      radius: this.hoverTabIndex === index ? 16 : 0,
      color: this.hoverTabIndex === index ? ColorHelper.hexWithAlpha(this.primaryColor, '77') : Color.Transparent
    })
    .scale({ x: this.hoverTabIndex === index ? 1.06 : 1, y: this.hoverTabIndex === index ? 1.06 : 1 })
    .animation({ duration: StyleConstants.ANIMATION_HOVER_DURATION, curve: Curve.EaseOut })
    .hoverEffect(this.bottomHoverEffect())
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

  loadPoetryLine(): void {
    this.poetryService.fetchRandomLine().then((line: string) => {
      if (line.length === 0) {
        return
      }
      this.getUIContext()?.animateTo({ duration: 600, curve: Curve.EaseOut }, () => {
        this.poetryLine = line
      })
    })
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
          SymbolGlyph($r('sys.symbol.music_note_list'))
            .fontSize(this.scaledSize(20))
            .fontColor([$r('app.color.player_icon_color')])
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
      if (this.showLyrics && this.isPC && this.currentSongTitle.length > 0 &&
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
        .height(this.scaledSize(18))
        .fillColor($r('app.color.player_icon_color'))
        .onClick(() => { this.playPrevious() })
      Image(this.isPlaying ? $r('app.media.ic_public_pause') : $r('app.media.ic_public_play'))
        .height(this.scaledSize(22))
        .fillColor($r('app.color.player_icon_color'))
        .onClick(() => {
          this.togglePlay()
        })
      Image($r('app.media.ic_public_play_next'))
        .height(this.scaledSize(18))
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
    // 玻璃样式 + 暗黑模式 + 非 API 26 时不应用 backgroundEffect，保持纯黑底；
    // 真机 API 26+ 由 systemMaterial 接管；浅色模式保留原玻璃模糊回退
    .backgroundEffect(this.tabStyle === 'immersive' && !this.isDarkTheme() ? {
      radius: this.glassBlurRadius(),
      saturation: this.glassSaturation,
      brightness: this.glassBrightness
    } : undefined)
    .systemMaterial(this.tabStyle === 'immersive' ? this.liquidGlassTabMaterial() : undefined)
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

  playPrevious(): void {
    this.avPlayerService.playPreviousSong()
  }

  playNext(): void {
    this.avPlayerService.playNextSong()
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
        Stack({ alignContent: Alignment.Top }) {
          HomeContent({
            topContentPadding: this.homeHeaderHeight(),
            bottomContentPadding: this.bottomOverlayInset()
          })
            .width('100%')
            .height('100%')

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
                .translate({ y: this.greetingOffset + (this.isPC ? this.scaledSize(8) : 0) })
              if (this.poetryLine.length > 0) {
                Text(this.poetryLine)
                  .fontSize(Math.round(12 * this.fontSizeScale))
                  .fontColor($r('app.color.text_sixty_color'))
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .margin({ left: 10 })
                  .layoutWeight(1)
                  .opacity(this.greetingOpacity)
                  .translate({ y: this.isPC ? this.scaledSize(8) : 0 })
                  .transition({ type: TransitionType.Insert, opacity: 0, translate: { y: 6 } })
              }
              Blank()
            }
            .width('100%')
            .height('100%')
            .justifyContent(FlexAlign.Start)
            .alignItems(VerticalAlign.Center)
            .padding({
              top: this.topContentInset(),
              left: 16,
              right: this.isPC ? Math.max(this.titleButtonWidth, 140) + 12 : 8
            })
          }
          .width('100%')
          .height(this.homeHeaderHeight())
          .hitTestBehavior(HitTestMode.Transparent)
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
