import { curves, uiMaterial } from '@kit.ArkUI'
import {
  HdsTabs, HdsTabsController, HdsTabsFloatingStyle, HdsTabsMiniBar, hdsMaterial
} from '@kit.UIDesignKit'
import { common, ConfigurationConstant } from '@kit.AbilityKit'
import { deviceInfo } from '@kit.BasicServicesKit'
import { KeyCode } from '@kit.InputKit'
import { AppStorageKeyConstants } from '../common/constants/AppStorageKeyConstants'
import { SongInfo } from '../model/SongInfo'
import { AVPlayerService } from '../service/AVPlayerService'
import { HomeContent } from './HomeContent'
import { PlaylistContent } from './PlaylistContent'
import { SettingsContent } from './SettingsContent'
import { DataService } from '../service/DataService'
import { PoetryService } from '../service/PoetryService'
import { ColorHelper } from '../common/utils/ColorHelper'
import {
  createBarGlassMaterial,
  createTabImmersiveMaterial,
  DEFAULT_GLASS_STYLE,
  getDeviceMaterialLevel,
  isLiquidGlassAvailable
} from '../common/utils/GlassUtil'
import Logger from '../common/utils/Logger'
import { LrcEntry } from '../viewmodel/LrcEntry'
import { loadLyricEntries } from '../service/LyricLoader'
import { AlbumCover } from '../component/AlbumCover'
import { ColorConversion } from '../common/utils/ColorConversion'
import { StyleConstants } from '../common/constants/StyleConstants'
import { ImportProgressOverlay } from '../view/ImportProgressOverlay'
import {
  KEY_HAS_POINTER_DEVICE,
  refreshPointerDeviceState,
  startPointerDeviceListener
} from '../common/utils/InputDeviceUtil'

const TAG = 'Index'


@Entry
@Component
struct MainPage {
  @State currentIndex: number = 0
  @State greetingTitle: string = '加载中……'
  @State greetingOpacity: number = 0
  @State greetingOffset: number = 20
  // 主页多选状态（由 HomeContent 写入）：进入多选时问候语整体上滑淡出，退出时回落淡入
  @StorageLink(AppStorageKeyConstants.KEY_HOME_MULTI_SELECT) @Watch(
    'onHomeMultiSelectChange') homeMultiSelect: boolean = false
  @State greetingShiftY: number = 0
  @State greetingVisible: number = 1
  @State poetryLine: string = ''
  @StorageLink(AppStorageKeyConstants.KEY_IS_PLAY) @Watch('onPlayStateChange') isPlaying: boolean = false
  @State rotationAngle: number = 0
  @State isGlowing: boolean = false
  @State breakpoint: string = 'md'
  // 主容器实测布局宽度（vp），onAreaChange 更新：悬浮样式宽度字段不支持百分比，需用具体 vp 值
  @State mainWidthVp: number = 0
  @StorageLink(AppStorageKeyConstants.KEY_TOP_HEIGHT) topSafeHeight: number = 0
  @StorageLink(AppStorageKeyConstants.KEY_BOTTOM_HEIGHT) bottomSafeHeight: number = 0
  @StorageLink(AppStorageKeyConstants.KEY_TITLE_BUTTON_WIDTH) titleButtonWidth: number = 0
  @StorageLink(AppStorageKeyConstants.KEY_TITLE_BUTTON_HEIGHT) titleButtonHeight: number = 0
  @StorageLink('uplayer_current_title') currentSongTitle: string = ''
  @StorageLink('uplayer_current_artist') currentSongArtist: string = ''
  @StorageLink('uplayer_current_album_art') @Watch('onAlbumArtChange') currentSongAlbumArt: string = ''
  // 播控条封面/迷你歌词按 id 解析当前歌曲，避免队列下标失配
  @StorageLink('uplayer_current_song_id') @Watch('onCurrentSongChange') currentSongId: string = ''
  @StorageLink('uplayer_primary_color') primaryColor: string = '#007DFF'
  @StorageLink('uplayer_theme_mode') themeMode: string = 'system'
  @StorageLink('uplayer_display_size_scale') @Watch('onDisplaySizeChange') displaySizeScale: number = 1.0
  @StorageLink('uplayer_font_size_scale') fontSizeScale: number = 1.0
  @StorageLink('uplayer_tab_style') tabStyle: string = 'classic'
  @StorageLink('uplayer_glass_blur_strength') glassBlurStrength: number = 25
  @StorageLink('uplayer_glass_thickness') glassThickness: number = DEFAULT_GLASS_STYLE
  @StorageLink('uplayer_light_color_mode') lightColorMode: string = 'theme'
  @StorageLink('uplayer_tab_touch_indicator') tabTouchIndicator: string = 'light'
  @StorageLink('uplayer_tab_indicator_opacity') tabIndicatorOpacity: number = 50
  @StorageLink('uplayer_tab_indicator_visible') tabIndicatorVisible: boolean = true
  // 是否存在鼠标/触控板设备（决定「白色蒙版」功能是否存在：无鼠标时 mask 降级为 off）
  @StorageLink(KEY_HAS_POINTER_DEVICE) hasPointerDevice: boolean = false
  @StorageLink('uplayer_interactive') interactive: boolean = true
  @StorageLink('uplayer_color_invert') colorInvert: boolean = false
  @StorageLink('uplayer_apply_shadow') applyShadow: boolean = true
  @StorageLink('uplayer_glass_frost_overlay') glassFrostOverlay: boolean = false
  @State albumArtFailed: boolean = false
  @State isTitleMarqueeRunning: boolean = true
  @State isArtistMarqueeRunning: boolean = true
  @State currentLyricLine: string = ''
  @State nextLyricLine: string = ''
  @State lyricEntries: LrcEntry[] = []
  @StorageLink(AppStorageKeyConstants.KEY_PROGRESS) @Watch('onProgressChange') playProgress: number = 0
  @StorageLink(AppStorageKeyConstants.KEY_SELECT_INDEX) @Watch('onCurrentSongChange') selectedSongIndex: number = 0
  // 曲库歌词引用发生集合级变化（自愈回填 / 重新导入）时重新加载迷你歌词
  @StorageProp(AppStorageKeyConstants.KEY_LYRIC_REVISION) @Watch('loadCurrentLyrics') lyricRevision: number = 0
  // 主窗口可见性（EntryAbility 前后台写入）：窗口隐藏时停掉封面旋转定时器，避免持续请求 vsync
  @StorageProp(AppStorageKeyConstants.KEY_UI_ACTIVE) @Watch('onUiActiveChange') uiActive: boolean = true
  private tabsController: HdsTabsController = new HdsTabsController()
  private tabWidth: number = 72
  private indicatorInset: number = 4
  private rotationTimer: number = -1
  private dataService: DataService = DataService.getInstance()
  private poetryService: PoetryService = PoetryService.getInstance()
  private avPlayerService: AVPlayerService = AVPlayerService.getInstance()
  private isPC: boolean = deviceInfo.deviceType === '2in1'
  private lyricLoadRequestId: number = 0

  onDisplaySizeChange(): void {
    // 官方 Tabs 指示器由系统管理，无需手动更新 offset
  }

  aboutToAppear(): void { // AppStorage 已由 EntryAbility 在 loadContent 之前完成初始化（initToAppStorage 幂等）， // 此处不再重复调用，避免重复执行可访问性检查与授权激活竞态
    ColorConversion.setSysBarLightBackground(this.isDarkTheme())
    this.updateGreeting()
    this.loadPoetryLine()
    this.logGlassGate() // 玻璃能力诊断（一次性）
    this.loadCurrentLyrics() // 白色蒙版开关按鼠标/触控板检测结果显隐：刷新状态并监听热插拔
    refreshPointerDeviceState()
    startPointerDeviceListener()
    this.getUIContext()?.animateTo({ duration: StyleConstants.ANIMATION_GREETING_DURATION, curve: Curve.EaseOut },
      () => {
        this.greetingOpacity = 1
        this.greetingOffset = 0
      })
  }

  // 手机/平板的返回键与侧滑返回：仅 @Entry 组件可监听
  onBackPress(): boolean {
    return this.tryExitMultiSelect()
  }

  onFolderClick(): void {
    this.tabsController.changeIndex(0)
  }

  // 让位给随后切换到该位置的 HomeContent 多选菜单栏
  onHomeMultiSelectChange(): void {
    const hidden: boolean = this.homeMultiSelect
    this.getUIContext()?.animateTo({
      duration: hidden ? StyleConstants.ANIMATION_GREETING_HIDE_DURATION :
        StyleConstants.ANIMATION_GREETING_SHOW_DURATION, curve: hidden ? Curve.EaseInOut : Curve.EaseOut
    }, () => {
      this.greetingShiftY = hidden ? -24 : 0
      this.greetingVisible = hidden ? 0 : 1
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

  // 断点改由主容器实际布局宽度（vp）驱动：折叠屏折叠/展开、窗口缩放、旋转都会实时触发 onAreaChange，
  // 而 display.getDefaultDisplaySync().width 返回的是物理屏宽，折叠态不会随之收窄，导致断点卡在展开态。
  updateBreakpointByVp(vpWidth: number) {
    let bp: string
    if (vpWidth < 320) {
      bp = 'sm'
    } else if (vpWidth < 600) {
      bp = 'md'
    } else if (vpWidth < 840) {
      bp = 'lg'
    } else if (vpWidth < 1280) {
      bp = 'xl'
    } else {
      bp = 'xxl'
    }
    if (this.breakpoint !== bp) {
      this.breakpoint = bp
      Logger.info(TAG, `breakpoint -> ${bp} (windowWidth=${vpWidth}vp)`)
    }
  }

  // 玻璃能力诊断：一次性把两套材质体系的判定值都打出来，定位"该出玻璃却出模糊"的原因
  private logGlassGate(): void {
    let api26: boolean = false
    let uiImmersive: boolean = false
    let hdsTypes: string = 'n/a'
    try {
      api26 = deviceInfo.apiAvailable('26.0.0')
    } catch (e) {
    }
    try {
      uiImmersive = uiMaterial.isImmersiveMaterialSupported()
    } catch (e) {
    }
    try {
      const types: Array<hdsMaterial.MaterialType> = hdsMaterial.getSystemMaterialTypes()
      const names: string[] = []
      for (const t of types) {
        if (t === hdsMaterial.MaterialType.IMMERSIVE) {
          names.push('IMMERSIVE')
        } else if (t === hdsMaterial.MaterialType.ADAPTIVE) {
          names.push('ADAPTIVE')
        } else if (t === hdsMaterial.MaterialType.NONE) {
          names.push('NONE')
        } else {
          names.push(String(t))
        }
      }
      hdsTypes = names.join(',')
    } catch (e) {
    }
    Logger.info(TAG,
      `glassGate api26=${api26} uiImmersive=${uiImmersive} hdsTypes=[${hdsTypes}] ` +
        `matLevel=${String(getDeviceMaterialLevel())} liquidGlass=${isLiquidGlassAvailable()} ` +
        `tabStyle=${this.tabStyle} glassTh=${this.glassThickness}`)
  }

  private getHdsBarFloatingStyle(): HdsTabsFloatingStyle | undefined {
    if (this.tabStyle !== 'immersive' || !isLiquidGlassAvailable()) {
      return undefined
    }
    // glassThickness <= 0 时仍返回 pill 配置（与开启时布局完全一致），
    // 仅 systemMaterialEffect 为 undefined（无玻璃材质效果）。
    // 布局由断点决定：小屏 sm/md 上下叠，大屏 lg/xl 左右分栏。
    const level: hdsMaterial.MaterialLevel = hdsMaterial.MaterialLevel.ADAPTIVE
    const useLight: boolean = this.tabTouchIndicator === 'light'
    const lightColor: ResourceColor | undefined = useLight
      ? (this.lightColorMode === 'white' ? '#FFFFFF' : this.primaryColor)
      : undefined
    const smallScreen: boolean = this.breakpoint === 'sm' || this.breakpoint === 'md'
    const barWidthVp: number = Math.round(this.mainWidthVp * 0.4)
    const hasBarWidth: boolean = this.mainWidthVp > 0
    // 小屏/折叠态（sm/md）：系统会把页签栏强制收折成小胶囊并接管迷你栏布局，
    // 不下发系统迷你栏，改由 build() 中自建的 playerControl 播控条叠放在 TabBar 上方。
    // 大屏态（lg/xl/xxl）：下发系统迷你栏，左右并排。
    let miniBar: HdsTabsMiniBar | undefined = undefined
    if (!smallScreen) {
      const miniBarWidthVp: number = Math.min(328, barWidthVp)
      miniBar = {
        miniBarBuilder: (): void => {
          this.miniBarBuilder()
        },
        enableMiniBarBackground: true,
        miniBarWidth: hasBarWidth ?
          { smallWidth: miniBarWidthVp, mediumWidth: miniBarWidthVp, largeWidth: miniBarWidthVp } : undefined,
      }
    }
    return {
      adaptToHandedness: true,
      systemMaterialEffect: this.glassThickness > 0 ? {
        materialType: hdsMaterial.MaterialType.IMMERSIVE,
        materialLevel: level,
      } : undefined,
      barBottomMargin: this.bottomSafeHeight > 0 ? 28 : 28,
      lightColor: lightColor,
      barWidth: (smallScreen || !hasBarWidth || this.glassThickness <= 0) ? undefined :
        { smallWidth: barWidthVp, mediumWidth: barWidthVp, largeWidth: barWidthVp },
      miniBar: miniBar,
    } as HdsTabsFloatingStyle
  }

  // 经典样式或 API 26 不可用时的 TabBar 毛玻璃：映射 glassBlurStrength → BlurStyle
  // glassBlurStrength 为 0（关闭）时返回 NONE
  private getBarBackgroundBlur(): BlurStyle {
    if (this.glassBlurStrength <= 0) {
      return BlurStyle.NONE
    }
    if (this.glassBlurStrength <= 30) {
      return BlurStyle.Thin
    }
    if (this.glassBlurStrength <= 50) {
      return BlurStyle.Regular
    }
    return BlurStyle.Thick
  }

  @Builder
  private tabLabelBuilder(index: number, name: string, icon: Resource) {
    Stack() {
      // 指示器光晕：选中 tab 时渲染径向渐变 + 蓝色光晕
      if (this.tabIndicatorVisible && this.currentIndex === index) {
        Row()
          .width(this.scaledSize(this.tabWidth - 2 * this.indicatorInset))
          .height(this.scaledSize(36))
          .borderRadius(this.scaledSize(18))
          .shadow({
            radius: 14,
            color: this.indicatorGradientColor(0.8),
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
      }

      Column() {
        Image(icon)
          .height(this.scaledSize(20))
          .fillColor(this.currentIndex === index ? this.selectedTabContentColor() : $r('app.color.tab_content_secondary'))
          .scale({
            x: this.currentIndex === index ? 1.25 : 1.0, y: this.currentIndex === index ? 1.25 : 1.0
          })
        Text(name)
          .fontSize(8)
          .fontColor(this.currentIndex === index ? this.selectedTabContentColor() : $r('app.color.tab_content_secondary'))
          .margin({ top: this.scaledSize(1) })
      }.width(this.scaledSize(this.tabWidth)).height(this.scaledSize(36)).justifyContent(FlexAlign.Center)
    }
    .width(this.scaledSize(this.tabWidth))
    .height(this.scaledSize(36))
  }

  @Builder
  playerControl() {
    Row({ space: this.scaledSize(20) }) {
      if (this.currentSongTitle.length > 0) {
        AlbumCover({
          song: this.currentSong(),
          coverWidth: this.scaledSize(32),
          coverHeight: this.scaledSize(32),
          coverRadius: this.scaledSize(16)
        }).width(this.scaledSize(32)).height(this.scaledSize(32)).rotate({ angle: this.rotationAngle }).onClick(() => {
          this.openPlayer()
        })
      } else {
        Stack() {
          Image($r('app.media.ic_public_music'))
            .width(this.scaledSize(20))
            .height(this.scaledSize(20))
            .fillColor($r('app.color.player_icon_inactive_color'))
        }
        .width(this.scaledSize(32))
        .height(this.scaledSize(32))
        .borderRadius(this.scaledSize(16))
        .rotate({ angle: this.rotationAngle })
        .onClick(() => {
          this.openPlayer()
        })
      }

      Column() {
        if (this.currentSongTitle.length > 0) {
          Column() {
            Marquee({
              start: this.isTitleMarqueeRunning,
              step: 2,
              loop: -1,
              fromStart: true,
              src: this.currentSongTitle
            })
              .fontSize(Math.round(13 * this.fontSizeScale))
              .fontColor($r('app.color.text_primary'))
              .fontWeight(FontWeight.Medium)
              .width('100%')
              .onFinish(() => {
                this.isTitleMarqueeRunning = false
              })
            Marquee({
              start: this.isArtistMarqueeRunning,
              step: 1,
              loop: -1,
              fromStart: true,
              src: this.currentSongArtist.length > 0 ? this.currentSongArtist : '未知歌手'
            })
              .fontSize(Math.round(10 * this.fontSizeScale))
              .fontColor($r('app.color.text_sixty_color'))
              .width('100%')
              .onFinish(() => {
                this.isArtistMarqueeRunning = false
              })
          }.width('100%').alignItems(HorizontalAlign.Start)
        } else {
          Column() {
            Text('未播放')
              .fontSize(Math.round(11 * this.fontSizeScale))
              .fontColor($r('app.color.text_twenty_color'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }.width('100%').alignItems(HorizontalAlign.Start)
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
        }.layoutWeight(this.lyricInfoWeight()).alignItems(HorizontalAlign.Start).onClick(() => {
          this.openPlayer()
        })
      }
      Image($r('app.media.ic_public_play_last'))
        .height(this.scaledSize(18))
        .fillColor(this.currentSongTitle.length > 0 ? $r('app.color.player_icon_color') :
          $r('app.color.player_icon_inactive_color'))
        .onClick(() => {
          this.playPrevious()
        })
      Image(this.isPlaying ? $r('app.media.ic_public_play') : $r('app.media.ic_public_pause'))
        .height(this.scaledSize(22))
        .fillColor(this.currentSongTitle.length > 0 ? $r('app.color.player_icon_color') :
          $r('app.color.player_icon_inactive_color'))
        .onClick(() => {
          this.togglePlay()
        })
      Image($r('app.media.ic_public_play_next'))
        .height(this.scaledSize(18))
        .fillColor(this.currentSongTitle.length > 0 ? $r('app.color.player_icon_color') :
          $r('app.color.player_icon_inactive_color'))
        .onClick(() => {
          this.playNext()
        })
    }
    .constraintSize({ maxWidth: this.breakpoint === 'sm' || this.breakpoint === 'md' ? '85%' : '42%' })
    .height(this.scaledSize(40))
    .alignSelf(ItemAlign.Center)
    .padding({
      left: this.scaledSize(12),
      right: this.scaledSize(16),
      top: this.scaledSize(4),
      bottom: this.scaledSize(4)
    })
    .backgroundColor(Color.Transparent)
    .backgroundEffect(this.frostLayerEnabled() ? {
      radius: this.glassBlurRadius()
    } : undefined)
    .systemMaterial(this.bottomBarGlassMaterial())
    .border({
      width: 1, color: 'rgba(255,255,255,0.22)'
    })
    .borderRadius(this.scaledSize(20))
    .shadow({
      radius: this.isGlowing ? 60 : 50,
      color: this.isGlowing ? ColorHelper.hexWithAlpha(this.primaryColor, '66') : $r('app.color.shadow_color'),
      offsetY: 5
    })
  }

  @Builder
  miniBarBuilder() {
    Row({ space: this.scaledSize(8) }) {
      if (this.currentSongTitle.length > 0) {
        AlbumCover({
          song: this.currentSong(),
          coverWidth: this.scaledSize(36),
          coverHeight: this.scaledSize(36),
          coverRadius: this.scaledSize(18)
        }).width(this.scaledSize(36)).height(this.scaledSize(36)).rotate({ angle: this.rotationAngle }).onClick(() => {
          this.openPlayer()
        })
      } else {
        Stack() {
          Image($r('app.media.ic_public_music'))
            .width(this.scaledSize(24))
            .height(this.scaledSize(24))
            .fillColor($r('app.color.player_icon_inactive_color'))
        }
        .width(this.scaledSize(36))
        .height(this.scaledSize(36))
        .borderRadius(this.scaledSize(18))
        .rotate({ angle: this.rotationAngle })
        .onClick(() => {
          this.openPlayer()
        })
      }

      Column() {
        if (this.currentSongTitle.length > 0) {
          Column() {
            Marquee({
              start: this.isTitleMarqueeRunning,
              step: 2,
              loop: -1,
              fromStart: true,
              src: this.currentSongTitle
            })
              .fontSize(Math.round(13 * this.fontSizeScale))
              .fontColor($r('app.color.text_primary'))
              .fontWeight(FontWeight.Medium)
              .width('100%')
              .onFinish(() => {
                this.isTitleMarqueeRunning = false
              })
            Marquee({
              start: this.isArtistMarqueeRunning,
              step: 1,
              loop: -1,
              fromStart: true,
              src: this.currentSongArtist.length > 0 ? this.currentSongArtist : '未知歌手'
            })
              .fontSize(Math.round(10 * this.fontSizeScale))
              .fontColor($r('app.color.text_sixty_color'))
              .width('100%')
              .onFinish(() => {
                this.isArtistMarqueeRunning = false
              })
          }.width('100%').alignItems(HorizontalAlign.Start)
        } else {
          Column() {
            Text('未播放')
              .fontSize(Math.round(11 * this.fontSizeScale))
              .fontColor($r('app.color.text_twenty_color'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }.width('100%').alignItems(HorizontalAlign.Start)
        }
      }
      .layoutWeight(this.songInfoWeight())
      .margin({ left: this.scaledSize(4), right: this.scaledSize(4) })
      .onClick(() => {
        this.openPlayer()
      })

      Image($r('app.media.ic_public_play_last'))
        .height(this.scaledSize(24))
        .fillColor(this.currentSongTitle.length > 0 ? $r('app.color.player_icon_color') :
          $r('app.color.player_icon_inactive_color'))
        .onClick(() => {
          this.playPrevious()
        })
      Image(this.isPlaying ? $r('app.media.ic_public_play') : $r('app.media.ic_public_pause'))
        .height(this.scaledSize(28))
        .fillColor(this.currentSongTitle.length > 0 ? $r('app.color.player_icon_color') :
          $r('app.color.player_icon_inactive_color'))
        .onClick(() => {
          this.togglePlay()
        })
      Image($r('app.media.ic_public_play_next'))
        .height(this.scaledSize(24))
        .fillColor(this.currentSongTitle.length > 0 ? $r('app.color.player_icon_color') :
          $r('app.color.player_icon_inactive_color'))
        .onClick(() => {
          this.playNext()
        })
    }
    .height(this.scaledSize(40))
    .alignSelf(ItemAlign.Center)
    .padding({
      left: this.scaledSize(10),
      right: this.scaledSize(12),
      top: this.scaledSize(2),
      bottom: this.scaledSize(2)
    })
  }

  // 颜色由 lightColorMode 控制（白/主题），仅在 tabTouchIndicator='light' 时开启，

  openPlayer(): void {
    if (this.currentSongTitle.length === 0) {
      return
    }
    this.getUIContext().getRouter().pushUrl({ url: 'pages/MusicPlayer' })
  }

  // 仅当「玻璃样式 + 设备系统达到 API 26 + 厚度未关断」时启用真·液态玻璃；

  onAlbumArtChange(): void {
    this.albumArtFailed = false
  }

  // 磨砂层挂载条件（经典 Tab 栏 / 玻璃 Tab 栏 / 播控条三处统一）：
  // - 暗黑模式或模糊强度为 0：从不挂载（保持原有行为）
  // - 无液态玻璃能力的老设备（设置页中开关已隐藏）：保留兜底磨砂层，由模糊强度控制
  // - 新设备：磨砂层与玻璃厚度/材质状态完全解耦，唯一判据是「磨砂层叠加」开关——

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
    this.nextLyricLine =
      currentIndex >= 0 && currentIndex + 1 < this.lyricEntries.length ? this.lyricEntries[currentIndex + 1].lineWords :
        ''
  }

  async loadCurrentLyrics(): Promise<void> {
    const requestId: number = ++this.lyricLoadRequestId
    this.lyricEntries = []
    this.currentLyricLine = ''
    this.nextLyricLine = ''
    const song: SongInfo = this.currentSong() // 准入条件是「当前播放歌曲有效」（按 id 解析），与队列下标、标题无关
    if (song.id.length === 0) {
      return
    }
    const entries: LrcEntry[] = await loadLyricEntries(song)
    if (requestId !== this.lyricLoadRequestId || this.currentSongId !== song.id) {
      return
    }
    this.lyricEntries = entries
    this.onProgressChange()
  }

  onPlayStateChange(): void {
    if (this.isPlaying) {
      this.getUIContext()?.animateTo(
        { duration: StyleConstants.ANIMATION_ROTATION_START_DURATION, curve: curves.springMotion(0.3, 0.7) }, () => {
        this.rotationAngle += 30
      })
      setTimeout(() => {
        this.startRotation()
      }, StyleConstants.ANIMATION_ROTATION_START_DURATION)
      this.getUIContext()?.animateTo({ duration: StyleConstants.ANIMATION_GLOW_ON_DURATION, curve: Curve.EaseInOut },
        () => {
          this.isGlowing = true
        })
    } else {
      this.stopRotation()
      this.getUIContext()?.animateTo({ duration: StyleConstants.ANIMATION_GLOW_OFF_DURATION, curve: Curve.EaseInOut },
        () => {
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

  // ── 返回键 / ESC 退出多选 ──
  // 多选态只存在于首页（tab 0），所以只在「当前在首页且处于多选」时拦截；
  // 其余情况必须返回 false，让系统执行默认返回逻辑（Index 是根页面，默认即退出应用）。

  startRotation() {
    this.stopRotation() // 窗口隐藏时不起旋转定时器：角度原地冻结，回前台由 onUiActiveChange 续转，无跳变
    if (!this.uiActive) {
      return
    }
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

  onUiActiveChange(): void {
    if (!this.uiActive) {
      this.stopRotation()
      return
    }
    if (this.isPlaying) {
      this.startRotation()
    }
  }

  aboutToDisappear(): void {
    this.stopRotation()
  }

  pageTransition() {
    PageTransitionEnter(
      { duration: StyleConstants.ANIMATION_PAGE_ENTER_DURATION, curve: curves.springMotion(0.6, 0.8) })
      .scale({ x: 0.92, y: 0.92 })
      .opacity(0.7)
    PageTransitionExit({ duration: StyleConstants.ANIMATION_PAGE_EXIT_DURATION, curve: curves.springMotion(0.7, 0.9) })
      .scale({ x: 0.92, y: 0.92 })
      .opacity(0.7)
  }

  // 主页进入/退出多选：问候语向上位移并淡出（退出时反向回落淡入），

  build() {
    Stack() {
      HdsTabs({ controller: this.tabsController, index: this.currentIndex }) {
        TabContent() {
          Stack({ alignContent: Alignment.Top }) {
            HomeContent({
              topContentPadding: this.homeHeaderHeight(),
              bottomContentPadding: this.bottomOverlayInset(),
              greetingBandTop: this.topContentInset(),
              greetingBandHeight: this.homeHeaderHeight() - this.topContentInset()
            }).width('100%').height('100%')

            Stack() {
              Column()
                .width('140%')
                .aspectRatio(1)
                .borderRadius('50%')
                .position({ top: -80, left: -60 })
                .radialGradient({
                  center: ['50%', '50%'],
                  radius: '80%',
                  colors: [[ColorHelper.hexToRgba(this.primaryColor, 0.04), 0.0],
                    [ColorHelper.hexToRgba(this.primaryColor, 0.01), 0.6],
                    [ColorHelper.hexToRgba(this.primaryColor, 0), 1.0],]
                })
              Row() {
                Row() {
                  Text(this.greetingTitle)
                    .fontWeight(FontWeight.Bolder)
                    .fontSize(Math.round(28 * this.fontSizeScale))
                    .lineHeight(Math.round(28 * this.fontSizeScale))
                    .fontColor($r('app.color.text_primary'))
                    .opacity(this.greetingOpacity)
                  if (this.poetryLine.length > 0) {
                    Text(this.poetryLine)
                      .fontSize(Math.round(12 * this.fontSizeScale))
                      .lineHeight(Math.round(12 * this.fontSizeScale))
                      .fontColor($r('app.color.text_sixty_color'))
                      .maxLines(1)
                      .textOverflow({ overflow: TextOverflow.MARQUEE })
                      .margin({ left: 10 })
                      .constraintSize({ maxWidth: '60%' })
                      .opacity(this.greetingOpacity)
                      .transition({ type: TransitionType.Insert, opacity: 0, translate: { y: 6 } })
                  }
                }
                .alignItems(VerticalAlign.Bottom)
                .layoutWeight(1)
                .translate({ y: this.greetingShiftY })
                .opacity(this.greetingVisible)
              }
              .width('100%')
              .height('100%')
              .justifyContent(FlexAlign.Start)
              .alignItems(VerticalAlign.Center)
              .padding({
                top: this.topContentInset(), left: 16, right: this.isPC ? Math.max(this.titleButtonWidth, 140) + 12 : 8
              })
            }.width('100%').height(this.homeHeaderHeight()).hitTestBehavior(HitTestMode.Transparent)
          }.width('100%').height('100%')
        }
        .tabBar(this.tabLabelBuilder(0, '首页', $r('app.media.ic_public_home')))

        TabContent() {
          PlaylistContent({
            topContentPadding: this.topContentInset(),
            bottomContentPadding: this.bottomOverlayInset(),
            onNavigateToHome: (): void => {
              this.onFolderClick()
            }
          }).width('100%').height('100%')
        }
        .tabBar(this.tabLabelBuilder(1, '歌单', $r('app.media.ic_public_view_list')))

        TabContent() {
          SettingsContent({
            topContentPadding: this.topContentInset(), bottomContentPadding: this.bottomOverlayInset()
          }).width('100%').height('100%')
        }
        .tabBar(this.tabLabelBuilder(2, '设置', $r('app.media.ic_public_settings')))
      }
      .barPosition(BarPosition.End)
      .barOverlap(true)
      .barHeight(this.scaledSize(44))
      .barWidth(this.scaledSize(228))
      .scrollable(true)
      .barFloatingStyle(this.getHdsBarFloatingStyle())
      .barBackgroundBlurStyle(this.tabStyle !== 'immersive' || this.getHdsBarFloatingStyle() === undefined
        ? this.getBarBackgroundBlur() : BlurStyle.NONE)
      .animationDuration(StyleConstants.ANIMATION_SWIPER_DURATION)
      .onChange((index: number) => {
        this.currentIndex = index
      })
      .width('100%')
      .height('100%')

      // 小屏/折叠态（sm/md）：系统迷你栏无法纵向堆叠，改用自建播控条叠放。
      // 大屏态（lg/xl）：系统 miniBar 左右分栏；glassThickness=0 时 miniBar 也为 undefined，同样需要自建播控条。
      if ((this.breakpoint === 'sm' || this.breakpoint === 'md') || this.glassThickness <= 0) {
        Column() {
          this.playerControl()
        }
        .width('100%')
        .alignItems(HorizontalAlign.Center)
        .padding({ left: this.scaledSize(16), right: this.scaledSize(16) })
        .margin({ bottom: this.controlBarBottomMargin() })
        .hitTestBehavior(HitTestMode.Default)
      }

      // 导入进度浮层：置顶显示，未导入时不拦截触摸
      ImportProgressOverlay()
    }
    .alignContent(Alignment.Bottom)
    .width('100%')
    .height('100%')
    .onKeyEvent((event: KeyEvent): boolean => this.handleKeyEvent(event))
    // 以主容器实际宽度（vp）驱动断点，折叠屏折叠/展开、窗口缩放、旋转均可实时响应
    .onAreaChange((_oldArea: Area, newArea: Area) => {
      const w: number = newArea.width as number
      if (w > 0 && w !== this.mainWidthVp) {
        this.mainWidthVp = w
      }
      this.updateBreakpointByVp(w)
    })
  }

  private isDarkTheme(): boolean {
    if (this.themeMode === 'dark') {
      return true
    }
    if (this.themeMode === 'system') {
      const context: common.UIAbilityContext | undefined =
        AppStorage.get<common.UIAbilityContext>(AppStorageKeyConstants.KEY_UI_ABILITY_CONTEXT)
      return context?.config.colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK
    }
    return false
  }

  private indicatorAlpha(base: number): number {
    const opacity: number = this.tabIndicatorOpacity / 100
    return Math.round(base * opacity * 255)
  }

  private indicatorGradientColor(base: number): ResourceColor {
    return ColorHelper.hexWithAlpha(this.primaryColor, this.indicatorAlpha(base)
      .toString(16)
      .padStart(2, '0'))
  }

  private selectedTabContentColor(): ResourceColor {
    return this.isDarkTheme() ? '#FFFFFF' : ColorHelper.darken(this.primaryColor, 0.35)
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
    // sm/md：playerControl 高于 TabBar 顶部（TabBar 默认 barBottomMargin=28vp，高度=56vp）
    // 128vp ≈ 56(vp tab bar) + 28(vp barBottomMargin) + 40(vp playerControl) + 4(vp 间距)
    if (this.breakpoint === 'sm' || this.breakpoint === 'md') {
      return this.scaledSize(128) + this.bottomSafeHeight
    }
    // lg/xl：playerControl 与 TabBar 大致同高，88vp ≈ 28(barBottomMargin) + 56(bar height) + 4(间距)
    return this.scaledSize(88) + this.bottomSafeHeight
  }

  // 小屏态自建播控条的底部偏移：压在 TabBar 顶部正上方。
  // TabBar 悬浮于底部：barBottomMargin(28) + barHeight(scaled 44) 到屏幕底；再加 4vp 间距。
  private controlBarBottomMargin(): number {
    return 28 + this.scaledSize(44) + this.scaledSize(4)
  }

  private glassBlurRadius(): number {
    return this.glassBlurStrength * 0.5
  }

  // 否则传 undefined 让 lightEffect 完全关闭，便于外层使用系统自带的按压白色蒙版。

  // 磨砂层挂载条件（播控条使用，与 Tab 风格解耦；新设备由「磨砂层叠加」开关控制）
  private frostLayerEnabled(): boolean {
    if (this.isDarkTheme() || this.glassBlurStrength <= 0) {
      return false
    }
    if (!isLiquidGlassAvailable()) {
      return true
    }
    return this.glassFrostOverlay
  }

  // 底部播放信息栏的液态玻璃材质：与磨砂层一致，不区分 Tab 风格，两种样式统一挂载
  private bottomBarGlassMaterial(): uiMaterial.Material | undefined {
    return createBarGlassMaterial(this.glassThickness, this.interactive)
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

  // KeyCode 与 KeyEvent/KeyType 的用法与 MusicPlayer.handleKeyEvent 保持一致。
  private tryExitMultiSelect(): boolean {
    if (this.currentIndex !== 0 || !this.homeMultiSelect) {
      return false
    } // isMultiSelectMode 已是 @StorageLink，写入 AppStorage 即可让 HomeContent 退出多选， // 并由它的 @Watch 顺带清空选中集合
    AppStorage.setOrCreate(AppStorageKeyConstants.KEY_HOME_MULTI_SELECT, false)
    return true
  }

  // Ctrl 是否按下：getModifierKeyState 为 API 12+ 的可选方法，低版本设备上不存在则视为未按下
  private isCtrlPressed(event: KeyEvent): boolean {
    if (event.getModifierKeyState === undefined) {
      return false
    }
    return event.getModifierKeyState(['Ctrl'])
  }

  // 2in1/PC：MusicPlayer 里已证实 ESC 不会走 onBackPress，需要单独监听键盘
  private handleKeyEvent(event: KeyEvent): boolean {
    if (event.type !== KeyType.Down) {
      return false
    }
    if (event.keyCode === KeyCode.KEYCODE_ESCAPE) {
      return this.tryExitMultiSelect()
    }
    if (event.keyCode === KeyCode.KEYCODE_A && this.currentIndex === 0 && this.homeMultiSelect &&
      this.isCtrlPressed(event)) {
      const current: number = AppStorage.get<number>(AppStorageKeyConstants.KEY_HOME_SELECT_ALL_REQUEST) ?? 0
      AppStorage.setOrCreate(AppStorageKeyConstants.KEY_HOME_SELECT_ALL_REQUEST, current + 1)
      return true
    }
    return false
  }

  private currentSong(): SongInfo {
    const song: SongInfo | undefined = this.dataService.getSongById(this.currentSongId)
    return song !== undefined ? song : new SongInfo()
  }
}
