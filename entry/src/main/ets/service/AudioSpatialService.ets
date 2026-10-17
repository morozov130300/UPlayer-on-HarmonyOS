import { audio } from '@kit.AudioKit'
import { SuppressWarnings, SuppressWarningsType } from '@kit.BasicServicesKit'
import Logger from '../common/utils/Logger'
import { AppStorageKeyConstants } from '../common/constants/AppStorageKeyConstants'

const TAG = 'AudioSpatialService'

/**
 * 系统空间音频状态服务（AudioSpatializationManager，API 18+）：
 * ArkTS 侧该接口只提供查询与订阅（isSpatializationEnabledForCurrentDevice /
 * on('spatializationEnabledChangeForCurrentDevice')），没有 setter——
 * 空间音频开关由系统设置控制，应用只能感知并展示。
 * - enabled：当前设备空间音频渲染开关状态（实时订阅系统变化）
 * - supported：当前发声设备是否具备空间音频渲染能力
 *   （AudioDeviceDescriptor.spatializationSupported，随首选输出设备变化刷新）
 * 两个状态写入 AppStorage，设置页「音效」分区只读展示。
 */
@SuppressWarnings({ rules: [SuppressWarningsType.SYSCAP] })
export class AudioSpatialService {
  private static instance: AudioSpatialService = new AudioSpatialService()
  private spatializationManager: audio.AudioSpatializationManager | undefined = undefined
  private routingManager: audio.AudioRoutingManager | undefined = undefined
  private musicRendererInfo: audio.AudioRendererInfo = {
    usage: audio.StreamUsage.STREAM_USAGE_MUSIC,
    rendererFlags: 0
  }
  private initialized: boolean = false

  public static getInstance(): AudioSpatialService {
    return AudioSpatialService.instance
  }

  // 幂等初始化（EntryAbility 启动期调用一次）
  init(): void {
    if (this.initialized) {
      return
    }
    try {
      const audioManager: audio.AudioManager = audio.getAudioManager()
      this.routingManager = audioManager.getRoutingManager()
      this.spatializationManager = audioManager.getSpatializationManager()
      this.spatializationManager.on('spatializationEnabledChangeForCurrentDevice',
        this.spatializationChangeCallback)
      this.routingManager.on('preferOutputDeviceChangeForRendererInfo', this.musicRendererInfo,
        this.preferOutputDeviceChangeCallback)
      this.initialized = true
      this.syncState()
      Logger.info(TAG, 'init succeeded')
    } catch (err) {
      Logger.error(TAG, `init failed: ${JSON.stringify(err)}`)
    }
  }

  private spatializationChangeCallback = (enabled: boolean): void => {
    AppStorage.setOrCreate<boolean>(AppStorageKeyConstants.KEY_SPATIALIZATION_ENABLED, enabled)
  }

  private preferOutputDeviceChangeCallback = (_descs: audio.AudioDeviceDescriptors): void => {
    this.syncState()
  }

  // 全量同步一次当前状态：开关 + 设备支持能力，写入 AppStorage 供设置页展示
  syncState(): void {
    try {
      if (this.spatializationManager === undefined) {
        return
      }
      const enabled: boolean = this.spatializationManager.isSpatializationEnabledForCurrentDevice()
      let supported: boolean = false
      if (this.routingManager !== undefined) {
        const descs: audio.AudioDeviceDescriptors =
          this.routingManager.getPreferredOutputDeviceForRendererInfoSync(this.musicRendererInfo)
        if (descs !== undefined && descs.length > 0) {
          const deviceSupported: boolean | undefined = descs[0].spatializationSupported
          supported = deviceSupported === true
        }
      }
      AppStorage.setOrCreate<boolean>(AppStorageKeyConstants.KEY_SPATIALIZATION_ENABLED, enabled)
      AppStorage.setOrCreate<boolean>(AppStorageKeyConstants.KEY_SPATIALIZATION_SUPPORTED, supported)
    } catch (err) {
      Logger.warn(TAG, `syncState failed: ${JSON.stringify(err)}`)
    }
  }
}
