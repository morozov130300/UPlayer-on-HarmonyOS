import { audio } from '@kit.AudioKit'
import { BusinessError, SuppressWarnings, SuppressWarningsType } from '@kit.BasicServicesKit'
import Logger from '../common/utils/Logger'
import { AppStorageKeyConstants } from '../common/constants/AppStorageKeyConstants'
import { AVPlayerService } from './AVPlayerService'
import { WindowUtil } from '../common/utils/WindowUtil'

const TAG = 'AudioRoutingService'

// 会被拔除/断开的可切换输出设备类型（扬声器/听筒本身不会"断开"，不计入）
const OUTPUT_PLUGGABLE_TYPES: number[] = [
  audio.DeviceType.WIRED_HEADSET,
  audio.DeviceType.WIRED_HEADPHONES,
  audio.DeviceType.BLUETOOTH_SCO,
  audio.DeviceType.BLUETOOTH_A2DP,
  audio.DeviceType.USB_HEADSET,
  audio.DeviceType.DISPLAY_PORT,
  audio.DeviceType.HDMI,
  audio.DeviceType.LINE_DIGITAL,
  audio.DeviceType.HEARING_AID,
  audio.DeviceType.NEARLINK
]

/**
 * 音频输出设备路由服务（全部走系统接口）：
 * - AudioRoutingManager.on('deviceChange', OUTPUT_DEVICES_FLAG)：监听耳机/蓝牙等设备断开，
 *   按设置「耳机断开时继续播放」决定自动暂停+提示，或交由系统自动切回扬声器继续播
 * - AudioRoutingManager.on('availableDeviceChange')：可选设备变化时通知「更多」面板刷新
 * - AudioDeviceEnhanceManager（API 26）：应用级输出设备选择（selectOutputDevice），
 *   系统不支持增强路由时 isEnhancedRoutingSupported() 返回 false，调用方应降级提示
 */
@SuppressWarnings({rules: [SuppressWarningsType.SYSCAP]})
export class AudioRoutingService {
  private static instance: AudioRoutingService = new AudioRoutingService()
  private audioManager: audio.AudioManager | undefined = undefined
  private routingManager: audio.AudioRoutingManager | undefined = undefined
  private musicRendererInfo: audio.AudioRendererInfo | undefined = undefined
  private initialized: boolean = false

  public static getInstance(): AudioRoutingService {
    return AudioRoutingService.instance
  }

  // 幂等初始化（EntryAbility 启动期调用一次）
  init(): void {
    if (this.initialized) {
      return
    }
    try {
      this.audioManager = audio.getAudioManager()
      this.routingManager = this.audioManager.getRoutingManager()
      this.routingManager.on('deviceChange', audio.DeviceFlag.OUTPUT_DEVICES_FLAG,
        this.deviceChangeCallback)
      this.routingManager.on('availableDeviceChange', audio.DeviceUsage.MEDIA_OUTPUT_DEVICES,
        this.availableDeviceChangeCallback)
      // 首选输出设备变化（含用户在系统音量面板切换设备）→ 刷新「更多」面板设备名
      this.musicRendererInfo = {
        usage: audio.StreamUsage.STREAM_USAGE_MUSIC,
        rendererFlags: 0
      }
      this.routingManager.on('preferOutputDeviceChangeForRendererInfo', this.musicRendererInfo,
        this.preferOutputDeviceChangeCallback)
      this.initialized = true
      Logger.info(TAG, 'init succeeded')
    } catch (err) {
      Logger.error(TAG, `init failed: ${JSON.stringify(err)}`)
    }
  }

  private deviceChangeCallback = (action: audio.DeviceChangeAction): void => {
    // 只在"可拔设备断开"时处理（连接事件、扬声器/听筒变化均忽略）
    if (action.type !== audio.DeviceChangeType.DISCONNECT) {
      return
    }
    const changed: audio.AudioDeviceDescriptors = action.deviceDescriptors
    const isPluggable: boolean = changed.some((d: audio.AudioDeviceDescriptor): boolean => {
      return OUTPUT_PLUGGABLE_TYPES.includes(d.deviceType)
    })
    if (!isPluggable) {
      return
    }
    const continuePlay: boolean = AppStorage.get<boolean>(AppStorageKeyConstants.KEY_CONTINUE_PLAY_ON_UNPLUG) ?? false
    if (continuePlay) {
      // 用户选择继续播放：系统会自动把路由切回扬声器，无需干预
      return
    }
    const isPlaying: boolean = AppStorage.get<boolean>(AppStorageKeyConstants.KEY_IS_PLAY) ?? false
    if (!isPlaying) {
      return
    }
    // 正在播放且关闭了「断开时继续播放」→ 暂停并提示
    AVPlayerService.getInstance().pause()
    this.showToast('输出设备已断开，播放已暂停')
  }

  private availableDeviceChangeCallback = (action: audio.DeviceChangeAction): void => {
    const revision: number = AppStorage.get<number>(AppStorageKeyConstants.KEY_OUTPUT_DEVICE_REVISION) ?? 0
    AppStorage.setOrCreate<number>(AppStorageKeyConstants.KEY_OUTPUT_DEVICE_REVISION, revision + 1)
  }

  private preferOutputDeviceChangeCallback = (desc: audio.AudioDeviceDescriptors): void => {
    this.bumpRevision()
  }

  // ─── 「更多」面板：输出设备选择（系统增强路由，API 26+） ───

  // 系统是否支持应用级输出设备选择（不支持时调用 selectOutputDevice 不生效）
  isEnhancedRoutingSupported(): boolean {
    try {
      const manager: audio.AudioManager | undefined = this.audioManager ?? audio.getAudioManager()
      return manager.getDeviceEnhanceManager().isEnhancedRoutingSupported()
    } catch (err) {
      return false
    }
  }

  // 当前首选输出设备（MUSIC 场景），无法获取时返回「系统默认」
  getCurrentOutputDeviceLabel(): string {
    try {
      if (this.routingManager === undefined) {
        return '系统默认'
      }
      const info: audio.AudioRendererInfo = this.musicRendererInfo ?? {
        usage: audio.StreamUsage.STREAM_USAGE_MUSIC,
        rendererFlags: 0
      }
      const descs: audio.AudioDeviceDescriptors =
        this.routingManager.getPreferredOutputDeviceForRendererInfoSync(info)
      if (descs !== undefined && descs.length > 0) {
        return this.getDeviceLabel(descs[0])
      }
      return '系统默认'
    } catch (err) {
      Logger.warn(TAG, `getCurrentOutputDeviceLabel failed: ${JSON.stringify(err)}`)
      return '系统默认'
    }
  }

  // 当前可用的媒体输出设备列表（系统接口，设备列表/名称均由系统提供）
  getAvailableOutputDevices(): audio.AudioDeviceDescriptors {
    try {
      const manager: audio.AudioRoutingManager | undefined = this.routingManager ??
        audio.getAudioManager().getRoutingManager()
      return manager.getAvailableDevices(audio.DeviceUsage.MEDIA_OUTPUT_DEVICES)
    } catch (err) {
      Logger.warn(TAG, `getAvailableOutputDevices failed: ${JSON.stringify(err)}`)
      return []
    }
  }

  // 应用级输出设备选择（AudioDeviceEnhanceManager，API 26+）
  selectOutputDevice(device: audio.AudioDeviceDescriptor): void {
    try {
      this.audioManager = audio.getAudioManager()
      this.audioManager.getDeviceEnhanceManager().selectOutputDevice(device)
        .then((): void => {
          this.bumpRevision()
          this.showToast(`已切换输出设备：${this.getDeviceLabel(device)}`)
        })
        .catch((err: BusinessError): void => {
          Logger.error(TAG, `selectOutputDevice failed: code=${err.code}, ${err.message}`)
        })
    } catch (err) {
      Logger.error(TAG, `selectOutputDevice error: ${JSON.stringify(err)}`)
    }
  }

  // 设备显示名：优先系统设备名，取不到（如蓝牙未授权）时退回类型中文标签
  getDeviceLabel(device: audio.AudioDeviceDescriptor): string {
    try {
      const name: string = device.name
      if (name !== undefined && name.length > 0 && name !== 'INVALID') {
        return name
      }
    } catch (err) {
      // name 访问失败（蓝牙设备无权限等）→ 走类型标签
    }
    return this.deviceTypeLabel(device.deviceType)
  }

  private deviceTypeLabel(type: number): string {
    switch (type) {
      case audio.DeviceType.EARPIECE:
        return '听筒'
      case audio.DeviceType.SPEAKER:
        return '扬声器'
      case audio.DeviceType.WIRED_HEADSET:
        return '有线耳机'
      case audio.DeviceType.WIRED_HEADPHONES:
        return '有线耳塞'
      case audio.DeviceType.BLUETOOTH_SCO:
      case audio.DeviceType.BLUETOOTH_A2DP:
        return '蓝牙设备'
      case audio.DeviceType.USB_HEADSET:
        return 'USB 耳机'
      case audio.DeviceType.DISPLAY_PORT:
        return 'HDMI/DP 输出'
      case audio.DeviceType.HDMI:
        return 'HDMI 设备'
      case audio.DeviceType.LINE_DIGITAL:
        return '数字音频输出'
      case audio.DeviceType.REMOTE_CAST:
        return '投送中'
      case audio.DeviceType.REMOTE_DAUDIO:
        return '分布式设备'
      case audio.DeviceType.HEARING_AID:
        return '助听器'
      case audio.DeviceType.NEARLINK:
        return '星闪设备'
      case audio.DeviceType.DEFAULT:
        return '系统默认'
      default:
        return '未知设备'
    }
  }

  private bumpRevision(): void {
    const revision: number = AppStorage.get<number>(AppStorageKeyConstants.KEY_OUTPUT_DEVICE_REVISION) ?? 0
    AppStorage.setOrCreate<number>(AppStorageKeyConstants.KEY_OUTPUT_DEVICE_REVISION, revision + 1)
  }

  private showToast(message: string): void {
    try {
      const windowUtil: WindowUtil | undefined = AppStorage.get<WindowUtil>(AppStorageKeyConstants.KEY_WINDOW_UTIL)
      windowUtil?.getUiContext()?.getPromptAction()?.showToast({ message })
    } catch (err) {
      Logger.warn(TAG, `showToast failed: ${JSON.stringify(err)}`)
    }
  }
}