import { media } from '@kit.MediaKit';
import { BusinessError } from '@kit.BasicServicesKit';

export class AVPlayerManager {
  private static instance: AVPlayerManager
  private avPlayer: media.AVPlayer | null = null
  private isInited: boolean = false
  private onTimeUpdate: ((time: number) => void) | null = null
  private onStateChange: ((state: string) => void) | null = null
  private onEnd: (() => void) | null = null
  private currentUrl: string = ''
  private timeInterval: number = -1

  public static getInstance(): AVPlayerManager {
    if (!AVPlayerManager.instance) {
      AVPlayerManager.instance = new AVPlayerManager()
    }
    return AVPlayerManager.instance
  }

  async init() {
    if (this.isInited) {
      return
    }
    try {
      this.avPlayer = await media.createAVPlayer()
      this.avPlayer.on('stateChange', (state: media.AVPlayerState) => {
        console.log('AVPlayer state:', state)
        this.onStateChange?.(state)
        if (state === 'playing') {
          this.startTimeUpdate()
        }
        if (state === 'prepared') {
          this.avPlayer?.play()
        }
        if (state === 'error') {
          console.error('AVPlayer error')
        }
      })
      this.isInited = true
    } catch (err) {
      console.error('AVPlayer init failed:', JSON.stringify(err))
    }
  }

  private startTimeUpdate() {
    this.stopTimeUpdate()
    this.timeInterval = setInterval(() => {
      if (this.avPlayer && this.avPlayer.state === 'playing') {
        this.onTimeUpdate?.(this.avPlayer.currentTime)
      }
    }, 250)
  }

  private stopTimeUpdate() {
    if (this.timeInterval !== -1) {
      clearInterval(this.timeInterval)
      this.timeInterval = -1
    }
  }

  setUrl(url: string) {
    this.currentUrl = url
  }

  async load(src: string) {
    if (!this.avPlayer) {
      await this.init()
    }
    if (!this.avPlayer) {
      return
    }
    try {
      this.avPlayer.url = src
      this.currentUrl = src
    } catch (err) {
      console.error('AVPlayer load failed:', JSON.stringify(err))
    }
  }

  async play() {
    if (!this.avPlayer) {
      return
    }
    try {
      if (this.avPlayer.state === 'idle') {
        await this.avPlayer.prepare()
      } else if (this.avPlayer.state === 'paused') {
        this.avPlayer.play()
      } else if (this.avPlayer.state === 'prepared') {
        this.avPlayer.play()
      }
    } catch (err) {
      console.error('AVPlayer play failed:', JSON.stringify(err))
    }
  }

  async pause() {
    if (!this.avPlayer || this.avPlayer.state !== 'playing') {
      return
    }
    try {
      this.avPlayer.pause()
      this.stopTimeUpdate()
    } catch (err) {
      console.error('AVPlayer pause failed:', JSON.stringify(err))
    }
  }

  async seek(time: number) {
    if (!this.avPlayer) {
      return
    }
    try {
      this.avPlayer.seek(time)
    } catch (err) {
      console.error('AVPlayer seek failed:', JSON.stringify(err))
    }
  }

  async stop() {
    this.stopTimeUpdate()
    if (!this.avPlayer) {
      return
    }
    try {
      this.avPlayer.stop()
    } catch (err) {
      console.error('AVPlayer stop failed:', JSON.stringify(err))
    }
  }

  release() {
    this.stopTimeUpdate()
    if (this.avPlayer) {
      this.avPlayer.release()
      this.avPlayer = null
    }
    this.isInited = false
  }

  getDuration(): number {
    return this.avPlayer?.duration ?? 0
  }

  getCurrentTime(): number {
    return this.avPlayer?.currentTime ?? 0
  }

  isPlaying(): boolean {
    return this.avPlayer?.state === 'playing'
  }

  setOnTimeUpdate(cb: (time: number) => void) {
    this.onTimeUpdate = cb
  }

  setOnStateChange(cb: (state: string) => void) {
    this.onStateChange = cb
  }

  setOnEnd(cb: () => void) {
    this.onEnd = cb
  }
}
