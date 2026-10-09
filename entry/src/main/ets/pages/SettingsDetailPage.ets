// ArkUI 26 Beta1: 接口定义变更（误报，本项目已是Stage模型）+ UX视觉布局变更（Text默认开启沉浸式材质，系统行为）
import { curves, uiAppearance } from '@kit.ArkUI'
import { hdsMaterial, HdsTabs, HdsTabsController, HdsTabsFloatingStyle } from '@kit.UIDesignKit'
import { bundleManager, common, ConfigurationConstant } from '@kit.AbilityKit'
import { updateManager } from '@kit.AppGalleryKit'
import { AppSettingsData, DataService } from '../service/DataService'
import { AVPlayerService } from '../service/AVPlayerService'
import { AppStorageKeyConstants } from '../common/constants/AppStorageKeyConstants'
import { ColorHelper } from '../common/utils/ColorHelper'
import Logger from '../common/utils/Logger'
import { BusinessError, deviceInfo, pasteboard, SuppressWarnings, SuppressWarningsType } from '@kit.BasicServicesKit'
import { HoldingHandService, KEY_HOLDING_HAND_ENABLED, KEY_HOLDING_HAND_LEFT } from '../service/HoldingHandService'
import { ColorConversion } from '../common/utils/ColorConversion'
import { isLiquidGlassAvailable, showToastGlassMaterial, topBlurRadiusFromStrength } from '../common/utils/GlassUtil'
import { StyleConstants } from '../common/constants/StyleConstants'
import { KEY_HAS_POINTER_DEVICE, refreshPointerDeviceState } from '../common/utils/InputDeviceUtil'
import { GlassBackButton } from '../view/GlassBackButton'

const TAG = 'SettingsDetailPage'
const KEY_PRIMARY_COLOR = 'uplayer_primary_color'

class EqBandInfo {
  freq: string = ''
  index: number = 0
}

// 官方均衡器 9 预设（增益表与 OHAudioSuite 内置预设一致，10 段 [-10,10]dB）
class EqPresetTable {
  static readonly NAMES: string[] = ['默认', '民谣', '中国风', '古典', '舞曲', '爵士', '流行', 'R&B', '摇滚']
  static readonly GAINS: number[][] = [
    [0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
    [3, 5, 2, -4, 1, 2, -3, 1, 4, 5],
    [0, 0, 2, 0, 0, 4, 4, 2, 2, 5],
    [2, 3, 2, 1, 0, 0, -5, -5, -5, -6],
    [4, 3, 2, -3, 0, 0, 5, 4, 2, 0],
    [2, 0, 2, 3, 6, 5, -1, 3, 4, 4],
    [5, 2, 1, -1, -5, -5, -2, 1, 2, 4],
    [1, 4, 5, 3, -2, -2, 2, 3, 5, 5],
    [6, 4, 4, 2, 0, 1, 3, 3, 5, 4]
  ]
}

// 空间渲染三模式：0=固定摆位(x,y,z) 1=旋转(x,y,z,环绕时间,方向) 2=扩展(半径,角度)
class SpaceRenderTable {
  static readonly MODE_NAMES: string[] = ['固定摆位', '旋转', '扩展']
  static readonly MODE_DEFAULTS: number[][] = [
    [0, 0, 0],
    [0, 0, 1, 10, 1],
    [2, 180]
  ]
}


interface ThemeColorOption {
  name: string
  value: string
}

interface ThemeOption {
  label: string
  value: string
}

interface TabStyleOption {
  label: string
  value: string
}

interface TouchIndicatorOption {
  label: string
  value: string
}

@Entry
@Component
@SuppressWarnings({ rules: [SuppressWarningsType.SYSCAP] })
struct SettingsDetailPage {
  @State settings: AppSettingsData = new AppSettingsData()
  // 初始值根据当前样式和设备能力计算：新设备玻璃样式隐藏，其他情况显示
  @State showClassicBlurStrength: boolean = !(isLiquidGlassAvailable() && this.settings.tabStyle === 'immersive')
  @StorageLink(KEY_PRIMARY_COLOR) primaryColor: string = '#007DFF'
  @StorageLink('uplayer_theme_mode') themeMode: string = 'system'
  @StorageLink(AppStorageKeyConstants.KEY_TITLE_BUTTON_WIDTH) titleButtonWidth: number = 0
  @StorageLink(AppStorageKeyConstants.KEY_TITLE_BUTTON_HEIGHT) titleButtonHeight: number = 0
  @StorageLink(AppStorageKeyConstants.KEY_TOP_HEIGHT) topSafeHeight: number = 0
  @StorageLink('uplayer_display_size_scale') displaySizeScale: number = 1.0
  @StorageLink('uplayer_font_size_scale') fontSizeScale: number = 1.0
  @StorageLink('uplayer_glass_blur_strength') glassBlurStrength: number = 25
  @StorageLink('uplayer_home_top_blur_strength') homeTopBlurStrength: number = 25
  @StorageLink('uplayer_tab_indicator_opacity') tabIndicatorOpacity: number = 50
  // 经典样式下隐藏"Tab栏与播控条模糊强度"：用动画过渡避免突兀
  // 由 @Watch 包进统一触发动画后翻转，芯片增删才会播放统一显隐过渡
  @StorageLink(KEY_HAS_POINTER_DEVICE) @Watch('onPointerDeviceChange') hasPointerDevice: boolean = false
  @State maskChipVisible: boolean = false
  // 是否存在鼠标/触控板设备（决定「白色蒙版」开关是否显示）。
  // 检测结果由 InputDeviceUtil 写入 AppStorage（无动画作用域），芯片显隐改读镜像值，
  @State pageTitle: string = ''
  // 顶部模糊预览的靠边方向：左手握持 → 靠右（沿用原有映射，由 HoldingHandService 统一滤波后广播）
  @StorageLink(KEY_HOLDING_HAND_LEFT) previewOnRight: boolean = false
  // Tab 栏实时预览：直接使用 HdsTabs 系统组件，与 Index 完全一致的渲染管线
  @State previewTabIndex: number = 0
  @State showColorPicker: boolean = false
  @State showGlassScope: boolean = false
  @State pickerHue: number = 210
  @State pickerSaturation: number = 1
  @State pickerValue: number = 1
  @State pickerOriginalColor: string = '#007DFF'
  // 滤波与订阅统一交给 HoldingHandService，本页不再自行订阅 holdingHandChanged
  @StorageLink(KEY_HOLDING_HAND_ENABLED) holdingHandEnabled: boolean = true
  // 设备是否支持智感握姿能力（检测失败时隐藏该设置项）
  @State holdingHandSupported: boolean = true
  // 系统音效节点设备支持探测（aboutToAppear 中按 OHAudioSuite 能力置位，不支持时禁用对应卡片开关）
  @State soundFieldSupported: boolean = false
  @State environmentSupported: boolean = false
  @State beautifierSupported: boolean = false
  @State spaceRenderSupported: boolean = false
  private context: common.UIAbilityContext
    | undefined = AppStorage.get<common.UIAbilityContext>(AppStorageKeyConstants.KEY_UI_ABILITY_CONTEXT)
  // Tab 栏实时预览：直接使用 HdsTabs 系统组件，与 Index 完全一致的渲染管线
  private previewTabsController: HdsTabsController = new HdsTabsController()
  private eqCurveSettings: RenderingContextSettings = new RenderingContextSettings(true)
  private eqCurveCtx: CanvasRenderingContext2D = new CanvasRenderingContext2D(this.eqCurveSettings)
  private eqCanvasWidth: number = 0
  private eqCanvasHeight: number = 0
  // 返回按钮玻璃材质只在「Navigation 标题栏」生效区渲染；用一个空路由栈把本页套进
  private dataService: DataService = DataService.getInstance()
  private avPlayerService: AVPlayerService = AVPlayerService.getInstance()
  // 智感握姿开关：写穿到 AppStorage（HoldingHandService 在页面外也要读开关），
  // Navigation 仅为取得玻璃生效区，实际返回仍走 router（GlassBackButton.onBack）
  private navStack: NavPathStack = new NavPathStack()
  private isPC: boolean = deviceInfo.deviceType === '2in1'
  private themeOptions: ThemeOption[] = [
    { label: '跟随系统', value: 'system' },
    { label: '深色模式', value: 'dark' },
    { label: '浅色模式', value: 'light' }
  ]
  private tabStyleOptions: TabStyleOption[] = [
    { label: '经典', value: 'classic' },
    { label: '玻璃', value: 'immersive' }
  ]
  // 底部栏触摸指示选项：关 / 白色蒙版 / 跟手光效
  // 「白色蒙版」仅在检测到鼠标/触控板设备（鸿蒙 PC、外接鼠标）时才显示
  private touchIndicatorOptions: TouchIndicatorOption[] = [
    { label: '关', value: 'off' },
    { label: '白色蒙版', value: 'mask' },
    { label: '跟手光效', value: 'light' }
  ]
  // ═══ 设置项显隐统一动画（所有条件显隐的设置卡片/选项必须完全一致，禁止各自定义）═══
  private colorOptions: ThemeColorOption[] = [
    { name: '鸿蒙蓝', value: '#007DFF' },
    { name: '绯霞红', value: '#FF3B30' },
    { name: '琥珀橙', value: '#FF9500' },
    { name: '典雅金', value: '#C79A3B' },
    { name: '翠微绿', value: '#34C759' },
    { name: '天青蓝', value: '#5AC8FA' },
    { name: '沉浸靛', value: '#5856D6' },
    { name: '紫罗兰', value: '#AF52DE' }
  ]
  // 触发动画：与本页其他交互动画同一条弹簧曲线；
  private eqBands: EqBandInfo[] = [
    { freq: '32', index: 0 }, { freq: '64', index: 1 }, { freq: '125', index: 2 },
    { freq: '250', index: 3 }, { freq: '500', index: 4 }, { freq: '1k', index: 5 },
    { freq: '2k', index: 6 }, { freq: '4k', index: 7 }, { freq: '8k', index: 8 },
    { freq: '16k', index: 9 }
  ]
  private titleMap: Record<string, string> = {
    'customize': '定制',
    'playback': '播放',
    'audio': '音效',
    'about': '关于'
  }
  // 仓库地址由 SSH 地址 git@github.com:morozov130300/UPlayer-on-HarmonyOS.git 转出的 HTTPS 网址
  private aboutRepoUrl: string = 'https://github.com/morozov130300/UPlayer-on-HarmonyOS'
  private aboutEmail: string = 'jhy130300@126.com'
  private aboutQq: string = '3500873394'
  @State aboutVersionName: string = ''
  @State checkingUpdate: boolean = false

  // 指针设备检测结果变化：包进统一触发动画后翻转「白色蒙版」芯片显隐镜像值
  onPointerDeviceChange(): void {
    if (this.maskChipVisible === this.hasPointerDevice) {
      return
    }
    this.animateSettingChange(() => {
      this.maskChipVisible = this.hasPointerDevice
    })
  }

  aboutToAppear(): void {
    this.settings = this.dataService.getSettings()
    // 声明处初始值读取的是默认 AppSettingsData（tabStyle 恒为 classic），并非已保存设置；
    // 必须在加载真实设置后重算磨砂强度滑块可见性，否则新设备 + 玻璃样式进页时滑块会错误显示
    this.showClassicBlurStrength = !isLiquidGlassAvailable() || this.settings.tabStyle !== 'immersive'
    // 进入设置页时刷新鼠标/触控板状态，决定「白色蒙版」开关是否显示；
    // 镜像初值在刷新前直接取当前检测结果（首帧渲染不播过渡），之后热插拔变化经 @Watch 带动画翻转
    this.maskChipVisible = this.hasPointerDevice
    refreshPointerDeviceState()
    const params = this.getUIContext()?.getRouter()
      .getParams() as Record<string, string>
    const route: string = params?.category ?? 'customize'
    this.pageTitle = this.titleMap[route] ?? '设置'
    // 版本号动态读取 app.json5 的 versionName，避免每次升版本手动同步
    bundleManager.getBundleInfoForSelf(bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT)
      .then((info: bundleManager.BundleInfo) => {
        this.aboutVersionName = info.versionName
      })
      .catch((error: BusinessError) => {
        Logger.error(TAG, 'getBundleInfoForSelf failed: ' + error.message)
      })
    ColorConversion.setSysBarLightBackground(this.isDark())
    // 智感握姿监听由 HoldingHandService 统一持有（首页加号与本页预览共用同一份滤波结果）
    HoldingHandService.getInstance().syncWithSetting()
    // 检测设备智感握姿能力：不支持时隐藏开关并将设置复位为默认值
    this.holdingHandSupported = HoldingHandService.isSupported()
    if (!this.holdingHandSupported) {
      this.settings.holdingHandEnabled = true
      AppStorage.setOrCreate(KEY_HOLDING_HAND_ENABLED, true)
    }
    // 设备音效节点能力探测：不支持的卡片禁用开关并提示
    this.soundFieldSupported = this.avPlayerService.isSoundFieldSupported()
    this.environmentSupported = this.avPlayerService.isEnvironmentSupported()
    this.beautifierSupported = this.avPlayerService.isVoiceBeautifierSupported()
    this.spaceRenderSupported = this.avPlayerService.isSpaceRenderSupported()
  }

  // 预览器说明：
  //   - homeTopBlurPreview：渐变模糊 (linearGradientBlur) 方块，随「首页上端模糊强度」变化
  //   - tabBarLivePreview：真实 Tab 栏实时预览（复刻 Index），只负责预览效果、不携带任何设置项，

  aboutToDisappear(): void {
    if (this.showColorPicker) {
      this.settings.primaryColor = this.pickerOriginalColor
      this.primaryColor = this.pickerOriginalColor
      this.showColorPicker = false
    }
    // 监听不随本页销毁而退订：首页加号仍在用同一份握姿结果（由 EntryAbility 按前后台与开关同步订阅）
  }

  // ═══ 底部栏实时预览：复刻 Index 真实底部栏的 Tab 栏 ═══
  // Tab 栏：结构/尺寸/材质/指示器/点击行为与 Index.build 中的 HdsTabs 完全一致，
  //   仅把页面级状态（currentIndex）替换为预览态（previewTabIndex）；
  //   磨砂走 barBackgroundEffect 连续半径（半径 = 强度 × 0.5，与 Index 磨砂层同公式），
  //   「模糊强度」滑杆拖动时预览 Tab 栏磨砂实时连续变化
  // 预览卡片内禁止放置任何设置项（滑块均已拆为独立设置项卡片），调节任一相关设置时实时反映效果。

  // 解析「底部栏触摸指示」实际生效值：

  //     随各独立设置项（Tab栏与播控条模糊强度 / Tab 指示器不透明度 / 组件风格等）实时变化
  @Builder
  homeTopBlurPreview(): void {
    Stack({ alignContent: Alignment.Center }) {
      Text('首页上端')
        .fontSize(this.scaledFont(12))
        .fontWeight(FontWeight.Bold)
        .fontColor(this.primaryColor)
        .letterSpacing(this.scaledSize(1))
      Row()
        .width('100%')
        .height('100%')
        .backgroundColor(Color.Transparent)
        .linearGradientBlur(this.topBlurRadius(), {
          fractionStops: [[1, 0], [1, 0.5], [0, 1]],
          direction: GradientDirection.Bottom
        })
      Row()
        .width('100%')
        .height('100%')
        .borderRadius(this.scaledSize(18))
        .linearGradient({
          angle: 180,
          colors: [
            [ColorHelper.hexToRgba(this.primaryColor, 0.16), 0],
            [ColorHelper.hexToRgba(this.primaryColor, 0.04), 0.55],
            ['rgba(0,0,0,0)', 1]
          ]
        })
        .border({ width: 1, color: 'rgba(255,255,255,0.28)' })
        .shadow({ radius: 12, color: ColorHelper.hexWithAlpha(this.primaryColor, '44') })
    }
    .width(this.scaledSize(82))
    .height(this.scaledSize(36))
    .borderRadius(this.scaledSize(18))
    .clip(true)
  }

  // 设置页顶部带模糊半径：统一走 GlassUtil 的分段函数（先正比例、到 60 后恒定，临界处无缝相接），

  @Builder
  previewTabBar(): void {
    Stack({ alignContent: Alignment.Center }) {
      HdsTabs({ controller: this.previewTabsController, index: this.previewTabIndex }) {
        TabContent()
          .tabBar(this.previewTabLabelBuilder(0, '首页', $r('app.media.ic_public_home')))
        TabContent()
          .tabBar(this.previewTabLabelBuilder(1, '歌单', $r('app.media.ic_public_view_list')))
        TabContent()
          .tabBar(this.previewTabLabelBuilder(2, '设置', $r('app.media.ic_public_settings')))
      }
      .barPosition(BarPosition.End)
      .barOverlap(true)
      .barHeight(this.scaledSize(44))
      .barWidth(this.scaledSize(228))
      .scrollable(true)
      .barBackgroundColor(Color.Transparent)
      .barFloatingStyle(this.getPreviewBarFloatingStyle())
      // 经典模式：barFloatingStyle 不含 systemMaterialEffect → TabBar 走 barBackgroundEffect 连续磨砂，
      //   半径随「模糊强度」滑杆实时变化（拖动即反馈）
      // 玻璃模式：barFloatingStyle 含 systemMaterialEffect（液态玻璃）→ 磨砂关闭（radius 0，与真机一致）
      .barBackgroundEffect(this.getPreviewBarBackgroundEffect())
      .animationDuration(StyleConstants.ANIMATION_SWIPER_DURATION)
      .onChange((index: number) => {
        this.switchPreviewTab(index)
      })
      .width(this.scaledSize(228))
      .height(this.scaledSize(72))
    }
    .width('100%')
    .height(this.scaledSize(72))
    .alignSelf(ItemAlign.Center)
  }

  @Builder
  previewTabLabelBuilder(index: number, name: string, icon: Resource) {
    Stack() {
      // 指示器光晕：恒定渲染 + translate 锚定选中 tab（与 Index.tabLabelBuilder 同一滑移方案）
      Row()
        .width(this.scaledSize(64))
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
        .opacity(this.previewTabIndex === index ? 1 : 0)
        .translate({ x: (this.previewTabIndex - index) * this.previewTabSlotWidth() })
        .hitTestBehavior(HitTestMode.None)
      Column() {
        Image(icon)
          .height(this.scaledSize(20))
          .fillColor(this.previewTabIndex === index ? this.previewTabContentColor() :
            $r('app.color.tab_content_secondary'))
          .scale({
            x: this.previewTabIndex === index ? 1.25 : 1.0,
            y: this.previewTabIndex === index ? 1.25 : 1.0
          })
        Text(name)
          .fontSize(8)
          .fontColor(this.previewTabIndex === index ? this.previewTabContentColor() :
            $r('app.color.tab_content_secondary'))
          .margin({ top: this.scaledSize(3) })
      }.width(this.scaledSize(72)).height(this.scaledSize(36)).justifyContent(FlexAlign.Center)
      .offset({ y: 2 })
    }
    .width(this.scaledSize(72))
    .height(this.scaledSize(36))
  }

  // Tab 栏悬浮其上；随底部栏样式设置切换经典/玻璃两种真实形态
  @Builder
  tabBarLivePreview(): void {
    Stack({ alignContent: Alignment.Center }) {
      Column({ space: this.scaledSize(4) }) {
        Text('UPlayer')
          .fontSize(this.scaledFont(16))
          .fontWeight(FontWeight.Bold)
          .fontColor('rgba(255,255,255,0.95)')
          .letterSpacing(this.scaledSize(1))
        Text('音乐 · 歌单 · 均衡器 · Aa 你好')
          .fontSize(this.scaledFont(11))
          .fontColor('rgba(255,255,255,0.75)')
      }
      .alignItems(HorizontalAlign.Center)

      this.previewTabBar()
    }
    .width('100%')
    .height(this.scaledSize(104))
    .borderRadius(this.scaledSize(12))
    .linearGradient({
      angle: 135,
      colors: [
        ['#FF5A5F', 0.0],
        ['#FF9500', 0.35],
        ['#34C759', 0.65],
        ['#5AC8FA', 1.0]
      ]
    })
    .clip(true)
  }

  updateSetting(): void {
    this.dataService.saveSettings(this.settings)
  }

  setThemeMode(mode: string): void {
    this.getUIContext()?.animateTo({ curve: curves.springMotion(0.4, 0.8) }, () => {
      this.settings.themeMode = mode
      this.settings = this.settings
    })
    this.updateSetting()
    AppStorage.setOrCreate('uplayer_theme_mode', mode)
    this.applyThemeMode(mode)
    ColorConversion.setSysBarLightBackground(this.isDark())
  }

  setTabStyle(style: string): void {
    // 切换样式时同步更新与样式挂钩的设置项可见性（磨砂强度卡片/底部栏触摸指示行）：
    // 新设备上玻璃样式不需要磨砂兜底（液态玻璃接管），经典样式需要；老设备两种样式都用磨砂兜底，始终显示。
    // 可见性翻转必须与样式切换同处一个统一触发动画，卡片显隐过渡才会播放
    this.animateSettingChange(() => {
      if (isLiquidGlassAvailable()) {
        this.showClassicBlurStrength = style === 'classic'
      }
      this.settings.tabStyle = style
      this.settings = this.settings
    })
    this.updateSetting()
    AppStorage.setOrCreate('uplayer_tab_style', style)
  }

  // Tab 栏磨砂半径：与 Index 磨砂层同公式（模糊强度 × 0.5），连续值，滑杆拖动时实时变化；

  applyThemeMode(mode: string): void {
    if (this.context === undefined) {
      return
    }
    const appCtx = this.context.getApplicationContext()
    try {
      if (mode === 'light') {
        appCtx.setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT)
      } else if (mode === 'dark') {
        appCtx.setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_DARK)
      } else {
        appCtx.setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET)
      }
    } catch (e) {
      Logger.error(TAG, 'setColorMode failed: ' + JSON.stringify(e))
    }
  }

  setPrimaryColor(color: string): void {
    this.settings.primaryColor = color
    this.updateSetting()
    AppStorage.setOrCreate(KEY_PRIMARY_COLOR, color)
  }

  // 预览容器：彩色渐变底衬 + 示例文字（模拟页面内容，让磨砂/液态玻璃的透视效果可见），

  onSpeedChange(value: number, mode: SliderChangeMode): void {
    this.settings.playSpeed = 0.5 + value / 100
    if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) {
      this.updateSetting()
    }
    try {
      this.avPlayerService.setSpeed(this.settings.playSpeed)
    } catch (e) {
      Logger.error(TAG, 'setSpeed failed: ' + JSON.stringify(e))
    }
  }

  onEqBandChange(bandIndex: number, value: number, mode: SliderChangeMode): void {
    const bands: number[] = this.settings.eqBands.slice()
    bands[bandIndex] = Math.round(value) - 10
    this.settings.eqBands = bands
    this.settings = this.settings
    this.drawEqCurve()
    const applied: boolean = this.avPlayerService.updateEqualizerBands(bands)
    if (!applied && (mode === SliderChangeMode.End || mode === SliderChangeMode.Click)) {
      Logger.error(TAG, `equalizer change not applied by native backend index=${bandIndex} value=${bands[bandIndex]}`)
    }
    if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) {
      this.updateSetting()
    }
  }

  // ═══ 均衡器预设（官方 9 预设一键切换，手动拖滑块后自动回到自定义态无高亮）═══
  private eqPresetActive(index: number): boolean {
    const preset: number[] = EqPresetTable.GAINS[index]
    const current: number[] = this.settings.eqBands
    if (preset.length !== current.length) {
      return false
    }
    for (let i = 0; i < preset.length; i++) {
      if (preset[i] !== current[i]) {
        return false
      }
    }
    return true
  }

  applyEqPreset(index: number): void {
    const gains: number[] = EqPresetTable.GAINS[index].slice()
    this.settings.eqBands = gains
    this.settings = this.settings
    this.drawEqCurve()
    this.updateSetting()
    this.avPlayerService.applyEqualizer(this.settings.eqEnabled, gains)
  }

  // ═══ 声场/环境/美声类型切换 ═══
  onSoundFieldTypeChange(type: number): void {
    this.animateSettingChange(() => {
      this.settings.soundFieldType = type
      this.settings = this.settings
    })
    this.updateSetting()
    this.avPlayerService.applySoundField(this.settings.soundFieldEnabled, type)
  }

  onEnvironmentTypeChange(type: number): void {
    this.animateSettingChange(() => {
      this.settings.environmentType = type
      this.settings = this.settings
    })
    this.updateSetting()
    this.avPlayerService.applyEnvironment(this.settings.environmentEnabled, type)
  }

  onBeautifierTypeChange(type: number): void {
    this.animateSettingChange(() => {
      this.settings.beautifierType = type
      this.settings = this.settings
    })
    this.updateSetting()
    this.avPlayerService.applyVoiceBeautifier(this.settings.beautifierEnabled, type)
  }

  // ═══ 空间渲染：模式 / 参数 / 旋转方向 ═══
  private spaceValue(i: number): number {
    const values: number[] = this.settings.spaceRenderValues
    if (i < values.length) {
      return values[i]
    }
    const defaults: number[] = SpaceRenderTable.MODE_DEFAULTS[this.settings.spaceRenderMode]
    return i < defaults.length ? defaults[i] : 0
  }

  private spaceText(i: number): string {
    const v: number = this.spaceValue(i)
    return Number.isInteger(v) ? String(v) : v.toFixed(1)
  }

  onSpaceModeChange(mode: number): void {
    this.animateSettingChange(() => {
      this.settings.spaceRenderMode = mode
      this.settings.spaceRenderValues = SpaceRenderTable.MODE_DEFAULTS[mode].slice()
      this.settings = this.settings
    })
    this.updateSetting()
    this.avPlayerService.applySpaceRender(this.settings.spaceRenderEnabled, mode, this.settings.spaceRenderValues)
  }

  onSpaceValueChange(i: number, value: number, mode: SliderChangeMode): void {
    const values: number[] = this.settings.spaceRenderValues.slice()
    if (i < values.length) {
      values[i] = value
    }
    this.settings.spaceRenderValues = values
    this.settings = this.settings
    if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) {
      this.updateSetting()
      this.avPlayerService.applySpaceRender(this.settings.spaceRenderEnabled, this.settings.spaceRenderMode, values)
    }
  }

  onSpaceDirectionChange(direction: number): void {
    const values: number[] = this.settings.spaceRenderValues.slice()
    if (values.length > 4) {
      values[4] = direction
    }
    this.settings.spaceRenderValues = values
    this.settings = this.settings
    this.updateSetting()
    this.avPlayerService.applySpaceRender(this.settings.spaceRenderEnabled, this.settings.spaceRenderMode, values)
  }

  pageTransition() {
    PageTransitionEnter({ duration: StyleConstants.ANIMATION_SETTINGS_ENTER_DURATION, curve: Curve.EaseOut })
      .slide(SlideEffect.Right)
      .opacity(1)
    PageTransitionExit({ duration: StyleConstants.ANIMATION_SETTINGS_EXIT_DURATION, curve: Curve.EaseIn })
      .slide(SlideEffect.Right)
      .opacity(0)
  }

  build() {
    // 套一层 Navigation：返回按钮的玻璃材质只在「Navigation 标题栏」生效区渲染。
    // BarStyle.STACK 让内容区延伸到标题栏底下（保持原有全屏/沉浸式布局），
    // 标题栏用自定义构建器放 GlassBackButton（自带 systemMaterial，进生效区即出玻璃）+ 标题。
    Navigation(this.navStack) {
      Stack() {
        Column() {
          // 沉浸式顶部：滚动内容从页面顶部开始（顶部空出标题带高度），
          // 内容向上滚动时从标题栏下方穿过，被标题栏玻璃/渐变层模糊（与首页上端一致）
          Stack({ alignContent: Alignment.Center }) {
            Column() {
              Scroll() {
                Column({ space: this.scaledSize(10) }) {
                  if (this.pageTitle === '定制') {
                    this.buildCustomizeSection()
                  } else if (this.pageTitle === '播放') {
                    this.buildPlaybackSection()
                  } else if (this.pageTitle === '音效') {
                    this.buildAudioSection()
                  } else if (this.pageTitle === '关于') {
                    this.buildAboutSection()
                  }
                }
                .width('100%')
                .constraintSize({ minWidth: 0, maxWidth: '100%' })
                .padding({
                  left: this.scaledSize(12),
                  right: this.scaledSize(12),
                  top: this.scaledSize(5) + this.titleBandHeight(),
                  bottom: this.scaledSize(40)
                })
              }
              .width('100%')
              .layoutWeight(1)
              .align(Alignment.Top)
              .edgeEffect(EdgeEffect.Spring)
            }
            .width('100%')
            .height('100%')

            if (this.showColorPicker) {
              this.colorPickerOverlay()
            }

            // 顶部渐变模糊/着色层保留（内容滚动到标题栏下方时被模糊）；返回按钮与标题已移至标题栏
            this.titleBand()
          }
          .width('100%')
          .layoutWeight(1)
        }
        .width('100%')
        .height('100%')
      }
      .width('100%')
      .height('100%')
      // 背景使用预设纯色（明暗自适应），不应用任何玻璃/模糊/透明度效果
      .backgroundColor($r('app.color.page_background_sm'))
    }
    .title({
      builder: this.glassTitleBar,
      height: this.titleBandHeight()
    }, { barStyle: BarStyle.STACK })
    .hideBackButton(true)
    .hideTitleBar(false)
    // 与播放器页一致：宽窗口（lg/xl，如 X7 展开态）默认走 Split 双栏会把内容挤进左侧窄栏、
    // 右侧露出黑色背景，强制 Stack 模式让内容区铺满整窗
    .mode(NavigationMode.Stack)
    .width('100%')
    .height('100%')
    .bindSheet($$this.showGlassScope, this.glassScopeSheetBuilder(), {
      height: SheetSize.FIT_CONTENT,
      dragBar: false,
      preferType: SheetType.CENTER,
      showClose: true,
      backgroundColor: $r('app.color.page_background_other')
    })
  }

  // 右侧预留 PC 窗口标题按钮区（titleButtonWidth + 12），沿用原 titleBand 的避让逻辑。
  @Builder
  glassTitleBar() {
    Row() {
      GlassBackButton({
        clickSize: this.scaledSize(48),
        iconSize: this.scaledSize(15),
        iconColor: this.settingTextColor(),
        iconOpacity: 0.9,
        onBack: () => {
          this.getUIContext()?.getRouter().back()
        }
      })
      Text(this.pageTitle)
        .fontSize(this.scaledFont(17))
        .fontColor(this.settingTextColor())
        .fontWeight(FontWeight.Bold)
        .margin({ left: 4 })
      Blank()
    }
    .width('100%')
    .padding({
      left: 4,
      right: this.isPC ? this.titleButtonWidth + 12 : 16,
      top: this.isPC ? 0 : this.topSafeHeight
    })
    .alignItems(VerticalAlign.Center)
    // 玻璃只落在返回键圆形上（GlassBackButton 自带 systemMaterial，处于 Navigation 标题栏生效区即渲染）；
    // 条带本身不挂材质，避免「条带材质 + 返回键材质」同子树嵌套（官方功耗约束），
    // 顶部观感由内容区既有磨砂 titleBand 承接
    .backgroundColor(Color.Transparent)
  }

  // 标题带浮在滚动内容之上，内容滚动到其下方时被模糊；经典/玻璃两种 Tab 风格下均启用
  @Builder
  titleBand(): void {
    Stack({ alignContent: Alignment.Top }) {
      Row()
        .width('100%')
        .height('100%')
        .backgroundColor(Color.Transparent)
        .linearGradientBlur(this.topBlurRadius(), {
          fractionStops: [[1, 0], [1, 0.5], [0, 1]],
          direction: GradientDirection.Bottom
        })

      Row()
        .width('100%')
        .height('100%')
        .linearGradient({
          angle: 180,
          colors: [
            [ColorHelper.hexToRgba(this.primaryColor, 0.04), 0],
            [ColorHelper.hexToRgba(this.primaryColor, 0.02), 0.5],
            ['rgba(0,0,0,0)', 1]
          ]
        })
    }
    .width('100%')
    .height(this.titleBandHeight())
    .position({ top: 0 })
    .clip(true)
    .hitTestBehavior(HitTestMode.Transparent)
    .zIndex(2)
  }

  // helpIconLabel 非空时，问号图标紧跟文字
  @Builder
  groupTitle(title: string, helpIconLabel?: string): void {
    Row() {
      Text(title)
        .fontSize(this.scaledFont(11))
        .fontColor(this.settingTextColor())
        .fontWeight(FontWeight.Bold)
      if (helpIconLabel !== undefined) {
        Stack({ alignContent: Alignment.Center }) {
          Circle()
            .width(this.scaledSize(18))
            .height(this.scaledSize(18))
            .fill(ColorHelper.hexToRgba(this.primaryColor, 0.12))
          Image($r('app.media.ic_public_help'))
            .width(this.scaledSize(13))
            .height(this.scaledSize(13))
            .fillColor(this.primaryColor)
        }
        .width(this.scaledSize(18))
        .height(this.scaledSize(18))
        .margin({ left: this.scaledSize(4) })
        .onClick(() => {
          this.showGlassScope = true
        })
      }
    }
    .width('100%')
    .padding({ left: this.scaledSize(8), top: this.scaledSize(1), bottom: this.scaledSize(4) })
    .alignItems(VerticalAlign.Center)
  }

  // 行内二级标题（用于 Row 内，不带 width 约束，避免溢出）
  @Builder
  subTitleRow(title: string): void {
    Text(title)
      .fontSize(this.scaledFont(14))
      .fontColor(this.settingTextColor())
      .fontWeight(FontWeight.Medium)
      .padding({ right: this.scaledSize(4) })
  }

  // 玻璃效果生效范围说明弹窗（bindSheet 半模态内容）
  @Builder
  glassScopeSheetBuilder(): void {
    Column({ space: this.scaledSize(10) }) {
      Text('玻璃效果生效范围')
        .fontSize(this.scaledFont(16))
        .fontColor(this.settingTextColor())
        .fontWeight(FontWeight.Bold)
        .width('100%')
        .textAlign(TextAlign.Start)

      Text('以下位置会使用玻璃效果：')
        .fontSize(this.scaledFont(12))
        .fontColor(this.settingSubTextColor())
        .width('100%')
        .padding({ top: this.scaledSize(2) })
      this.scopeLine('• 底部 Tab 栏（沉浸式玻璃，带光效跟手 + 按压 Q 弹形变）')
      this.scopeLine('• 右下角播控条')
      this.scopeLine('• 顶部的模糊层（首页顶部标题区，覆盖首页第一屏）')
      this.scopeLine('• 首页 / 歌单 / 设置 / 设置详情 四个一级页面的顶层背景（仅档位与材质在此生效）')
      this.scopeLine(
        '• 操作时屏幕底部短暂弹出的文字提示浮层（如切换播放模式时的"随机播放"）——设备支持液态玻璃时固定使用液态玻璃材质')

      Text('以下位置不使用玻璃效果：')
        .fontSize(this.scaledFont(12))
        .fontColor(this.settingSubTextColor())
        .width('100%')
        .padding({ top: this.scaledSize(6) })
      this.scopeLine('• 音乐播放器页面')
      this.scopeLine('• 系统API ≤ 26 （液态玻璃材质降级为背景模糊）')

      Row() {
        Button('知道了')
          .layoutWeight(1)
          .height(this.scaledSize(30))
          .fontColor('#FFFFFF')
          .backgroundColor(this.primaryColor)
          .borderRadius(this.scaledSize(15))
          .onClick(() => {
            this.showGlassScope = false
          })
      }
      .width('100%')
      .padding({ top: this.scaledSize(8), bottom: this.scaledSize(10) })
    }
    .width('100%')
    .padding({ left: this.scaledSize(20), right: this.scaledSize(20), top: this.scaledSize(14) })
  }

  @Builder
  scopeLine(text: string): void {
    Text(text)
      .fontSize(this.scaledFont(12))
      .fontColor(this.settingSubTextColor())
      .width('100%')
      .padding({ top: this.scaledSize(2) })
  }

  @Builder
  buildCustomizeSection(): void {
    Column({ space: this.scaledSize(10) }) {
      Row() {
        this.groupTitle('全局')
      }

      Column() {
        this.toggleRow('向下滑动时隐藏加号按钮', this.settings.plusButtonScrollHide, (val: boolean) => {
          this.settings.plusButtonScrollHide = val
          this.updateSetting()
        })
      }
      .width('100%')
      .padding({ left: this.scaledSize(14), right: this.scaledSize(14) })
      .backgroundColor(ColorHelper.hexToRgba(this.primaryColor, 0.04))
      .borderRadius(this.scaledSize(10))

      // 智感握姿（设备不支持时隐藏）
      if (this.holdingHandSupported) {
        Row() {
          Column({ space: this.scaledSize(6) }) {
            Text('智感握姿')
              .fontSize(this.scaledFont(14))
              .fontColor(this.settingTextColor())
              .fontWeight(FontWeight.Medium)
            Text('根据单手握持方向自动调整首页顶部预览与控件靠左/靠右。')
              .fontSize(this.scaledFont(12))
              .fontColor(this.settingSubTextColor())
          }
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center)
          .alignItems(HorizontalAlign.Start)

          Toggle({ type: ToggleType.Switch, isOn: this.settings.holdingHandEnabled })
            .selectedColor(this.primaryColor)
            .alignSelf(ItemAlign.Center)
            .onChange((isOn: boolean) => {
              this.settings.holdingHandEnabled = isOn
              // 写穿到 AppStorage 后由共享服务按新开关重新订阅/退订
              this.holdingHandEnabled = isOn
              this.updateSetting()
              HoldingHandService.getInstance().syncWithSetting()
            })
        }
        .width('100%')
        .height(this.scaledSize(52))
        .padding({ left: this.scaledSize(14), right: this.scaledSize(14) })
        .backgroundColor(ColorHelper.hexToRgba(this.primaryColor, 0.04))
        .borderRadius(this.scaledSize(10))
        .transition(this.settingCardTransition())
      }

      Column() {
        Row() {
          Text('主题模式')
            .fontSize(this.scaledFont(14))
            .fontColor(this.settingTextColor())
            .fontWeight(FontWeight.Medium)
          Blank()
          ForEach(this.themeOptions, (opt: ThemeOption) => {
            Column() {
              Text(opt.label)
                .fontSize(this.scaledFont(11))
                .fontColor(this.settings.themeMode === opt.value ? '#FFFFFF' : this.settingInactiveTextColor())
            }
            .padding({
              left: this.scaledSize(10),
              right: this.scaledSize(10),
              top: this.scaledSize(5),
              bottom: this.scaledSize(5)
            })
            .backgroundColor(this.settings.themeMode === opt.value ? this.primaryColor :
              ColorHelper.hexToRgba(this.primaryColor, 0.08))
            .borderRadius(this.scaledSize(14))
            .animation({ duration: 200, curve: Curve.EaseInOut })
            .onClick(() => {
              this.setThemeMode(opt.value)
            })
          }, (opt: ThemeOption) => opt.value)
        }
        .padding({ left: this.scaledSize(14), right: this.scaledSize(14) })
        .width('100%')
        .height(this.scaledSize(44))
        .alignItems(VerticalAlign.Center)
      }
      .width('100%')
      .backgroundColor(ColorHelper.hexToRgba(this.primaryColor, 0.04))
      .borderRadius(this.scaledSize(10))

      Column() {
        // 首页上端模糊强度
        Column({ space: this.scaledSize(6) }) {
          Row() {
            this.subTitleRow('首页上端模糊强度')
            Blank()
          }
          .width('100%')

          Text('控制首页顶部标题区玻璃模糊的渐变强度。')
            .fontSize(this.scaledFont(12))
            .fontColor(this.settingSubTextColor())
            .width('100%')
          Row({ space: this.scaledSize(12) }) {
            if (!this.previewOnRight) {
              this.homeTopBlurPreview()
            }
            Text('浅')
              .fontSize(this.scaledFont(11))
              .fontColor(this.settingTextColor())
              .margin({
                left: this.previewOnRight ? 0 : this.scaledSize(14),
                right: this.scaledSize(8)
              })
            Slider({
              value: this.settings.homeTopBlurStrength,
              min: 0,
              max: 100,
              step: 1,
              style: SliderStyle.OutSet
            })
              .layoutWeight(1)
              .selectedColor(this.primaryColor)
              .trackColor(ColorHelper.hexToRgba(this.primaryColor, 0.12))
              .blockColor('#FFFFFF')
              .blockSize({ width: this.scaledSize(20), height: this.scaledSize(20) })
              .blockBorderColor(this.primaryColor)
              .blockBorderWidth(3)
              .onChange((value: number, mode: SliderChangeMode) => {
                this.settings.homeTopBlurStrength = value
                this.homeTopBlurStrength = value
                if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) {
                  this.updateSetting()
                }
              })
            Text('深')
              .fontSize(this.scaledFont(11))
              .fontColor(this.settingTextColor())
              .margin({ left: this.scaledSize(8) })
            if (this.previewOnRight) {
              Blank().width(this.scaledSize(14))
              this.homeTopBlurPreview()
            }
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)
          .padding({ top: this.scaledSize(2), bottom: this.scaledSize(2) })
        }
        .width('100%')
        .padding({
          top: this.scaledSize(10),
          left: this.scaledSize(14),
          right: this.scaledSize(14),
          bottom: this.scaledSize(10)
        })
        .backgroundColor(ColorHelper.hexToRgba(this.primaryColor, 0.04))
        .borderRadius(this.scaledSize(10))

        // 「Tab栏与播控条模糊强度」「Tab 指示器不透明度」是「高级样式」组的独立设置项卡片，
        // Tab 实时预览卡片只负责预览效果、不携带任何设置项
      }
      .width('100%')

      Column({ space: this.scaledSize(8) }) {
        Row() {
          this.subTitleRow('主题色')
          Blank()
        }
        .width('100%')

        Grid() {
          ForEach(this.colorOptions, (option: ThemeColorOption) => {
            GridItem() {
              Row({ space: this.scaledSize(8) }) {
                Column()
                  .width(this.scaledSize(24))
                  .height(this.scaledSize(24))
                  .borderRadius(this.scaledSize(12))
                  .backgroundColor(option.value)
                  .border({
                    width: this.settings.primaryColor === option.value ? 3 : 0,
                    color: '#FFFFFF'
                  })
                Text(option.name)
                  .fontSize(this.scaledFont(11))
                  .fontColor(this.settingTextColor())
                  .maxLines(1)
              }
              .width('100%')
              .height(this.scaledSize(42))
              .padding({
                left: this.scaledSize(8),
                right: this.scaledSize(8),
                top: this.scaledSize(4),
                bottom: this.scaledSize(4)
              })
              .margin({ bottom: this.scaledSize(4) })
              .borderRadius(this.scaledSize(10))
              .backgroundColor(ColorHelper.hexToRgba(this.primaryColor, 0.04))
              .onClick(() => {
                this.setPrimaryColor(option.value)
              })
            }
          }, (option: ThemeColorOption) => option.value)
        }
        .columnsTemplate(this.isPC ? '1fr 1fr 1fr 1fr' : '1fr 1fr')
        .columnsGap(this.scaledSize(8))
        .rowsGap(this.scaledSize(8))
        .width('100%')

        Row({ space: this.scaledSize(8) }) {
          Column()
            .width(this.scaledSize(24))
            .height(this.scaledSize(24))
            .borderRadius(this.scaledSize(12))
            .backgroundColor(this.settings.primaryColor)
            .border({
              width: !this.colorOptions.some((opt: ThemeColorOption) => opt.value === this.settings.primaryColor) ? 3 :
                0,
              color: '#FFFFFF'
            })
          Text('自定义颜色')
            .fontSize(this.scaledFont(11))
            .fontColor(this.settingTextColor())
            .maxLines(1)
          Blank()
          Image($r('app.media.ic_public_themes'))
            .width(this.scaledSize(16))
            .height(this.scaledSize(16))
            .fillColor(this.settings.primaryColor)
        }
        .width('100%')
        .height(this.scaledSize(42))
        .padding({ left: this.scaledSize(14), right: this.scaledSize(14) })
        .borderRadius(this.scaledSize(10))
        .backgroundColor(ColorHelper.hexToRgba(this.primaryColor, 0.04))
        .alignItems(VerticalAlign.Center)
        .onClick(() => {
          this.openColorPicker()
        })
      }
      .width('100%')
      .padding({
        top: this.scaledSize(10),
        left: this.scaledSize(14),
        right: this.scaledSize(14),
        bottom: this.scaledSize(10)
      })
      .backgroundColor(ColorHelper.hexToRgba(this.primaryColor, 0.04))
      .borderRadius(this.scaledSize(10))

      Column({ space: this.scaledSize(6) }) {
        Row() {
          this.subTitleRow('字体大小')
          Blank()
        }
        .width('100%')

        Row() {
          Text('A')
            .fontSize(this.scaledFont(11))
            .fontColor(this.settingTextColor())
          Stack() {
            Slider({
              value: this.settings.fontSizeScale * 100,
              min: 80,
              max: 150,
              step: 1,
              style: SliderStyle.OutSet
            })
              .layoutWeight(1)
              .selectedColor(this.primaryColor)
              .trackColor(ColorHelper.hexToRgba(this.primaryColor, 0.12))
              .blockColor('#FFFFFF')
              .blockSize({ width: this.scaledSize(20), height: this.scaledSize(20) })
              .blockBorderColor(this.primaryColor)
              .blockBorderWidth(3)
              .onChange((value: number, mode: SliderChangeMode) => {
                this.settings.fontSizeScale = value / 100
                this.fontSizeScale = this.settings.fontSizeScale
                if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) {
                  this.updateSetting()
                }
              })
          }
          .layoutWeight(1)
          .height(this.scaledSize(36))

          Text('A')
            .fontSize(this.scaledFont(20))
            .fontColor(this.settingTextColor())
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
      }
      .width('100%')
      .padding({
        top: this.scaledSize(10),
        left: this.scaledSize(14),
        right: this.scaledSize(14),
        bottom: this.scaledSize(10)
      })
      .backgroundColor(ColorHelper.hexToRgba(this.primaryColor, 0.04))
      .borderRadius(this.scaledSize(10))

      Column({ space: this.scaledSize(6) }) {
        Row() {
          this.subTitleRow('显示大小')
          Blank()
        }
        .width('100%')

        Row() {
          Text('小')
            .fontSize(this.scaledFont(11))
            .fontColor(this.settingTextColor())
          Stack() {
            Slider({
              value: this.settings.displaySizeScale * 100,
              min: 80,
              max: 150,
              step: 1,
              style: SliderStyle.OutSet
            })
              .layoutWeight(1)
              .selectedColor(this.primaryColor)
              .trackColor(ColorHelper.hexToRgba(this.primaryColor, 0.12))
              .blockColor('#FFFFFF')
              .blockSize({ width: this.scaledSize(20), height: this.scaledSize(20) })
              .blockBorderColor(this.primaryColor)
              .blockBorderWidth(3)
              .onChange((value: number, mode: SliderChangeMode) => {
                this.settings.displaySizeScale = value / 100
                this.displaySizeScale = this.settings.displaySizeScale
                if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) {
                  this.updateSetting()
                }
              })
          }
          .layoutWeight(1)
          .height(this.scaledSize(36))

          Text('大')
            .fontSize(this.scaledFont(14))
            .fontColor(this.settingTextColor())
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
      }
      .width('100%')
      .padding({
        top: this.scaledSize(10),
        left: this.scaledSize(14),
        right: this.scaledSize(14),
        bottom: this.scaledSize(10)
      })
      .backgroundColor(ColorHelper.hexToRgba(this.primaryColor, 0.04))
      .borderRadius(this.scaledSize(10))

      // ─── 一级标题「高级样式」 + 右上角叹号角标 ───
      // 点击叹号弹窗说明玻璃效果所影响的所有位置
      Column({ space: this.scaledSize(10) }) {
        this.groupTitle('高级样式', 'glass')
        // Tab 栏实时预览卡片：只负责预览效果，禁止携带任何设置项，
        // 各独立设置项卡片调节时实时反映透视与磨砂效果
        Column() {
          this.tabBarLivePreview()
        }
        .width('100%')
        .padding({
          top: this.scaledSize(10),
          left: this.scaledSize(14),
          right: this.scaledSize(14),
          bottom: this.scaledSize(10)
        })
        .backgroundColor(ColorHelper.hexToRgba(this.primaryColor, 0.04))
        .borderRadius(this.scaledSize(10))

        Column() {
          Row() {
            Text('组件风格')
              .fontSize(this.scaledFont(14))
              .fontColor(this.settingTextColor())
              .fontWeight(FontWeight.Medium)
            Blank()
            ForEach(this.tabStyleOptions, (opt: TabStyleOption) => {
              Column() {
                Text(opt.label)
                  .fontSize(this.scaledFont(11))
                  .fontColor(this.settings.tabStyle === opt.value ? '#FFFFFF' : this.settingInactiveTextColor())
              }
              .padding({
                left: this.scaledSize(10),
                right: this.scaledSize(10),
                top: this.scaledSize(5),
                bottom: this.scaledSize(5)
              })
              .backgroundColor(this.settings.tabStyle === opt.value ? this.primaryColor :
                ColorHelper.hexToRgba(this.primaryColor, 0.08))
              .borderRadius(this.scaledSize(14))
              .animation({ duration: 200, curve: Curve.EaseInOut })
              .onClick(() => {
                this.setTabStyle(opt.value)
              })
            }, (opt: TabStyleOption) => opt.value)
          }
          .padding({ left: this.scaledSize(14), right: this.scaledSize(14) })
          .width('100%')
          .height(this.scaledSize(44))
          .alignItems(VerticalAlign.Center)
        }
        .width('100%')
        .backgroundColor(ColorHelper.hexToRgba(this.primaryColor, 0.04))
        .borderRadius(this.scaledSize(10))

        // 底部栏触摸指示：关 / 白色蒙版 / 跟手光效。
        // 仅玻璃样式且设备支持液态玻璃时显示：触摸指示依赖液态玻璃材质，经典样式下不生效；
        // 白色蒙版开关按鼠标检测结果动态显示/隐藏（见 visibleTouchIndicatorOptions）
        if (isLiquidGlassAvailable() && this.settings.tabStyle === 'immersive') {
          Column() {
            Row() {
              this.subTitleRow('底部栏触摸指示')
              Blank()
              ForEach(this.visibleTouchIndicatorOptions(), (opt: TouchIndicatorOption) => {
                Column() {
                  Text(opt.label)
                    .fontSize(this.scaledFont(11))
                    .fontColor(this.settings.tabTouchIndicator === opt.value
                      ? '#FFFFFF' : this.settingInactiveTextColor())
                }
                .padding({
                  left: this.scaledSize(10),
                  right: this.scaledSize(10),
                  top: this.scaledSize(5),
                  bottom: this.scaledSize(5)
                })
                .backgroundColor(this.settings.tabTouchIndicator === opt.value
                  ? this.primaryColor : ColorHelper.hexToRgba(this.primaryColor, 0.08))
                .borderRadius(this.scaledSize(14))
                .animation({ duration: 200, curve: Curve.EaseInOut })
                .onClick(() => {
                  this.settings.tabTouchIndicator = opt.value
                  this.updateSetting()
                  AppStorage.setOrCreate('uplayer_tab_touch_indicator', opt.value)
                })
                .transition(this.settingCardTransition())
              }, (opt: TouchIndicatorOption) => opt.value)
            }
            .width('100%')
            .constraintSize({ minWidth: 0, maxWidth: '100%' })
            .alignItems(VerticalAlign.Center)
            .padding({
              left: this.scaledSize(14),
              right: this.scaledSize(14),
              top: this.scaledSize(10),
              bottom: this.scaledSize(10)
            })
          }
          .width('100%')
          .backgroundColor(ColorHelper.hexToRgba(this.primaryColor, 0.04))
          .borderRadius(this.scaledSize(10))
          .transition(this.settingCardTransition())
        }

        // 磨砂兜底模糊强度（独立设置项卡片）：
        // - 老设备：两种样式都显示（磨砂兜底始终生效）
        // - 新设备：仅经典样式显示（玻璃样式液态玻璃接管，磨砂层关闭）
        // 切换样式时带动画收起/展开
        if (!isLiquidGlassAvailable() || this.showClassicBlurStrength) {
          Column({ space: this.scaledSize(6) }) {
            Row() {
              this.subTitleRow('Tab栏与播控条模糊强度')
              Blank()
            }
            .width('100%')

            Text('控制底部 Tab 栏与迷你播控条的磨砂模糊半径；明暗模式均生效，0 为关闭。')
              .fontSize(this.scaledFont(12))
              .fontColor(this.settingSubTextColor())
              .width('100%')
            Row({ space: this.scaledSize(12) }) {
              Text('弱')
                .fontSize(this.scaledFont(11))
                .fontColor(this.settingTextColor())
              Slider({
                value: this.settings.glassBlurStrength,
                min: 0,
                max: 100,
                step: 1,
                style: SliderStyle.OutSet
              })
                .layoutWeight(1)
                .selectedColor(this.primaryColor)
                .trackColor(ColorHelper.hexToRgba(this.primaryColor, 0.12))
                .blockColor('#FFFFFF')
                .blockSize({ width: this.scaledSize(20), height: this.scaledSize(20) })
                .blockBorderColor(this.primaryColor)
                .blockBorderWidth(3)
                .onChange((value: number, mode: SliderChangeMode) => {
                  this.settings.glassBlurStrength = value
                  this.glassBlurStrength = value
                  if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) {
                    this.updateSetting()
                  }
                })
              Text('强')
                .fontSize(this.scaledFont(11))
                .fontColor(this.settingTextColor())
            }
            .width('100%')
            .alignItems(VerticalAlign.Center)
            .padding({ top: this.scaledSize(2), bottom: this.scaledSize(2) })
          }
          .width('100%')
          .padding({
            top: this.scaledSize(10),
            left: this.scaledSize(14),
            right: this.scaledSize(14),
            bottom: this.scaledSize(10)
          })
          .backgroundColor(ColorHelper.hexToRgba(this.primaryColor, 0.04))
          .borderRadius(this.scaledSize(10))
          .transition(this.settingCardTransition())
        }

        // Tab 指示器不透明度（独立设置项卡片）
        Column({ space: this.scaledSize(6) }) {
          Row() {
            this.subTitleRow('Tab 指示器不透明度')
            Blank()
          }
          .width('100%')

          Row({ space: this.scaledSize(12) }) {
            Text('浅')
              .fontSize(this.scaledFont(11))
              .fontColor(this.settingTextColor())
            Slider({
              value: this.settings.tabIndicatorOpacity,
              min: 0,
              max: 100,
              step: 1,
              style: SliderStyle.OutSet
            })
              .layoutWeight(1)
              .selectedColor(this.primaryColor)
              .trackColor(ColorHelper.hexToRgba(this.primaryColor, 0.12))
              .blockColor('#FFFFFF')
              .blockSize({ width: this.scaledSize(20), height: this.scaledSize(20) })
              .blockBorderColor(this.primaryColor)
              .blockBorderWidth(3)
              .onChange((value: number, mode: SliderChangeMode) => {
                this.settings.tabIndicatorOpacity = value
                this.tabIndicatorOpacity = value
                if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) {
                  this.updateSetting()
                }
              })
            Text('深')
              .fontSize(this.scaledFont(11))
              .fontColor(this.settingTextColor())
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)
          .padding({ top: this.scaledSize(2), bottom: this.scaledSize(2) })
        }
        .width('100%')
        .padding({
          top: this.scaledSize(10),
          left: this.scaledSize(14),
          right: this.scaledSize(14),
          bottom: this.scaledSize(10)
        })
        .backgroundColor(ColorHelper.hexToRgba(this.primaryColor, 0.04))
        .borderRadius(this.scaledSize(10))

        // 自动反色/材质阴影/磨砂层叠加/系统组件液态玻璃等档位设置已删除：消费点固定默认开启

        // 玻璃效果生效范围：已通过一级标题右上角的小叹号引出弹窗说明
      }
      .width('100%')

    }
    .width('100%')
    .constraintSize({ minWidth: 0, maxWidth: '100%' })
  }

  @Builder
  colorPickerOverlay(): void {
    Stack({ alignContent: Alignment.Center }) {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor('rgba(0,0,0,0.45)')

      Column({ space: this.scaledSize(12) }) {
        Row() {
          Text('自定义主题色')
            .fontSize(this.scaledFont(16))
            .fontColor(this.settingTextColor())
            .fontWeight(FontWeight.Bold)
          Blank()
          Column()
            .width(this.scaledSize(34))
            .height(this.scaledSize(34))
            .borderRadius(this.scaledSize(17))
            .backgroundColor(this.currentPickerColor())
            .border({ width: 2, color: '#FFFFFF' })
        }
        .width('100%')

        Stack({ alignContent: Alignment.TopStart }) {
          Row()
            .width('100%')
            .height('100%')
            .linearGradient({
              angle: 90,
              colors: [['#FFFFFF', 0], [this.hueColor(), 1]]
            })
          Row()
            .width('100%')
            .height('100%')
            .linearGradient({
              angle: 180,
              colors: [['rgba(0,0,0,0)', 0], ['#000000', 1]]
            })
          Column()
            .width(this.scaledSize(18))
            .height(this.scaledSize(18))
            .borderRadius(this.scaledSize(9))
            .border({ width: 3, color: '#FFFFFF' })
            .shadow({ radius: 5, color: '#88000000' })
            .position({
              x: this.pickerSaturation * this.scaledSize(264) - this.scaledSize(9),
              y: (1 - this.pickerValue) * this.scaledSize(150) - this.scaledSize(9)
            })
        }
        .width(this.scaledSize(264))
        .height(this.scaledSize(150))
        .borderRadius(this.scaledSize(12))
        .clip(true)
        .gesture(
          PanGesture()
            .onActionStart((event: GestureEvent) => {
              if (event.fingerList.length > 0) {
                this.updateColorBoard(event.fingerList[0].localX, event.fingerList[0].localY)
              }
            })
            .onActionUpdate((event: GestureEvent) => {
              if (event.fingerList.length > 0) {
                this.updateColorBoard(event.fingerList[0].localX, event.fingerList[0].localY)
              }
            })
        )

        Text('色相')
          .fontSize(this.scaledFont(11))
          .fontColor(this.settingSubTextColor())
          .width('100%')
        Slider({
          value: this.pickerHue,
          min: 0,
          max: 360,
          step: 1,
          style: SliderStyle.OutSet
        })
          .width('100%')
          .selectedColor(this.hueColor())
          .trackColor(ColorHelper.hexToRgba(this.hueColor(), 0.2))
          .blockColor(this.hueColor())
          .blockBorderColor('#FFFFFF')
          .blockBorderWidth(2)
          .onChange((value: number) => {
            this.pickerHue = value
            this.updatePickerColor()
          })

        Row() {
          Text(this.currentPickerColor()
            .toUpperCase())
            .fontSize(this.scaledFont(12))
            .fontColor(this.settingTextColor())
            .fontWeight(FontWeight.Medium)
          Blank()
          Text('S ' + Math.round(this.pickerSaturation * 100) + '%  V ' +
            Math.round(this.pickerValue * 100) + '%')
            .fontSize(this.scaledFont(10))
            .fontColor(this.settingSubTextColor())
        }
        .width('100%')

        Row({ space: this.scaledSize(10) }) {
          Button('取消')
            .layoutWeight(1)
            .height(this.scaledSize(38))
            .fontColor(this.settingTextColor())
            .backgroundColor(ColorHelper.hexToRgba(this.primaryColor, 0.08))
            .onClick(() => {
              this.cancelColorPicker()
            })
          Button('确定')
            .layoutWeight(1)
            .height(this.scaledSize(38))
            .fontColor('#FFFFFF')
            .backgroundColor(this.currentPickerColor())
            .onClick(() => {
              this.confirmColorPicker()
            })
        }
        .width('100%')
      }
      .width(this.scaledSize(304))
      .padding(this.scaledSize(20))
      .borderRadius(this.scaledSize(22))
      .backgroundColor($r('app.color.page_background_other'))
      .border({ width: 1, color: ColorHelper.hexToRgba(this.primaryColor, 0.2) })
      .shadow({ radius: 28, color: '#66000000' })
    }
    .width('100%')
    .height('100%')
    .zIndex(50)
  }

  @Builder
  buildPlaybackSection(): void {
    Column({ space: 10 }) {
      Column() {
        this.toggleRow('淡入淡出', this.settings.fadeInOut, (val: boolean) => {
          this.settings.fadeInOut = val
          this.updateSetting()
          AppStorage.setOrCreate('uplayer_fade_in_out', val)
        })
      }
      .width('100%')
      .padding({ left: this.scaledSize(14), right: this.scaledSize(14) })
      .backgroundColor(ColorHelper.hexToRgba(this.primaryColor, 0.04))
      .borderRadius(this.scaledSize(10))

      Column() {
        this.toggleRow('耳机断开时继续播放', this.settings.continuePlayOnHeadsetUnplug, (val: boolean) => {
          this.settings.continuePlayOnHeadsetUnplug = val
          this.updateSetting()
        })
        Text('关闭时：拔出耳机/断开蓝牙会自动暂停播放并提示；开启时：系统默认切回扬声器继续播放')
          .fontSize(this.scaledFont(11))
          .fontColor(this.settingSubTextColor())
          .width('100%')
          .margin({ top: this.scaledSize(2) })
      }
      .width('100%')
      .padding({ left: this.scaledSize(14), right: this.scaledSize(14) })
      .backgroundColor(ColorHelper.hexToRgba(this.primaryColor, 0.04))
      .borderRadius(this.scaledSize(10))

      Column() {
        Row() {
          this.subTitleRow('播放速度')
          Blank()
        }
        .width('100%')

        Row() {
          Text(this.settings.playSpeed.toFixed(1) + 'x')
            .fontSize(this.scaledFont(12))
            .fontColor(this.settingTextColor())
        }
        .width('100%')
        .padding({ left: this.scaledSize(12), right: this.scaledSize(12), top: this.scaledSize(2) })

        Stack() {
          Slider({
            value: (this.settings.playSpeed - 0.5) * 100,
            min: 0,
            max: 250,
            step: 10,
            style: SliderStyle.OutSet
          })
            .width('100%')
            .selectedColor(this.primaryColor)
            .trackColor(ColorHelper.hexToRgba(this.primaryColor, 0.12))
            .blockColor('#FFFFFF')
            .blockSize({ width: this.scaledSize(20), height: this.scaledSize(20) })
            .blockBorderColor(this.primaryColor)
            .blockBorderWidth(3)
            .onChange((value: number, mode: SliderChangeMode) => {
              this.onSpeedChange(value, mode)
            })
        }
        .width('100%')
        .height(this.scaledSize(40))
        .padding({ left: this.scaledSize(12), right: this.scaledSize(12), bottom: this.scaledSize(8) })
      }
      .width('100%')
      .backgroundColor(ColorHelper.hexToRgba(this.primaryColor, 0.04))
      .borderRadius(this.scaledSize(10))
    }
    .width('100%')
    .constraintSize({ minWidth: 0, maxWidth: '100%' })
  }

  @Builder
  buildAudioSection(): void {
    Column({ space: 10 }) {
      Column() {
        this.toggleRow('均衡器', this.settings.eqEnabled, (val: boolean) => {
          // 面板显隐翻转必须包进统一触发动画，过渡才会播放
          this.animateSettingChange(() => {
            this.settings.eqEnabled = val
          })
          this.updateSetting()
          this.avPlayerService.applyEqualizer(val, this.settings.eqBands)
        })
      }
      .width('100%')
      .padding({ left: this.scaledSize(14), right: this.scaledSize(14) })
      .backgroundColor(ColorHelper.hexToRgba(this.primaryColor, 0.04))
      .borderRadius(this.scaledSize(10))

      if (this.settings.eqEnabled) {
        Stack({ alignContent: Alignment.Bottom }) {
          Column() {
            // 官方 9 预设一键选择：切换后滑块与曲线联动，手动拖滑块回到自定义态（无高亮）
            Scroll() {
              Row({ space: this.scaledSize(6) }) {
                ForEach(EqPresetTable.NAMES, (name: string, i: number) => {
                  Text(name)
                    .fontSize(this.scaledFont(11))
                    .fontColor(this.eqPresetActive(i) ? '#FFFFFF' : this.settingTextColor())
                    .padding({ left: this.scaledSize(10), right: this.scaledSize(10), top: this.scaledSize(4), bottom: this.scaledSize(4) })
                    .backgroundColor(this.eqPresetActive(i) ? this.primaryColor : ColorHelper.hexToRgba(this.primaryColor, 0.08))
                    .borderRadius(this.scaledSize(14))
                    .onClick(() => {
                      this.applyEqPreset(i)
                    })
                }, (name: string) => name)
              }
              .height(this.scaledSize(30))
              .alignItems(VerticalAlign.Center)
              .padding({ left: this.scaledSize(2), right: this.scaledSize(2) })
            }
            .scrollable(ScrollDirection.Horizontal)
            .scrollBar(BarState.Off)
            .edgeEffect(EdgeEffect.None)
            .align(Alignment.TopStart)
            .width('100%')
            .margin({ bottom: this.scaledSize(6) })

            Row({ space: this.scaledSize(4) }) {
              ForEach(this.eqBands, (band: EqBandInfo) => {
                Column() {
                  Text((this.settings.eqBands[band.index] >= 0 ? '+' : '') + this.settings.eqBands[band.index] + 'dB')
                    .fontSize(this.scaledFont(9))
                    .fontColor(ColorHelper.hexWithAlpha(this.primaryColor, '88'))
                    .margin({ bottom: 4 })
                }
                .width(this.scaledSize(44))
                .alignItems(HorizontalAlign.Center)
              }, (band: EqBandInfo) => band.freq)
            }
            .width('100%')
            .justifyContent(FlexAlign.Center)

            Stack({ alignContent: Alignment.Start }) {
              Canvas(this.eqCurveCtx)
                .width('100%')
                .height(this.scaledSize(180))
                .hitTestBehavior(HitTestMode.None)
                .onAreaChange((_oldVal: Area, newVal: Area) => {
                  this.eqCanvasWidth = newVal.width as number
                  this.eqCanvasHeight = newVal.height as number
                  this.drawEqCurve()
                })
                .onReady(() => {
                  this.drawEqCurve()
                })

              Row({ space: this.scaledSize(4) }) {
                ForEach(this.eqBands, (band: EqBandInfo) => {
                  Column() {
                    Slider({
                      value: this.settings.eqBands[band.index] + 10,
                      min: 0,
                      max: 20,
                      step: 1,
                      style: SliderStyle.OutSet,
                      direction: Axis.Vertical,
                      reverse: true
                    })
                      .width(this.scaledSize(40))
                      .height(this.scaledSize(180))
                      .selectedColor(this.primaryColor)
                      .trackColor(ColorHelper.hexToRgba(this.primaryColor, 0.16))
                      .blockColor('#FFFFFF')
                      .blockSize({ width: this.scaledSize(26), height: this.scaledSize(14) })
                      .blockBorderColor(this.primaryColor)
                      .blockBorderWidth(2)
                      .onChange((value: number, mode: SliderChangeMode) => {
                        this.onEqBandChange(band.index, value, mode)
                      })
                  }
                  .width(this.scaledSize(44))
                  .alignItems(HorizontalAlign.Center)
                }, (band: EqBandInfo) => band.freq)
              }
              .width('100%')
              .justifyContent(FlexAlign.Center)
            }
            .height(this.scaledSize(180))

            Row({ space: this.scaledSize(4) }) {
              ForEach(this.eqBands, (band: EqBandInfo) => {
                Column() {
                  Text(band.freq)
                    .fontSize(this.scaledFont(10))
                    .fontColor(this.settingSubTextColor())
                    .fontWeight(FontWeight.Medium)
                    .margin({ top: 6 })
                }
                .width(this.scaledSize(44))
                .alignItems(HorizontalAlign.Center)
              }, (band: EqBandInfo) => band.freq)
            }
            .width('100%')
            .justifyContent(FlexAlign.Center)
          }
          .padding({
            left: 8,
            right: 8,
            top: 12,
            bottom: 12
          })
        }
        .width('100%')
        .height(this.scaledSize(280))
        .backgroundColor(ColorHelper.hexToRgba(this.primaryColor, 0.04))
        .borderRadius(this.scaledSize(10))
        .transition(this.settingCardTransition())
      }

      // ═══ 声场 ═══
      Column() {
        this.toggleRow('声场', this.settings.soundFieldEnabled, (val: boolean) => {
          this.animateSettingChange(() => {
            this.settings.soundFieldEnabled = val
          })
          this.updateSetting()
          this.avPlayerService.applySoundField(val, this.settings.soundFieldType)
        })
        if (!this.soundFieldSupported) {
          Text('当前设备不支持声场效果')
            .fontSize(this.scaledFont(11))
            .fontColor(this.settingSubTextColor())
            .width('100%')
            .margin({ top: this.scaledSize(2) })
        }
      }
      .width('100%')
      .enabled(this.soundFieldSupported)
      .padding({ left: this.scaledSize(14), right: this.scaledSize(14) })
      .backgroundColor(ColorHelper.hexToRgba(this.primaryColor, 0.04))
      .borderRadius(this.scaledSize(10))

      if (this.settings.soundFieldEnabled && this.soundFieldSupported) {
        Column() {
          this.typeChipRow(['前置', '宏大', '聆听', '宽广'], this.settings.soundFieldType, (t: number) => {
            this.onSoundFieldTypeChange(t)
          })
        }
        .width('100%')
        .padding({ left: this.scaledSize(14), right: this.scaledSize(14) })
        .backgroundColor(ColorHelper.hexToRgba(this.primaryColor, 0.04))
        .borderRadius(this.scaledSize(10))
        .transition(this.settingCardTransition())
      }

      // ═══ 环境效果 ═══
      Column() {
        this.toggleRow('环境效果', this.settings.environmentEnabled, (val: boolean) => {
          this.animateSettingChange(() => {
            this.settings.environmentEnabled = val
          })
          this.updateSetting()
          this.avPlayerService.applyEnvironment(val, this.settings.environmentType)
        })
        if (!this.environmentSupported) {
          Text('当前设备不支持环境效果')
            .fontSize(this.scaledFont(11))
            .fontColor(this.settingSubTextColor())
            .width('100%')
            .margin({ top: this.scaledSize(2) })
        }
      }
      .width('100%')
      .enabled(this.environmentSupported)
      .padding({ left: this.scaledSize(14), right: this.scaledSize(14) })
      .backgroundColor(ColorHelper.hexToRgba(this.primaryColor, 0.04))
      .borderRadius(this.scaledSize(10))

      if (this.settings.environmentEnabled && this.environmentSupported) {
        Column() {
          this.typeChipRow(['广播', '听筒', '水下', '留声机'], this.settings.environmentType, (t: number) => {
            this.onEnvironmentTypeChange(t)
          })
        }
        .width('100%')
        .padding({ left: this.scaledSize(14), right: this.scaledSize(14) })
        .backgroundColor(ColorHelper.hexToRgba(this.primaryColor, 0.04))
        .borderRadius(this.scaledSize(10))
        .transition(this.settingCardTransition())
      }

      // ═══ 声音美化 ═══
      Column() {
        this.toggleRow('声音美化', this.settings.beautifierEnabled, (val: boolean) => {
          this.animateSettingChange(() => {
            this.settings.beautifierEnabled = val
          })
          this.updateSetting()
          this.avPlayerService.applyVoiceBeautifier(val, this.settings.beautifierType)
        })
        if (!this.beautifierSupported) {
          Text('当前设备不支持声音美化')
            .fontSize(this.scaledFont(11))
            .fontColor(this.settingSubTextColor())
            .width('100%')
            .margin({ top: this.scaledSize(2) })
        }
      }
      .width('100%')
      .enabled(this.beautifierSupported)
      .padding({ left: this.scaledSize(14), right: this.scaledSize(14) })
      .backgroundColor(ColorHelper.hexToRgba(this.primaryColor, 0.04))
      .borderRadius(this.scaledSize(10))

      if (this.settings.beautifierEnabled && this.beautifierSupported) {
        Column() {
          this.typeChipRow(['清澈', '剧场', 'CD', '录音棚'], this.settings.beautifierType, (t: number) => {
            this.onBeautifierTypeChange(t)
          })
        }
        .width('100%')
        .padding({ left: this.scaledSize(14), right: this.scaledSize(14) })
        .backgroundColor(ColorHelper.hexToRgba(this.primaryColor, 0.04))
        .borderRadius(this.scaledSize(10))
        .transition(this.settingCardTransition())
      }

      // ═══ 空间渲染 ═══
      Column() {
        this.toggleRow('空间渲染', this.settings.spaceRenderEnabled, (val: boolean) => {
          this.animateSettingChange(() => {
            this.settings.spaceRenderEnabled = val
          })
          this.updateSetting()
          this.avPlayerService.applySpaceRender(val, this.settings.spaceRenderMode, this.settings.spaceRenderValues)
        })
        if (!this.spaceRenderSupported) {
          Text('当前设备不支持空间渲染')
            .fontSize(this.scaledFont(11))
            .fontColor(this.settingSubTextColor())
            .width('100%')
            .margin({ top: this.scaledSize(2) })
        }
      }
      .width('100%')
      .enabled(this.spaceRenderSupported)
      .padding({ left: this.scaledSize(14), right: this.scaledSize(14) })
      .backgroundColor(ColorHelper.hexToRgba(this.primaryColor, 0.04))
      .borderRadius(this.scaledSize(10))

      if (this.settings.spaceRenderEnabled && this.spaceRenderSupported) {
        Column({ space: this.scaledSize(10) }) {
          this.chipRow(SpaceRenderTable.MODE_NAMES, this.settings.spaceRenderMode, (m: number) => {
            this.onSpaceModeChange(m)
          })
          if (this.settings.spaceRenderMode === 0) {
            this.spaceSliderRow('X 位置', 0, -5, 5, 0.5, ' m')
            this.spaceSliderRow('Y 位置', 1, -5, 5, 0.5, ' m')
            this.spaceSliderRow('Z 位置', 2, -5, 5, 0.5, ' m')
          } else if (this.settings.spaceRenderMode === 1) {
            this.spaceSliderRow('X 位置', 0, -5, 5, 0.5, ' m')
            this.spaceSliderRow('Y 位置', 1, -5, 5, 0.5, ' m')
            this.spaceSliderRow('Z 位置', 2, -5, 5, 0.5, ' m')
            this.spaceSliderRow('环绕时间', 3, 2, 40, 1, ' s')
            this.chipRow(['逆时针', '顺时针'], Math.round(this.spaceValue(4)), (d: number) => {
              this.onSpaceDirectionChange(d)
            })
          } else {
            this.spaceSliderRow('扩展半径', 0, 1, 5, 0.5, ' m')
            this.spaceSliderRow('扩展角度', 1, 1, 359, 1, '°')
          }
        }
        .width('100%')
        .padding({ left: this.scaledSize(14), right: this.scaledSize(14) })
        .backgroundColor(ColorHelper.hexToRgba(this.primaryColor, 0.04))
        .borderRadius(this.scaledSize(10))
        .transition(this.settingCardTransition())
      }
    }
    .width('100%')
    .constraintSize({ minWidth: 0, maxWidth: '100%' })
  }

  @Builder
  aboutInfoRow(label: string, value: string): void {
    Row() {
      Text(label)
        .fontSize(this.scaledFont(13))
        .fontColor(this.settingTextColor())
        .textAlign(TextAlign.Start)
        .flexShrink(0)
      Blank()
      Text(value)
        .fontSize(this.scaledFont(13))
        .fontColor(this.settingTextColor())
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .flexShrink(1)
        .textAlign(TextAlign.End)
    }
    .width('100%')
    .constraintSize({ minWidth: 0, maxWidth: '100%' })
    .height(this.scaledSize(40))
    .alignItems(VerticalAlign.Center)
    .padding({ left: this.scaledSize(14), right: this.scaledSize(14) })
    .backgroundColor(ColorHelper.hexToRgba(this.primaryColor, 0.04))
    .borderRadius(this.scaledSize(10))
    .onClick(() => {
      this.copyToClipboard(label, value)
    })
  }

  @Builder
  buildAboutSection(): void {
    Column({ space: this.scaledSize(10) }) {
      // 居中的软件图标 + 软件名 + 版本号
      Column({ space: this.scaledSize(8) }) {
        Image($r('app.media.foreground'))
          .width(this.scaledSize(72))
          .height(this.scaledSize(72))
          .borderRadius(this.scaledSize(20))
        Text('UPlayer')
          .fontSize(this.scaledFont(18))
          .fontColor(this.settingTextColor())
          .fontWeight(FontWeight.Bold)
        Text('v' + this.aboutVersionName)
          .fontSize(this.scaledFont(12))
          .fontColor(this.settingTextColor())
      }
      .width('100%')
      .alignItems(HorizontalAlign.Center)
      .padding({ top: this.scaledSize(24), bottom: this.scaledSize(8) })

      Column({ space: this.scaledSize(6) }) {
        Text('仓库地址')
          .fontSize(this.scaledFont(13))
          .fontColor(this.settingTextColor())
          .fontWeight(FontWeight.Bold)
          .width('100%')
          .padding({ left: this.scaledSize(4) })
        this.aboutInfoRow('仓库', this.aboutRepoUrl)
      }
      .width('100%')

      Column({ space: this.scaledSize(6) }) {
        Text('联系方式')
          .fontSize(this.scaledFont(13))
          .fontColor(this.settingTextColor())
          .fontWeight(FontWeight.Bold)
          .width('100%')
          .padding({ left: this.scaledSize(4) })
        this.aboutInfoRow('邮箱', this.aboutEmail)
        this.aboutInfoRow('QQ', this.aboutQq)
      }
      .width('100%')

      Column({ space: this.scaledSize(6) }) {
        Text('更新')
          .fontSize(this.scaledFont(13))
          .fontColor(this.settingTextColor())
          .fontWeight(FontWeight.Bold)
          .width('100%')
          .padding({ left: this.scaledSize(4) })
        this.checkUpdateRow()
      }
      .width('100%')

      Text('本地音乐播放器 · 为鸿蒙打造')
        .fontSize(this.scaledFont(11))
        .fontColor(this.settingTextColor())
        .width('100%')
        .textAlign(TextAlign.Center)
        .margin({ top: this.scaledSize(8) })
    }
    .width('100%')
    .constraintSize({ minWidth: 0, maxWidth: '100%' })
  }

  // 检查更新行：点击调用应用市场更新服务（checkAppUpdate + showUpdateDialog）
  @Builder
  checkUpdateRow(): void {
    Row() {
      Text('检查更新')
        .fontSize(this.scaledFont(13))
        .fontColor(this.settingTextColor())
        .textAlign(TextAlign.Start)
        .flexShrink(0)
      Blank()
      Text(this.checkingUpdate ? '正在检查…' : '检查新版本')
        .fontSize(this.scaledFont(13))
        .fontColor(this.checkingUpdate ? this.settingInactiveTextColor() : this.primaryColor)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .flexShrink(1)
        .textAlign(TextAlign.End)
    }
    .width('100%')
    .constraintSize({ minWidth: 0, maxWidth: '100%' })
    .height(this.scaledSize(40))
    .alignItems(VerticalAlign.Center)
    .padding({ left: this.scaledSize(14), right: this.scaledSize(14) })
    .backgroundColor(ColorHelper.hexToRgba(this.primaryColor, 0.04))
    .borderRadius(this.scaledSize(10))
    .onClick(() => {
      this.checkForUpdate()
    })
  }

  // 调用应用市场更新服务：有新版本弹系统升级框，无新版本 toast 提示
  private checkForUpdate(): void {
    if (this.checkingUpdate) {
      return
    }
    const context: common.UIAbilityContext = this.getUIContext()?.getHostContext() as common.UIAbilityContext
    this.checkingUpdate = true
    try {
      updateManager.checkAppUpdate(context)
        .then((result: updateManager.CheckUpdateResult) => {
          this.checkingUpdate = false
          if (result.updateAvailable === updateManager.UpdateAvailableCode.LATER_VERSION_EXIST) {
            updateManager.showUpdateDialog(context)
              .catch((error: BusinessError) => {
                Logger.error(TAG, 'showUpdateDialog failed: ' + error.message)
              })
          } else {
            showToastGlassMaterial(this.getUIContext()?.getPromptAction(), '当前已是最新版本')
          }
        })
        .catch((error: BusinessError) => {
          this.checkingUpdate = false
          Logger.error(TAG, 'checkAppUpdate failed: ' + error.message)
          showToastGlassMaterial(this.getUIContext()?.getPromptAction(), '检查更新失败，请稍后重试')
        })
    } catch (error) {
      this.checkingUpdate = false
      const err = error as BusinessError
      Logger.error(TAG, 'checkAppUpdate exception: ' + err.message)
      showToastGlassMaterial(this.getUIContext()?.getPromptAction(), '检查更新失败，请稍后重试')
    }

  // 效果选项芯片行：labels[i] 对应值 i+1（声场/环境/美声类型），选中高亮主题色
  @Builder
  typeChipRow(labels: string[], current: number, onPick: (value: number) => void): void {
    this.chipRow(labels, current, (v: number) => {
      onPick(v + 1)
    })
  }

  @Builder
  chipRow(labels: string[], current: number, onPick: (value: number) => void): void {
    Row({ space: this.scaledSize(6) }) {
      ForEach(labels, (label: string, i: number) => {
        Text(label)
          .fontSize(this.scaledFont(12))
          .fontColor(current === i ? '#FFFFFF' : this.settingTextColor())
          .padding({
            left: this.scaledSize(10),
            right: this.scaledSize(10),
            top: this.scaledSize(5),
            bottom: this.scaledSize(5)
          })
          .backgroundColor(current === i ? this.primaryColor : ColorHelper.hexToRgba(this.primaryColor, 0.08))
          .borderRadius(this.scaledSize(15))
          .onClick(() => {
            if (current !== i) {
              onPick(i)
            }
          })
      }, (label: string) => label)
    }
    .width('100%')
    .justifyContent(FlexAlign.Start)
  }

  // 空间渲染参数滑块行：标签 + 水平滑杆 + 当前值
  @Builder
  spaceSliderRow(label: string, index: number, min: number, max: number, step: number, unit: string): void {
    Row() {
      Text(label)
        .fontSize(this.scaledFont(12))
        .fontColor(this.settingSubTextColor())
        .width(this.scaledSize(72))
        .flexShrink(0)
      Slider({
        value: this.spaceValue(index),
        min: min,
        max: max,
        step: step,
        style: SliderStyle.OutSet
      })
        .layoutWeight(1)
        .selectedColor(this.primaryColor)
        .trackColor(ColorHelper.hexToRgba(this.primaryColor, 0.12))
        .blockColor('#FFFFFF')
        .blockSize({ width: this.scaledSize(16), height: this.scaledSize(16) })
        .blockBorderColor(this.primaryColor)
        .blockBorderWidth(2)
        .onChange((value: number, mode: SliderChangeMode) => {
          this.onSpaceValueChange(index, value, mode)
        })
      Text(this.spaceText(index) + unit)
        .fontSize(this.scaledFont(12))
        .fontColor(this.settingTextColor())
        .width(this.scaledSize(56))
        .textAlign(TextAlign.End)
        .flexShrink(0)
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  toggleRow(toggleLabel: string, isChecked: boolean, onToggleChange: (val: boolean) => void): void {
    Row() {
      Text(toggleLabel)
        .fontSize(this.scaledFont(14))
        .fontColor(this.settingTextColor())
        .fontWeight(FontWeight.Medium)
        .maxLines(1)
      Blank()
      Toggle({ type: ToggleType.Switch, isOn: isChecked })
        .selectedColor(this.primaryColor)
        .onChange((isOn: boolean) => {
          onToggleChange(isOn)
        })
    }
    .width('100%')
    .height(this.scaledSize(44))
    .alignItems(VerticalAlign.Center)
  }

  // 过渡规格：出现/消失对称的「淡入淡出 + 缩放 0.95」
  private settingCardTransition(): TransitionEffect {
    return TransitionEffect.OPACITY.combine(TransitionEffect.scale({ x: 0.95, y: 0.95 }))
  }

  // 任何驱动设置项增删的状态变化都必须包进本方法，否则过渡不会播放
  private animateSettingChange(change: () => void): void {
    this.getUIContext()?.animateTo({ curve: curves.springMotion(0.4, 0.8) }, change)
  }

  // 根据鼠标检测结果过滤选项：无鼠标/触控板设备时隐藏「白色蒙版」（镜像值翻转带统一显隐动画）
  private visibleTouchIndicatorOptions(): TouchIndicatorOption[] {
    if (this.maskChipVisible) {
      return this.touchIndicatorOptions
    }
    return [this.touchIndicatorOptions[0], this.touchIndicatorOptions[2]]
  }

  // 设备无鼠标/触控板时「白色蒙版」功能不存在，mask 值降级为 off（开关本身已隐藏）
  private effectiveTouchIndicator(): string {
    if (this.settings.tabTouchIndicator === 'mask' && !this.hasPointerDevice) {
      return 'off'
    }
    return this.settings.tabTouchIndicator
  }

  // 与首页上端 glassBlurRadius 是同一个函数、同一份取值，禁止在本文件重写公式
  private topBlurRadius(): number {
    return topBlurRadiusFromStrength(this.homeTopBlurStrength)
  }

  // 顶部标题带高度：与本页标题栏（返回按钮 + 页面标题）等高
  private titleBandHeight(): number {
    return Math.max(56, this.titleButtonHeight) + (this.isPC ? 0 : this.topSafeHeight)
  }

  // 与 Index.selectedTabContentColor 同逻辑
  private previewTabContentColor(): ResourceColor {
    return this.isDark() ? '#FFFFFF' : ColorHelper.darken(this.primaryColor, 0.35)
  }

  // 预览内点击 Tab：联动 previewTabIndex（与 Index.onChange 同一弹簧动画，保持预览与真机行为一致）
  private switchPreviewTab(index: number): void {
    this.getUIContext()?.animateTo({ curve: curves.springMotion(0.4, 0.8) }, () => {
      this.previewTabIndex = index
    })
  }

  // 玻璃标题栏：返回按钮（自带 systemMaterial，处于 Navigation 标题栏生效区内 → 出真玻璃）+ 标题。

  private getPreviewBarFloatingStyle(): HdsTabsFloatingStyle {
    const useLight: boolean = this.effectiveTouchIndicator() === 'light'
    const lightColor: ResourceColor | undefined = useLight
      ? (this.isDark() ? '#FFFFFF' : this.primaryColor)
      : undefined
    const previewBarWidth: number = 228
    // 预览器垂直居中：栏在 72vp 预览带内上下居中，边距随显示大小缩放（栏高 scaledSize(44)）
    const previewBarBottomMargin: number = (this.scaledSize(72) - this.scaledSize(44)) / 2
    if (this.settings.tabStyle === 'immersive' && isLiquidGlassAvailable()) {
      return {
        adaptToHandedness: false,
        gradientMask: { maskColor: 'rgba(0,0,0,0)', maskHeight: 0 },
        systemMaterialEffect: {
          materialType: hdsMaterial.MaterialType.IMMERSIVE,
          materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE,
        },
        barBottomMargin: previewBarBottomMargin,
        barSideMargin: 0,
        lightColor: lightColor,
        barWidth: { smallWidth: previewBarWidth, mediumWidth: previewBarWidth, largeWidth: previewBarWidth },
      } as HdsTabsFloatingStyle
    }
    return {
      adaptToHandedness: false,
      gradientMask: { maskColor: 'rgba(0,0,0,0)', maskHeight: 0 },
      barBottomMargin: previewBarBottomMargin,
      barSideMargin: 0,
      lightColor: lightColor,
      barWidth: { smallWidth: previewBarWidth, mediumWidth: previewBarWidth, largeWidth: previewBarWidth },
    } as HdsTabsFloatingStyle
  }

  // 顶部标题带：与首页上端完全同款的渐变模糊层（先正比例后恒定）+ 主题色渐变着色层，

  // 玻璃样式且设备支持液态玻璃时磨砂关闭（液态玻璃材质接管，与真机一致），radius 0 即无磨砂
  private getPreviewBarBackgroundEffect(): BackgroundEffectOptions {
    if (this.settings.tabStyle === 'immersive' && isLiquidGlassAvailable()) {
      return { radius: 0 }
    }
    return { radius: this.glassBlurStrength * 0.5 }
  }

  // 一级标题（用于把同类设置项聚合在一起，可选带右上角「问号」角标以引出说明弹窗）

  private indicatorAlpha(base: number): number {
    const opacity: number = this.tabIndicatorOpacity / 100
    return Math.round(base * opacity * 255)
  }

  private indicatorGradientColor(base: number): ResourceColor {
    return ColorHelper.hexWithAlpha(this.primaryColor, this.indicatorAlpha(base)
      .toString(16)
      .padStart(2, '0'))
  }

  // 与 Index.tabSlotWidth 同逻辑：barWidth(228vp) 均分 3 个页签
  private previewTabSlotWidth(): number {
    return this.scaledSize(228) / 3
  }

  private isDark(): boolean {
    if (this.themeMode === 'dark') {
      return true
    }
    if (this.themeMode === 'system') {
      try {
        return uiAppearance.getDarkMode() === uiAppearance.DarkMode.ALWAYS_DARK
      } catch (e) {
        return false
      }
    }
    return false
  }

  private settingTextColor(): ResourceColor {
    return this.isDark() ? '#FFFFFF' : ColorHelper.darken(this.primaryColor, 0.35)
  }

  private settingSubTextColor(): ResourceColor {
    return this.isDark() ? ColorHelper.hexWithAlpha('#FFFFFF', '88') : ColorHelper.darken(this.primaryColor, 0.3)
  }

  private settingInactiveTextColor(): ResourceColor {
    return this.isDark() ? ColorHelper.hexWithAlpha('#FFFFFF', '99') : ColorHelper.darken(this.primaryColor, 0.4)
  }

  private scaledFont(size: number): number {
    return Math.round(size * this.fontSizeScale)
  }

  private scaledSize(size: number): number {
    return Math.round(size * this.displaySizeScale)
  }

  private currentPickerColor(): string {
    return ColorHelper.hsvToHex(this.pickerHue, this.pickerSaturation, this.pickerValue)
  }

  // ═══ 关于页面：居中的软件图标 + 软件名/版本 + 仓库地址 + 联系方式，点击复制 ═══

  private hueColor(): string {
    return ColorHelper.hsvToHex(this.pickerHue, 1, 1)
  }

  private openColorPicker(): void {
    const hsv = ColorHelper.hexToHsv(this.settings.primaryColor)
    this.pickerOriginalColor = this.settings.primaryColor
    this.pickerHue = hsv.h
    this.pickerSaturation = hsv.s
    this.pickerValue = hsv.v
    this.showColorPicker = true
  }

  private updatePickerColor(): void {
    this.settings.primaryColor = this.currentPickerColor()
    this.primaryColor = this.currentPickerColor()
  }

  private cancelColorPicker(): void {
    this.settings.primaryColor = this.pickerOriginalColor
    this.primaryColor = this.pickerOriginalColor
    this.showColorPicker = false
  }

  private confirmColorPicker(): void {
    this.setPrimaryColor(this.currentPickerColor())
    this.showColorPicker = false
  }

  private updateColorBoard(localX: number, localY: number): void {
    const width: number = this.scaledSize(264)
    const height: number = this.scaledSize(150)
    this.pickerSaturation = Math.max(0, Math.min(1, localX / width))
    this.pickerValue = 1 - Math.max(0, Math.min(1, localY / height))
    this.updatePickerColor()
  }

  private drawEqCurve(): void {
    const ctx: CanvasRenderingContext2D = this.eqCurveCtx
    if (!ctx) {
      return
    }
    // 优先使用 onAreaChange 提供的 vp 尺寸，后备使用 ctx.width/ctx.height（物理像素，除以 2 估算 vp）
    const dpr: number = 2
    const canvasW: number = this.eqCanvasWidth > 0 ? this.eqCanvasWidth : ctx.width / dpr
    const canvasH: number = this.eqCanvasHeight > 0 ? this.eqCanvasHeight : ctx.height / dpr
    if (canvasW <= 0 || canvasH <= 0) {
      return
    }
    const bands: number[] = this.settings.eqBands
    const color: string = this.primaryColor
    ctx.clearRect(0, 0, ctx.width, ctx.height)
    // Canvas 与滑轨 Row 同处内层 Stack：
    // Canvas 从 x=0 到 x=canvasW 填充整个 Stack
    // 滑轨 Row 使用 width('100%') + justifyContent(Center)，内容在 Stack 中居中
    // bandW 为每个频段 Column 的宽度，Slider(40) 在 Column(44) 中居中
    const bandW: number = this.scaledSize(44)
    const bandGap: number = this.scaledSize(4)
    const sliderH: number = canvasH
    const sliderMidY: number = sliderH / 2
    const bandCount: number = bands.length
    // Row 内容总宽度 = 所有 Column 宽度 + 间距总和
    const totalRowWidth: number = bandCount * bandW + (bandCount - 1) * bandGap
    // Row 内容在 Stack 中居中，起始 x 偏移
    const rowOffset: number = Math.max(0, (canvasW - totalRowWidth) / 2)
    // 每个频段滑块的中心 x 坐标
    const bandXs: number[] = []
    for (let i = 0; i < bandCount; i++) {
      bandXs.push(rowOffset + i * (bandW + bandGap) + bandW / 2)
    }
    // 构建数据点：左端点(0 db) + 10 个频段 + 右端点(0 db)
    const points: number[] = []
    points.push(0)
    for (let i = 0; i < bandCount; i++) {
      points.push(bands[i])
    }
    points.push(0)
    // 对应的 x 坐标：左端点在第一个滑块左侧，右端点在最后一个滑块右侧
    const xs: number[] = []
    xs.push(bandXs[0] - bandW / 2)
    for (let i = 0; i < bandCount; i++) {
      xs.push(bandXs[i])
    }
    xs.push(bandXs[bandCount - 1] + bandW / 2)
    const total: number = points.length
    // db → y：+10dB → 0(顶)，-10dB → sliderH(底)，0dB → sliderMidY
    const ys: number[] = []
    for (let i = 0; i < total; i++) {
      ys.push(sliderMidY - (points[i] / 10) * (sliderH / 2))
    }
    // 逐段独立平滑曲线（分段三次 Hermite，两端切线斜率恒为 0）：
    // 每两个相邻点之间单独生成一条平滑曲线，且在点的两侧斜率均为 0，
    // 保证曲线精确穿过每个数据点，且不会因相邻点差异产生过冲。
    // 控制点取水平方向 1/3 处，即 CP1=(x0+dx/3, y0)、CP2=(x1-dx/3, y1)
    ctx.beginPath()
    ctx.moveTo(xs[0], ys[0])
    for (let i = 0; i < total - 1; i++) {
      const p0x: number = xs[i]
      const p0y: number = ys[i]
      const p1x: number = xs[i + 1]
      const p1y: number = ys[i + 1]
      const dx: number = p1x - p0x
      const cp1x: number = p0x + dx / 3
      const cp1y: number = p0y
      const cp2x: number = p1x - dx / 3
      const cp2y: number = p1y
      ctx.bezierCurveTo(cp1x, cp1y, cp2x, cp2y, p1x, p1y)
    }
    ctx.strokeStyle = color
    ctx.lineWidth = 2
    ctx.lineJoin = 'round'
    ctx.lineCap = 'round'
    ctx.stroke()
    // 曲线下方半透明填充
    ctx.lineTo(xs[total - 1], sliderH)
    ctx.lineTo(xs[0], sliderH)
    ctx.closePath()
    ctx.fillStyle = ColorHelper.hexToRgba(color, 0.1)
    ctx.fill()
  }

  private copyToClipboard(label: string, content: string): void {
    try {
      const pasteData: pasteboard.PasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, content)
      const systemPasteboard: pasteboard.SystemPasteboard = pasteboard.getSystemPasteboard()
      systemPasteboard.setDataSync(pasteData)
      showToastGlassMaterial(this.getUIContext()?.getPromptAction(), label + '已复制')
    } catch (e) {
      Logger.error(TAG, 'copyToClipboard failed: ' + JSON.stringify(e))
    }
  }
}
