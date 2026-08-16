import { media } from '@kit.MediaKit'
import { fileIo as fs } from '@kit.CoreFileKit'
import { BusinessError } from '@kit.BasicServicesKit'
import { common } from '@kit.AbilityKit'
import { audio } from '@kit.AudioKit'
import Logger from '../common/utils/Logger'
import { AppStorageKeyConstants } from '../common/constants/AppStorageKeyConstants'
import { AVSessionController } from '../common/utils/mediautils/AVSessionController'
import { BackgroundUtil } from '../common/utils/BackgroundUtil'
import { LiveViewService } from '../service/LiveViewService'
import nativeAudio from 'libuplayer.so'
import { SongInfo } from '../model/SongInfo'

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
  private interruptedWhilePlaying: boolean = false
  public onSongComplete: (() => void) | undefined = undefined
  private sessionController: AVSessionController = AVSessionController.getInstance()
  private liveViewService: LiveViewService = LiveViewService.getInstance()
  private nativeMode: boolean = false
  private equalizerEnabled: boolean = false
  private equalizerBands: number[] = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
  private nativeProgressTimer: number = -1
  private nativeStartupTimer: number = -1
  private playRequestId: number = 0
  private nativeRequestActive: boolean = false

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
      if (this.nativeRequestActive || this.nativeMode) {
        if (state === 'released') {
          this.isPrepared = false
        }
        return
      }
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
        this.interruptedWhilePlaying = false
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
      if (this.nativeRequestActive || this.nativeMode) {
        return
      }
      AppStorage.setOrCreate(AppStorageKeyConstants.KEY_PROGRESS, time)
      const totalMs: number = AppStorage.get<number>(AppStorageKeyConstants.KEY_TOTAL_MS_TIME) ?? 0
      if (totalMs > 0) {
        AppStorage.setOrCreate(AppStorageKeyConstants.KEY_CURRENT_TIME, this.formatTime(time))
      }
      this.sessionController.setProgressState(time)
    })

    this.avPlayer.on('durationUpdate', (duration: number): void => {
      if (this.nativeRequestActive || this.nativeMode) {
        return
      }
      AppStorage.setOrCreate(AppStorageKeyConstants.KEY_TOTAL_MS_TIME, duration)
      AppStorage.setOrCreate(AppStorageKeyConstants.KEY_PROGRESS_MAX, duration)
      AppStorage.setOrCreate(AppStorageKeyConstants.KEY_TOTAL_TIME, this.formatTime(duration))
    })

    this.avPlayer.on('error', (err: BusinessError): void => {
      Logger.error(TAG, `AVPlayer error: code=${err.code}, message=${err.message}`)
      if (this.nativeRequestActive || this.nativeMode) {
        return
      }
      AppStorage.setOrCreate<boolean>(AppStorageKeyConstants.KEY_IS_PLAY, false)
      this.pendingPlay = false
      if (this.resolvePrepare !== undefined) {
        this.resolvePrepare()
        this.resolvePrepare = undefined
      }
    })

    this.avPlayer.on('audioInterrupt', (interruptEvent: audio.InterruptEvent): void => {
      Logger.info(TAG, `audioInterrupt: forceType=${interruptEvent.forceType}, hintType=${interruptEvent.hintType}`)
      if (interruptEvent.forceType === audio.InterruptForceType.INTERRUPT_FORCE) {
        if (interruptEvent.hintType === audio.InterruptHint.INTERRUPT_HINT_PAUSE) {
          this.interruptedWhilePlaying = true
          AppStorage.setOrCreate<boolean>(AppStorageKeyConstants.KEY_IS_PLAY, false)
          this.sessionController.setPlayState(false)
        }
      } else if (interruptEvent.forceType === audio.InterruptForceType.INTERRUPT_SHARE) {
        if (interruptEvent.hintType === audio.InterruptHint.INTERRUPT_HINT_RESUME) {
          if (this.interruptedWhilePlaying && this.avPlayer !== undefined) {
            this.interruptedWhilePlaying = false
            this.avPlayer.play()
          }
        } else if (interruptEvent.hintType === audio.InterruptHint.INTERRUPT_HINT_PAUSE) {
          this.interruptedWhilePlaying = true
        }
      }
    })
  }

  async play(fileUri: string): Promise<void> {
    const requestId: number = ++this.playRequestId
    const useNativePlayer: boolean = this.equalizerEnabled && nativeAudio.isEqualizerSupported()
    this.nativeRequestActive = useNativePlayer
    if (useNativePlayer) {
      await this.stopAvPlayerForNative(requestId)
      if (requestId !== this.playRequestId) {
        return
      }
      const nativeStarted: boolean = await this.playWithEqualizer(fileUri, requestId)
      if (requestId !== this.playRequestId) {
        return
      }
      if (nativeStarted) {
        this.nativeRequestActive = false
        return
      }
      this.nativeRequestActive = false
      Logger.warn(TAG, 'native player failed, fallback to AVPlayer')
    } else if (this.nativeMode) {
      nativeAudio.stop()
      this.stopNativeProgressTimer()
      this.stopNativeStartupCheck()
      this.nativeMode = false
    }
    if (requestId === this.playRequestId) {
      await this.playWithAvPlayer(fileUri, requestId)
    }
  }

  async playSong(song: SongInfo, index: number): Promise<void> {
    AppStorage.setOrCreate('uplayer_current_title', song.title.length > 0 ? song.title : song.name)
    AppStorage.setOrCreate('uplayer_current_artist', song.artist)
    AppStorage.setOrCreate('uplayer_current_album_art', song.albumArtPath)
    AppStorage.setOrCreate('uplayer_current_song_path', song.filePath)
    AppStorage.setOrCreate(AppStorageKeyConstants.KEY_PROGRESS, 0)
    AppStorage.setOrCreate(AppStorageKeyConstants.KEY_CURRENT_TIME, '00:00')
    AppStorage.setOrCreate(AppStorageKeyConstants.KEY_TOTAL_MS_TIME, song.duration)
    AppStorage.setOrCreate(AppStorageKeyConstants.KEY_PROGRESS_MAX, song.duration)
    AppStorage.setOrCreate(AppStorageKeyConstants.KEY_TOTAL_TIME, this.formatTime(song.duration))
    AppStorage.setOrCreate(AppStorageKeyConstants.KEY_SELECT_INDEX, index)
    await this.play(song.uri.length > 0 ? song.uri : song.filePath)
  }

  private async stopAvPlayerForNative(requestId: number): Promise<void> {
    if (this.avPlayer === undefined) {
      return
    }
    this.pendingPlay = false
    if (this.resolvePrepare !== undefined) {
      this.resolvePrepare()
      this.resolvePrepare = undefined
    }
    try {
      const state: string = this.avPlayer.state
      if (state === 'playing' || state === 'paused' || state === 'prepared' || state === 'completed') {
        await this.avPlayer.stop()
      }
      if (requestId !== this.playRequestId) {
        return
      }
      if (this.avPlayer.state !== 'idle') {
        await this.avPlayer.reset()
      }
      this.isPrepared = false
    } catch (err) {
      Logger.warn(TAG, `stopAvPlayerForNative failed: ${JSON.stringify(err)}`)
    }
  }

  private async playWithAvPlayer(fileUri: string, requestId: number): Promise<void> {
    this.nativeRequestActive = false
    await this.init()
    if (this.avPlayer === undefined || requestId !== this.playRequestId) {
      return
    }
    if (this.currentFilePath === fileUri && this.isPrepared &&
      (this.avPlayer.state === 'prepared' || this.avPlayer.state === 'paused' ||
        this.avPlayer.state === 'completed')) {
      this.avPlayer.play()
      this.sessionController.setAVMetadata()
      return
    }
    this.currentFilePath = fileUri
    this.isPrepared = false
    try {
      const curState: string = this.avPlayer.state
      if (curState === 'playing' || curState === 'paused') {
        await this.avPlayer.stop()
      }
      if (requestId !== this.playRequestId) {
        return
      }
      if (curState !== 'idle') {
        await this.avPlayer.reset()
      }
      if (requestId !== this.playRequestId) {
        return
      }
      let file: fs.File = fs.openSync(fileUri, fs.OpenMode.READ_ONLY)
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
    if (this.nativeMode) {
      if (nativeAudio.resume()) {
        AppStorage.setOrCreate<boolean>(AppStorageKeyConstants.KEY_IS_PLAY, true)
        this.sessionController.setPlayState(true)
        this.startBackground()
      }
      return
    }
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
    if (this.nativeMode) {
      if (nativeAudio.pause()) {
        AppStorage.setOrCreate<boolean>(AppStorageKeyConstants.KEY_IS_PLAY, false)
        this.sessionController.setPlayState(false)
      }
      return
    }
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
    this.playRequestId++
    this.nativeRequestActive = false
    if (this.nativeMode) {
      nativeAudio.stop()
      this.stopNativeProgressTimer()
      this.stopNativeStartupCheck()
      this.nativeMode = false
      this.currentFilePath = ''
      AppStorage.setOrCreate<boolean>(AppStorageKeyConstants.KEY_IS_PLAY, false)
      this.sessionController.setPlayState(false)
      return
    }
    if (this.avPlayer === undefined) {
      return
    }
    try {
      this.stopFade()
      await this.avPlayer.stop()
      this.currentFilePath = ''
      this.isPrepared = false
      this.sessionController.setPlayState(false)
    } catch (err) {
      Logger.error(TAG, `stop failed: ${JSON.stringify(err)}`)
    }
  }

  async seek(timeMs: number): Promise<void> {
    if (this.nativeMode) {
      nativeAudio.seek(timeMs)
      return
    }
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
    if (this.nativeMode) {
      nativeAudio.setVolume(vol)
      return
    }
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
    if (this.nativeMode) {
      nativeAudio.setSpeed(speed)
      return
    }
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
    this.playRequestId++
    this.nativeRequestActive = false
    if (this.nativeMode) {
      nativeAudio.stop()
      this.stopNativeProgressTimer()
      this.stopNativeStartupCheck()
      this.nativeMode = false
    }
    if (this.avPlayer === undefined) {
      return
    }
    try {
      this.stopFade()
      await this.avPlayer.release()
      this.avPlayer = undefined
      this.currentFilePath = ''
      this.isPrepared = false
    } catch (err) {
      Logger.error(TAG, `release failed: ${JSON.stringify(err)}`)
    }
  }

  async onForegroundRestore(): Promise<void> {
    if (this.nativeMode) {
      AppStorage.setOrCreate<boolean>(AppStorageKeyConstants.KEY_IS_PLAY, nativeAudio.isPlaying())
      return
    }
    if (this.avPlayer === undefined) {
      return
    }
    try {
      const state: string = this.avPlayer.state
      if (state === 'paused' && this.interruptedWhilePlaying) {
        this.interruptedWhilePlaying = false
        this.avPlayer.play()
      } else if (state === 'playing') {
        AppStorage.setOrCreate<boolean>(AppStorageKeyConstants.KEY_IS_PLAY, true)
      }
    } catch (err) {
      Logger.error(TAG, `onForegroundRestore failed: ${JSON.stringify(err)}`)
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

  async applyEqualizer(enabled: boolean, bands: number[]): Promise<void> {
    this.equalizerEnabled = enabled
    this.equalizerBands = bands.slice(0, 10)
    nativeAudio.setEqualizerEnable(enabled)
    if (enabled) {
      nativeAudio.setEqualizerBands(this.equalizerBands)
    }
  }

  private async playWithEqualizer(fileUri: string, requestId: number): Promise<boolean> {
    this.stopNativeProgressTimer()
    this.stopNativeStartupCheck()
    this.nativeMode = false
    let file: fs.File | undefined = undefined
    try {
      file = fs.openSync(fileUri, fs.OpenMode.READ_ONLY)
      const size: number = fs.statSync(file.fd).size
      nativeAudio.setEqualizerEnable(this.equalizerEnabled)
      if (this.equalizerEnabled) {
        nativeAudio.setEqualizerBands(this.equalizerBands)
      }
      const started: boolean = await nativeAudio.play(file.fd, size)
      if (requestId !== this.playRequestId) {
        return false
      }
      if (!started) {
        Logger.error(TAG, 'native equalizer player start failed')
        return false
      }
      this.nativeMode = true
      this.currentFilePath = fileUri
      this.isPrepared = true
      AppStorage.setOrCreate<boolean>(AppStorageKeyConstants.KEY_IS_PLAY, true)
      AppStorage.setOrCreate(AppStorageKeyConstants.KEY_TOTAL_MS_TIME, nativeAudio.getDuration())
      AppStorage.setOrCreate(AppStorageKeyConstants.KEY_PROGRESS_MAX, nativeAudio.getDuration())
      AppStorage.setOrCreate(AppStorageKeyConstants.KEY_TOTAL_TIME, this.formatTime(nativeAudio.getDuration()))
      this.sessionController.setPlayState(true)
      this.sessionController.setAVMetadata()
      this.startBackground()
      this.startNativeProgressTimer(requestId)
      this.startNativeStartupCheck(fileUri, requestId)
      return true
    } catch (err) {
      Logger.error(TAG, `playWithEqualizer failed: ${JSON.stringify(err)}`)
      return false
    } finally {
      if (file !== undefined) {
        fs.closeSync(file)
      }
    }
  }

  private startNativeProgressTimer(requestId: number): void {
    this.stopNativeProgressTimer()
    this.nativeProgressTimer = setInterval(() => {
      if (requestId !== this.playRequestId || !this.nativeMode) {
        this.stopNativeProgressTimer()
        return
      }
      const position: number = nativeAudio.getPosition()
      AppStorage.setOrCreate(AppStorageKeyConstants.KEY_PROGRESS, position)
      AppStorage.setOrCreate(AppStorageKeyConstants.KEY_CURRENT_TIME, this.formatTime(position))
      this.sessionController.setProgressState(position)
      if (nativeAudio.isCompleted()) {
        this.stopNativeProgressTimer()
        AppStorage.setOrCreate<boolean>(AppStorageKeyConstants.KEY_IS_PLAY, false)
        this.sessionController.setPlayState(false)
        if (this.onSongComplete !== undefined) {
          this.onSongComplete()
        }
      }
    }, 250)
  }

  private stopNativeProgressTimer(): void {
    if (this.nativeProgressTimer !== -1) {
      clearInterval(this.nativeProgressTimer)
      this.nativeProgressTimer = -1
    }
  }

  private startNativeStartupCheck(fileUri: string, requestId: number): void {
    this.stopNativeStartupCheck()
    let checkCount: number = 0
    this.nativeStartupTimer = setInterval(() => {
      if (requestId !== this.playRequestId) {
        this.stopNativeStartupCheck()
        return
      }
      checkCount++
      if (!this.nativeMode || nativeAudio.isReady()) {
        this.stopNativeStartupCheck()
        return
      }
      if (nativeAudio.hasFailed() || checkCount >= 20) {
        this.stopNativeStartupCheck()
        nativeAudio.stop()
        this.stopNativeProgressTimer()
        this.nativeMode = false
        this.nativeRequestActive = false
        this.isPrepared = false
        Logger.warn(TAG, 'native startup timeout, fallback to AVPlayer')
        this.playWithAvPlayer(fileUri, requestId)
      }
    }, 100)
  }

  private stopNativeStartupCheck(): void {
    if (this.nativeStartupTimer !== -1) {
      clearInterval(this.nativeStartupTimer)
      this.nativeStartupTimer = -1
    }
  }
}
