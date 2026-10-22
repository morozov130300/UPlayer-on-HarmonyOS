// ArkUI 26 Beta1: 接口定义变更（误报，本项目已是Stage模型）+ UX视觉布局变更（Text默认开启沉浸式材质，系统行为）
import { curves, uiMaterial } from '@kit.ArkUI'
import { hdsMaterial, HdsTabs, HdsTabsController, HdsTabsFloatingStyle } from '@kit.UIDesignKit'
import { bundleManager, common, ConfigurationConstant } from '@kit.AbilityKit'
import { updateManager } from '@kit.AppGalleryKit'
import { AppSettingsData, DataService } from '../service/DataService'
import { SongInfo } from '../model/SongInfo'
import { AVPlayerService, EffectNodeSupport } from '../service/AVPlayerService'
import nativeAudio from 'libuplayer.so'
import { AudioFocusService } from '../service/AudioFocusService'
import { AppStorageKeyConstants } from '../common/constants/AppStorageKeyConstants'
import { ColorHelper } from '../common/utils/ColorHelper'
import Logger from '../common/utils/Logger'
import { BusinessError, deviceInfo, pasteboard, SuppressWarnings, SuppressWarningsType } from '@kit.BasicServicesKit'
import { HoldingHandService, HOLDING_HAND_CONFIRM_WINDOW_MAX_MS, HOLDING_HAND_CONFIRM_WINDOW_MIN_MS,
  HOLDING_HAND_CONFIRM_WINDOW_STEP_MS, HOLDING_HAND_SOFT_FALLBACK_MAX_MS,
  HOLDING_HAND_SOFT_FALLBACK_MIN_MS, HOLDING_HAND_SOFT_FALLBACK_STEP_MS,
  KEY_HOLDING_HAND_CONFIRM_WINDOW_MS, KEY_HOLDING_HAND_ENABLED, KEY_HOLDING_HAND_LEFT,
  KEY_HOLDING_HAND_SOFT_FALLBACK_MS } from '../service/HoldingHandService'
import { ColorConversion } from '../common/utils/ColorConversion'
import { createStyleGlassMaterial, DEFAULT_GLASS_STYLE, isLiquidGlassAvailable,
  showToastGlassMaterial, topBlurRadiusFromStrength } from '../common/utils/GlassUtil'
import { StyleConstants } from '../common/constants/StyleConstants'
import { GlassBackButton } from '../view/GlassBackButton'
import { isDarkThemeEffective } from '../common/utils/ThemeUtil'

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

// 通用变声 10 类型（引擎枚举 1-10，顺序与 OH_AudioSuite_GeneralVoiceChangeType 一致）
class GeneralVoiceChangeTable {
  static readonly NAMES: string[] = ['萝莉', '赛博朋克', '女声', '男声', '混响', '怪兽', '大叔', '合成器', '颤音', '战争']
}

// 传统变声 7 类型（引擎枚举 1-7）与性别（1=女 2=男）
class PureVoiceChangeTable {
  static readonly GENDER_NAMES: string[] = ['女声', '男声']
  static readonly TYPE_NAMES: string[] = ['卡通', '萝莉', '女声', '男声', '怪兽', '机器人', '大叔']
  // 音调滑块：0 表示系统推荐（引擎 OH_PURE_VOICE_DEFAULT_PITCH），[0.3,3.0] 为自定义
  static readonly PITCH_MIN: number = 0.3
  static readonly PITCH_MAX: number = 3.0
}

// 音源分离输出：1=仅人声 2=仅伴奏 3=混合
class SeparationTable {
  static readonly OUTPUT_NAMES: string[] = ['人声', '伴奏', '混合']
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

// 芯片行 @Builder 参数：@Builder 多参数/按值传递时内部 UI 不随状态刷新（点选后高亮不动），
// 必须合并为单对象字面量按引用传递（$$ 接收），current 直接携带状态属性读取才实时刷新
interface ChipRowOptions {
  labels: string[]
  current: number
  onPick: (value: number) => void
}

// 最常播放 Top 20 条目（P0-4）：设置页关于分组展示
class TopPlayedEntry {
  title: string = ''
  artist: string = ''
  playCount: number = 0
}

// 快捷键速查条目：keys 为按键徽标序列（如 ['Ctrl', 'A']），description 为功能说明
class ShortcutEntry {
  keys: string[] = []
  description: string = ''
}

// toggleRow 唯一入参（按引用传递：@Builder 只有单参数对象字面量传参才能随状态变量刷新）
class ToggleRowConfig {
  label: string = ''
  isOn: boolean = false
  onChange: (val: boolean) => void = (_val: boolean) => {
  }
}

// 全局快捷键速查（关于分区展示）：与 Index.handleKeyEvent / MusicPlayer.handleKeyEvent 一一对应，单列表不分组
class ShortcutTable {
  static readonly ALL: ShortcutEntry[] = [
    { keys: ['Space'], description: '播放 / 暂停' },
    { keys: ['←'], description: '上一首' },
    { keys: ['→'], description: '下一首' },
    { keys: ['←', '→'], description: '切换标签页（首页/歌单/设置）' },
    { keys: ['Ctrl', 'F'], description: '打开首页搜索并聚焦' },
    { keys: ['Ctrl', 'A'], description: '全选歌曲（首页多选态）' },
    { keys: ['Delete'], description: '删除选中歌曲（首页/歌单多选态）' },
    { keys: ['Esc'], description: '退出首页多选模式' },
    { keys: ['Esc'], description: '返回上一页' }
  ]
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
  @State pageTitle: string = ''
  // 预览器跟随系统手习惯方向（与真机 Tab 栏同配置：adaptToHandedness=true 时左右手翻转靠边）
  @StorageLink(KEY_HOLDING_HAND_LEFT) previewOnRight: boolean = false
  // 预览 HdsTabs 实际布局宽（vp）：onAreaChange 上报，驱动 barWidth 同真机公式（宽×0.4）
  @State previewBarWidthVp: number = 0
  // Tab 栏实时预览：直接使用 HdsTabs 系统组件，与 Index 完全一致的渲染管线
  @State previewTabIndex: number = 0
  @State showColorPicker: boolean = false
  @State showGlassScope: boolean = false
  @State showShortcutSheet: boolean = false
  // 自动音量均衡说明弹窗
  @State showReplayGainHelp: boolean = false
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
  @State generalVoiceChangeSupported: boolean = false
  @State noiseReductionSupported: boolean = false
  @State pureVoiceChangeSupported: boolean = false
  @State tempoPitchSupported: boolean = false
  @State separationSupported: boolean = false
  // 音效节点能力是否已探测（只在「音效」分区按需探测一次，见 probeEffectNodeSupport）
  private effectSupportProbed: boolean = false
  // 系统空间音频只读状态（AudioSpatializationManager 无 setter，开关由系统设置控制）
  @StorageProp(AppStorageKeyConstants.KEY_SPATIALIZATION_SUPPORTED) spatializationSupported: boolean = false
  @StorageProp(AppStorageKeyConstants.KEY_SPATIALIZATION_ENABLED) spatializationEnabled: boolean = false
  // 低功耗播放：设备是否支持 OH_LowPowerAudioSink 链路（进入「播放」分区时探测一次）
  @State lowPowerSupported: boolean = true
  // 艺术家分隔符自定义输入框内容（「播放」分区「艺术家分隔符」卡片）
  @State artistSepInput: string = ''
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
  // 跟手光效颜色选项：无（=关）/ 白光 / 主题色
  private lightColorOptions: TouchIndicatorOption[] = [
    { label: '无', value: 'none' },
    { label: '白光', value: 'white' },
    { label: '主题色', value: 'theme' }
  ]
  // Tab 栏材质等级选项（玻璃样式）：→ hdsMaterial.MaterialLevel
  private materialLevelOptions: TouchIndicatorOption[] = [
    { label: '自适应', value: 'adaptive' },
    { label: '精美', value: 'exquisite' },
    { label: '轻柔', value: 'gentle' },
    { label: '流畅', value: 'smooth' }
  ]
  // 艺术家分隔符预置候选（「播放」分区多选）：首页筛选下拉列表按这些符号拆分多艺人串
  private artistSeparatorOptions: string[] = [',', '，', '&', '＆', ';', '；', '、', '/']
  // ═══ 设置项显隐统一动画（所有条件显隐的设置卡片/选项必须完全一致，禁止各自定义）═══
  private colorOptions: ThemeColorOption[] = [
    { name: '鸿蒙蓝', value: '#007DFF' },
    { name: '绯霞红', value: StyleConstants.COLOR_DANGER_RED },
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

  aboutToAppear(): void {
    this.settings = this.dataService.getSettings()
    // 声明处初始值读取的是默认 AppSettingsData（tabStyle 恒为 classic），并非已保存设置；
    // 必须在加载真实设置后重算磨砂强度滑块可见性，否则新设备 + 玻璃样式进页时滑块会错误显示
    this.showClassicBlurStrength = !isLiquidGlassAvailable() || this.settings.tabStyle !== 'immersive'
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
    // 设备音效节点能力探测已移出共享打开路径：它是 9 次同步 native 系统 IPC，
    // 只有「音效」分区消费，却会让定制/播放/关于 也付出同样代价。改为进入音效分区时按需探测一次。
    if (this.pageTitle === '音效') {
      this.probeEffectNodeSupport()
    }
    // 低功耗链路能力探测：「播放」分区消费，其余分区不付出 native IPC 代价
    if (this.pageTitle === '播放') {
      this.lowPowerSupported = nativeAudio.isLowPowerSupported()
    }
  }

  // 设备音效节点能力探测（按需、一次）：结果写入 9 个 @State 驱动对应卡片开关的禁用与提示。
  // probeEffectNodeSupport 只在「音效」分区调用，其余分区完全不触碰 native。
  private probeEffectNodeSupport(): void {
    if (this.effectSupportProbed) {
      return
    }
    this.effectSupportProbed = true
    const support: EffectNodeSupport = this.avPlayerService.ensureEffectNodeSupport()
    this.soundFieldSupported = support.soundField
    this.environmentSupported = support.environment
    this.beautifierSupported = support.beautifier
    this.spaceRenderSupported = support.spaceRender
    this.generalVoiceChangeSupported = support.generalVoiceChange
    this.noiseReductionSupported = support.noiseReduction
    this.pureVoiceChangeSupported = support.pureVoiceChange
    this.tempoPitchSupported = support.tempoPitch
    this.separationSupported = support.separation
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
      // 与真机同参：Index.barWidth 恒传 scaledSize(228)；小屏（<600vp）下系统收折成胶囊默认宽
      .barWidth(this.scaledSize(228))
      .scrollable(true)
      .barBackgroundColor(Color.Transparent)
      .barFloatingStyle(this.getPreviewBarFloatingStyle())
      // 磨砂档位与真机 Tab 栏同机制（barBackgroundBlurStyle 离散档位，阈值同 Index.getBarBackgroundBlur）：
      //   0=NONE / ≤30=Thin / ≤50=Regular / 其他=Thick，滑杆拖动跨阈值时档位跳变，观感与真机一致
      // 玻璃模式：barFloatingStyle 含 systemMaterialEffect（液态玻璃）→ 磨砂关闭（NONE，与真机一致）
      .barBackgroundBlurStyle((this.settings.tabStyle !== 'immersive' || !isLiquidGlassAvailable())
        ? this.getPreviewBarBackgroundBlur() : BlurStyle.NONE)
      .animationDuration(StyleConstants.ANIMATION_SWIPER_DURATION)
      .onChange((index: number) => {
        this.switchPreviewTab(index)
      })
      .width('100%')
      .height(this.scaledSize(100))
      .onAreaChange((_oldArea: Area, newArea: Area) => {
        // 与真机同公式：barWidth = 主容器宽 × 宽度占比%（≥600vp 才下发，小屏交给系统胶囊默认值）
        const w: number = newArea.width as number
        if (w > 0 && w !== this.previewBarWidthVp) {
          this.previewBarWidthVp = w
        }
      })
    }
    .width('100%')
    .height(this.scaledSize(100))
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
    .height(this.scaledSize(100))
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

  // immediate=true 立即落盘（离散操作）；false 走惰性 flush（拖动逐帧调用，避免每帧写盘卡顿）
  updateSetting(immediate: boolean = true): void {
    this.dataService.saveSettings(this.settings, immediate)
  }

  // 滑轨是否已松手（松手帧才需要立即落盘）
  private isSliderSettled(mode: SliderChangeMode): boolean {
    return mode === SliderChangeMode.End || mode === SliderChangeMode.Click
  }

  // 艺术家分隔符展示名：预置候选的字符 + 中文名
  private artistSeparatorLabel(sep: string): string {
    if (sep === ',') {
      return '英文逗号 ,'
    }
    if (sep === '，') {
      return '中文逗号 ，'
    }
    if (sep === '&') {
      return '和号 &'
    }
    if (sep === '＆') {
      return '全角和号 ＆'
    }
    if (sep === ';') {
      return '分号 ;'
    }
    if (sep === '；') {
      return '全角分号 ；'
    }
    if (sep === '、') {
      return '顿号 、'
    }
    return '斜杠 /'
  }

  // 已启用的自定义分隔符：artistSeparators 中不在预置候选里的字符
  private customArtistSeparators(): string[] {
    const out: string[] = []
    const seps: string[] = this.settings.artistSeparators
    for (let i = 0; i < seps.length; i++) {
      if (this.artistSeparatorOptions.indexOf(seps[i]) < 0) {
        out.push(seps[i])
      }
    }
    return out
  }

  // 统一写入艺术家分隔符：换数组引用 + 整体重赋 settings 触发芯片刷新；
  // 保存后经 saveSettings 推送 KEY_ARTIST_SEPARATORS，首页 @Watch 自动重筛
  private setArtistSeparators(next: string[]): void {
    this.settings.artistSeparators = next
    this.settings = this.settings
    this.updateSetting()
  }

  toggleArtistSeparator(sep: string): void {
    const next: string[] = this.settings.artistSeparators.slice()
    const idx: number = next.indexOf(sep)
    if (idx >= 0) {
      next.splice(idx, 1)
    } else {
      next.push(sep)
    }
    this.setArtistSeparators(next)
  }

  removeArtistSeparator(sep: string): void {
    const next: string[] = this.settings.artistSeparators.slice()
    const idx: number = next.indexOf(sep)
    if (idx >= 0) {
      next.splice(idx, 1)
      this.setArtistSeparators(next)
    }
  }

  // 自定义输入按字符逐个添加：每个字符都是独立分隔符；空白字符跳过（会误拆含空格的
  // 艺人名），已存在（含预置候选已启用的字符）不重复添加
  addCustomArtistSeparators(): void {
    const raw: string = this.artistSepInput
    const next: string[] = this.settings.artistSeparators.slice()
    let added: boolean = false
    for (let i = 0; i < raw.length; i++) {
      const ch: string = raw.charAt(i)
      if (ch.trim().length === 0) {
        continue
      }
      if (next.indexOf(ch) < 0) {
        next.push(ch)
        added = true
      }
    }
    this.artistSepInput = ''
    if (added) {
      this.setArtistSeparators(next)
    }
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
    // 先广播到 AppStorage：底部 Tab 栏/多选栏/弹窗材质的消费方都是 @StorageLink，
    // 先写键再落盘，切换当天立即重绘，不必等 saveSettings（之前顺序反了，切换有一帧滞后）
    AppStorage.setOrCreate('uplayer_tab_style', style)
    // 切换样式时同步更新与样式挂钩的设置项可见性（磨砂强度卡片/底部栏触摸指示行）：
    // 新设备上玻璃样式不需要磨砂兜底（液态玻璃接管），经典样式需要；老设备两种样式都用磨砂兜底，始终显示。
    // 可见性翻转必须与样式切换同处一个统一触发动画，卡片显隐过渡才会播放
    this.animateSettingChange(() => {
      if (isLiquidGlassAvailable()) {
        this.showClassicBlurStrength = style === 'classic'
      }
      this.settings.tabStyle = style
    })
    this.updateSetting()
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
    this.updateSetting(this.isSliderSettled(mode))
    try {
      this.avPlayerService.setSpeed(this.settings.playSpeed)
    } catch (e) {
      Logger.error(TAG, 'setSpeed failed: ' + JSON.stringify(e))
    }
  }

  // 定时停止淡出时长（P0-1）：拖动实时写 AppStorage（saveSettings 内联动推送），
  // AVPlayerService 触发定时停止时读取；松手帧才立即落盘
  onTimerFadeSecondsChange(value: number, mode: SliderChangeMode): void {
    this.settings.timerFadeSeconds = Math.round(value)
    this.updateSetting(this.isSliderSettled(mode))
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
    this.updateSetting(this.isSliderSettled(mode))
  }

  // ═══ 均衡器预设（官方 9 预设一键切换，手动拖滑块后自动回到自定义态无高亮）═══
  private eqPresetCacheBands: number[] | undefined = undefined
  private eqPresetCacheIndex: number = -1

  // 命中的预设下标（-1 为自定义态）：按 eqBands 引用缓存，避免渲染期对每个预设逐帧全量比较
  private eqActivePresetIndex(): number {
    const current: number[] = this.settings.eqBands
    if (this.eqPresetCacheBands !== current) {
      this.eqPresetCacheBands = current
      this.eqPresetCacheIndex = -1
      for (let presetIndex = 0; presetIndex < EqPresetTable.NAMES.length; presetIndex++) {
        if (this.eqPresetMatches(EqPresetTable.GAINS[presetIndex], current)) {
          this.eqPresetCacheIndex = presetIndex
          break
        }
      }
    }
    return this.eqPresetCacheIndex
  }

  private eqPresetMatches(preset: number[], current: number[]): boolean {
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

  private eqPresetActive(index: number): boolean {
    return this.eqActivePresetIndex() === index
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
    this.updateSetting(this.isSliderSettled(mode))
    this.avPlayerService.applySpaceRender(this.settings.spaceRenderEnabled, this.settings.spaceRenderMode, values)
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

  // ═══ 通用变声 / 降噪 / 传统变声 / 变速变调 / 音源分离 ═══
  onGeneralVoiceTypeChange(type: number): void {
    this.animateSettingChange(() => {
      this.settings.generalVoiceChangeType = type
      this.settings = this.settings
    })
    this.updateSetting()
    this.avPlayerService.applyGeneralVoiceChange(this.settings.generalVoiceChangeEnabled, type)
  }

  onPureVoiceGenderChange(gender: number): void {
    this.animateSettingChange(() => {
      this.settings.pureVoiceChangeGender = gender
      this.settings = this.settings
    })
    this.updateSetting()
    this.avPlayerService.applyPureVoiceChange(this.settings.pureVoiceChangeEnabled, gender,
      this.settings.pureVoiceChangeType, this.settings.pureVoiceChangePitch)
  }

  onPureVoiceTypeChange(type: number): void {
    this.animateSettingChange(() => {
      this.settings.pureVoiceChangeType = type
      this.settings = this.settings
    })
    this.updateSetting()
    this.avPlayerService.applyPureVoiceChange(this.settings.pureVoiceChangeEnabled,
      this.settings.pureVoiceChangeGender, type, this.settings.pureVoiceChangePitch)
  }

  onPureVoicePitchChange(value: number, mode: SliderChangeMode): void {
    // 0 表示系统推荐音调（引擎默认值），其余为 [0.3,3.0] 自定义
    this.settings.pureVoiceChangePitch = value
    this.settings = this.settings
    this.updateSetting(this.isSliderSettled(mode))
    this.avPlayerService.applyPureVoiceChange(this.settings.pureVoiceChangeEnabled,
      this.settings.pureVoiceChangeGender, this.settings.pureVoiceChangeType, value)
  }

  onTempoSpeedChange(value: number, mode: SliderChangeMode): void {
    this.settings.tempoSpeed = value
    this.settings = this.settings
    this.updateSetting(this.isSliderSettled(mode))
    this.avPlayerService.applyTempoPitch(this.settings.tempoPitchEnabled, value, this.settings.tempoPitch)
  }

  onTempoPitchChange(value: number, mode: SliderChangeMode): void {
    this.settings.tempoPitch = value
    this.settings = this.settings
    this.updateSetting(this.isSliderSettled(mode))
    this.avPlayerService.applyTempoPitch(this.settings.tempoPitchEnabled, this.settings.tempoSpeed, value)
  }

  // 自动音量均衡（P2-1）：0=off 1=track 2=album（chipRow 选中下标）
  replayGainModeIndex(): number {
    if (this.settings.replayGainMode === 'track') {
      return 1
    }
    return this.settings.replayGainMode === 'album' ? 2 : 0
  }

  onReplayGainModeChange(index: number): void {
    const mode: string = index === 1 ? 'track' : (index === 2 ? 'album' : 'off')
    this.animateSettingChange(() => {
      this.settings.replayGainMode = mode
      this.settings = this.settings
    })
    this.updateSetting()
    this.avPlayerService.applyReplayGainSettings()
  }

  onReplayGainPreGainChange(value: number, mode: SliderChangeMode): void {
    const clamped: number = Math.max(-12, Math.min(12, Math.round(value)))
    this.settings.replayGainPreGainDb = clamped
    this.settings = this.settings
    this.updateSetting(this.isSliderSettled(mode))
    this.avPlayerService.applyReplayGainSettings()
  }

  onSeparationOutputChange(output: number): void {
    this.animateSettingChange(() => {
      this.settings.separationOutput = output
      this.settings = this.settings
    })
    this.updateSetting()
    this.avPlayerService.applySeparation(this.settings.separationEnabled, output)
  }

  private pureVoicePitchText(): string {
    const pitch: number = this.settings.pureVoiceChangePitch
    return pitch <= 0 ? '系统推荐' : pitch.toFixed(1) + 'x'
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
      detents: [SheetSize.MEDIUM],
      dragBar: false,
      title: this.glassScopeSheetTitle(),
      showClose: true,
      preferType: SheetType.CENTER,
      systemMaterial: this.styleGlassMaterial()
    })
    .bindSheet($$this.showShortcutSheet, this.shortcutSheetBuilder(), {
      detents: [SheetSize.MEDIUM],
      dragBar: false,
      title: this.shortcutSheetTitle(),
      showClose: true,
      preferType: SheetType.CENTER,
      systemMaterial: this.styleGlassMaterial()
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

  @Builder
  groupTitle(title: string): void {
    Text(title)
      .fontSize(this.scaledFont(11))
      .fontColor(this.settingTextColor())
      .fontWeight(FontWeight.Bold)
      .width('100%')
      .padding({ left: this.scaledSize(8), top: this.scaledSize(1), bottom: this.scaledSize(4) })
  }

  // 玻璃效果范围说明问号按钮：点击弹出半模态说明
  @Builder
  glassHelpIcon(): void {
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

  // 行内二级标题（用于 Row 内，不带 width 约束，避免溢出）
  @Builder
  subTitleRow(title: string): void {
    Text(title)
      .fontSize(this.scaledFont(14))
      .fontColor(this.settingTextColor())
      .fontWeight(FontWeight.Medium)
      .padding({ right: this.scaledSize(4) })
  }

  // 组件风格（tabStyle）驱动的弹窗与选择类组件材质（bindSheet options 的 systemMaterial
  // 字段、Toggle/Slider 通用属性）：玻璃风格 → 液态玻璃；经典风格 → Material.empty
  // 显式关闭（undefined 只会恢复系统默认，关不干净）；设备不支持 → undefined
  private styleGlassMaterial(): uiMaterial.Material | undefined {
    return createStyleGlassMaterial(this.settings.tabStyle, DEFAULT_GLASS_STYLE)
  }

  // 玻璃效果生效范围说明弹窗标题（bindSheet 官方标题栏）
  @Builder
  glassScopeSheetTitle(): void {
    Text('玻璃效果生效范围')
      .fontSize(this.scaledFont(20))
      .fontColor($r('app.color.text_primary'))
      .fontWeight(FontWeight.Bold)
      .maxLines(1)
      .width('100%')
  }

  // 玻璃效果生效范围说明弹窗（bindSheet 半模态内容）：标题移入官方标题栏，正文可滚、按钮固定底部
  @Builder
  glassScopeSheetBuilder(): void {
    Column({ space: this.scaledSize(10) }) {
      Scroll() {
        Column({ space: this.scaledSize(10) }) {
          Text('以下位置会使用玻璃效果：')
            .fontSize(this.scaledFont(12))
            .fontColor(this.settingSubTextColor())
            .width('100%')
            .padding({ top: this.scaledSize(2) })
          this.scopeLine('• 底部 Tab 栏：玻璃样式下挂液态玻璃（跟手光效由「跟手光效颜色」决定，设为「无」即关闭）；经典样式为磨砂，强度随「Tab栏与播控条模糊强度」')
          this.scopeLine('• 右下角播控条：大屏上玻璃样式生效（与底部 Tab 栏一致），小屏上为磨砂效果')
          this.scopeLine('• 首页上端与设置详情页顶部的渐变模糊层（随「首页上端模糊强度」设置变化）')
          this.scopeLine('• 首页长按歌曲进入多选后的顶部菜单栏：玻璃样式下液态玻璃叠加磨砂兜底，经典样式不挂背景效果')
          this.scopeLine('• 各页面左上角圆形返回按钮（设置详情、播放器等页面；玻璃样式出真玻璃，经典样式为磨砂兜底）')
          this.scopeLine('• 全局悬浮加号按钮（磨砂玻璃盘）')
          this.scopeLine(
            '• 操作时屏幕底部短暂弹出的文字提示浮层（如切换播放模式时的"随机播放"）——设备支持液态玻璃时固定使用液态玻璃材质')
          this.scopeLine('• 半模态弹窗与气泡（播放列表、更多面板、倍速/音量气泡、本说明弹窗等）：玻璃样式下使用液态玻璃，经典样式恢复常规背景')
          this.scopeLine('• 设置页的开关与滑块：玻璃样式下跟随液态玻璃，经典样式恢复主题色自定义样式')

          Text('以下位置不使用玻璃效果：')
            .fontSize(this.scaledFont(12))
            .fontColor(this.settingSubTextColor())
            .width('100%')
            .padding({ top: this.scaledSize(6) })
          this.scopeLine('• 首页 / 歌单 / 设置 / 设置详情 页面的顶层背景（均使用预设纯色背景，明暗自适应）')
          this.scopeLine('• 音乐播放器页面背景（仅左上角返回按钮使用玻璃）')
          this.scopeLine('• 系统 API < 26 或未声明支持沉浸式材质的设备（液态玻璃自动降级为磨砂模糊）')

        }
        .width('100%')
      }
      .layoutWeight(1)
      .width('100%')
      .align(Alignment.Top)
      .edgeEffect(EdgeEffect.Spring)

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
    .height('100%')
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

  // 自动音量均衡说明弹窗（bindSheet 半模态内容）
  @Builder
  replayGainHelpSheetBuilder(): void {
    Column({ space: this.scaledSize(10) }) {
      Text('自动音量均衡')
        .fontSize(this.scaledFont(16))
        .fontColor(this.settingTextColor())
        .fontWeight(FontWeight.Bold)
        .width('100%')
        .textAlign(TextAlign.Start)

      Text('按歌曲内嵌 ReplayGain 标签在播放时统一响度，不修改文件本身。')
        .fontSize(this.scaledFont(12))
        .fontColor(this.settingSubTextColor())
        .width('100%')
        .padding({ top: this.scaledSize(2) })
      this.scopeLine('• 均衡关：不处理，保持原始音量')
      this.scopeLine('• 按曲目：每首歌用自己的增益，逐首拉平')
      this.scopeLine('• 按专辑：同专辑共用一个增益，保留专辑内强弱起伏；缺专辑标签时按曲目处理')
      this.scopeLine('• 预增益：在标签增益上整体叠加，正数更响、负数更轻')
      this.scopeLine('• 增益切换与换曲逐采样平滑，无爆音；增益过大时软限幅防削波')
      this.scopeLine('• 仅 MP3（ID3v2）/ FLAC 标签有效，其他格式与无标签歌曲不调整；设了非 0 预增益时仍会整体加减')

      Row() {
        Button('知道了')
          .layoutWeight(1)
          .height(this.scaledSize(30))
          .fontColor('#FFFFFF')
          .backgroundColor(this.primaryColor)
          .borderRadius(this.scaledSize(15))
          .onClick(() => {
            this.showReplayGainHelp = false
          })
      }
      .width('100%')
      .padding({ top: this.scaledSize(8), bottom: this.scaledSize(10) })
    }
    .width('100%')
    .padding({ left: this.scaledSize(20), right: this.scaledSize(20), top: this.scaledSize(14) })
  }

  @Builder
  buildCustomizeSection(): void {
    Column({ space: this.scaledSize(10) }) {
      Row() {
        this.groupTitle('全局')
      }

      Column() {
        this.toggleRow({
          label: '向下滑动时隐藏加号按钮',
          isOn: this.settings.plusButtonScrollHide,
          onChange: (val: boolean) => {
            this.settings.plusButtonScrollHide = val
            this.updateSetting()
          }
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
            .systemMaterial(this.styleGlassMaterial())
            .alignSelf(ItemAlign.Center)
            .margin({ left: this.scaledSize(10) })
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

        // 灵敏度滑轨：仅在握姿开关开启时显示
        if (this.settings.holdingHandEnabled) {
          Column({ space: this.scaledSize(6) }) {
            Row() {
              this.subTitleRow('切换确认窗')
              Blank()
              Text(`${this.settings.holdingHandConfirmWindowMs} ms`)
                .fontSize(this.scaledFont(12))
                .fontColor(this.primaryColor)
                .fontWeight(FontWeight.Medium)
            }
            .width('100%')

            Text('握姿切换滤波的确认时间：检测到换手后需持续该时长无回摆才真正切边。值越小换手贴边越快，但越易被瞬时误报带偏；值越大越稳，但换手响应越慢。')
              .fontSize(this.scaledFont(12))
              .fontColor(this.settingSubTextColor())
              .width('100%')

            Row({ space: this.scaledSize(8) }) {
              Text('快')
                .fontSize(this.scaledFont(11))
                .fontColor(this.settingTextColor())
                .margin({ right: this.scaledSize(4) })
              Slider({
                value: this.settings.holdingHandConfirmWindowMs,
                min: HOLDING_HAND_CONFIRM_WINDOW_MIN_MS,
                max: HOLDING_HAND_CONFIRM_WINDOW_MAX_MS,
                step: HOLDING_HAND_CONFIRM_WINDOW_STEP_MS,
                style: SliderStyle.OutSet
              })
                .layoutWeight(1)
                .selectedColor(this.primaryColor)
                .trackColor(ColorHelper.hexToRgba(this.primaryColor, 0.12))
                .blockColor('#FFFFFF')
                .blockSize({ width: this.scaledSize(20), height: this.scaledSize(20) })
                .blockBorderColor(this.primaryColor)
                .blockBorderWidth(3)
                .sliderInteractionMode(SliderInteraction.SLIDE_AND_CLICK)
                .systemMaterial(this.styleGlassMaterial())
                .onChange((value: number, mode: SliderChangeMode) => {
                  this.settings.holdingHandConfirmWindowMs = value
                  AppStorage.setOrCreate(KEY_HOLDING_HAND_CONFIRM_WINDOW_MS, value)
                  this.updateSetting(this.isSliderSettled(mode))
                })
              Text('稳')
                .fontSize(this.scaledFont(11))
                .fontColor(this.settingTextColor())
                .margin({ left: this.scaledSize(4) })
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
          .transition(this.settingCardTransition())

          Column({ space: this.scaledSize(6) }) {
            Row() {
              this.subTitleRow('不确定回落窗')
              Blank()
              Text(`${this.settings.holdingHandSoftFallbackMs} ms`)
                .fontSize(this.scaledFont(12))
                .fontColor(this.primaryColor)
                .fontWeight(FontWeight.Medium)
            }
            .width('100%')

            Text('不确定状态（未握持/双手/未识别）的回落时间：已贴左后握姿变模糊，持续该时长无左手复确认才回落默认右侧。值越小回退越快；值越大对短暂识别抖动越不敏感。')
              .fontSize(this.scaledFont(12))
              .fontColor(this.settingSubTextColor())
              .width('100%')

            Row({ space: this.scaledSize(8) }) {
              Text('快')
                .fontSize(this.scaledFont(11))
                .fontColor(this.settingTextColor())
                .margin({ right: this.scaledSize(4) })
              Slider({
                value: this.settings.holdingHandSoftFallbackMs,
                min: HOLDING_HAND_SOFT_FALLBACK_MIN_MS,
                max: HOLDING_HAND_SOFT_FALLBACK_MAX_MS,
                step: HOLDING_HAND_SOFT_FALLBACK_STEP_MS,
                style: SliderStyle.OutSet
              })
                .layoutWeight(1)
                .selectedColor(this.primaryColor)
                .trackColor(ColorHelper.hexToRgba(this.primaryColor, 0.12))
                .blockColor('#FFFFFF')
                .blockSize({ width: this.scaledSize(20), height: this.scaledSize(20) })
                .blockBorderColor(this.primaryColor)
                .blockBorderWidth(3)
                .sliderInteractionMode(SliderInteraction.SLIDE_AND_CLICK)
                .systemMaterial(this.styleGlassMaterial())
                .onChange((value: number, mode: SliderChangeMode) => {
                  this.settings.holdingHandSoftFallbackMs = value
                  AppStorage.setOrCreate(KEY_HOLDING_HAND_SOFT_FALLBACK_MS, value)
                  this.updateSetting(this.isSliderSettled(mode))
                })
              Text('钝')
                .fontSize(this.scaledFont(11))
                .fontColor(this.settingTextColor())
                .margin({ left: this.scaledSize(4) })
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
          .transition(this.settingCardTransition())
        }
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
              .sliderInteractionMode(SliderInteraction.SLIDE_AND_CLICK)
              .systemMaterial(this.styleGlassMaterial())
              .onChange((value: number, mode: SliderChangeMode) => {
                this.settings.homeTopBlurStrength = value
                this.homeTopBlurStrength = value
                this.updateSetting(this.isSliderSettled(mode))
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
              .sliderInteractionMode(SliderInteraction.SLIDE_AND_CLICK)
              .systemMaterial(this.styleGlassMaterial())
              .onChange((value: number, mode: SliderChangeMode) => {
                this.settings.fontSizeScale = value / 100
                this.fontSizeScale = this.settings.fontSizeScale
                this.updateSetting(this.isSliderSettled(mode))
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
              .sliderInteractionMode(SliderInteraction.SLIDE_AND_CLICK)
              .systemMaterial(this.styleGlassMaterial())
              .onChange((value: number, mode: SliderChangeMode) => {
                this.settings.displaySizeScale = value / 100
                this.displaySizeScale = this.settings.displaySizeScale
                this.updateSetting(this.isSliderSettled(mode))
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

      // ─── 一级标题「高级样式」 ───
      Column({ space: this.scaledSize(10) }) {
        this.groupTitle('高级样式')
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
            this.glassHelpIcon()
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

        // 跟手光效颜色：无（=关）/ 白光 / 主题色。仅玻璃样式时显示；
        // 选「无」即关闭跟手光效，不再单设开关。tabTouchIndicator 由颜色派生（off/light），
        // 供 GlassBackButton/HomeContent 联动消费
        if (isLiquidGlassAvailable() && this.settings.tabStyle === 'immersive') {
          Column() {
            Row() {
              this.subTitleRow('跟手光效颜色')
              Blank()
              ForEach(this.lightColorOptions, (opt: TouchIndicatorOption) => {
                Column() {
                  Text(opt.label)
                    .fontSize(this.scaledFont(11))
                    .fontColor(this.settings.tabLightColor === opt.value
                      ? '#FFFFFF' : this.settingInactiveTextColor())
                }
                .padding({
                  left: this.scaledSize(10),
                  right: this.scaledSize(10),
                  top: this.scaledSize(5),
                  bottom: this.scaledSize(5)
                })
                .backgroundColor(this.settings.tabLightColor === opt.value
                  ? this.primaryColor : ColorHelper.hexToRgba(this.primaryColor, 0.08))
                .borderRadius(this.scaledSize(14))
                .animation({ duration: 200, curve: Curve.EaseInOut })
                .onClick(() => {
                  this.animateSettingChange(() => {
                    this.settings.tabLightColor = opt.value
                    this.settings.tabTouchIndicator = opt.value === 'none' ? 'off' : 'light'
                  })
                  this.updateSetting()
                  AppStorage.setOrCreate('uplayer_tab_light_color', opt.value)
                  AppStorage.setOrCreate('uplayer_tab_touch_indicator', this.settings.tabTouchIndicator)
                })
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

        // Tab 栏材质等级（玻璃样式专属）：控制页签栏液态玻璃的渲染档位
        // （hdsMaterial.MaterialLevel：自适应/精美/轻柔/流畅），实时下发 barFloatingStyle
        if (isLiquidGlassAvailable() && this.settings.tabStyle === 'immersive') {
          Column() {
            Row() {
              this.subTitleRow('材质等级')
              Blank()
              ForEach(this.materialLevelOptions, (opt: TouchIndicatorOption) => {
                Column() {
                  Text(opt.label)
                    .fontSize(this.scaledFont(11))
                    .fontColor(this.settings.tabMaterialLevel === opt.value
                      ? '#FFFFFF' : this.settingInactiveTextColor())
                }
                .padding({
                  left: this.scaledSize(10),
                  right: this.scaledSize(10),
                  top: this.scaledSize(5),
                  bottom: this.scaledSize(5)
                })
                .backgroundColor(this.settings.tabMaterialLevel === opt.value
                  ? this.primaryColor : ColorHelper.hexToRgba(this.primaryColor, 0.08))
                .borderRadius(this.scaledSize(14))
                .animation({ duration: 200, curve: Curve.EaseInOut })
                .onClick(() => {
                  this.settings.tabMaterialLevel = opt.value
                  this.updateSetting()
                })
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

        // 播控条底部间距已删除（布局参数写死 28，不再暴露：布局不动，只调样式）

        // Tab 栏不透明度设置已删除（Tab 栏恒完全不透明，barOpacity 写死 1）

        // 底部渐变遮罩与温控降级设置已删除（gradientMask 恒禁用、thermoCtrl 不下发走 SDK 默认 false）

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

            Text('控制底部 Tab 栏与迷你播控条的磨砂档位；明暗模式均生效。')
              .fontSize(this.scaledFont(12))
              .fontColor(this.settingSubTextColor())
              .width('100%')
            Row({ space: this.scaledSize(12) }) {
              Text('弱')
                .fontSize(this.scaledFont(11))
                .fontColor(this.settingTextColor())
              Slider({
                value: this.sliderBlurValue(),
                min: 0,
                max: 60,
                step: 20,
                style: SliderStyle.OutSet
              })
                .layoutWeight(1)
                .selectedColor(this.primaryColor)
                .trackColor(ColorHelper.hexToRgba(this.primaryColor, 0.12))
                .blockColor('#FFFFFF')
                .blockSize({ width: this.scaledSize(20), height: this.scaledSize(20) })
                .blockBorderColor(this.primaryColor)
                .blockBorderWidth(3)
                .sliderInteractionMode(SliderInteraction.SLIDE_AND_CLICK)
                .systemMaterial(this.styleGlassMaterial())
                .onChange((value: number, mode: SliderChangeMode) => {
                  this.settings.glassBlurStrength = value
                  this.glassBlurStrength = value
                  this.updateSetting(this.isSliderSettled(mode))
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
              .sliderInteractionMode(SliderInteraction.SLIDE_AND_CLICK)
              .systemMaterial(this.styleGlassMaterial())
              .onChange((value: number, mode: SliderChangeMode) => {
                this.settings.tabIndicatorOpacity = value
                this.tabIndicatorOpacity = value
                this.updateSetting(this.isSliderSettled(mode))
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
    Column({ space: this.scaledSize(10) }) {
      Column() {
        Row() {
          Column({ space: this.scaledSize(6) }) {
            Text('淡入淡出')
              .fontSize(this.scaledFont(14))
              .fontColor(this.settingTextColor())
              .fontWeight(FontWeight.Medium)
            Text('开启时：起播、恢复、暂停时音量平滑渐变；关闭时：立即播放/暂停，音量直接生效')
              .fontSize(this.scaledFont(12))
              .fontColor(this.settingSubTextColor())
          }
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center)
          .alignItems(HorizontalAlign.Start)

          Toggle({ type: ToggleType.Switch, isOn: this.settings.fadeInOut })
            .selectedColor(this.primaryColor)
            .systemMaterial(this.styleGlassMaterial())
            .alignSelf(ItemAlign.Center)
            .margin({ left: this.scaledSize(10) })
            .onChange((val: boolean) => {
              this.settings.fadeInOut = val
              this.updateSetting()
              AppStorage.setOrCreate('uplayer_fade_in_out', val)
            })
        }
        .width('100%')
        .constraintSize({ minHeight: this.scaledSize(44) })
        .alignItems(VerticalAlign.Center)
      }
      .width('100%')
      .padding({ left: this.scaledSize(14), right: this.scaledSize(14) })
      .backgroundColor(ColorHelper.hexToRgba(this.primaryColor, 0.04))
      .borderRadius(this.scaledSize(10))

      Column() {
        Row() {
          Column({ space: this.scaledSize(6) }) {
            Text('定时停止淡出时长')
              .fontSize(this.scaledFont(14))
              .fontColor(this.settingTextColor())
              .fontWeight(FontWeight.Medium)
            Text('定时关闭到期时音量平滑淡出后停止；0 秒为立即停止。按歌曲数定时会淡出最后一首的曲尾')
              .fontSize(this.scaledFont(12))
              .fontColor(this.settingSubTextColor())
          }
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center)
          .alignItems(HorizontalAlign.Start)

          Text(this.settings.timerFadeSeconds + ' 秒')
            .fontSize(this.scaledFont(12))
            .fontColor(this.settingTextColor())
            .alignSelf(ItemAlign.Center)
            .margin({ left: this.scaledSize(10) })
        }
        .width('100%')
        .padding({ top: this.scaledSize(10) })
        .alignItems(VerticalAlign.Center)

        Slider({
          value: this.settings.timerFadeSeconds,
          min: 0,
          max: 10,
          step: 1,
          style: SliderStyle.OutSet
        })
          .width('100%')
          .selectedColor(this.primaryColor)
          .trackColor(ColorHelper.hexToRgba(this.primaryColor, 0.12))
          .blockColor('#FFFFFF')
          .blockSize({ width: this.scaledSize(20), height: this.scaledSize(20) })
          .blockBorderColor(this.primaryColor)
          .blockBorderWidth(3)
          .sliderInteractionMode(SliderInteraction.SLIDE_AND_CLICK)
          .systemMaterial(this.styleGlassMaterial())
          .onChange((value: number, mode: SliderChangeMode) => {
            this.onTimerFadeSecondsChange(value, mode)
          })
          .margin({ top: this.scaledSize(4), bottom: this.scaledSize(12) })
      }
      .width('100%')
      .padding({ left: this.scaledSize(14), right: this.scaledSize(14) })
      .backgroundColor(ColorHelper.hexToRgba(this.primaryColor, 0.04))
      .borderRadius(this.scaledSize(10))

      Row() {
        Column({ space: this.scaledSize(6) }) {
          Text('启动时恢复上次播放')
            .fontSize(this.scaledFont(14))
            .fontColor(this.settingTextColor())
            .fontWeight(FontWeight.Medium)
          Text('开启后冷启动自动载入上次播放的歌曲并定位到上次进度')
            .fontSize(this.scaledFont(12))
            .fontColor(this.settingSubTextColor())
        }
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Start)

        Toggle({ type: ToggleType.Switch, isOn: this.settings.resumePlaybackOnStart })
          .selectedColor(this.primaryColor)
          .systemMaterial(this.styleGlassMaterial())
          .alignSelf(ItemAlign.Center)
          .margin({ left: this.scaledSize(10) })
          .onChange((isOn: boolean) => {
            this.settings.resumePlaybackOnStart = isOn
            this.updateSetting()
          })
      }
      .width('100%')
      .padding({
        left: this.scaledSize(14),
        right: this.scaledSize(14),
        top: this.scaledSize(10),
        bottom: this.scaledSize(10)
      })
      .backgroundColor(ColorHelper.hexToRgba(this.primaryColor, 0.04))
      .borderRadius(this.scaledSize(10))

      Row() {
        Column({ space: this.scaledSize(6) }) {
          Text('恢复后自动播放')
            .fontSize(this.scaledFont(14))
            .fontColor(this.settingTextColor())
            .fontWeight(FontWeight.Medium)
          Text('开启后启动恢复完成即自动开始播放；关闭则恢复为暂停状态，手动点播放继续')
            .fontSize(this.scaledFont(12))
            .fontColor(this.settingSubTextColor())
        }
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Start)

        Toggle({ type: ToggleType.Switch, isOn: this.settings.autoPlayAfterResume })
          .selectedColor(this.primaryColor)
          .systemMaterial(this.styleGlassMaterial())
          .alignSelf(ItemAlign.Center)
          .margin({ left: this.scaledSize(10) })
          .enabled(this.settings.resumePlaybackOnStart)
          .onChange((isOn: boolean) => {
            this.settings.autoPlayAfterResume = isOn
            this.updateSetting()
          })
      }
      .width('100%')
      .padding({
        left: this.scaledSize(14),
        right: this.scaledSize(14),
        top: this.scaledSize(10),
        bottom: this.scaledSize(10)
      })
      .backgroundColor(ColorHelper.hexToRgba(this.primaryColor, 0.04))
      .borderRadius(this.scaledSize(10))

      Row() {
        Column({ space: this.scaledSize(6) }) {
          Text('耳机断开时继续播放')
            .fontSize(this.scaledFont(14))
            .fontColor(this.settingTextColor())
            .fontWeight(FontWeight.Medium)
          Text('关闭时：拔出耳机/断开蓝牙会自动暂停播放并提示；开启时：系统默认切回扬声器继续播放')
            .fontSize(this.scaledFont(12))
            .fontColor(this.settingSubTextColor())
        }
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Start)

        Toggle({ type: ToggleType.Switch, isOn: this.settings.continuePlayOnHeadsetUnplug })
          .selectedColor(this.primaryColor)
          .systemMaterial(this.styleGlassMaterial())
          .alignSelf(ItemAlign.Center)
          .margin({ left: this.scaledSize(10) })
          .onChange((isOn: boolean) => {
            this.settings.continuePlayOnHeadsetUnplug = isOn
            this.updateSetting()
          })
      }
      .width('100%')
      .padding({
        left: this.scaledSize(14),
        right: this.scaledSize(14),
        top: this.scaledSize(10),
        bottom: this.scaledSize(10)
      })
      .backgroundColor(ColorHelper.hexToRgba(this.primaryColor, 0.04))
      .borderRadius(this.scaledSize(10))

      Row() {
        Column({ space: this.scaledSize(6) }) {
          Text('与其他音频应用同时播放')
            .fontSize(this.scaledFont(14))
            .fontColor(this.settingTextColor())
            .fontWeight(FontWeight.Medium)
          Text('开启后与其它应用音频并发播放、互不打断；系统通知、提示音也不压低本应用音量（两种效果共用同一系统策略，无法单独关闭其一）')
            .fontSize(this.scaledFont(12))
            .fontColor(this.settingSubTextColor())
        }
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Start)

        Toggle({ type: ToggleType.Switch, isOn: this.settings.ignoreNotificationDuck })
          .selectedColor(this.primaryColor)
          .systemMaterial(this.styleGlassMaterial())
          .alignSelf(ItemAlign.Center)
          .margin({ left: this.scaledSize(10) })
          .onChange((isOn: boolean) => {
            this.settings.ignoreNotificationDuck = isOn
            this.updateSetting()
            AudioFocusService.getInstance().applyIgnoreNotificationDuck(isOn)
          })
      }
      .width('100%')
      .padding({
        left: this.scaledSize(14),
        right: this.scaledSize(14),
        top: this.scaledSize(10),
        bottom: this.scaledSize(10)
      })
      .backgroundColor(ColorHelper.hexToRgba(this.primaryColor, 0.04))
      .borderRadius(this.scaledSize(10))

      Column() {
        Row() {
          Text('播放速度')
            .fontSize(this.scaledFont(14))
            .fontColor(this.settingTextColor())
            .fontWeight(FontWeight.Medium)
          Blank()
          Text(this.settings.playSpeed.toFixed(1) + 'x')
            .fontSize(this.scaledFont(12))
            .fontColor(this.settingTextColor())
        }
        .width('100%')
        .height(this.scaledSize(44))
        .alignItems(VerticalAlign.Center)

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
          .sliderInteractionMode(SliderInteraction.SLIDE_AND_CLICK)
          .systemMaterial(this.styleGlassMaterial())
          .onChange((value: number, mode: SliderChangeMode) => {
            this.onSpeedChange(value, mode)
          })
          .margin({ top: this.scaledSize(4), bottom: this.scaledSize(12) })
      }
      .width('100%')
      .padding({ left: this.scaledSize(14), right: this.scaledSize(14) })
      .backgroundColor(ColorHelper.hexToRgba(this.primaryColor, 0.04))
      .borderRadius(this.scaledSize(10))

      Row() {
        Column({ space: this.scaledSize(6) }) {
          Text('低功耗播放')
            .fontSize(this.scaledFont(14))
            .fontColor(this.settingTextColor())
            .fontWeight(FontWeight.Medium)
          Text(this.lowPowerSupported ?
            '开启后解码与渲染卸载至低功耗硬件，降低播放功耗、延长续航；期间均衡器等音效不可用，播放中切换将从当前位置重播当前曲目' :
            '当前设备不支持低功耗音频链路，开关不会生效')
            .fontSize(this.scaledFont(12))
            .fontColor(this.settingSubTextColor())
        }
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Start)

        Toggle({ type: ToggleType.Switch, isOn: this.settings.lowPowerPlayback })
          .selectedColor(this.primaryColor)
          .systemMaterial(this.styleGlassMaterial())
          .alignSelf(ItemAlign.Center)
          .margin({ left: this.scaledSize(10) })
          .enabled(this.lowPowerSupported)
          .onChange((isOn: boolean) => {
            this.settings.lowPowerPlayback = isOn
            this.updateSetting()
            this.avPlayerService.applyLowPowerPlayback(isOn)
          })
      }
      .width('100%')
      .padding({
        left: this.scaledSize(14),
        right: this.scaledSize(14),
        top: this.scaledSize(10),
        bottom: this.scaledSize(10)
      })
      .backgroundColor(ColorHelper.hexToRgba(this.primaryColor, 0.04))
      .borderRadius(this.scaledSize(10))

      // 艺术家分隔符：首页筛选下拉列表按这些符号把多艺人串拆开归类（可多选 + 自定义）
      Column() {
        Text('艺术家分隔符')
          .fontSize(this.scaledFont(14))
          .fontColor(this.settingTextColor())
          .fontWeight(FontWeight.Medium)
          .width('100%')
        Text('首页筛选下拉列表按启用的符号把「甲,乙」等多位艺术家拆开归类，可多选；全部停用则不拆分')
          .fontSize(this.scaledFont(12))
          .fontColor(this.settingSubTextColor())
          .width('100%')
          .margin({ top: this.scaledSize(2) })

        Flex({ wrap: FlexWrap.Wrap }) {
          ForEach(this.artistSeparatorOptions, (sep: string) => {
            Text(this.artistSeparatorLabel(sep))
              .fontSize(this.scaledFont(12))
              .fontColor(this.settings.artistSeparators.indexOf(sep) >= 0 ?
                '#FFFFFF' : this.settingTextColor())
              .padding({
                left: this.scaledSize(10),
                right: this.scaledSize(10),
                top: this.scaledSize(5),
                bottom: this.scaledSize(5)
              })
              .margin({ right: this.scaledSize(6), bottom: this.scaledSize(6) })
              .backgroundColor(this.settings.artistSeparators.indexOf(sep) >= 0 ?
                this.primaryColor : ColorHelper.hexToRgba(this.primaryColor, 0.08))
              .borderRadius(this.scaledSize(15))
              .onClick(() => {
                this.toggleArtistSeparator(sep)
              })
          }, (sep: string) => sep + (this.settings.artistSeparators.indexOf(sep) >= 0 ? '_on' : '_off'))
          // 自定义分隔符紧随预置候选同一行/同一样式（启用态主色 + ×，点击移除）
          ForEach(this.customArtistSeparators(), (sep: string) => {
            Text(sep + ' ×')
              .fontSize(this.scaledFont(12))
              .fontColor('#FFFFFF')
              .padding({
                left: this.scaledSize(10),
                right: this.scaledSize(10),
                top: this.scaledSize(5),
                bottom: this.scaledSize(5)
              })
              .margin({ right: this.scaledSize(6), bottom: this.scaledSize(6) })
              .backgroundColor(this.primaryColor)
              .borderRadius(this.scaledSize(15))
              .onClick(() => {
                this.removeArtistSeparator(sep)
              })
          }, (sep: string) => 'custom_' + sep)
        }
        .width('100%')
        .margin({ top: this.scaledSize(8) })

        Row({ space: this.scaledSize(8) }) {
          TextInput({ text: this.artistSepInput, placeholder: '自定义分隔符，每个字符各算一个' })
            .layoutWeight(1)
            .height(this.scaledSize(36))
            .fontSize(this.scaledFont(13))
            .backgroundColor(ColorHelper.hexToRgba(this.primaryColor, 0.06))
            .borderRadius(this.scaledSize(12))
            .onChange((value: string) => {
              this.artistSepInput = value
            })
            .enterKeyType(EnterKeyType.Done)
            .onSubmit(() => {
              this.addCustomArtistSeparators()
            })
          Text('添加')
            .fontSize(this.scaledFont(13))
            .fontColor(Color.White)
            .padding({
              left: this.scaledSize(14),
              right: this.scaledSize(14),
              top: this.scaledSize(8),
              bottom: this.scaledSize(8)
            })
            .borderRadius(this.scaledSize(14))
            .backgroundColor(this.primaryColor)
            .onClick(() => {
              this.addCustomArtistSeparators()
            })
        }
        .width('100%')
        .margin({ top: this.scaledSize(2) })
      }
      .width('100%')
      .padding({
        left: this.scaledSize(14),
        right: this.scaledSize(14),
        top: this.scaledSize(10),
        bottom: this.scaledSize(12)
      })
      .backgroundColor(ColorHelper.hexToRgba(this.primaryColor, 0.04))
      .borderRadius(this.scaledSize(10))
    }
    .width('100%')
    .constraintSize({ minWidth: 0, maxWidth: '100%' })
  }

  @Builder
  buildAudioSection(): void {
    Column({ space: this.scaledSize(10) }) {
      Column() {
        this.toggleRow({
          label: '均衡器',
          isOn: this.settings.eqEnabled,
          onChange: (val: boolean) => {
            // 面板显隐翻转必须包进统一触发动画，过渡才会播放
            this.animateSettingChange(() => {
              this.settings.eqEnabled = val
            })
            this.updateSetting()
            this.avPlayerService.applyEqualizer(val, this.settings.eqBands)
          }
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
                }, (name: string, i: number) => name + (this.eqPresetActive(i) ? '_on' : '_off'))
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
                    .margin({ bottom: this.scaledSize(4) })
                }
                .width(this.scaledSize(44))
                .alignItems(HorizontalAlign.Center)
              }, (band: EqBandInfo) => band.freq + this.settings.eqBands[band.index])
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
                      .sliderInteractionMode(SliderInteraction.SLIDE_AND_CLICK)
                      .systemMaterial(this.styleGlassMaterial())
                      .onChange((value: number, mode: SliderChangeMode) => {
                        this.onEqBandChange(band.index, value, mode)
                      })
                  }
                  .width(this.scaledSize(44))
                  .alignItems(HorizontalAlign.Center)
                }, (band: EqBandInfo) => band.freq + this.settings.eqBands[band.index])
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
                    .margin({ top: this.scaledSize(6) })
                }
                .width(this.scaledSize(44))
                .alignItems(HorizontalAlign.Center)
              }, (band: EqBandInfo) => band.freq)
            }
            .width('100%')
            .justifyContent(FlexAlign.Center)
          }
          .padding({
            left: this.scaledSize(8),
            right: this.scaledSize(8),
            top: this.scaledSize(12),
            bottom: this.scaledSize(12)
          })
        }
        .width('100%')
        .height(this.scaledSize(280))
        .backgroundColor(ColorHelper.hexToRgba(this.primaryColor, 0.04))
        .borderRadius(this.scaledSize(10))
        .transition(this.settingCardTransition())
      }

      // ═══ 自动音量均衡（P2-1 ReplayGain）═══
      Column() {
        Row() {
          Text('自动音量均衡')
            .fontSize(this.scaledFont(13))
            .fontWeight(FontWeight.Medium)
            .fontColor(this.settingTextColor())
          // 说明弹窗入口：与分组标题问号同款样式
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
          .margin({ left: this.scaledSize(6) })
          .onClick(() => {
            this.showReplayGainHelp = true
          })
          .bindSheet($$this.showReplayGainHelp, this.replayGainHelpSheetBuilder(), {
            height: SheetSize.FIT_CONTENT,
            dragBar: false,
            preferType: SheetType.CENTER,
            showClose: true,
            systemMaterial: this.styleGlassMaterial(),
            backgroundColor: $r('app.color.page_background_other')
          })
          Blank()
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
        Text('按内嵌 ReplayGain 标签统一响度')
          .fontSize(this.scaledFont(11))
          .fontColor(this.settingSubTextColor())
          .width('100%')
          .margin({ top: this.scaledSize(2) })
        Column() {
          this.chipRow({
            labels: ['均衡关', '按曲目', '按专辑'],
            current: this.replayGainModeIndex(),
            onPick: (i: number) => {
              this.onReplayGainModeChange(i)
            }
          })
        }
        .width('100%')
        .margin({ top: this.scaledSize(8) })
      }
      .width('100%')
      .padding({
        left: this.scaledSize(14),
        right: this.scaledSize(14),
        top: this.scaledSize(10),
        bottom: this.scaledSize(10)
      })
      .backgroundColor(ColorHelper.hexToRgba(this.primaryColor, 0.04))
      .borderRadius(this.scaledSize(10))

      if (this.settings.replayGainMode !== 'off') {
        Column() {
          this.optionSliderRow('预增益', this.settings.replayGainPreGainDb, -12, 12, 1, 'dB',
            (value: number, mode: SliderChangeMode) => {
              this.onReplayGainPreGainChange(value, mode)
            })
          Text('在标签增益上整体叠加的固定量，正数更响、负数更轻')
            .fontSize(this.scaledFont(12))
            .fontColor(this.settingSubTextColor())
            .width('100%')
            .margin({ top: this.scaledSize(4) })
        }
        .width('100%')
        .padding({
          left: this.scaledSize(14),
          right: this.scaledSize(14),
          top: this.scaledSize(10),
          bottom: this.scaledSize(10)
        })
        .backgroundColor(ColorHelper.hexToRgba(this.primaryColor, 0.04))
        .borderRadius(this.scaledSize(10))
        .transition(this.settingCardTransition())
      }

      // ═══ 声场 ═══
      Column() {
        this.toggleRow({
          label: '声场',
          isOn: this.settings.soundFieldEnabled,
          onChange: (val: boolean) => {
            this.animateSettingChange(() => {
              this.settings.soundFieldEnabled = val
            })
            this.updateSetting()
            this.avPlayerService.applySoundField(val, this.settings.soundFieldType)
          }
        })
        if (!this.soundFieldSupported) {
          Text('当前设备不支持声场效果')
            .fontSize(this.scaledFont(12))
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
          this.chipRow({
            labels: ['前置', '宏大', '聆听', '宽广'],
            current: this.settings.soundFieldType - 1,
            onPick: (t: number) => {
              this.onSoundFieldTypeChange(t + 1)
            }
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
        this.toggleRow({
          label: '环境效果',
          isOn: this.settings.environmentEnabled,
          onChange: (val: boolean) => {
            this.animateSettingChange(() => {
              this.settings.environmentEnabled = val
            })
            this.updateSetting()
            this.avPlayerService.applyEnvironment(val, this.settings.environmentType)
          }
        })
        if (!this.environmentSupported) {
          Text('当前设备不支持环境效果')
            .fontSize(this.scaledFont(12))
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
          this.chipRow({
            labels: ['广播', '听筒', '水下', '留声机'],
            current: this.settings.environmentType - 1,
            onPick: (t: number) => {
              this.onEnvironmentTypeChange(t + 1)
            }
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
        this.toggleRow({
          label: '声音美化',
          isOn: this.settings.beautifierEnabled,
          onChange: (val: boolean) => {
            this.animateSettingChange(() => {
              this.settings.beautifierEnabled = val
            })
            this.updateSetting()
            this.avPlayerService.applyVoiceBeautifier(val, this.settings.beautifierType)
          }
        })
        if (!this.beautifierSupported) {
          Text('当前设备不支持声音美化')
            .fontSize(this.scaledFont(12))
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
          this.chipRow({
            labels: ['清澈', '剧场', 'CD', '录音棚'],
            current: this.settings.beautifierType - 1,
            onPick: (t: number) => {
              this.onBeautifierTypeChange(t + 1)
            }
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
        this.toggleRow({
          label: '空间渲染',
          isOn: this.settings.spaceRenderEnabled,
          onChange: (val: boolean) => {
            this.animateSettingChange(() => {
              this.settings.spaceRenderEnabled = val
            })
            this.updateSetting()
            this.avPlayerService.applySpaceRender(val, this.settings.spaceRenderMode, this.settings.spaceRenderValues)
          }
        })
        if (!this.spaceRenderSupported) {
          Text('当前设备不支持空间渲染')
            .fontSize(this.scaledFont(12))
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
          this.chipRow({
            labels: SpaceRenderTable.MODE_NAMES,
            current: this.settings.spaceRenderMode,
            onPick: (m: number) => {
              this.onSpaceModeChange(m)
            }
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
            this.chipRow({
              labels: ['逆时针', '顺时针'],
              current: Math.round(this.spaceValue(4)),
              onPick: (d: number) => {
                this.onSpaceDirectionChange(d)
              }
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

      // ═══ 通用变声（主链内，10 种风格化变声）═══
      Column() {
        this.toggleRow({
          label: '通用变声',
          isOn: this.settings.generalVoiceChangeEnabled,
          onChange: (val: boolean) => {
            this.animateSettingChange(() => {
              this.settings.generalVoiceChangeEnabled = val
            })
            this.updateSetting()
            this.avPlayerService.applyGeneralVoiceChange(val, this.settings.generalVoiceChangeType)
          }
        })
        if (!this.generalVoiceChangeSupported) {
          Text('当前设备不支持通用变声')
            .fontSize(this.scaledFont(12))
            .fontColor(this.settingSubTextColor())
            .width('100%')
            .margin({ top: this.scaledSize(2) })
        }
      }
      .width('100%')
      .enabled(this.generalVoiceChangeSupported)
      .padding({ left: this.scaledSize(14), right: this.scaledSize(14) })
      .backgroundColor(ColorHelper.hexToRgba(this.primaryColor, 0.04))
      .borderRadius(this.scaledSize(10))

      if (this.settings.generalVoiceChangeEnabled && this.generalVoiceChangeSupported) {
        Column() {
          this.scrollChipRow({
            labels: GeneralVoiceChangeTable.NAMES,
            current: this.settings.generalVoiceChangeType - 1,
            onPick: (t: number) => {
              this.onGeneralVoiceTypeChange(t + 1)
            }
          })
        }
        .width('100%')
        .padding({ left: this.scaledSize(14), right: this.scaledSize(14) })
        .backgroundColor(ColorHelper.hexToRgba(this.primaryColor, 0.04))
        .borderRadius(this.scaledSize(10))
        .transition(this.settingCardTransition())
      }

      // ═══ 降噪（无参数，仅开关）═══
      Column() {
        this.toggleRow({
          label: '降噪',
          isOn: this.settings.noiseReductionEnabled,
          onChange: (val: boolean) => {
            this.animateSettingChange(() => {
              this.settings.noiseReductionEnabled = val
            })
            this.updateSetting()
            this.avPlayerService.applyNoiseReduction(val)
          }
        })
        Text(this.noiseReductionSupported ? '降低背景噪声，输出为 16kHz 单声道（语音向处理）'
          : '当前设备不支持降噪')
          .fontSize(this.scaledFont(12))
          .fontColor(this.settingSubTextColor())
          .width('100%')
          .margin({ top: this.scaledSize(2) })
      }
      .width('100%')
      .enabled(this.noiseReductionSupported)
      .padding({ left: this.scaledSize(14), right: this.scaledSize(14) })
      .backgroundColor(ColorHelper.hexToRgba(this.primaryColor, 0.04))
      .borderRadius(this.scaledSize(10))

      // ═══ 传统变声（性别 + 7 类型 + 音调）═══
      Column() {
        this.toggleRow({
          label: '传统变声',
          isOn: this.settings.pureVoiceChangeEnabled,
          onChange: (val: boolean) => {
            this.animateSettingChange(() => {
              this.settings.pureVoiceChangeEnabled = val
            })
            this.updateSetting()
            this.avPlayerService.applyPureVoiceChange(val, this.settings.pureVoiceChangeGender,
              this.settings.pureVoiceChangeType, this.settings.pureVoiceChangePitch)
          }
        })
        if (!this.pureVoiceChangeSupported) {
          Text('当前设备不支持传统变声')
            .fontSize(this.scaledFont(12))
            .fontColor(this.settingSubTextColor())
            .width('100%')
            .margin({ top: this.scaledSize(2) })
        }
      }
      .width('100%')
      .enabled(this.pureVoiceChangeSupported)
      .padding({ left: this.scaledSize(14), right: this.scaledSize(14) })
      .backgroundColor(ColorHelper.hexToRgba(this.primaryColor, 0.04))
      .borderRadius(this.scaledSize(10))

      if (this.settings.pureVoiceChangeEnabled && this.pureVoiceChangeSupported) {
        Column({ space: this.scaledSize(10) }) {
          this.chipRow({
            labels: PureVoiceChangeTable.GENDER_NAMES,
            current: this.settings.pureVoiceChangeGender - 1,
            onPick: (g: number) => {
              this.onPureVoiceGenderChange(g + 1)
            }
          })
          this.scrollChipRow({
            labels: PureVoiceChangeTable.TYPE_NAMES,
            current: this.settings.pureVoiceChangeType - 1,
            onPick: (t: number) => {
              this.onPureVoiceTypeChange(t + 1)
            }
          })
          Row() {
            Text('音调')
              .fontSize(this.scaledFont(12))
              .fontColor(this.settingSubTextColor())
              .width(this.scaledSize(72))
              .flexShrink(0)
            Slider({
              value: this.settings.pureVoiceChangePitch <= 0 ? PureVoiceChangeTable.PITCH_MIN :
                this.settings.pureVoiceChangePitch,
              min: PureVoiceChangeTable.PITCH_MIN,
              max: PureVoiceChangeTable.PITCH_MAX,
              step: 0.1,
              style: SliderStyle.OutSet
            })
              .layoutWeight(1)
              .selectedColor(this.primaryColor)
              .trackColor(ColorHelper.hexToRgba(this.primaryColor, 0.12))
              .blockColor('#FFFFFF')
              .blockSize({ width: this.scaledSize(16), height: this.scaledSize(16) })
              .blockBorderColor(this.primaryColor)
              .blockBorderWidth(2)
              .sliderInteractionMode(SliderInteraction.SLIDE_AND_CLICK)
              .systemMaterial(this.styleGlassMaterial())
              .onChange((value: number, mode: SliderChangeMode) => {
                this.onPureVoicePitchChange(value, mode)
              })
            Text(this.pureVoicePitchText())
              .fontSize(this.scaledFont(12))
              .fontColor(this.settingTextColor())
              .width(this.scaledSize(64))
              .textAlign(TextAlign.End)
              .flexShrink(0)
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)
          Text('提示：传统变声输出为 16kHz 单声道（语音向处理）')
            .fontSize(this.scaledFont(12))
            .fontColor(this.settingSubTextColor())
            .width('100%')
        }
        .width('100%')
        .padding({ left: this.scaledSize(14), right: this.scaledSize(14) })
        .backgroundColor(ColorHelper.hexToRgba(this.primaryColor, 0.04))
        .borderRadius(this.scaledSize(10))
        .transition(this.settingCardTransition())
      }

      // ═══ 变速变调（速度 + 音调，与播放倍速相互独立）═══
      Column() {
        this.toggleRow({
          label: '变速变调',
          isOn: this.settings.tempoPitchEnabled,
          onChange: (val: boolean) => {
            this.animateSettingChange(() => {
              this.settings.tempoPitchEnabled = val
            })
            this.updateSetting()
            this.avPlayerService.applyTempoPitch(val, this.settings.tempoSpeed, this.settings.tempoPitch)
          }
        })
        if (!this.tempoPitchSupported) {
          Text('当前设备不支持变速变调')
            .fontSize(this.scaledFont(12))
            .fontColor(this.settingSubTextColor())
            .width('100%')
            .margin({ top: this.scaledSize(2) })
        }
      }
      .width('100%')
      .enabled(this.tempoPitchSupported)
      .padding({ left: this.scaledSize(14), right: this.scaledSize(14) })
      .backgroundColor(ColorHelper.hexToRgba(this.primaryColor, 0.04))
      .borderRadius(this.scaledSize(10))

      if (this.settings.tempoPitchEnabled && this.tempoPitchSupported) {
        Column({ space: this.scaledSize(10) }) {
          this.optionSliderRow('速度', this.settings.tempoSpeed, 0.5, 10.0, 0.1, 'x',
            (value: number, mode: SliderChangeMode) => {
              this.onTempoSpeedChange(value, mode)
            })
          this.optionSliderRow('音调', this.settings.tempoPitch, 0.1, 5.0, 0.1, 'x',
            (value: number, mode: SliderChangeMode) => {
              this.onTempoPitchChange(value, mode)
            })
          Text('提示：变速变调输出为 48kHz 单声道')
            .fontSize(this.scaledFont(12))
            .fontColor(this.settingSubTextColor())
            .width('100%')
        }
        .width('100%')
        .padding({ left: this.scaledSize(14), right: this.scaledSize(14) })
        .backgroundColor(ColorHelper.hexToRgba(this.primaryColor, 0.04))
        .borderRadius(this.scaledSize(10))
        .transition(this.settingCardTransition())
      }

      // ═══ 音源分离（独立管线，多输出人声/伴奏）═══
      Column() {
        this.toggleRow({
          label: '音源分离',
          isOn: this.settings.separationEnabled,
          onChange: (val: boolean) => {
            this.animateSettingChange(() => {
              this.settings.separationEnabled = val
            })
            this.updateSetting()
            this.avPlayerService.applySeparation(val, this.settings.separationOutput)
          }
        })
        if (!this.separationSupported) {
          Text('当前设备不支持音源分离（依赖 NPU）')
            .fontSize(this.scaledFont(12))
            .fontColor(this.settingSubTextColor())
            .width('100%')
            .margin({ top: this.scaledSize(2) })
        }
      }
      .width('100%')
      .enabled(this.separationSupported)
      .padding({ left: this.scaledSize(14), right: this.scaledSize(14) })
      .backgroundColor(ColorHelper.hexToRgba(this.primaryColor, 0.04))
      .borderRadius(this.scaledSize(10))

      if (this.settings.separationEnabled && this.separationSupported) {
        Column({ space: this.scaledSize(8) }) {
          this.chipRow({
            labels: SeparationTable.OUTPUT_NAMES,
            current: this.settings.separationOutput - 1,
            onPick: (o: number) => {
              this.onSeparationOutputChange(o + 1)
            }
          })
          Text('分离使用独立管线，开启期间其他音效暂停生效，关闭后自动恢复')
            .fontSize(this.scaledFont(12))
            .fontColor(this.settingSubTextColor())
            .width('100%')
        }
        .width('100%')
        .padding({ left: this.scaledSize(14), right: this.scaledSize(14) })
        .backgroundColor(ColorHelper.hexToRgba(this.primaryColor, 0.04))
        .borderRadius(this.scaledSize(10))
        .transition(this.settingCardTransition())
      }

      // ═══ 系统空间音频（只读状态展示：API 无 setter，开关由系统设置控制）═══
      Row() {
        Column({ space: this.scaledSize(6) }) {
          Text('系统空间音频')
            .fontSize(this.scaledFont(14))
            .fontColor(this.settingTextColor())
            .fontWeight(FontWeight.Medium)
          Text('系统级空间音频渲染状态，可在系统设置中开启或关闭')
            .fontSize(this.scaledFont(12))
            .fontColor(this.settingSubTextColor())
        }
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Start)

        Text(this.spatialStatusText())
          .fontSize(this.scaledFont(12))
          .fontColor(this.spatializationSupported && this.spatializationEnabled ?
            this.primaryColor : this.settingSubTextColor())
          .fontWeight(FontWeight.Medium)
          .alignSelf(ItemAlign.Center)
      }
      .width('100%')
      .padding({ left: this.scaledSize(14), right: this.scaledSize(14), top: this.scaledSize(10), bottom: this.scaledSize(10) })
      .backgroundColor(ColorHelper.hexToRgba(this.primaryColor, 0.04))
      .borderRadius(this.scaledSize(10))
    }
    .width('100%')
    .constraintSize({ minWidth: 0, maxWidth: '100%' })
  }

  // 系统空间音频状态文案：设备不支持 / 已开启 / 已关闭
  private spatialStatusText(): string {
    if (!this.spatializationSupported) {
      return '当前设备不支持'
    }
    return this.spatializationEnabled ? '已开启' : '已关闭'
  }

  @Builder
  aboutInfoRow(label: string, value: string): void {
    Row() {
      Text(label)
        .fontSize(this.scaledFont(14))
        .fontColor(this.settingTextColor())
        .fontWeight(FontWeight.Medium)
        .maxLines(1)
        .flexShrink(0)
      Blank()
      Text(value)
        .fontSize(this.scaledFont(14))
        .fontColor(this.settingTextColor())
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .flexShrink(1)
        .textAlign(TextAlign.End)
    }
    .width('100%')
    .constraintSize({ minWidth: 0, maxWidth: '100%' })
    .height(this.scaledSize(44))
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
    Column({ space: this.scaledSize(6) }) {
      // 居中的软件图标 + 软件名 + 版本号
      Column({ space: this.scaledSize(6) }) {
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
        Text('联系方式')
          .fontSize(this.scaledFont(13))
          .fontColor(this.settingTextColor())
          .fontWeight(FontWeight.Bold)
          .width('100%')
          .padding({ left: this.scaledSize(4) })
        this.aboutInfoRow('邮箱', this.aboutEmail)
        this.aboutInfoRow('QQ', this.aboutQq)
        this.aboutInfoRow('仓库地址', this.aboutRepoUrl)
      }
      .width('100%')

      this.checkUpdateRow()

      // 全局快捷键速查：数据来源 Index.handleKeyEvent / MusicPlayer.handleKeyEvent
      // 内容移入二级弹窗（bindSheet 半模态），正文只保留入口行
      Column({ space: this.scaledSize(6) }) {
        Text('快捷键')
          .fontSize(this.scaledFont(13))
          .fontColor(this.settingTextColor())
          .fontWeight(FontWeight.Bold)
          .width('100%')
          .padding({ left: this.scaledSize(4) })
        this.shortcutEntryRow()
      }
      .width('100%')

      // 最常播放 Top 20（P0-4）：playCount 倒序，实时读取曲库统计
      Column({ space: this.scaledSize(6) }) {
        Text('最常播放 Top 20')
          .fontSize(this.scaledFont(13))
          .fontColor(this.settingTextColor())
          .fontWeight(FontWeight.Bold)
          .width('100%')
          .padding({ left: this.scaledSize(4) })
        this.topPlayCountRows()
      }
      .width('100%')

      Text('本地音乐播放器 · 为鸿蒙打造')
        .fontSize(this.scaledFont(11))
        .fontColor(this.settingTextColor())
        .width('100%')
        .textAlign(TextAlign.Center)
        .margin({ top: this.scaledSize(6) })
    }
    .width('100%')
    .constraintSize({ minWidth: 0, maxWidth: '100%' })
  }

  // P0-4：最常播放 Top 20 数据（playCount 倒序，仅含播过的歌）
  private topPlayedSongs(): TopPlayedEntry[] {
    const songs: SongInfo[] = DataService.getInstance().getSongs()
    const entries: TopPlayedEntry[] = []
    for (let i = 0; i < songs.length; i++) {
      if (songs[i].playCount > 0) {
        const entry: TopPlayedEntry = new TopPlayedEntry()
        entry.title = songs[i].title.length > 0 ? songs[i].title : songs[i].name
        entry.artist = songs[i].artist.length > 0 ? songs[i].artist : '未知歌手'
        entry.playCount = songs[i].playCount
        entries.push(entry)
      }
    }
    entries.sort((a: TopPlayedEntry, b: TopPlayedEntry): number => {
      return b.playCount - a.playCount
    })
    const capped: TopPlayedEntry[] = []
    for (let i = 0; i < entries.length && i < 20; i++) {
      capped.push(entries[i])
    }
    return capped
  }

  @Builder
  topPlayCountRows(): void {
    if (this.topPlayedSongs().length === 0) {
      Text('暂无播放记录')
        .fontSize(this.scaledFont(13))
        .fontColor(this.settingTextColor())
        .opacity(0.6)
        .width('100%')
        .padding({ left: this.scaledSize(14), right: this.scaledSize(14) })
    } else {
      ForEach(this.topPlayedSongs(), (entry: TopPlayedEntry, index: number) => {
        Row() {
          Text(String(index + 1))
            .fontSize(this.scaledFont(13))
            .fontColor(this.settingTextColor())
            .fontWeight(FontWeight.Bold)
            .width(this.scaledSize(24))
            .flexShrink(0)
          Text(entry.title)
            .fontSize(this.scaledFont(13))
            .fontColor(this.settingTextColor())
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
          Text(entry.artist)
            .fontSize(this.scaledFont(12))
            .fontColor(this.settingTextColor())
            .opacity(0.7)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .constraintSize({ maxWidth: '38%' })
            .flexShrink(0)
            .margin({ left: this.scaledSize(8) })
          Text(entry.playCount + ' 次')
            .fontSize(this.scaledFont(12))
            .fontColor(this.settingTextColor())
            .opacity(0.7)
            .flexShrink(0)
            .margin({ left: this.scaledSize(8) })
        }
        .width('100%')
        .height(this.scaledSize(36))
        .alignItems(VerticalAlign.Center)
        .padding({ left: this.scaledSize(14), right: this.scaledSize(14) })
        .backgroundColor(ColorHelper.hexToRgba(this.primaryColor, 0.04))
        .borderRadius(this.scaledSize(10))
        .margin({ top: index === 0 ? 0 : this.scaledSize(4) })
      }, (entry: TopPlayedEntry, index: number) => 'top_' + index + '_' + entry.playCount)
    }
  }

  // 快捷键入口行（关于分区）：点击打开二级弹窗查看完整快捷键速查
  @Builder
  shortcutEntryRow(): void {
    Row() {
      Text('快捷键')
        .fontSize(this.scaledFont(14))
        .fontColor(this.settingTextColor())
        .fontWeight(FontWeight.Medium)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
      Image($r('app.media.ic_public_arrow_right'))
        .width(this.scaledSize(18))
        .height(this.scaledSize(18))
        .fillColor(this.settingSubTextColor())
    }
    .width('100%')
    .constraintSize({ minWidth: 0, maxWidth: '100%' })
    .height(this.scaledSize(44))
    .alignItems(VerticalAlign.Center)
    .padding({ left: this.scaledSize(14), right: this.scaledSize(14) })
    .backgroundColor(ColorHelper.hexToRgba(this.primaryColor, 0.04))
    .borderRadius(this.scaledSize(10))
    .onClick(() => {
      this.showShortcutSheet = true
    })
  }

  // 快捷键速查二级弹窗标题（bindSheet 官方标题栏）
  @Builder
  shortcutSheetTitle(): void {
    Text('快捷键')
      .fontSize(this.scaledFont(20))
      .fontColor($r('app.color.text_primary'))
      .fontWeight(FontWeight.Bold)
      .maxLines(1)
      .width('100%')
  }

  // 快捷键速查二级弹窗（bindSheet 半模态内容）：标题移入官方标题栏，单一扁平列表不分组、铺满弹窗可滚
  @Builder
  shortcutSheetBuilder(): void {
    Column({ space: this.scaledSize(10) }) {
      Scroll() {
        Column({ space: this.scaledSize(10) }) {
          ForEach(ShortcutTable.ALL, (entry: ShortcutEntry) => {
            Row() {
              Text(entry.description)
                .fontSize(this.scaledFont(14))
                .fontColor(this.settingTextColor())
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .layoutWeight(1)
              Row({ space: this.scaledSize(4) }) {
                ForEach(entry.keys, (key: string) => {
                  Text(key)
                    .fontSize(this.scaledFont(11))
                    .fontColor(this.settingTextColor())
                    .padding({
                      left: this.scaledSize(7),
                      right: this.scaledSize(7),
                      top: this.scaledSize(3),
                      bottom: this.scaledSize(3)
                    })
                    .backgroundColor(ColorHelper.hexToRgba(this.primaryColor, 0.08))
                    .borderRadius(this.scaledSize(6))
                    .constraintSize({ minWidth: this.scaledSize(22) })
                    .textAlign(TextAlign.Center)
                }, (key: string) => key)
              }
              .flexShrink(0)
              .margin({ left: this.scaledSize(8) })
            }
            .width('100%')
            .height(this.scaledSize(44))
            .alignItems(VerticalAlign.Center)
            .padding({ left: this.scaledSize(14), right: this.scaledSize(14) })
            .backgroundColor(ColorHelper.hexToRgba(this.primaryColor, 0.04))
            .borderRadius(this.scaledSize(10))
          }, (entry: ShortcutEntry) => entry.description)
        }
        .width('100%')
        .constraintSize({ minWidth: 0, maxWidth: '100%' })
      }
      .width('100%')
      .layoutWeight(1)
      .align(Alignment.Top)
      .edgeEffect(EdgeEffect.Spring)
    }
    .width('100%')
    .height('100%')
    .constraintSize({ minWidth: 0, maxWidth: '100%' })
    .padding({
      left: this.scaledSize(18),
      right: this.scaledSize(18),
      top: this.scaledSize(16),
      bottom: this.scaledSize(12)
    })
  }

  // 检查更新行：点击调用应用市场更新服务（checkAppUpdate + showUpdateDialog）
  @Builder
  checkUpdateRow(): void {
    Row() {
      Text('检查更新')
        .fontSize(this.scaledFont(14))
        .fontColor(this.settingTextColor())
        .fontWeight(FontWeight.Medium)
        .maxLines(1)
        .flexShrink(0)
      Blank()
      Text(this.checkingUpdate ? '正在检查…' : '检查新版本')
        .fontSize(this.scaledFont(14))
        .fontColor(this.checkingUpdate ? this.settingInactiveTextColor() : this.primaryColor)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .flexShrink(1)
        .textAlign(TextAlign.End)
    }
    .width('100%')
    .constraintSize({ minWidth: 0, maxWidth: '100%' })
    .height(this.scaledSize(44))
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
  }

  // 芯片行：必须按引用传递（单对象字面量 + $$ 接收），current 携带状态属性读取，
  // 状态变化才会触发内部高亮刷新；按值多参数传递时点选后高亮不动（参数被冻结，
  // ForEach key/属性绑定都不会随状态重新求值）。
  // current 语义为与 ForEach 索引同基准（0 起）的选中下标：空间渲染模式/方向直接传 0 起值，
  // 声场/环境/美声的 1 起类型值（引擎枚举 1-4）在调用处 -1 归一，onPick 回调处再 +1 还原
  @Builder
  chipRow($$: ChipRowOptions): void {
    Row({ space: this.scaledSize(6) }) {
      ForEach($$.labels, (label: string, i: number) => {
        Text(label)
          .fontSize(this.scaledFont(12))
          .fontColor($$.current === i ? '#FFFFFF' : this.settingTextColor())
          .padding({
            left: this.scaledSize(10),
            right: this.scaledSize(10),
            top: this.scaledSize(5),
            bottom: this.scaledSize(5)
          })
          .backgroundColor($$.current === i ? this.primaryColor : ColorHelper.hexToRgba(this.primaryColor, 0.08))
          .borderRadius(this.scaledSize(15))
          .onClick(() => {
            if ($$.current !== i) {
              $$.onPick(i)
            }
          })
      }, (label: string) => label)
    }
    .width('100%')
    .justifyContent(FlexAlign.Start)
  }

  // 横向滚动芯片行：选项超过 6 个（通用变声 10 项/传统变声 7 项）时用，避免挤压换行
  @Builder
  scrollChipRow($$: ChipRowOptions): void {
    Scroll() {
      Row({ space: this.scaledSize(6) }) {
        ForEach($$.labels, (label: string, i: number) => {
          Text(label)
            .fontSize(this.scaledFont(12))
            .fontColor($$.current === i ? '#FFFFFF' : this.settingTextColor())
            .padding({
              left: this.scaledSize(10),
              right: this.scaledSize(10),
              top: this.scaledSize(5),
              bottom: this.scaledSize(5)
            })
            .backgroundColor($$.current === i ? this.primaryColor : ColorHelper.hexToRgba(this.primaryColor, 0.08))
            .borderRadius(this.scaledSize(15))
            .onClick(() => {
              if ($$.current !== i) {
                $$.onPick(i)
              }
            })
        }, (label: string) => label)
      }
      .padding({ left: this.scaledSize(2), right: this.scaledSize(2) })
    }
    .scrollable(ScrollDirection.Horizontal)
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.None)
    .width('100%')
  }

  // 通用参数滑块行：标签 + 水平滑杆 + 当前值（变速变调速度/音调等）
  @Builder
  optionSliderRow(label: string, value: number, min: number, max: number, step: number, unit: string,
    onChange: (value: number, mode: SliderChangeMode) => void): void {
    Row() {
      Text(label)
        .fontSize(this.scaledFont(12))
        .fontColor(this.settingSubTextColor())
        .width(this.scaledSize(72))
        .flexShrink(0)
      Slider({
        value: value,
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
        .sliderInteractionMode(SliderInteraction.SLIDE_AND_CLICK)
        .systemMaterial(this.styleGlassMaterial())
        .onChange((v: number, mode: SliderChangeMode) => {
          onChange(v, mode)
        })
      Text((Number.isInteger(value) ? value.toString() : value.toFixed(1)) + unit)
        .fontSize(this.scaledFont(12))
        .fontColor(this.settingTextColor())
        .width(this.scaledSize(56))
        .textAlign(TextAlign.End)
        .flexShrink(0)
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
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
        .sliderInteractionMode(SliderInteraction.SLIDE_AND_CLICK)
        .systemMaterial(this.styleGlassMaterial())
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

  // 单参数对象字面量按引用传递：this.settings.* 变化会触发 Toggle 的 isOn 刷新
  @Builder
  toggleRow(cfg: ToggleRowConfig): void {
    Row() {
      Text(cfg.label)
        .fontSize(this.scaledFont(14))
        .fontColor(this.settingTextColor())
        .fontWeight(FontWeight.Medium)
        .maxLines(1)
      Blank()
      Toggle({ type: ToggleType.Switch, isOn: cfg.isOn })
        .selectedColor(this.primaryColor)
        .systemMaterial(this.styleGlassMaterial())
        .onChange((isOn: boolean) => {
          cfg.onChange(isOn)
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

  // 材质等级设置 → hdsMaterial.MaterialLevel（预览与真机同映射）
  private previewMaterialLevelEnum(): hdsMaterial.MaterialLevel {
    if (this.settings.tabMaterialLevel === 'exquisite') {
      return hdsMaterial.MaterialLevel.EXQUISITE
    }
    if (this.settings.tabMaterialLevel === 'gentle') {
      return hdsMaterial.MaterialLevel.GENTLE
    }
    if (this.settings.tabMaterialLevel === 'smooth') {
      return hdsMaterial.MaterialLevel.SMOOTH
    }
    return hdsMaterial.MaterialLevel.ADAPTIVE
  }

  // 跟手光效颜色解析（预览与真机同逻辑）：none=关（全透明），white=白，theme=主题色
  private previewFollowLightColor(): ResourceColor {
    if (this.settings.tabLightColor === 'none') {
      return Color.Transparent
    }
    if (this.settings.tabLightColor === 'white') {
      return '#FFFFFF'
    }
    return this.primaryColor
  }

  // 玻璃标题栏：返回按钮（自带 systemMaterial，处于 Navigation 标题栏生效区内 → 出真玻璃）+ 标题。

  private getPreviewBarFloatingStyle(): HdsTabsFloatingStyle {
    // 与真机 Index 同逻辑：选「无」传全透明色显式关闭
    //（lightColor 默认值是深浅色固定光效色，传 undefined 会回落默认光效而非关闭）
    const lightColor: ResourceColor = this.previewFollowLightColor()
    // 与真机同公式：主容器宽 × 0.4（HdsTabs 宽 <600vp 小屏态时不下发，系统走默认胶囊，与真机 sm/md 行为一致）
    const hasBarWidth: boolean = this.previewBarWidthVp > 0
    const smallScreen: boolean = this.previewBarWidthVp < 600
    const barWidthVp: number = Math.round(this.previewBarWidthVp * 0.4)
    if (this.settings.tabStyle === 'immersive' && isLiquidGlassAvailable()) {
      return {
        adaptToHandedness: true,
        gradientMask: { maskColor: 'rgba(0,0,0,0)', maskHeight: 0 },
        systemMaterialEffect: {
          materialType: hdsMaterial.MaterialType.IMMERSIVE,
          materialLevel: this.previewMaterialLevelEnum(),
        },
        barOpacity: 1,
        barBottomMargin: 25,
        lightColor: lightColor,
        barWidth: (smallScreen || !hasBarWidth) ? undefined :
          { smallWidth: barWidthVp, mediumWidth: barWidthVp, largeWidth: barWidthVp },
      } as HdsTabsFloatingStyle
    }
    // 实验中：显式传 MaterialType.NONE（"无材质效果"）尝试剥掉悬浮栏默认底色，
    // 使 barBackgroundBlurStyle 磨砂档位透出生效
    return {
      adaptToHandedness: true,
      gradientMask: { maskColor: 'rgba(0,0,0,0)', maskHeight: 0 },
      systemMaterialEffect: {
        materialType: hdsMaterial.MaterialType.NONE,
        materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE,
      },
      barOpacity: 1,
      barBottomMargin: 25,
      lightColor: lightColor,
      barWidth: (smallScreen || !hasBarWidth) ? undefined :
        { smallWidth: barWidthVp, mediumWidth: barWidthVp, largeWidth: barWidthVp },
    } as HdsTabsFloatingStyle
  }

  // 顶部标题带：与首页上端完全同款的渐变模糊层（先正比例后恒定）+ 主题色渐变着色层，

  // 预览栏磨砂档位：与 Index.getBarBackgroundBlur 同一套阈值（0=NONE / ≤30=Thin / ≤50=Regular / 其他=Thick），
  // 玻璃样式下的关闭由调用点判断（返回 BlurStyle.NONE），本方法只做强度 → 档位映射
  // 当前磨砂强度归档后的滑轨档位值（0/20/40/60）：阈值与 Index.getBarBackgroundBlur 一致
  private sliderBlurValue(): number {
    const v: number = this.settings.glassBlurStrength
    if (v <= 0) {
      return 0
    }
    if (v <= 30) {
      return 20
    }
    if (v <= 50) {
      return 40
    }
    return 60
  }

  private getPreviewBarBackgroundBlur(): BlurStyle {
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

  // 玻璃样式且设备支持液态玻璃时磨砂档位关闭（由调用点判断返回 BlurStyle.NONE），radius 0 即无磨砂

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
    return isDarkThemeEffective(this.themeMode)
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
