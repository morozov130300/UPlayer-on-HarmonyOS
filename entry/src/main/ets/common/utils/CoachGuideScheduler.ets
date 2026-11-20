// 聚光引导弹出编排：已完成标记检查 + 宿主忙碌重试（最多 6 次）+ 延迟弹出定时器。
// HomeContent / PlaylistContent 的引导弹出流程同构，收口到此处避免两页各维护一份；
// 页面只提供完成标记 key、忙碌守卫与 begin 回调（buildSteps + 挂载浮层）。
import { SettingsStore } from './SettingsStore'

// 引导走完/跳过后的提示文案：告知重看路径。两页共用同一句，避免文案分叉
export const GUIDE_REPLAY_TIP: string = '您可在「设置 - 关于 - 重新查看引导」中再次查看本引导'

export class CoachGuideScheduler {
  private timer: number = -1
  private retries: number = 0

  // 取消待弹的定时器（页面 aboutToDisappear 时调用，防止销毁后回调）
  cancel(): void {
    if (this.timer >= 0) {
      clearTimeout(this.timer)
      this.timer = -1
    }
  }

  // 重试计数归零（设置-关于「重新查看引导」重弹前调用）
  resetRetries(): void {
    this.retries = 0
  }

  schedule(doneKey: string, delayMs: number, isBusy: () => boolean, begin: () => void): void {
    if (SettingsStore.getInstance().get(doneKey, '') === '1') {
      return
    }
    this.cancel()
    this.timer = setTimeout((): void => {
      this.timer = -1
      if (isBusy()) {
        if (this.retries < 6) {
          this.retries++
          this.schedule(doneKey, delayMs, isBusy, begin)
        }
        return
      }
      begin()
    }, delayMs)
  }
}
