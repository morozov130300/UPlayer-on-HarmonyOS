import { audio } from '@kit.AudioKit'
import { BusinessError } from '@kit.BasicServicesKit'
import Logger from '../common/utils/Logger'
import { AppStorageKeyConstants } from '../common/constants/AppStorageKeyConstants'

const TAG = 'AudioFocusService'

/**
 * 音频焦点策略服务：控制「系统通知/提示音响起时是否压低本应用音量」。
 *
 * 系统默认焦点策略下，通知音（STREAM_USAGE_NOTIFICATION）等流启动时会对正在播放的音乐流
 * 执行 duck（压低到约 20%），结束后再 unduck。该行为由系统按流类型决策，应用侧没有「关闭 duck」的开关；
 * 官方给出的绕开方式是 AudioSession 并发策略：
 *
 *   - CONCURRENCY_MIX_WITH_OTHERS：与其它音频流并发播放。官方明确该模式
 *     「在本应用请求焦点时，以及其它应用后续请求焦点时，均生效」，
 *     因此其它应用（含系统通知音）后续抢占焦点时不会压低/暂停本应用。
 *   - CONCURRENCY_DUCK_OTHERS / CONCURRENCY_PAUSE_OTHERS：只在自身请求焦点时生效，
 *     其它应用后续请求焦点时以对方策略为准，达不到本诉求。
 *
 * 代价：并发模式下其它应用播放音频时本应用不会被暂停（双方同时出声）。
 * 因此设置项默认关闭，由用户在「播放」设置中自行开启。
 */
export class AudioFocusService {
  private static instance: AudioFocusService = new AudioFocusService()
  private sessionManager: audio.AudioSessionManager | undefined = undefined

  public static getInstance(): AudioFocusService {
    return AudioFocusService.instance
  }

  private getSessionManager(): audio.AudioSessionManager | undefined {
    if (this.sessionManager !== undefined) {
      return this.sessionManager
    }
    try {
      this.sessionManager = audio.getAudioManager().getSessionManager()
      return this.sessionManager
    } catch (err) {
      Logger.error(TAG, `getSessionManager failed: ${JSON.stringify(err)}`)
      return undefined
    }
  }

  // 按设置开关激活/去激活「并发播放」AudioSession。
  // 关闭时去激活，回到系统默认焦点策略（通知音响起会压低本应用音量）。
  applyIgnoreNotificationDuck(enabled: boolean): void {
    const manager: audio.AudioSessionManager | undefined = this.getSessionManager()
    if (manager === undefined) {
      return
    }
    if (enabled) {
      const strategy: audio.AudioSessionStrategy = {
        concurrencyMode: audio.AudioConcurrencyMode.CONCURRENCY_MIX_WITH_OTHERS
      }
      manager.activateAudioSession(strategy).then((): void => {
        Logger.info(TAG, 'audio session activated: MIX_WITH_OTHERS')
      }).catch((err: BusinessError): void => {
        Logger.error(TAG, `activateAudioSession failed: code=${err.code}, message=${err.message}`)
      })
    } else {
      manager.deactivateAudioSession().then((): void => {
        Logger.info(TAG, 'audio session deactivated')
      }).catch((err: BusinessError): void => {
        Logger.error(TAG, `deactivateAudioSession failed: code=${err.code}, message=${err.message}`)
      })
    }
  }

  // AudioSession 若在「已激活但无音频流运行」状态持续一段时间，会被系统超时去激活。
  // 因此每次开始播放前按当前设置补一次激活，保证通知音到达时并发策略仍然有效。
  ensureStrategy(): void {
    if (AppStorage.get<boolean>(AppStorageKeyConstants.KEY_IGNORE_NOTIFICATION_DUCK) !== true) {
      return
    }
    const manager: audio.AudioSessionManager | undefined = this.getSessionManager()
    if (manager === undefined) {
      return
    }
    let activated: boolean = false
    try {
      activated = manager.isAudioSessionActivated()
    } catch (err) {
      Logger.warn(TAG, `isAudioSessionActivated failed: ${JSON.stringify(err)}`)
    }
    if (activated) {
      return
    }
    this.applyIgnoreNotificationDuck(true)
  }
}
