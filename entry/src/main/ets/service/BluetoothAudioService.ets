import { a2dp, access, baseProfile, connection } from '@kit.ConnectivityKit'
import { abilityAccessCtrl, common, Permissions } from '@kit.AbilityKit'
import Logger from '../common/utils/Logger'
import { AppStorageKeyConstants } from '../common/constants/AppStorageKeyConstants'

const TAG = 'BluetoothAudioService'

/**
 * 蓝牙 A2DP 音频状态服务（三方应用只读）：
 * - A2DP Source Profile（createA2dpSrcProfile）：查询已连接蓝牙音频设备与播放状态
 * - baseProfile.on('connectionStateChange')：耳机/音箱连接断开实时刷新
 * - access.on('stateChange')：蓝牙开关状态变化刷新
 * - 需要用户授权 ohos.permission.ACCESS_BLUETOOTH（首次打开「更多」面板时弹窗申请）
 * - 编解码选择/码率协商为系统应用接口，三方不可用，本服务仅做状态查询与展示
 */
export class BluetoothAudioService {
  private static instance: BluetoothAudioService = new BluetoothAudioService()
  private profile: a2dp.A2dpSourceProfile | undefined = undefined
  private permissionGranted: boolean = false
  private initialized: boolean = false
  private supported: boolean = false
  private btEnabled: boolean = false
  private connected: boolean = false
  private playing: boolean = false
  private deviceName: string = ''
  private refreshing: boolean = false

  public static getInstance(): BluetoothAudioService {
    return BluetoothAudioService.instance
  }

  // ─── 查询接口（「更多」面板「蓝牙音频」行使用） ───

  isPermissionGranted(): boolean {
    return this.permissionGranted
  }

  // 设备是否支持 A2DP（capability 801 / profile 创建失败时为 false）
  isSupported(): boolean {
    return this.supported
  }

  isBluetoothEnabled(): boolean {
    return this.btEnabled
  }

  isConnectedDevice(): boolean {
    return this.connected
  }

  getDeviceName(): string {
    return this.deviceName
  }

  isPlaying(): boolean {
    return this.playing
  }

  // ─── 授权 + 初始化（打开「更多」面板时调用；拒绝后点「蓝牙音频」行重试） ───

  async ensurePermissionAndInit(context: common.UIAbilityContext | undefined): Promise<void> {
    if (this.permissionGranted) {
      if (this.initialized) {
        this.refresh()
      }
      return
    }
    if (context === undefined) {
      Logger.warn(TAG, 'ensurePermissionAndInit skipped: no UIAbilityContext')
      return
    }
    try {
      const atManager: abilityAccessCtrl.AtManager = abilityAccessCtrl.createAtManager()
      const permissions: Array<Permissions> = ['ohos.permission.ACCESS_BLUETOOTH']
      const result = await atManager.requestPermissionsFromUser(context, permissions)
      this.permissionGranted = result.authResults.length > 0 && result.authResults[0] === 0
      if (!this.permissionGranted) {
        Logger.warn(TAG, 'ACCESS_BLUETOOTH denied by user')
        this.bumpRevision()
        return
      }
      Logger.info(TAG, 'ACCESS_BLUETOOTH granted')
      this.initInternal()
    } catch (err) {
      Logger.error(TAG, `requestPermissionsFromUser failed: ${JSON.stringify(err)}`)
    }
  }

  // ─── 内部实现 ───

  private initInternal(): void {
    if (this.initialized) {
      return
    }
    try {
      this.profile = a2dp.createA2dpSrcProfile()
      this.supported = true
    } catch (err) {
      // 801 capability not supported：设备无蓝牙/A2DP 能力
      this.supported = false
      Logger.warn(TAG, `createA2dpSrcProfile failed: ${JSON.stringify(err)}`)
      this.bumpRevision()
      return
    }
    try {
      this.profile.on('connectionStateChange', (param: baseProfile.StateChangeParam): void => {
        Logger.info(TAG, `a2dp connection state change device=${param.deviceId} state=${param.state}`)
        this.refresh()
      })
    } catch (err) {
      Logger.error(TAG, `subscribe connectionStateChange failed: ${JSON.stringify(err)}`)
    }
    try {
      access.on('stateChange', (state: access.BluetoothState): void => {
        Logger.info(TAG, `bluetooth state change: ${state}`)
        this.refresh()
      })
    } catch (err) {
      Logger.error(TAG, `subscribe bluetooth stateChange failed: ${JSON.stringify(err)}`)
    }
    this.initialized = true
    this.refresh()
  }

  // 汇总一次蓝牙开关 + A2DP 连接设备 + 播放状态，完成后 bump revision 通知 UI
  private refresh(): void {
    if (this.refreshing) {
      return
    }
    this.refreshing = true
    try {
      this.btEnabled = access.getState() === access.BluetoothState.STATE_ON
    } catch (err) {
      this.btEnabled = false
    }
    this.connected = false
    this.playing = false
    this.deviceName = ''
    if (this.profile !== undefined && this.btEnabled) {
      try {
        const devices: Array<string> = this.profile.getConnectedDevices()
        if (devices.length > 0) {
          const deviceId: string = devices[0]
          this.connected = true
          try {
            const name: string = connection.getRemoteDeviceName(deviceId)
            this.deviceName = name.length > 0 ? name : deviceId
          } catch (err) {
            // 名称获取失败（未配对名/服务异常）退回设备地址
            this.deviceName = deviceId
          }
          try {
            this.playing = this.profile.getPlayingState(deviceId) === a2dp.PlayingState.STATE_PLAYING
          } catch (err) {
            this.playing = false
          }
        }
      } catch (err) {
        Logger.warn(TAG, `getConnectedDevices failed: ${JSON.stringify(err)}`)
      }
    }
    this.refreshing = false
    this.bumpRevision()
  }

  private bumpRevision(): void {
    const revision: number = AppStorage.get<number>(AppStorageKeyConstants.KEY_BLUETOOTH_AUDIO_REVISION) ?? 0
    AppStorage.setOrCreate<number>(AppStorageKeyConstants.KEY_BLUETOOTH_AUDIO_REVISION, revision + 1)
  }
}
