import { motion } from '@kit.MultimodalAwarenessKit'
import { deviceInfo, SuppressWarnings, SuppressWarningsType } from '@kit.BasicServicesKit'
import Logger from '../common/utils/Logger'

const TAG: string = 'HoldingHandService'

// AppStorage 键：智感握姿开关（沿用既有 key 名，DataService 初始化与设置页开关都在用，不可改）
export const KEY_HOLDING_HAND_ENABLED: string = 'uplayer_holding_hand_enabled'

// AppStorage 键：智感握姿的滤波结果，true = 左手握持。
// 服务只广播「滤波后的握姿」这一件事，靠左还是靠右由各使用方自己决定：
//   - 首页加号：左手握持 → 靠左，其余（右手/双手/无握持/未知）→ 靠右（默认）
//   - 设置页顶部预览：左手握持 → 靠右（沿用原有映射）
export const KEY_HOLDING_HAND_LEFT: string = 'uplayer_holding_hand_left'

// 智感握姿共享监听服务
// 全应用只向系统订阅一次 holdingHandChanged：设置页预览与首页控件共用同一份滤波结果，
// 避免同一事件被多处订阅、各自滤波，导致两侧状态不一致或传感器回调重复触发。
@SuppressWarnings({ rules: [SuppressWarningsType.SYSCAP] })
export class HoldingHandService {
  private static readonly instance: HoldingHandService = new HoldingHandService()
  // 置信度滤波：连续 HOLD_STREAK_REQUIRED 帧同向才允许翻转（经验值：原值 1 太敏感，3 较稳）
  private static readonly HOLD_STREAK_REQUIRED: number = 3
  private readonly isPC: boolean = deviceInfo.deviceType === '2in1'
  private lastStatus: motion.HoldingHandStatus | undefined = undefined
  private streakCount: number = 0
  private registered: boolean = false
  private readonly callback: (status: motion.HoldingHandStatus) => void =
    (status: motion.HoldingHandStatus): void => {
      this.onStatusChanged(status)
    }

  public static getInstance(): HoldingHandService {
    return HoldingHandService.instance
  }

  // 按当前设置同步订阅状态：开关打开 + 非 PC + 能力支持 才订阅，其余一律退订并复位到默认（靠右）。
  // 页面外（EntryAbility）与设置页开关都调用本方法，重复调用安全。
  public syncWithSetting(): void {
    if (this.isPC || !this.isEnabled() || !this.isSupported()) {
      this.stop()
      return
    }
    if (this.registered) {
      return
    }
    this.reset()
    try {
      motion.on('holdingHandChanged', this.callback)
      this.registered = true
      Logger.info(TAG, 'holdingHandChanged registered')
    } catch (err) {
      Logger.warn(TAG, `holdingHandChanged register failed: ${JSON.stringify(err)}`)
    }
  }

  // 退订并复位：应用退到后台、开关关闭、能力不支持时调用
  public stop(): void {
    if (this.registered && this.isSupported()) {
      try {
        motion.off('holdingHandChanged', this.callback)
      } catch (err) {
        Logger.warn(TAG, `holdingHandChanged unregister failed: ${JSON.stringify(err)}`)
      }
    }
    this.registered = false
    this.reset()
  }

  // 当前滤波结果：true = 左手握持（供非响应式场景读取，页面侧请用 @StorageLink）
  public isLeftHandHeld(): boolean {
    return AppStorage.get<boolean>(KEY_HOLDING_HAND_LEFT) ?? false
  }

  private isEnabled(): boolean {
    return AppStorage.get<boolean>(KEY_HOLDING_HAND_ENABLED) ?? true
  }

  private isSupported(): boolean {
    return canIUse('SystemCapability.MultimodalAwareness.Motion')
  }

  private onStatusChanged(status: motion.HoldingHandStatus): void {
    // 置信度滤波：连续 N 次同向才允许翻转，避免传感器抖动引起频繁切边
    if (status === this.lastStatus) {
      this.streakCount = this.streakCount + 1
    } else {
      this.lastStatus = status
      this.streakCount = 1
    }
    if (this.streakCount < HoldingHandService.HOLD_STREAK_REQUIRED) {
      return
    }
    this.publish(status === motion.HoldingHandStatus.LEFT_HAND_HELD)
  }

  private reset(): void {
    this.lastStatus = undefined
    this.streakCount = 0
    this.publish(false)
  }

  private publish(isLeftHandHeld: boolean): void {
    if (AppStorage.get<boolean>(KEY_HOLDING_HAND_LEFT) === isLeftHandHeld) {
      return
    }
    AppStorage.setOrCreate(KEY_HOLDING_HAND_LEFT, isLeftHandHeld)
  }
}