import { audio } from '@kit.AudioKit'
import { BusinessError } from '@kit.BasicServicesKit'
import Logger from '../common/utils/Logger'
import { AppStorageKeyConstants } from '../common/constants/AppStorageKeyConstants'

const TAG = 'AudioFocusService'

/**
 * 音频焦点策略服务：控制「是否与其它音频并发播放」——统一开关同时涵盖
 * 「与其它应用音频同时播放」与「系统通知/提示音不压低本应用音量」两种效果。
 *
 * 系统默认焦点策略下，通知音（STREAM_USAGE_NOTIFICATION）等流启动时会对正在播放的音乐流
 * 执行 duck（压低到约 20%），结束后再 unduck；其它应用音频流启动时会暂停/停止本应用。
 * AudioSession 只提供一个全局 concurrencyMode、不区分对方流类型，因此两种效果无法独立控制、
 * 共用同一开关；官方给出的实现方式是 AudioSession 并发策略：
 *
 *   - CONCURRENCY_MIX_WITH_OTHERS：与其它音频流并发播放。官方明确该模式
 *     「在本应用请求焦点时，以及其它应用后续请求焦点时，均生效」，
 *     因此其它应用（含系统通知音）后续抢占焦点时不会压低/暂停本应用。
 *   - CONCURRENCY_DUCK_OTHERS / CONCURRENCY_PAUSE_OTHERS：只在自身请求焦点时生效，
 *     其它应用后续请求焦点时以对方策略为准，达不到本诉求。
 *
 * 设置项默认关闭，由用户在「播放」设置中自行开启。
 */
export class AudioFocusService {
  private static instance: AudioFocusService = new AudioFocusService()
  private sessionManager: audio.AudioSessionManager | undefined = undefined
  private listenersRegistered: boolean = false

  public static getInstance(): AudioFocusService {
    return AudioFocusService.instance
  }

  // 幂等注册会话事件监听（EntryAbility 启动期调用一次）：
  // - audioSessionDeactivated：会话被系统去激活（如「已激活但无音频流运行」超时）时回调，
  //   仅记录日志；下次播放前 ensureStrategy 会按需补激活，无需在此即时重试
  // - audioSessionStateChanged：会话焦点状态变更（API 20）跟踪
  init(): void {
    if (this.listenersRegistered) {
      return
    }
    const manager: audio.AudioSessionManager | undefined = this.getSessionManager()
    if (manager === undefined) {
      return
    }
    try {
      manager.on('audioSessionDeactivated', this.sessionDeactivatedCallback)
      manager.on('audioSessionStateChanged', this.sessionStateChangedCallback)
      this.listenersRegistered = true
      Logger.info(TAG, 'session event listeners registered')
    } catch (err) {
      Logger.error(TAG, `register session listeners failed: ${JSON.stringify(err)}`)
    }
  }

  private sessionDeactivatedCallback = (event: audio.AudioSessionDeactivatedEvent): void => {
    Logger.info(TAG, `audio session deactivated by system: ${JSON.stringify(event)}`)
  }

  private sessionStateChangedCallback = (event: audio.AudioSessionStateChangedEvent): void => {
    Logger.info(TAG, `audio session state changed: ${JSON.stringify(event)}`)
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
  // 关闭时去激活，回到系统默认焦点策略（通知音响起会压低本应用音量、其它应用音频会暂停本应用）。
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
  // 因此每次开始播放前按当前设置补一次激活，保证「与其他音频同时播放」的并发策略在整个播放期间仍然有效。
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
