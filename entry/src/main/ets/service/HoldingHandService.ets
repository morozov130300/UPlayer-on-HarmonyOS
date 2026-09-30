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
//
// 滤波设计（针对「未换手仍左右抽搐」）：
// holdingHandChanged 是变化型事件（系统只在状态改变时回调），历史帧计数滤波（连续 N 帧同向）
// 与该事件模型不匹配：N=1 等于零滤波（瞬态抽搐），N=3 因相邻回调必不同而几乎永不翻转（迟钝）。
// 现改为「不确定态忽略 + 时间窗确认 + 不对称回落」三级滤波：
//   1) NOT_HELD / UNKNOWN_STATUS / BOTH_HANDS_HELD 属不确定态，不允许直接切边
//      （左手握持时传感器瞬时报未握持/未识别/双手，正是抽搐根源）；
//   2) 置信翻转（LEFT/RIGHT）需经 CONFIRM_WINDOW_MS 确认窗，窗内出现反向或不确定报告即取消；
//   3) 不对称回落：已靠左时进入不确定态，持续 SOFT_FALLBACK_MS 无左手复确认才回落默认（靠右）；
//      RIGHT 仍走短确认窗快速回右，保证真换手不迟钝。
@SuppressWarnings({ rules: [SuppressWarningsType.SYSCAP] })
export class HoldingHandService {
  private static readonly instance: HoldingHandService = new HoldingHandService()
  // 置信翻转确认窗：LEFT/RIGHT 报告后经该窗口仍无回摆才真正切边（真换手约 0.5s 生效）
  private static readonly CONFIRM_WINDOW_MS: number = 500
  // 不确定态回落窗：已靠左时不确定态持续超过该时长无左手复确认，才回落默认侧（靠右）
  private static readonly SOFT_FALLBACK_MS: number = 1000
  private readonly isPC: boolean = deviceInfo.deviceType === '2in1'
  private registered: boolean = false
  // 置信翻转待定窗：待定目标侧与定时器 id。窗口内收到反向/不确定报告则取消，杜绝瞬态来回切边
  private pendingLeft: boolean | undefined = undefined
  private pendingTimerId: number = -1
  // 不确定态回落定时器：只在「已靠左」时启动，锚定在最后一次左手报告之后；
  // 窗内左手复确认即取消，超时才回落右侧（短暂识别抖动完全不动）
  private softTimerId: number = -1
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
    if (this.isPC || !this.isEnabled() || !HoldingHandService.isSupported()) {
      this.stop()
      return
    }
    if (this.registered) {
      return
    }
    // 只清滤波状态、不动已广播的贴边结果：回前台重新订阅时保留上次贴边，
    // 由系统订阅后的首个上报经确认窗自行纠正，避免「先跳右再滑回左」的抽动
    this.clearFilter()
    try {
      motion.on('holdingHandChanged', this.callback)
      this.registered = true
      Logger.info(TAG, 'holdingHandChanged registered')
    } catch (err) {
      Logger.warn(TAG, `holdingHandChanged register failed: ${JSON.stringify(err)}`)
    }
  }

  // 退订并复位到默认侧（靠右）：开关关闭 / 能力不支持 / PC 时调用
  public stop(): void {
    this.unregister()
    this.clearFilter()
    this.publish(false)
  }

  // 退订但保留当前贴边结果：退后台调用。回前台重新订阅后系统会立刻上报当前握姿，
  // 经确认窗自行纠正；若在此强制复位，每次前后台切换都会「先跳右再滑回左」抽一下
  public suspend(): void {
    this.unregister()
    this.clearFilter()
  }

  // 当前滤波结果：true = 左手握持（供非响应式场景读取，页面侧请用 @StorageLink）
  public isLeftHandHeld(): boolean {
    return AppStorage.get<boolean>(KEY_HOLDING_HAND_LEFT) ?? false
  }

  private isEnabled(): boolean {
    return AppStorage.get<boolean>(KEY_HOLDING_HAND_ENABLED) ?? true
  }

  // 公开：检测设备是否支持智感握姿（非 PC + 系统 Motion 能力可用）
  public static isSupported(): boolean {
    return deviceInfo.deviceType !== '2in1' && canIUse('SystemCapability.MultimodalAwareness.Motion')
  }

  private unregister(): void {
    if (this.registered && HoldingHandService.isSupported()) {
      try {
        motion.off('holdingHandChanged', this.callback)
      } catch (err) {
        Logger.warn(TAG, `holdingHandChanged unregister failed: ${JSON.stringify(err)}`)
      }
    }
    this.registered = false
  }

  private onStatusChanged(status: motion.HoldingHandStatus): void {
    Logger.debug(TAG, `holdingHand raw status: ${status}`)
    if (status === motion.HoldingHandStatus.LEFT_HAND_HELD) {
      this.onLeftReported()
      return
    }
    if (status === motion.HoldingHandStatus.RIGHT_HAND_HELD) {
      this.onRightReported()
      return
    }
    // NOT_HELD / BOTH_HANDS_HELD / UNKNOWN_STATUS：不确定态，不允许直接切边
    this.onSoftStatusReported()
  }

  // 左手报告：取消不确定态回落；当前不靠左时开确认窗，窗内无回摆才真正切左
  private onLeftReported(): void {
    this.clearSoftTimer()
    this.clearPendingTimer()
    if (this.isLeftHandHeld()) {
      return
    }
    this.pendingLeft = true
    this.pendingTimerId = setTimeout((): void => {
      this.pendingLeft = undefined
      this.publish(true)
    }, HoldingHandService.CONFIRM_WINDOW_MS)
  }

  // 右手报告（置信反向）：取消不确定态回落，开确认窗快速切回默认右侧
  private onRightReported(): void {
    this.clearSoftTimer()
    this.clearPendingTimer()
    if (!this.isLeftHandHeld()) {
      return
    }
    this.pendingLeft = false
    this.pendingTimerId = setTimeout((): void => {
      this.pendingLeft = undefined
      this.publish(false)
    }, HoldingHandService.CONFIRM_WINDOW_MS)
  }

  // 不确定态：取消任何待定翻转（窗口内出现回摆说明刚收到的置信报告是瞬态）；
  // 已靠左时启动回落窗——窗内左手复确认即取消，超时才回落右侧
  private onSoftStatusReported(): void {
    this.clearPendingTimer()
    if (!this.isLeftHandHeld() || this.softTimerId !== -1) {
      return
    }
    this.softTimerId = setTimeout((): void => {
      this.softTimerId = -1
      this.publish(false)
    }, HoldingHandService.SOFT_FALLBACK_MS)
  }

  private clearFilter(): void {
    this.clearPendingTimer()
    this.clearSoftTimer()
  }

  private clearPendingTimer(): void {
    if (this.pendingTimerId !== -1) {
      clearTimeout(this.pendingTimerId)
      this.pendingTimerId = -1
    }
    this.pendingLeft = undefined
  }

  private clearSoftTimer(): void {
    if (this.softTimerId !== -1) {
      clearTimeout(this.softTimerId)
      this.softTimerId = -1
    }
  }

  private publish(isLeftHandHeld: boolean): void {
    if (AppStorage.get<boolean>(KEY_HOLDING_HAND_LEFT) === isLeftHandHeld) {
      return
    }
    AppStorage.setOrCreate(KEY_HOLDING_HAND_LEFT, isLeftHandHeld)
    Logger.info(TAG, `holdingHand published: ${isLeftHandHeld}`)
  }
}
