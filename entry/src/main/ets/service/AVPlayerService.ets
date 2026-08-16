import { media } from '@kit.MediaKit'
import { fileIo as fs } from '@kit.CoreFileKit'
import { BusinessError } from '@kit.BasicServicesKit'
import { common } from '@kit.AbilityKit'
import Logger from '../common/utils/Logger'
import { AppStorageKeyConstants } from '../common/constants/AppStorageKeyConstants'
import { AVSessionController } from '../common/utils/mediautils/AVSessionController'
import { BackgroundUtil } from '../common/utils/BackgroundUtil'
import { LiveViewService } from '../service/LiveViewService'

const TAG = 'AVPlayerService'

export class AVPlayerService {
  private static instance: AVPlayerService = new AVPlayerService()
  private avPlayer: media.AVPlayer | undefined = undefined
  private context: common.UIAbilityContext | undefined = AppStorage.get<common.UIAbilityContext>(AppStorageKeyConstants.KEY_UI_ABILITY_CONTEXT)
  private currentFilePath: string = ''
  private isPrepared: boolean = false
  private pendingPlay: boolean = false
  private resolvePrepare: (() => void) | undefined = undefined
  private fadeTimer: number = -1
  private fadeStep: number = 0
  private static FADE_STEPS: number = 6
  private static FADE_INTERVAL: number = 50
  public onSongComplete: (() => void) | undefined = undefined
  private sessionController: AVSessionController = AVSessionController.getInstance()
  private liveViewService: LiveViewService = LiveViewService.getInstance()

  public static getInstance(): AVPlayerService {
    return AVPlayerService.instance
  }

  async init(): Promise<void> {
    if (this.avPlayer !== undefined) {
      return
    }
    try {
      this.avPlayer = await media.createAVPlayer()
      this.setupListeners()
    } catch (err) {
      Logger.error(TAG, `createAVPlayer failed: ${JSON.stringify(err)}`)
    }
  }

  private setupListeners(): void {
    if (this.avPlayer === undefined) {
      return
    }
    this.avPlayer.on('stateChange', (state: string): void => {
      Logger.info(TAG, `AVPlayer state: ${state}`)
      if (state === 'initialized') {
        if (this.avPlayer !== undefined) {
          this.avPlayer.prepare()
        }
      } else if (state === 'prepared') {
        this.isPrepared = true
        if (this.pendingPlay && this.avPlayer !== undefined) {
          this.avPlayer.play()
          this.pendingPlay = false
        }
        if (this.resolvePrepare !== undefined) {
          this.resolvePrepare()
          this.resolvePrepare = undefined
        }
      } else if (state === 'playing') {
        AppStorage.setOrCreate<boolean>(AppStorageKeyConstants.KEY_IS_PLAY, true)
        this.sessionController.setPlayState(true)
        this.startBackground()
        this.liveViewService.startLiveView()
      } else if (state === 'paused') {
        AppStorage.setOrCreate<boolean>(AppStorageKeyConstants.KEY_IS_PLAY, false)
        this.sessionController.setPlayState(false)
        this.liveViewService.updateLiveView()
      } else if (state === 'stopped') {
        AppStorage.setOrCreate<boolean>(AppStorageKeyConstants.KEY_IS_PLAY, false)
        this.isPrepared = false
        this.sessionController.setPlayState(false)
      } else if (state === 'completed') {
        AppStorage.setOrCreate<boolean>(AppStorageKeyConstants.KEY_IS_PLAY, false)
        this.sessionController.setPlayState(false)
        this.liveViewService.updateLiveView()
        if (this.onSongComplete !== undefined) {
          this.onSongComplete()
        }
      } else if (state === 'released') {
        this.isPrepared = false
      }
    })

    this.avPlayer.on('timeUpdate', (time: number): void => {
      AppStorage.setOrCreate(AppStorageKeyConstants.KEY_PROGRESS, time)
      const totalMs: number = AppStorage.get<number>(AppStorageKeyConstants.KEY_TOTAL_MS_TIME) ?? 0
      if (totalMs > 0) {
        AppStorage.setOrCreate(AppStorageKeyConstants.KEY_CURRENT_TIME, this.formatTime(time))
      }
      this.sessionController.setProgressState(time)
    })

    this.avPlayer.on('durationUpdate', (duration: number): void => {
      AppStorage.setOrCreate(AppStorageKeyConstants.KEY_TOTAL_MS_TIME, duration)
      AppStorage.setOrCreate(AppStorageKeyConstants.KEY_PROGRESS_MAX, duration)
      AppStorage.setOrCreate(AppStorageKeyConstants.KEY_TOTAL_TIME, this.formatTime(duration))
    })

    this.avPlayer.on('error', (err: BusinessError): void => {
      Logger.error(TAG, `AVPlayer error: code=${err.code}, message=${err.message}`)
      AppStorage.setOrCreate<boolean>(AppStorageKeyConstants.KEY_IS_PLAY, false)
      this.pendingPlay = false
      if (this.resolvePrepare !== undefined) {
        this.resolvePrepare()
        this.resolvePrepare = undefined
      }
    })
  }

  async play(filePath: string): Promise<void> {
    await this.init()
    if (this.avPlayer === undefined) {
      return
    }
    if (this.currentFilePath === filePath && this.isPrepared) {
      this.avPlayer.play()
      this.sessionController.setAVMetadata()
      return
    }
    this.currentFilePath = filePath
    this.isPrepared = false
    try {
      const curState: string = this.avPlayer.state
      if (curState === 'playing' || curState === 'paused') {
        await this.avPlayer.stop()
      }
      if (curState !== 'idle') {
        await this.avPlayer.reset()
      }
      let file: fs.File = fs.openSync(filePath, fs.OpenMode.READ_ONLY)
      let avFd: media.AVFileDescriptor = { fd: file.fd, offset: 0, length: 0 }
      this.avPlayer.fdSrc = avFd
      this.pendingPlay = true
      this.sessionController.setAVMetadata()
      await new Promise<void>((resolve: Function): void => {
        this.resolvePrepare = resolve as (() => void)
      })
    } catch (err) {
      Logger.error(TAG, `play failed: ${JSON.stringify(err)}`)
      this.pendingPlay = false
    }
  }

  resume(): void {
    if (this.avPlayer === undefined) {
      return
    }
    try {
      const fadeInOut: boolean = AppStorage.get<boolean>('uplayer_fade_in_out') ?? false
      if (fadeInOut) {
        this.avPlayer.setVolume(0)
        this.avPlayer.play()
        this.fadeIn()
      } else {
        this.avPlayer.play()
      }
      this.sessionController.setPlayState(true)
    } catch (err) {
      Logger.error(TAG, `resume failed: ${JSON.stringify(err)}`)
    }
  }

  pause(): void {
    if (this.avPlayer === undefined) {
      return
    }
    try {
      const fadeInOut: boolean = AppStorage.get<boolean>('uplayer_fade_in_out') ?? false
      if (fadeInOut) {
        this.fadeOut()
      } else {
        this.avPlayer.pause()
      }
      this.sessionController.setPlayState(false)
    } catch (err) {
      Logger.error(TAG, `pause failed: ${JSON.stringify(err)}`)
    }
  }

  private fadeIn(): void {
    this.stopFade()
    this.fadeStep = 0
    const targetVol: number = AppStorage.get<number>(AppStorageKeyConstants.KEY_CURRENT_VOLUME) ?? 1
    if (targetVol === 0) {
      return
    }
    this.fadeTimer = setInterval(() => {
      this.fadeStep++
      const vol: number = Math.min((this.fadeStep / AVPlayerService.FADE_STEPS) * targetVol, targetVol)
      if (this.avPlayer !== undefined) {
        this.avPlayer.setVolume(vol)
      }
      if (this.fadeStep >= AVPlayerService.FADE_STEPS) {
        this.stopFade()
      }
    }, AVPlayerService.FADE_INTERVAL)
  }

  private fadeOut(): void {
    this.stopFade()
    const startVol: number = AppStorage.get<number>(AppStorageKeyConstants.KEY_CURRENT_VOLUME) ?? 1
    this.fadeStep = 0
    this.fadeTimer = setInterval(() => {
      this.fadeStep++
      const vol: number = Math.max(startVol - (this.fadeStep / AVPlayerService.FADE_STEPS) * startVol, 0)
      if (this.avPlayer !== undefined) {
        this.avPlayer.setVolume(vol)
      }
      if (this.fadeStep >= AVPlayerService.FADE_STEPS) {
        this.stopFade()
        if (this.avPlayer !== undefined) {
          this.avPlayer.pause()
        }
      }
    }, AVPlayerService.FADE_INTERVAL)
  }

  private stopFade(): void {
    if (this.fadeTimer !== -1) {
      clearInterval(this.fadeTimer)
      this.fadeTimer = -1
    }
  }

  private startBackground(): void {
    const ctx: common.UIAbilityContext | undefined = AppStorage.get<common.UIAbilityContext>(AppStorageKeyConstants.KEY_UI_ABILITY_CONTEXT)
    if (ctx !== undefined) {
      BackgroundUtil.startContinuousTask(ctx)
    }
  }

  async stop(): Promise<void> {
    if (this.avPlayer === undefined) {
      return
    }
    try {
      await this.avPlayer.stop()
      this.currentFilePath = ''
      this.isPrepared = false
      this.sessionController.setPlayState(false)
    } catch (err) {
      Logger.error(TAG, `stop failed: ${JSON.stringify(err)}`)
    }
  }

  async seek(timeMs: number): Promise<void> {
    if (this.avPlayer === undefined) {
      return
    }
    try {
      this.avPlayer.seek(timeMs)
    } catch (err) {
      Logger.error(TAG, `seek failed: ${JSON.stringify(err)}`)
    }
  }

  setVolume(vol: number): void {
    if (this.avPlayer === undefined) {
      return
    }
    try {
      this.avPlayer.setVolume(vol)
    } catch (err) {
      Logger.error(TAG, `setVolume failed: ${JSON.stringify(err)}`)
    }
  }

  setSpeed(speed: number): void {
    if (this.avPlayer === undefined) {
      return
    }
    try {
      this.avPlayer.setPlaybackRate(speed)
    } catch (err) {
      Logger.error(TAG, `setPlaybackRate failed: ${JSON.stringify(err)}`)
    }
  }

  async release(): Promise<void> {
    if (this.avPlayer === undefined) {
      return
    }
    try {
      await this.avPlayer.release()
      this.avPlayer = undefined
      this.currentFilePath = ''
      this.isPrepared = false
    } catch (err) {
      Logger.error(TAG, `release failed: ${JSON.stringify(err)}`)
    }
  }

  private formatTime(ms: number): string {
    const totalSec: number = Math.floor(ms / 1000)
    const min: number = Math.floor(totalSec / 60)
    const sec: number = totalSec % 60
    const minStr: string = min < 10 ? '0' + min : '' + min
    const secStr: string = sec < 10 ? '0' + sec : '' + sec
    return minStr + ':' + secStr
  }
}
