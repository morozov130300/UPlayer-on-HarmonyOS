import display from '@ohos.display'
import { curves, uiMaterial } from '@kit.ArkUI'
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
import { createBarGlassMaterial, createTabGlassMaterial, DEFAULT_GLASS_STYLE, isLiquidGlassAvailable, isLowPowerGlassDevice } from '../common/utils/GlassUtil'
import Logger from '../common/utils/Logger'
import { LrcEntry } from '../viewmodel/LrcEntry'
import { loadLyricEntries } from '../service/LyricLoader'
import { AlbumCover } from '../component/AlbumCover'
import { ColorConversion } from '../common/utils/ColorConversion'
import { StyleConstants } from '../common/constants/StyleConstants'
import { ImportProgressOverlay } from '../view/ImportProgressOverlay'
import { KEY_HAS_POINTER_DEVICE, refreshPointerDeviceState, startPointerDeviceListener } from '../common/utils/InputDeviceUtil'

const TAG = 'Index'

@Entry
@Component
struct MainPage {
  @State currentIndex: number = 0
  @State indicatorOffset: number = 4
  @State greetingTitle: string = '加载中……'
  @State greetingOpacity: number = 0
  @State greetingOffset: number = 20
  // 主页多选状态（由 HomeContent 写入）：进入多选时问候语整体上滑淡出，退出时回落淡入
  @StorageLink(AppStorageKeyConstants.KEY_HOME_MULTI_SELECT) @Watch('onHomeMultiSelectChange') homeMultiSelect: boolean = false
  @State greetingShiftY: number = 0
  @State greetingVisible: number = 1
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
  // 播控条封面/迷你歌词按 id 解析当前歌曲，避免队列下标失配
  @StorageLink('uplayer_current_song_id') @Watch('onCurrentSongChange') currentSongId: string = ''
  @StorageLink('uplayer_primary_color') primaryColor: string = '#007DFF'
  @StorageLink('uplayer_theme_mode') themeMode: string = 'system'
  @StorageLink('uplayer_display_size_scale') @Watch('onDisplaySizeChange') displaySizeScale: number = 1.0
  @StorageLink('uplayer_font_size_scale') fontSizeScale: number = 1.0
  @StorageLink('uplayer_tab_style') tabStyle: string = 'classic'
  @StorageLink('uplayer_glass_blur_strength') glassBlurStrength: number = 25
  @StorageLink('uplayer_tab_indicator_opacity') tabIndicatorOpacity: number = 50
  @StorageLink('uplayer_glass_thickness') glassThickness: number = DEFAULT_GLASS_STYLE
  @StorageLink('uplayer_light_color_mode') lightColorMode: string = 'theme'
  @StorageLink('uplayer_tab_touch_indicator') tabTouchIndicator: string = 'light'
  // 是否存在鼠标/触控板设备（决定「白色蒙版」功能是否存在：无鼠标时 mask 降级为 off）
  @StorageLink(KEY_HAS_POINTER_DEVICE) hasPointerDevice: boolean = false
  @StorageLink('uplayer_interactive') interactive: boolean = true
  @StorageLink('uplayer_color_invert') colorInvert: boolean = false
  @StorageLink('uplayer_apply_shadow') applyShadow: boolean = true
  @StorageLink('uplayer_glass_frost_overlay') glassFrostOverlay: boolean = false
  @State albumArtFailed: boolean = false
  @State isTitleMarqueeRunning: boolean = true
  @State isArtistMarqueeRunning: boolean = true
  @State hoverTabIndex: number = -1
  @State currentLyricLine: string = ''
  @State nextLyricLine: string = ''
  @State lyricEntries: LrcEntry[] = []
  @StorageLink(AppStorageKeyConstants.KEY_PROGRESS) @Watch('onProgressChange') playProgress: number = 0
  @StorageLink(AppStorageKeyConstants.KEY_SELECT_INDEX) @Watch('onCurrentSongChange') selectedSongIndex: number = 0
  // 曲库歌词引用发生集合级变化（自愈回填 / 重新导入）时重新加载迷你歌词
  @StorageProp(AppStorageKeyConstants.KEY_LYRIC_REVISION) @Watch('loadCurrentLyrics') lyricRevision: number = 0
  // 主窗口可见性（EntryAbility 前后台写入）：窗口隐藏时停掉封面旋转定时器，避免持续请求 vsync
  @StorageProp(AppStorageKeyConstants.KEY_UI_ACTIVE) @Watch('onUiActiveChange') uiActive: boolean = true

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

  // ── 液态玻璃（沉浸式系统材质，HarmonyOS API 26+）──
  // 材质构造统一走 GlassUtil.createTabGlassMaterial 工厂，与设置页预览器共用同一份逻辑，
  // 保证预览效果与真实渲染一致。
  // 解析「底部栏触摸指示」实际生效值：
  // 设备无鼠标/触控板时「白色蒙版」功能不存在，mask 值降级为 off
  private effectiveTouchIndicator(): string {
    if (this.tabTouchIndicator === 'mask' && !this.hasPointerDevice) {
      return 'off'
    }
    return this.tabTouchIndicator
  }

  // 颜色由 lightColorMode 控制（白/主题），仅在 tabTouchIndicator='light' 时开启，
  // 否则传 undefined 让 lightEffect 完全关闭，便于外层使用系统自带的按压白色蒙版。
  private liquidGlassMaterial(): uiMaterial.Material | undefined {
    const useLight: boolean = this.effectiveTouchIndicator() === 'light'
    const lightColor: string | undefined = useLight
      ? (this.lightColorMode === 'white' ? '#FFFFFF' : this.primaryColor)
      : undefined
    return createTabGlassMaterial(this.glassThickness, this.interactive, lightColor, this.colorInvert, this.applyShadow)
  }

  // 开启白色蒙版（按下雾蒙蒙的发白指示器）时返回 HoverEffect.Highlight，否则返回 None
  // mask 模式下仅 Tab item 显示白色蒙版；light 模式下不做任何 hover 效果（避免白色蒙版）
  private bottomHoverEffect(): HoverEffect {
    return this.effectiveTouchIndicator() === 'mask' ? HoverEffect.Highlight : HoverEffect.None
  }

  // 仅当「玻璃样式 + 设备系统达到 API 26 + 厚度未关断」时启用真·液态玻璃；
  // 其余情况（经典样式、老系统、厚度为 0）回退到原有 backgroundEffect 玻璃模糊。
  private liquidGlassEnabled(): boolean {
    return this.tabStyle === 'immersive' && isLiquidGlassAvailable() && this.glassThickness > 0
  }

  // 条状组件（经典 Tab 栏 / 播控条）液态玻璃材质的激活条件，与 createBarGlassMaterial 工厂
  // 及设置页预览共用同一判定：API 26+ 且设备支持 + 厚度未关断 + 高/中算力（低算力材质退化为
  // 纯色面，由磨砂层兜底，不受「磨砂层叠加」开关约束）
  private barMaterialActive(): boolean {
    return isLiquidGlassAvailable() && this.glassThickness > 0 && !isLowPowerGlassDevice()
  }

  // 磨砂层挂载条件（经典 Tab 栏 / 玻璃 Tab 栏 / 播控条三处统一）：
  // - 暗黑模式或模糊强度为 0：从不挂载（保持原有行为）
  // - 材质激活：仅当「磨砂层叠加」开关开启时挂载（默认关 = 纯液态玻璃观感，
  //   避免明亮模式下磨砂层叠在材质之上把指示器糊成蓝雾，官方 FAQ 亦标注二者同设为重复处理）
  // - 材质未激活（老设备 / 低算力 / 厚度为 0）：作为兜底挂载，不受开关影响
  private frostLayerEnabled(materialActive: boolean): boolean {
    if (this.isDarkTheme() || this.glassBlurStrength <= 0) {
      return false
    }
    return materialActive ? this.glassFrostOverlay : true
  }

  private liquidGlassTabMaterial(): uiMaterial.Material | undefined {
    return this.liquidGlassEnabled() ? this.liquidGlassMaterial() : undefined
  }

  // 经典样式 Tab 栏的液态玻璃材质（API 26+ 全设备能力，与 tabStyle 解耦）：
  // 能力不足/玻璃关断/低算力设备返回 undefined，由调用处保留 backgroundEffect 兜底
  private classicTabBarMaterial(): uiMaterial.Material | undefined {
    return this.tabStyle === 'classic' ? createBarGlassMaterial(this.glassThickness, this.interactive) : undefined
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

  onDisplaySizeChange(): void {
    this.updateIndicatorOffset(this.currentIndex)
  }

  aboutToAppear(): void {
    // AppStorage 已由 EntryAbility 在 loadContent 之前完成初始化（initToAppStorage 幂等），
    // 此处不再重复调用，避免重复执行可访问性检查与授权激活竞态
    ColorConversion.setSysBarLightBackground(this.isDarkTheme())
    this.updateGreeting()
    this.loadPoetryLine()
    this.initBreakpoint()
    this.loadCurrentLyrics()
    // 白色蒙版开关按鼠标/触控板检测结果显隐：刷新状态并监听热插拔
    refreshPointerDeviceState()
    startPointerDeviceListener()
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

  // ── 返回键 / ESC 退出多选 ──
  // 多选态只存在于首页（tab 0），所以只在「当前在首页且处于多选」时拦截；
  // 其余情况必须返回 false，让系统执行默认返回逻辑（Index 是根页面，默认即退出应用）。
  // KeyCode 与 KeyEvent/KeyType 的用法与 MusicPlayer.handleKeyEvent 保持一致。
  private tryExitMultiSelect(): boolean {
    if (this.currentIndex !== 0 || !this.homeMultiSelect) {
      return false
    }
    // isMultiSelectMode 已是 @StorageLink，写入 AppStorage 即可让 HomeContent 退出多选，
    // 并由它的 @Watch 顺带清空选中集合
    AppStorage.setOrCreate(AppStorageKeyConstants.KEY_HOME_MULTI_SELECT, false)
    return true
  }

  // 手机/平板的返回键与侧滑返回：仅 @Entry 组件可监听
  onBackPress(): boolean {
    return this.tryExitMultiSelect()
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
    if (event.keyCode === KeyCode.KEYCODE_A && this.currentIndex === 0 && this.homeMultiSelect
      && this.isCtrlPressed(event)) {
      const current: number = AppStorage.get<number>(AppStorageKeyConstants.KEY_HOME_SELECT_ALL_REQUEST) ?? 0
      AppStorage.setOrCreate(AppStorageKeyConstants.KEY_HOME_SELECT_ALL_REQUEST, current + 1)
      return true
    }
    return false
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
        // 磨砂层挂载条件统一走 frostLayerEnabled：材质激活时由「磨砂层叠加」开关控制，
        // 材质未激活（老设备/低算力/厚度 0）保持兜底挂载（暗黑模式与强度 0 不挂）
        .backgroundEffect(this.frostLayerEnabled(this.barMaterialActive()) ? {
          radius: this.glassBlurRadius()
        } : undefined)
        .systemMaterial(this.classicTabBarMaterial())
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
        // 指示器与经典样式同款径向渐变 + 蓝色光晕（深浅接入 indicatorAlpha/indicatorGradientColor），
        // 去掉纯色 backgroundColor：浅色玻璃下边缘更锐利，避免「蓝雾」观感
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

      Row({ space: this.scaledSize(this.tabGap) }) {
        this.immersiveTabItem(0, '首页', $r('app.media.ic_public_home'))
        this.immersiveTabItem(1, '歌单', $r('app.media.ic_public_view_list'))
        this.immersiveTabItem(2, '设置', $r('app.media.ic_public_settings'))
      }
      .margin({ bottom: this.scaledSize(10) })
      .height(this.scaledSize(40))
      .borderRadius(this.scaledSize(20))
      .backgroundColor(Color.Transparent)
      // 液态玻璃启用时 systemMaterial 接管渲染；磨砂层由「磨砂层叠加」开关控制（默认关，
      // 避免明亮模式下双层叠加造成蓝雾）；材质未激活时保持兜底挂载
      .backgroundEffect(this.frostLayerEnabled(this.liquidGlassEnabled()) ? {
        radius: this.glassBlurRadius()
      } : undefined)
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
    .backgroundColor(this.hoverTabIndex === index && this.effectiveTouchIndicator() === 'mask' ? 'rgba(255,255,255,0.16)' : Color.Transparent)
    .borderRadius(this.scaledSize(18))
    // 蓝色悬停投影属于「白色蒙版」模式的悬停指示，蒙版关闭（off/light）时不再残留
    .shadow({
      radius: this.hoverTabIndex === index && this.effectiveTouchIndicator() === 'mask' ? 14 : 0,
      color: this.hoverTabIndex === index && this.effectiveTouchIndicator() === 'mask'
        ? ColorHelper.hexWithAlpha(this.primaryColor, '66') : Color.Transparent
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
    .backgroundColor(this.hoverTabIndex === index && this.effectiveTouchIndicator() === 'mask' ? 'rgba(255,255,255,0.18)' : Color.Transparent)
    .borderRadius(this.scaledSize(18))
    // 蓝色悬停投影属于「白色蒙版」模式的悬停指示，蒙版关闭（off/light）时不再残留
    .shadow({
      radius: this.hoverTabIndex === index && this.effectiveTouchIndicator() === 'mask' ? 16 : 0,
      color: this.hoverTabIndex === index && this.effectiveTouchIndicator() === 'mask'
        ? ColorHelper.hexWithAlpha(this.primaryColor, '77') : Color.Transparent
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

  // 主页进入/退出多选：问候语向上位移并淡出（退出时反向回落淡入），
  // 让位给随后切换到该位置的 HomeContent 多选菜单栏
  onHomeMultiSelectChange(): void {
    const hidden: boolean = this.homeMultiSelect
    this.getUIContext()?.animateTo({
      duration: hidden ? StyleConstants.ANIMATION_GREETING_HIDE_DURATION : StyleConstants.ANIMATION_GREETING_SHOW_DURATION,
      curve: hidden ? Curve.EaseInOut : Curve.EaseOut
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
            .width(this.scaledSize(20))
            .height(this.scaledSize(20))
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
        .height(this.scaledSize(18))
        .fillColor($r('app.color.player_icon_color'))
        .onClick(() => { this.playPrevious() })
      Image(this.isPlaying ? $r('app.media.ic_public_play') : $r('app.media.ic_public_pause'))
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
    // 磨砂层与玻璃厚度、Tab 风格解耦，两种样式统一挂载；挂载条件统一走 frostLayerEnabled
    // （材质激活时由「磨砂层叠加」开关控制，材质未激活时兜底挂载；暗黑模式与强度 0 不挂）
    .backgroundEffect(this.frostLayerEnabled(this.barMaterialActive()) ? {
      radius: this.glassBlurRadius()
    } : undefined)
    // 液态玻璃：与磨砂层一致不区分 Tab 风格；能力不足时传 undefined 关闭
    .systemMaterial(this.bottomBarGlassMaterial())
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
    const song: SongInfo | undefined = this.dataService.getSongById(this.currentSongId)
    return song !== undefined ? song : new SongInfo()
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
    const song: SongInfo = this.currentSong()
    // 准入条件是「当前播放歌曲有效」（按 id 解析），与队列下标、标题无关
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
    // 窗口隐藏时不起旋转定时器：角度原地冻结，回前台由 onUiActiveChange 续转，无跳变
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
            bottomContentPadding: this.bottomOverlayInset(),
            greetingBandTop: this.topContentInset(),
            greetingBandHeight: this.homeHeaderHeight() - this.topContentInset()
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
              Row() {
                //展示问候语
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

      // 导入进度浮层：置顶显示，未导入时不拦截触摸
      ImportProgressOverlay()
    }
    .alignContent(Alignment.Bottom)
    .width('100%')
    .height('100%')
    .onKeyEvent((event: KeyEvent): boolean => this.handleKeyEvent(event))
  }
}
