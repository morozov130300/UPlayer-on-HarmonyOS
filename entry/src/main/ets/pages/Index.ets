import { curves, uiMaterial } from '@kit.ArkUI'
import {
  HdsTabs, HdsTabsBackgroundStyle, HdsTabsController, HdsTabsFloatingStyle, HdsTabsMiniBar, hdsEffect, hdsMaterial
} from '@kit.UIDesignKit'
import { common } from '@kit.AbilityKit'
import { deviceInfo } from '@kit.BasicServicesKit'
import { KeyCode } from '@kit.InputKit'
import { AppStorageKeyConstants } from '../common/constants/AppStorageKeyConstants'
import { SongInfo } from '../model/SongInfo'
import { AVPlayerService } from '../service/AVPlayerService'
import { HomeContent } from './HomeContent'
import { PlaylistContent } from './PlaylistContent'
import { SettingsContent } from './SettingsContent'
import { DataService } from '../service/DataService'
import { importSongsWithToast } from '../service/SongScanner'
import { PoetryService } from '../service/PoetryService'
import { ColorHelper } from '../common/utils/ColorHelper'
import {
  DEFAULT_GLASS_STYLE,
  getDeviceMaterialLevel,
  isLiquidGlassAvailable
} from '../common/utils/GlassUtil'
import Logger from '../common/utils/Logger'
import { LrcEntry } from '../viewmodel/LrcEntry'
import { loadLyricEntries } from '../service/LyricLoader'
import { AlbumCover } from '../component/AlbumCover'
import { ColorConversion } from '../common/utils/ColorConversion'
import { isDarkThemeEffective } from '../common/utils/ThemeUtil'
import { StyleConstants } from '../common/constants/StyleConstants'
import { ImportProgressOverlay } from '../view/ImportProgressOverlay'
import { ScaleButton } from '../component/ScaleButton'
import { PressScaleHost } from '../component/PressScaleHost'
import { GlassPlusButton } from '../view/GlassPlusButton'

const TAG = 'Index'


@Entry
@Component
struct MainPage {
  @State currentIndex: number = 0
  // 加号 Tab 级挂载开关：由 HdsTabs onSelected 在点击/滑动切换动画开始的瞬间提前翻转
  // （onChange 要等切换动画结束才回调），保证切设置页的隐藏动画与页面切换动画同时启动
  @State plusTabMounted: boolean = true
  @State greetingTitle: string = '加载中……'
  @State greetingOpacity: number = 0
  // 主页多选状态（由 HomeContent 写入）：进入多选时问候语整体上滑淡出，退出时回落淡入
  @StorageLink(AppStorageKeyConstants.KEY_HOME_MULTI_SELECT) homeMultiSelect: boolean = false
  // 歌单页多选状态（由 PlaylistContent 写入）：与首页多选同一套机制，
  // 页面级返回键/ESC 需要能把它收回去，故同样挂 AppStorage
  @StorageLink(AppStorageKeyConstants.KEY_PLAYLIST_MULTI_SELECT) playlistMultiSelect: boolean = false
  // 歌单页文件夹编辑态：同属歌单页的批量操作，返回键/ESC 也要能收回
  @StorageLink(AppStorageKeyConstants.KEY_PLAYLIST_FOLDER_EDIT) playlistFolderEdit: boolean = false
  // 全局悬浮加号可见性（由各内容页上报）：滚动隐藏、多选/编辑态变化时写入，
  // 首页/歌单共用 Index 上的一颗加号，切页不重建不位移，设置页隐藏
  @StorageLink(AppStorageKeyConstants.KEY_HOME_PLUS_VISIBLE) homePlusVisible: boolean = true
  @StorageLink(AppStorageKeyConstants.KEY_PLAYLIST_PLUS_VISIBLE) playlistPlusVisible: boolean = true
  @State poetryLine: string = ''
  @StorageLink(AppStorageKeyConstants.KEY_IS_PLAY) @Watch('onPlayStateChange') isPlaying: boolean = false
  @State rotationAngle: number = 0
  @State isGlowing: boolean = false
  // 播控条「打开播放页」区域按压动效（封面/歌名/歌词块共用，同一时刻只有一处被按）
  @State pressedBarItem: boolean = false
  @StorageLink('uplayer_press_animation') pressAnimOn: boolean = false
  // ── spike: hdsEffect.pointLight 点光源跟手光效真机验证，失败整段回滚 ──
  // 光源位置（vp，相对播控条触控宿主 Stack），初始 -100 藏到条外
  @State spikeBarLightX: number = -100
  @State spikeBarLightY: number = -100
  @State spikeBarLightOn: boolean = false
  // miniBar 独立一套状态（两布局互斥渲染，不共用）
  @State spikeMiniLightX: number = -100
  @State spikeMiniLightY: number = -100
  @State spikeMiniLightOn: boolean = false
  @State breakpoint: string = 'md'
  // 主容器实测布局宽度（vp），onAreaChange 更新：悬浮样式宽度字段不支持百分比，需用具体 vp 值
  @State mainWidthVp: number = 0
  @StorageLink(AppStorageKeyConstants.KEY_TOP_HEIGHT) topSafeHeight: number = 0
  @StorageLink(AppStorageKeyConstants.KEY_BOTTOM_HEIGHT) bottomSafeHeight: number = 0
  @StorageLink(AppStorageKeyConstants.KEY_TITLE_BUTTON_WIDTH) titleButtonWidth: number = 0
  @StorageLink(AppStorageKeyConstants.KEY_TITLE_BUTTON_HEIGHT) titleButtonHeight: number = 0
  @StorageLink('uplayer_current_title') currentSongTitle: string = ''
  @StorageLink('uplayer_current_artist') currentSongArtist: string = ''
  // 播控条封面/迷你歌词按 id 解析当前歌曲，避免队列下标失配
  @StorageLink('uplayer_current_song_id') @Watch('onCurrentSongChange') currentSongId: string = ''
  @StorageLink('uplayer_primary_color') primaryColor: string = '#007DFF'
  @StorageLink('uplayer_theme_mode') themeMode: string = 'system'
  @StorageLink('uplayer_display_size_scale') displaySizeScale: number = 1.0
  @StorageLink('uplayer_font_size_scale') fontSizeScale: number = 1.0
  @StorageLink('uplayer_tab_style') tabStyle: string = 'classic'
  @StorageLink('uplayer_glass_blur_strength') glassBlurStrength: number = 25
  @StorageLink('uplayer_tab_light_color') tabLightColor: string = 'theme'
  @StorageLink('uplayer_tab_material_level') tabMaterialLevel: string = 'adaptive'
  @StorageLink('uplayer_tab_indicator_opacity') tabIndicatorOpacity: number = 50
  @State isTitleMarqueeRunning: boolean = true
  @State isArtistMarqueeRunning: boolean = true
  @State currentLyricLine: string = ''
  @State nextLyricLine: string = ''
  @State lyricEntries: LrcEntry[] = []
  @StorageLink(AppStorageKeyConstants.KEY_PROGRESS) @Watch('onProgressChange') playProgress: number = 0
  @StorageProp(AppStorageKeyConstants.KEY_SELECT_INDEX) @Watch('onCurrentSongChange') selectedSongIndex: number = 0
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

  aboutToAppear(): void { // AppStorage 已由 EntryAbility 在 loadContent 之前完成初始化（initToAppStorage 幂等）， // 此处不再重复调用，避免重复执行可访问性检查与授权激活竞态
    Logger.info(TAG, 'aboutToAppear begin')
    ColorConversion.setSysBarLightBackground(this.isDarkTheme())
    Logger.info(TAG, 'aboutToAppear after isDarkTheme')
    this.updateGreeting()
    this.loadPoetryLine()
    this.logGlassGate() // 玻璃能力诊断（一次性）
    Logger.info(TAG, 'aboutToAppear before loadCurrentLyrics')
    this.loadCurrentLyrics()
    Logger.info(TAG, 'aboutToAppear end')
    this.getUIContext()?.animateTo({ duration: StyleConstants.ANIMATION_GREETING_DURATION, curve: Curve.EaseOut },
      () => {
        this.greetingOpacity = 1
      })
  }

  // 手机/平板的返回键与侧滑返回：仅 @Entry 组件可监听
  onBackPress(): boolean {
    return this.tryExitMultiSelect()
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
        `tabStyle=${this.tabStyle} glassTh=${DEFAULT_GLASS_STYLE}`)
  }

  // 悬浮样式缓存：build() 每次重绘都会调用 barFloatingStyle()，键不变时复用同一对象，
  // 避免每帧新建样式对象触发 HdsTabs 样式重应用
  private hdsBarStyleCache: HdsTabsFloatingStyle | undefined = undefined
  private hdsBarStyleCacheKey: string = ''

  // 材质等级设置（uplayer_tab_material_level）→ hdsMaterial.MaterialLevel
  private tabMaterialLevelEnum(): hdsMaterial.MaterialLevel {
    if (this.tabMaterialLevel === 'exquisite') {
      return hdsMaterial.MaterialLevel.EXQUISITE
    }
    if (this.tabMaterialLevel === 'gentle') {
      return hdsMaterial.MaterialLevel.GENTLE
    }
    if (this.tabMaterialLevel === 'smooth') {
      return hdsMaterial.MaterialLevel.SMOOTH
    }
    return hdsMaterial.MaterialLevel.ADAPTIVE
  }

  private getHdsBarFloatingStyle(): HdsTabsFloatingStyle | undefined {
    // 缓存键覆盖全部输入（tabStyle/断点/主容器宽/光效配色/主题色/材质等级），键不变即样式不变
    const cacheKey: string = `${this.tabStyle}|${this.breakpoint}|${this.mainWidthVp}|` +
      `${this.tabLightColor}|${this.primaryColor}|` +
      `${this.tabMaterialLevel}`
    if (this.hdsBarStyleCache !== undefined && this.hdsBarStyleCacheKey === cacheKey) {
      return this.hdsBarStyleCache
    }
    // 经典样式与玻璃样式：除了底色（磨砂 vs 液态玻璃）外，整体布局（悬浮 TabBar + 并排 miniBar + barWidth + barBottomMargin）必须完全一致
    // 因此本方法在两种样式下都返回有效 barFloatingStyle，仅 systemMaterialEffect 在经典下不设置
    // 设备不支持液态玻璃时仍可走悬浮布局（只是没有玻璃材质），布局不降级
    const level: hdsMaterial.MaterialLevel = this.tabMaterialLevelEnum()
    // 选「无」时传全透明色显式关闭（lightColor 默认值是深浅色固定光效色，传 undefined 会回落默认光效而非关闭）
    const lightColor: ResourceColor = this.tabLightColor === 'none' ? Color.Transparent : this.followLightColor()
    const smallScreen: boolean = this.breakpoint === 'sm' || this.breakpoint === 'md'
    // Tab 栏宽度固定主容器宽 2/5，不受任何设置影响（用户拍板：Tab 栏不许动）
    const barWidthVp: number = Math.round(this.mainWidthVp * 0.4)
    const hasBarWidth: boolean = this.mainWidthVp > 0
    // 渐变遮罩恒禁用（用户拍板 2026-10-18：整体删除该设置，写死关闭）
    const gradientMask: HdsTabsBackgroundStyle = { maskColor: 'rgba(0,0,0,0)', maskHeight: 0 }
    // 小屏/折叠态（sm/md）：系统会把页签栏强制收折成小胶囊并接管迷你栏布局，
    // 不下发系统迷你栏，改由 build() 中自建的 playerControl 播控条叠放在 TabBar 上方。
    // 大屏态（lg/xl/xxl）：下发系统迷你栏，左右并排。
    let miniBar: HdsTabsMiniBar | undefined = undefined
    if (!smallScreen) {
      // 播控条宽度固定整个窗口的 1/3（用户拍板 2026-10-18：占窗口三分之一，定死）
      const miniBarWidthVp: number = Math.round(this.mainWidthVp / 3)
      // 迷你栏背景恒走系统背景（跟随页签栏）：迷你栏区域内自挂 backgroundBlurStyle 采样不到
      // 页面背景（渲染为透明，5cfa2cf 已证实）；自挂 systemMaterial 在迷你栏容器内也不渲染
      // （真机 MateBook Pro 实测：迷你栏是独立悬浮容器，不在官方文档规定的底部 TabBar
      // 液态玻璃生效区内），两种样式统一由系统背景提供底板，玻璃样式下跟随页签栏材质。
      miniBar = {
        miniBarBuilder: (): void => {
          this.miniBarBuilder()
        },
        // 迷你栏背景恒走系统背景（跟随页签栏）：自挂 systemMaterial 在迷你栏 builder 内容上
        // 不渲染（2026-10-18 三次真机实证：含无背景层干扰的干净配置，底板仍纯黑透明，
        // 官方 FAQ 生效区限制——builder 内容属"其他组件"不在底部 TabBar 生效区内）
        enableMiniBarBackground: true,
        // 关闭迷你栏容器对 builder 内容的默认裁剪（SDK 默认 enableMiniBarClip=true）：
        // 否则交互形变鼓包超出容器边界的部分被剪掉，不动边缘看起来像一圈"围栏"
        enableMiniBarClip: false,
        miniBarWidth: hasBarWidth ?
          { smallWidth: miniBarWidthVp, mediumWidth: miniBarWidthVp, largeWidth: miniBarWidthVp } : undefined,
      }
    }
    let style: HdsTabsFloatingStyle
    // 仅沉浸式样式下发液态玻璃材质；经典样式 systemMaterialEffect 保持 undefined（不挂玻璃），
    // 由 barBackgroundBlurStyle 走磨砂兜底。这样两种样式的布局与组件完全一致，只差底色。
    if (this.tabStyle === 'immersive' && isLiquidGlassAvailable()) {
      style = {
        adaptToHandedness: true,
        gradientMask: gradientMask,
        systemMaterialEffect: {
          materialType: hdsMaterial.MaterialType.IMMERSIVE,
          materialLevel: level,
        },
        barOpacity: 1,
        barBottomMargin: 25,
        lightColor: lightColor,
        barWidth: (smallScreen || !hasBarWidth) ? undefined :
          { smallWidth: barWidthVp, mediumWidth: barWidthVp, largeWidth: barWidthVp },
        miniBar: miniBar,
      } as HdsTabsFloatingStyle
    } else {
      // 经典样式（或设备无液态玻璃）：同布局结构，仅不挂玻璃材质，底色由 barBackgroundBlurStyle 磨砂兜底
      style = {
        adaptToHandedness: true,
        gradientMask: gradientMask,
        barOpacity: 1,
        barBottomMargin: 25,
        lightColor: lightColor,
        barWidth: (smallScreen || !hasBarWidth) ? undefined :
          { smallWidth: barWidthVp, mediumWidth: barWidthVp, largeWidth: barWidthVp },
        miniBar: miniBar,
      } as HdsTabsFloatingStyle
    }
    this.hdsBarStyleCacheKey = cacheKey
    this.hdsBarStyleCache = style
    return style
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

  // 播控条打开播放页区域的按压弹簧动画（大块档 0.9）
  private barItemScale(): number {
    return this.pressAnimOn && this.pressedBarItem ? 0.9 : 1.0
  }

  private onBarItemTouch(event: TouchEvent): void {
    if (!this.pressAnimOn) {
      if (this.pressedBarItem) {
        this.pressedBarItem = false
      }
      return
    }
    if (event.type === TouchType.Down) {
      this.getUIContext()?.animateTo({ duration: 100, curve: Curve.EaseOut }, () => {
        this.pressedBarItem = true
      })
    } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
      this.getUIContext()?.animateTo({ curve: curves.springMotion() }, () => {
        this.pressedBarItem = false
      })
    }
  }

  @Builder
  private tabLabelBuilder(index: number, name: string, icon: Resource) {
    Stack() {
      // 指示器光晕：径向渐变 + 主题色光晕，恒定渲染。
      // translate 恒锚定选中 tab：切换时三个光晕同帧整体平移，旧光晕淡出、新光晕淡入且像素重合，
      // 视觉等效于一枚指示器从 A 滑到 B，而非原地淡入淡出
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
        .opacity(this.currentIndex === index ? 1 : 0)
        .translate({ x: (this.currentIndex - index) * this.tabSlotWidth() })
        .hitTestBehavior(HitTestMode.None)

      // Tab 项按压缩放：本 builder 带参（按值传参不随状态重算），交给自带状态的 PressScaleHost
      PressScaleHost({ pressScale: 0.9, hoverScale: 1.02 }) {
        Column() {
          Image(icon)
            .height(this.scaledSize(20))
            .fillColor(this.currentIndex === index ? this.selectedTabContentColor() :
              $r('app.color.tab_content_secondary'))
            .scale({
              x: this.currentIndex === index ? 1.25 : 1.0, y: this.currentIndex === index ? 1.25 : 1.0
            })
          Text(name)
            .fontSize(8)
            .fontColor(this.currentIndex === index ? this.selectedTabContentColor() :
              $r('app.color.tab_content_secondary'))
            .margin({ top: this.scaledSize(3) })
        }.width(this.scaledSize(this.tabWidth)).height(this.scaledSize(36)).justifyContent(FlexAlign.Center)
          .offset({ y: 2 })
      }
    }
    .width(this.scaledSize(this.tabWidth))
    .height(this.scaledSize(36))
  }

  @Builder
  playerControl() {
    // spike: Stack 作为触控宿主与点光源挂载点（hdsEffect.pointLight 跟手光验证，失败整段回滚）
    Stack() {
      // spike: 透明光源小块，position 跟随手指（options-only 模式，光色跟随页签栏光效设置）
      Row()
        .width(2)
        .height(2)
        .position({ x: this.spikeBarLightX - 1, y: this.spikeBarLightY - 1 })
        .hitTestBehavior(HitTestMode.None)
        .visualEffect(new hdsEffect.HdsEffectBuilder()
          .pointLight({
            options: {
              color: this.followLightColor(),
              intensity: this.spikeBarLightOn && this.tabLightColor !== 'none' ? 1.0 : 0,
              height: 75,
              bloom: 0.9
            }
          })
          .buildEffect())
      Row({ space: this.scaledSize(20) }) {
      if (this.currentSongTitle.length > 0) {
        AlbumCover({
          song: this.currentSong(),
          coverWidth: this.scaledSize(32),
          coverHeight: this.scaledSize(32),
          coverRadius: this.scaledSize(16)
        }).width(this.scaledSize(32)).height(this.scaledSize(32)).rotate({ angle: this.rotationAngle })
          .scale({ x: this.barItemScale(), y: this.barItemScale() })
          .onTouch((event: TouchEvent) => { this.onBarItemTouch(event) })
          .onClick(() => {
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
        .scale({ x: this.barItemScale(), y: this.barItemScale() })
        .onTouch((event: TouchEvent) => { this.onBarItemTouch(event) })
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
      .scale({ x: this.barItemScale(), y: this.barItemScale() })
      .onTouch((event: TouchEvent) => { this.onBarItemTouch(event) })
      .onClick(() => {
        this.openPlayer()
      })

      // 按窗口断点而非设备类型判定：任何设备（PC/平板/折叠屏/手机）窗口宽度达到 xl 及以上
      // 都显示迷你歌词，PC 小窗口同样不显示，与「窗口大小决定布局」的断点体系保持一致
      if ((this.breakpoint === 'xl' || this.breakpoint === 'xxl') && this.currentSongTitle.length > 0 &&
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
            .margin({ top: this.scaledSize(8) })
        }.layoutWeight(this.lyricInfoWeight()).alignItems(HorizontalAlign.Start)
        .scale({ x: this.barItemScale(), y: this.barItemScale() })
        .onTouch((event: TouchEvent) => { this.onBarItemTouch(event) })
        .onClick(() => {
          this.openPlayer()
        })
      }
      ScaleButton({ pressScale: 0.8, hoverScale: 1.1, onButtonTap: () => { this.playPrevious() } }) {
        Image($r('app.media.ic_public_play_last'))
          .height(this.scaledSize(18))
          .fillColor(this.currentSongTitle.length > 0 ? $r('app.color.player_icon_color') :
            $r('app.color.player_icon_inactive_color'))
      }
      ScaleButton({ pressScale: 0.8, hoverScale: 1.1, onButtonTap: () => { this.togglePlay() } }) {
        Image(this.isPlaying ? $r('app.media.ic_public_play') : $r('app.media.ic_public_pause'))
          .height(this.scaledSize(22))
          .fillColor(this.currentSongTitle.length > 0 ? $r('app.color.player_icon_color') :
            $r('app.color.player_icon_inactive_color'))
      }
      ScaleButton({ pressScale: 0.8, hoverScale: 1.1, onButtonTap: () => { this.playNext() } }) {
        Image($r('app.media.ic_public_play_next'))
          .height(this.scaledSize(18))
          .fillColor(this.currentSongTitle.length > 0 ? $r('app.color.player_icon_color') :
            $r('app.color.player_icon_inactive_color'))
      }
    }
    .constraintSize({ maxWidth: this.breakpoint === 'sm' || this.breakpoint === 'md' ? '85%' : '42%' })
    .height(this.scaledSize(44))
    .alignSelf(ItemAlign.Center)
    .padding({
      left: this.scaledSize(12),
      right: this.scaledSize(16),
      top: this.scaledSize(2),
      bottom: this.scaledSize(2)
    })
    .backgroundColor(Color.Transparent)
    // 播控条挂在根 Stack，位于 Tabs 底部栏液态玻璃生效区外（官方文档：ImmersiveMaterial
    // 仅在 Navigation 标题栏/底部 TabBar 生效区渲染），systemMaterial 在此永不生效，
    // 两种样式统一走系统磨砂底板
    .backgroundBlurStyle(this.getBarBackgroundBlur())
    .border({
      width: 1, color: 'rgba(255,255,255,0.22)'
    })
    .borderRadius(this.scaledSize(22))
    .shadow({
      radius: this.isGlowing ? 60 : 50,
      color: this.isGlowing ? ColorHelper.hexWithAlpha(this.primaryColor, '66') : $r('app.color.shadow_color'),
      offsetY: 5
    })
    // spike: 播控条整条标记受光（V4 探针：边框+内容受光，验证内容可照亮的范围）
    .visualEffect(new hdsEffect.HdsEffectBuilder()
      .pointLight({ illuminatedType: hdsEffect.PointLightIlluminatedType.BORDER_CONTENT })
      .buildEffect())
    }
    .onTouch((event: TouchEvent) => {
      if (event.type === TouchType.Down || event.type === TouchType.Move) {
        this.spikeBarLightX = event.touches[0].x
        this.spikeBarLightY = event.touches[0].y
        if (!this.spikeBarLightOn) {
          Logger.info(TAG, 'spikeLight bar on')
        }
        this.spikeBarLightOn = true
      } else {
        if (this.spikeBarLightOn) {
          Logger.info(TAG, 'spikeLight bar off')
        }
        this.spikeBarLightOn = false
      }
    })
  }

  @Builder
  miniBarBuilder() {
    // spike: Stack 作为触控宿主与点光源挂载点（miniBar 容器内渲染验证，失败整段回滚）
    Stack() {
      // spike: 透明光源小块，position 跟随手指（options-only 模式，光色跟随页签栏光效设置）
      Row()
        .width(2)
        .height(2)
        .position({ x: this.spikeMiniLightX - 1, y: this.spikeMiniLightY - 1 })
        .hitTestBehavior(HitTestMode.None)
        .visualEffect(new hdsEffect.HdsEffectBuilder()
          .pointLight({
            options: {
              color: this.followLightColor(),
              intensity: this.spikeMiniLightOn && this.tabLightColor !== 'none' ? 1.0 : 0,
              height: 75,
              bloom: 0.9
            }
          })
          .buildEffect())
      Row({ space: this.scaledSize(8) }) {
      if (this.currentSongTitle.length > 0) {
        AlbumCover({
          song: this.currentSong(),
          coverWidth: this.scaledSize(36),
          coverHeight: this.scaledSize(36),
          coverRadius: this.scaledSize(18)
        }).width(this.scaledSize(36)).height(this.scaledSize(36)).rotate({ angle: this.rotationAngle })
          .scale({ x: this.barItemScale(), y: this.barItemScale() })
          .onTouch((event: TouchEvent) => { this.onBarItemTouch(event) })
          .onClick(() => {
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
        .scale({ x: this.barItemScale(), y: this.barItemScale() })
        .onTouch((event: TouchEvent) => { this.onBarItemTouch(event) })
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
      .scale({ x: this.barItemScale(), y: this.barItemScale() })
      .onTouch((event: TouchEvent) => { this.onBarItemTouch(event) })
      .onClick(() => {
        this.openPlayer()
      })

      ScaleButton({ pressScale: 0.8, hoverScale: 1.1, onButtonTap: () => { this.playPrevious() } }) {
        Image($r('app.media.ic_public_play_last'))
          .height(this.scaledSize(24))
          .fillColor(this.currentSongTitle.length > 0 ? $r('app.color.player_icon_color') :
            $r('app.color.player_icon_inactive_color'))
      }
      ScaleButton({ pressScale: 0.8, hoverScale: 1.1, onButtonTap: () => { this.togglePlay() } }) {
        Image(this.isPlaying ? $r('app.media.ic_public_play') : $r('app.media.ic_public_pause'))
          .height(this.scaledSize(28))
          .fillColor(this.currentSongTitle.length > 0 ? $r('app.color.player_icon_color') :
            $r('app.color.player_icon_inactive_color'))
      }
      ScaleButton({ pressScale: 0.8, hoverScale: 1.1, onButtonTap: () => { this.playNext() } }) {
        Image($r('app.media.ic_public_play_next'))
          .height(this.scaledSize(24))
          .fillColor(this.currentSongTitle.length > 0 ? $r('app.color.player_icon_color') :
            $r('app.color.player_icon_inactive_color'))
      }
    }
    .height(this.scaledSize(44))
    .borderRadius(this.scaledSize(22))
    .alignSelf(ItemAlign.Center)
    .padding({
      left: this.scaledSize(10),
      right: this.scaledSize(12),
      top: this.scaledSize(2),
      bottom: this.scaledSize(2)
    })
    // miniBar 底色恒由系统迷你栏背景提供（enableMiniBarBackground=true，跟随页签栏）。
    // 自挂 systemMaterial 三次真机实证不渲染（生效区限制），不得再挂，
    // 否则玻璃样式下底板纯黑透明（2026-10-18 回归实测）
    // spike: miniBar 整条标记受光（V4 探针：边框+内容受光）
    .visualEffect(new hdsEffect.HdsEffectBuilder()
      .pointLight({ illuminatedType: hdsEffect.PointLightIlluminatedType.BORDER_CONTENT })
      .buildEffect())
    }
    .onTouch((event: TouchEvent) => {
      if (event.type === TouchType.Down || event.type === TouchType.Move) {
        this.spikeMiniLightX = event.touches[0].x
        this.spikeMiniLightY = event.touches[0].y
        if (!this.spikeMiniLightOn) {
          Logger.info(TAG, 'spikeLight mini on')
        }
        this.spikeMiniLightOn = true
      } else {
        if (this.spikeMiniLightOn) {
          Logger.info(TAG, 'spikeLight mini off')
        }
        this.spikeMiniLightOn = false
      }
    })
  }

  openPlayer(): void {
    this.getUIContext().getRouter().pushUrl({ url: 'pages/MusicPlayer' })
  }

  // 仅当「玻璃样式 + 设备系统达到 API 26」时启用真·液态玻璃（厚度档位设置已删除，默认开启）；

  onCurrentSongChange(): void {
    this.loadCurrentLyrics()
  }

  // P0-3：当前播放歌曲对象缓存（按 id 失配重建）——字段读取实时反映歌词偏移等原地更新
  private currentLyricSong: SongInfo | undefined = undefined

  private currentLyricOffsetMs(): number {
    if (this.currentLyricSong === undefined || this.currentLyricSong.id !== this.currentSongId) {
      this.currentLyricSong = this.dataService.getSongById(this.currentSongId)
    }
    return this.currentLyricSong !== undefined ? this.currentLyricSong.lyricOffsetMs : 0
  }

  onProgressChange(): void {
    // 迷你歌词按「进度+每歌偏移」对齐（与 LrcListView 换算口径一致）
    const matchTime: number = this.playProgress + this.currentLyricOffsetMs()
    let low: number = 0
    let high: number = this.lyricEntries.length - 1
    let currentIndex: number = -1
    while (low <= high) {
      const middle: number = Math.floor((low + high) / 2)
      if (this.lyricEntries[middle].lineStartTime <= matchTime) {
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
      // 恢复播放直接从当前角度续转匀速旋转：不再做 +30° 弹簧「起步踢脚」，
      // 避免暂停→续播时封面先快转一个角度再匀速的观感
      this.startRotation()
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

  build() {
    Stack() {
      HdsTabs({ controller: this.tabsController, index: this.currentIndex }) {
        TabContent() {
          Stack({ alignContent: Alignment.Top }) {
            HomeContent({
              topContentPadding: this.homeHeaderHeight(),
              bottomSafeHeight: this.bottomSafeHeight,
              smallBreakpoint: this.breakpoint === 'sm' || this.breakpoint === 'md',
              greetingBandTop: this.topContentInset(),
              greetingBandHeight: this.homeHeaderHeight() - this.topContentInset()
            }).width('100%').height('100%')

            Stack() {
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
                .translate({ y: this.homeMultiSelect ? -24 : 0 })
                .opacity(this.homeMultiSelect ? 0 : 1)
                .animation({
                  duration: StyleConstants.ANIMATION_GREETING_HIDE_DURATION,
                  curve: Curve.EaseInOut
                })
              }
              .width('100%')
              .height('100%')
              .justifyContent(FlexAlign.Start)
              .alignItems(VerticalAlign.Center)
              .padding({
                top: this.topContentInset(), left: 20, right: this.isPC ? Math.max(this.titleButtonWidth, 140) + 12 : 8
              })
            }.width('100%').height(this.homeHeaderHeight()).hitTestBehavior(HitTestMode.Transparent)
          }.width('100%').height('100%')
        }
        .tabBar(this.tabLabelBuilder(0, '首页', $r('app.media.ic_public_home')))

        TabContent() {
          PlaylistContent({
            topContentPadding: this.topContentInset(),
            topBandHeight: this.homeHeaderHeight() - this.topContentInset(),
            bottomSafeHeight: this.bottomSafeHeight,
            smallBreakpoint: this.breakpoint === 'sm' || this.breakpoint === 'md'
          }).width('100%').height('100%')
        }
        .tabBar(this.tabLabelBuilder(1, '歌单', $r('app.media.ic_public_view_list')))

        TabContent() {
          SettingsContent({
            topContentPadding: this.topContentInset(),
            topBandHeight: this.homeHeaderHeight() - this.topContentInset(),
            bottomSafeHeight: this.bottomSafeHeight,
            smallBreakpoint: this.breakpoint === 'sm' || this.breakpoint === 'md'
          }).width('100%').height('100%')
        }
        .tabBar(this.tabLabelBuilder(2, '设置', $r('app.media.ic_public_settings')))
      }
      .barPosition(BarPosition.End)
      .barOverlap(true)
      .barHeight(this.scaledSize(44))
      .barWidth(this.scaledSize(228))
      .scrollable(true)
      .barBackgroundColor(Color.Transparent)
      .barFloatingStyle(this.getHdsBarFloatingStyle())
      // 经典模式：barFloatingStyle 不含 systemMaterialEffect → TabBar 走磨砂兜底（与玻璃模式布局完全一致，仅底色不同）
      // 玻璃模式：barFloatingStyle 含 systemMaterialEffect（液态玻璃）→ 磨砂关闭
      .barBackgroundBlurStyle((this.tabStyle !== 'immersive' || !isLiquidGlassAvailable())
        ? this.getBarBackgroundBlur() : BlurStyle.NONE)
      // PC 禁滑动切页：系统把鼠标滚轮转换成横向滑动事件，scrollable(true) 下滚一轮就切一次页签；
      // PC 上切页本就走 TabBar 点击，关掉滑动切页后滚轮回归列表滚动。触屏设备保留滑动切页。
      .scrollable(!this.isPC)
      .animationDuration(StyleConstants.ANIMATION_SWIPER_DURATION)
      .onChange((index: number) => {
        // tab 切换：弹簧曲线驱动指示器光晕从旧 tab 滑向新 tab，图标缩放/变色同帧过渡
        this.getUIContext()?.animateTo({ curve: curves.springMotion(0.4, 0.8) }, () => {
          this.currentIndex = index
        })
      })
      .onTabBarClick((index: number) => {
        this.updatePlusTabMounted(index)
      })
      .onSelected((index: number) => {
        this.updatePlusTabMounted(index)
      })
      .onContentWillChange((current: number, coming: number) => {
        this.updatePlusTabMounted(coming)
        return true
      })
      .width('100%')
      .height('100%')

      // 小屏（sm/md）：系统迷你栏无法纵向堆叠，改用自建播控条叠放在 TabBar 上方。
      // 大屏（lg/xl）：系统 miniBar 左右并排展示播控，不渲染自建 playerControl。
      // 布局完全由断点决定。
      if (this.breakpoint === 'sm' || this.breakpoint === 'md') {
        Column() {
          this.playerControl()
        }
        .width('100%')
        .alignItems(HorizontalAlign.Center)
        .padding({ left: this.scaledSize(16), right: this.scaledSize(16) })
        .margin({ bottom: this.controlBarBottomMargin() })
        .hitTestBehavior(HitTestMode.Default)
      }

      // 全局悬浮加号：挂在 Index 根 Stack（Tabs 之上）的单实例，首页↔歌单切换时不随
      // 页面内容滑动、不重建；挂载开关由 onTabBarClick/onSelected/onContentWillChange
      // 在点击/切换开始的瞬间提前翻转（比 onChange 早一个切换动画周期），切到/切离
      // 设置页的 Insert/Delete 过渡与页面切换动画同时启停。
      // 页面上报的可见性（滚动隐藏设置 + 多选/编辑态）经 visible 参数在组件内部淡入淡出
      if (this.plusTabMounted) {
        GlassPlusButton({
          bottomInset: this.plusButtonBottomInset(),
          onPlusClick: (): void => {
            this.onPlusClick()
          },
          visible: this.plusVisibleOnActiveTab()
        })
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
    return isDarkThemeEffective(this.themeMode)
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

  // Tab 槽位间距：barWidth(228vp) 均分 3 个页签，指示器滑移按此步长平移
  private tabSlotWidth(): number {
    return this.scaledSize(228) / 3
  }

  private selectedTabContentColor(): ResourceColor {
    return this.isDarkTheme() ? '#FFFFFF' : ColorHelper.darken(this.primaryColor, 0.35)
  }

  private topContentInset(): number {
    return this.isPC ? Math.max(this.topSafeHeight, this.titleButtonHeight) : this.topSafeHeight
  }

  private homeHeaderHeight(): number {
    return this.isPC ? Math.max(64, this.topContentInset() + 32) : this.topContentInset() + 40
  }

  private scaledSize(size: number): number {
    return Math.round(size * this.displaySizeScale)
  }

  // 小屏态自建播控条的底部偏移：压在 TabBar 顶部正上方。
  // 25(tab barBottomMargin) + 44(tab 高) 到 tab 顶；再加 4vp 基础间距，最后 +4.5vp 把播控条上移到
  // 「加号底」与「tab 顶」的垂直中点，使播控条到加号与到 tab 的垂直距离相等（窄态真机实测）。
  private controlBarBottomMargin(): number {
    return 25 + this.scaledSize(44) + this.scaledSize(4) + 4.5
  }

  // 加号组件底边位置：紧贴播控条（迷你栏）上沿。真机实测（vp）：
  // sm/md 窄屏叠放态与大屏并排态统一取 146。lg/xl 曾取 40，会使加号沉入
  // TabBar/迷你栏区域（真机实测沉底），已统一按首页效果对齐。
  // 加号现挂在 Index 根 Stack（单实例），不存在页面懒加载时各页捕获值不一致的问题。
  private plusButtonBottomInset(): number {
    return 146
  }

  // 加号 Tab 级挂载开关的提前翻转：三个前置回调（onTabBarClick 点击 / onSelected 切换动画开始 /
  // onContentWillChange 切换前）任一命中即更新，谁先到谁触发，保证点击设置页的那一刻
  // 隐藏动画就与页面切换动画同时启动。翻转必须放进 animateTo 闭包（与 onChange 驱动
  // 指示器光晕的写法一致），否则挂载/卸载的 Insert/Delete 过渡不播放、加号会瞬移消失。
  // 值未变化时直接返回，首页↔歌单互切不产生任何动画
  private updatePlusTabMounted(index: number): void {
    const mounted: boolean = index === 0 || index === 1
    if (this.plusTabMounted === mounted) {
      return
    }
    this.getUIContext()?.animateTo({ curve: curves.springMotion(0.4, 0.8) }, () => {
      this.plusTabMounted = mounted
    })
  }

  // 全局加号可见性：首页/歌单读对应页上报的状态，设置页恒为隐藏
  private plusVisibleOnActiveTab(): boolean {
    if (this.currentIndex === 0) {
      return this.homePlusVisible
    }
    if (this.currentIndex === 1) {
      return this.playlistPlusVisible
    }
    return false
  }

  // 全局加号点击：选歌 → 分批入库 → toast。两页列表经 KEY_LIBRARY_REVISION 的 @Watch 逐批自动刷新
  async onPlusClick(): Promise<void> {
    const context: common.UIAbilityContext | undefined =
      AppStorage.get<common.UIAbilityContext>(AppStorageKeyConstants.KEY_UI_ABILITY_CONTEXT)
    if (context === undefined) {
      return
    }
    await importSongsWithToast(context, this.getUIContext()?.getPromptAction())
  }

  // 否则传 undefined 让 lightEffect 完全关闭，便于外层使用系统自带的按压白色蒙版。

  // 跟手光效颜色：white=白光，theme=主题色（设置项 uplayer_tab_light_color；none 已在外层过滤）
  private followLightColor(): string {
    if (this.tabLightColor === 'white') {
      return '#FFFFFF'
    }
    return this.primaryColor
  }

  private isSongInfoShort(): boolean {
    const artistLength: number = this.currentSongArtist.length > 0 ? this.currentSongArtist.length : 4
    return this.currentSongTitle.length + artistLength <= 16
  }

  private songInfoWeight(): number {
    return (this.breakpoint === 'xl' || this.breakpoint === 'xxl') && this.isSongInfoShort() ? 2 : 3
  }

  private lyricInfoWeight(): number {
    return this.isSongInfoShort() ? 4 : 3
  }

  // KeyCode 与 KeyEvent/KeyType 的用法与 MusicPlayer.handleKeyEvent 保持一致。
  private tryExitMultiSelect(): boolean {
    // 首页多选：写入 AppStorage 即可让 HomeContent 退出，并由它的 @Watch 清空选中集合
    if (this.currentIndex === 0 && this.homeMultiSelect) {
      AppStorage.setOrCreate(AppStorageKeyConstants.KEY_HOME_MULTI_SELECT, false)
      return true
    }
    // 歌单页多选：同一套机制（PlaylistContent 的 @Watch 负责清空选中集合）
    if (this.currentIndex === 1 && this.playlistMultiSelect) {
      AppStorage.setOrCreate(AppStorageKeyConstants.KEY_PLAYLIST_MULTI_SELECT, false)
      return true
    }
    // 歌单页文件夹编辑态：同一套退出路径
    if (this.currentIndex === 1 && this.playlistFolderEdit) {
      AppStorage.setOrCreate(AppStorageKeyConstants.KEY_PLAYLIST_FOLDER_EDIT, false)
      return true
    }
    return false
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
    // 左右方向键：外接键盘切页（首页↔歌单↔设置）。方向键事件只能来自物理键盘，未连键盘时
    // 本分支天然不触发；按键经多模输入按焦点链派发，PC/平板/手机连键盘的行为完全一致
    if (event.keyCode === KeyCode.KEYCODE_DPAD_LEFT || event.keyCode === KeyCode.KEYCODE_DPAD_RIGHT) {
      const target: number =
        event.keyCode === KeyCode.KEYCODE_DPAD_LEFT ? this.currentIndex - 1 : this.currentIndex + 1
      if (target >= 0 && target <= 2) {
        this.tabsController.changeIndex(target)
      }
      return true
    }
    // Ctrl+A：多选态下全选当前页可见项（首页=可见歌曲 / 歌单页=全部歌单卡）
    if (event.keyCode === KeyCode.KEYCODE_A && this.isCtrlPressed(event)) {
      if (this.currentIndex === 0 && this.homeMultiSelect) {
        const current: number = AppStorage.get<number>(AppStorageKeyConstants.KEY_HOME_SELECT_ALL_REQUEST) ?? 0
        AppStorage.setOrCreate(AppStorageKeyConstants.KEY_HOME_SELECT_ALL_REQUEST, current + 1)
        return true
      }
      if (this.currentIndex === 1 && (this.playlistMultiSelect || this.playlistFolderEdit)) {
        const current: number = AppStorage.get<number>(AppStorageKeyConstants.KEY_PLAYLIST_SELECT_ALL_REQUEST) ?? 0
        AppStorage.setOrCreate(AppStorageKeyConstants.KEY_PLAYLIST_SELECT_ALL_REQUEST, current + 1)
        return true
      }
    }
    // Ctrl+F：聚焦首页搜索框——打开搜索行并让输入框获焦（由 HomeContent 的 @Watch 处理）
    if (event.keyCode === KeyCode.KEYCODE_F && this.currentIndex === 0 && this.isCtrlPressed(event)) {
      const current: number = AppStorage.get<number>(AppStorageKeyConstants.KEY_HOME_SEARCH_FOCUS) ?? 0
      AppStorage.setOrCreate(AppStorageKeyConstants.KEY_HOME_SEARCH_FOCUS, current + 1)
      return true
    }
    // Delete 键：多选/编辑态下与删除按钮功能一致，按当前页分发删除请求，由内容页 @Watch 执行
    if (event.keyCode === KeyCode.KEYCODE_FORWARD_DEL &&
      (this.currentIndex === 0 || this.currentIndex === 1)) {
      const key: string = this.currentIndex === 0 ?
        AppStorageKeyConstants.KEY_HOME_DELETE_REQUEST : AppStorageKeyConstants.KEY_PLAYLIST_DELETE_REQUEST
      const current: number = AppStorage.get<number>(key) ?? 0
      AppStorage.setOrCreate(key, current + 1)
      return true
    }
    return false
  }

  private currentSong(): SongInfo {
    const song: SongInfo | undefined = this.dataService.getSongById(this.currentSongId)
    return song !== undefined ? song : new SongInfo()
  }
}
