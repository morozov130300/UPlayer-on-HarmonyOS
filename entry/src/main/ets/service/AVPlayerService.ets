// AVPlayer播放服务，使用media.AVPlayer播放导入的音频文件（替代仅支持PCM的AudioRendererController）
import { media } from '@kit.MediaKit'
import { fileIo as fs } from '@kit.CoreFileKit'
import { BusinessError } from '@kit.BasicServicesKit'
import { common } from '@kit.AbilityKit'
import Logger from '../common/utils/Logger'
import { AppStorageKeyConstants } from '../common/constants/AppStorageKeyConstants'

const TAG = 'AVPlayerService'

export class AVPlayerService {
  private static instance: AVPlayerService = new AVPlayerService()
  private avPlayer: media.AVPlayer | undefined = undefined
  private context: common.UIAbilityContext | undefined = AppStorage.get<common.UIAbilityContext>(AppStorageKeyConstants.KEY_UI_ABILITY_CONTEXT)
  private currentFilePath: string = ''
  private isPrepared: boolean = false
  private pendingPlay: boolean = false
  private resolvePrepare: (() => void) | undefined = undefined

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
      } else if (state === 'paused') {
        AppStorage.setOrCreate<boolean>(AppStorageKeyConstants.KEY_IS_PLAY, false)
      } else if (state === 'stopped') {
        AppStorage.setOrCreate<boolean>(AppStorageKeyConstants.KEY_IS_PLAY, false)
        this.isPrepared = false
      } else if (state === 'completed') {
        AppStorage.setOrCreate<boolean>(AppStorageKeyConstants.KEY_IS_PLAY, false)
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
      await new Promise<void>((resolve: Function): void => {
        this.resolvePrepare = resolve as (() => void)
      })
    } catch (err) {
      Logger.error(TAG, `play failed: ${JSON.stringify(err)}`)
      this.pendingPlay = false
    }
  }

  async resume(): Promise<void> {
    if (this.avPlayer === undefined) {
      return
    }
    try {
      this.avPlayer.play()
    } catch (err) {
      Logger.error(TAG, `resume failed: ${JSON.stringify(err)}`)
    }
  }

  async pause(): Promise<void> {
    if (this.avPlayer === undefined) {
      return
    }
    try {
      this.avPlayer.pause()
    } catch (err) {
      Logger.error(TAG, `pause failed: ${JSON.stringify(err)}`)
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
      this.avPlayer.setSpeed(speed)
    } catch (err) {
      Logger.error(TAG, `setSpeed failed: ${JSON.stringify(err)}`)
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
