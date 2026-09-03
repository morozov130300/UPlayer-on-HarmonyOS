import { media } from '@kit.MediaKit'
import { fileIo as fs } from '@kit.CoreFileKit'
import { BusinessError, SuppressWarnings, SuppressWarningsType } from '@kit.BasicServicesKit'
import { common } from '@kit.AbilityKit'
import { audio } from '@kit.AudioKit'
import Logger from '../common/utils/Logger'
import { AppStorageKeyConstants } from '../common/constants/AppStorageKeyConstants'
import { AVSessionController } from '../common/utils/mediautils/AVSessionController'
import { BackgroundUtil } from '../common/utils/BackgroundUtil'
import { LiveViewService } from '../service/LiveViewService'
import nativeAudio from 'libuplayer.so'
import { SongInfo } from '../model/SongInfo'
import { AlbumCoverSize, AudioMetadataService, CoverPriority } from './AudioMetadataService'
import { DataService } from './DataService'
import { MusicPlayMode } from '../common/constants/PlayerConstants'

const TAG = 'AVPlayerService'

enum BackendState {
  IDLE = 'idle',
  STARTING_AV = 'startingAv',
  PLAYING_AV = 'playingAv',
  STARTING_NATIVE = 'startingNative',
  PLAYING_NATIVE = 'playingNative',
  STOPPING = 'stopping',
  RELEASING = 'releasing'
}

@SuppressWarnings({rules: [SuppressWarningsType.SYSCAP]})
export class AVPlayerService {
  private static instance: AVPlayerService = new AVPlayerService()
  private avPlayer: media.AVPlayer | undefined = undefined
  private context: common.UIAbilityContext | undefined = AppStorage.get<common.UIAbilityContext>(AppStorageKeyConstants.KEY_UI_ABILITY_CONTEXT)
  private currentFilePath: string = ''
  private isPrepared: boolean = false
  private resolvePrepare: ((success: boolean) => void) | undefined = undefined
  private prepareRequestId: number = 0
  private prepareTimer: number = -1
  private pendingAvFile: fs.File | undefined = undefined
  private currentAvFile: fs.File | undefined = undefined
  private fadeTimer: number = -1
  private fadeStep: number = 0
  private static FADE_STEPS: number = 6
  private static FADE_INTERVAL: number = 50
  private static EQUALIZER_MIN_GAIN_DB: number = -10
  private static EQUALIZER_MAX_GAIN_DB: number = 10
  private static SEEK_SETTLE_MS: number = 2000
  private interruptedWhilePlaying: boolean = false
  private sessionController: AVSessionController = AVSessionController.getInstance()
  private liveViewService: LiveViewService = LiveViewService.getInstance()
  private nativeMode: boolean = false
  private equalizerEnabled: boolean = false
  private equalizerBands: number[] = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
  private nativeProgressTimer: number = -1
  private nativeStartupTimer: number = -1
  private playRequestId: number = 0
  private activePlaybackGeneration: number = -1
  private completionGeneration: number = -1
  private isSwitchingTrack: boolean = false
  private operationQueue: Promise<void> = Promise.resolve()
  private backendState: BackendState = BackendState.IDLE
  private fallbackGeneration: number = -1
  private pendingSeekMs: number | undefined = undefined
  private desiredVolume: number = 1
  private desiredSpeed: number = 1
  private isSeeking: boolean = false
  private seekingClearTimer: number = -1

  public static getInstance(): AVPlayerService {
    return AVPlayerService.instance
  }

  private enqueueOperation(operation: () => Promise<void>): Promise<void> {
    const queued: Promise<void> = this.operationQueue.then(operation, operation)
    this.operationQueue = queued.catch((err: Error) => {
      Logger.error(TAG, `playback operation failed: ${JSON.stringify(err)}`)
    })
    return queued
  }

  private isCurrentGeneration(generation: number): boolean {
    return generation === this.playRequestId
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

  @SuppressWarnings({rules: [SuppressWarningsType.SYSCAP]})
  private setupListeners(): void {
    if (this.avPlayer === undefined) {
      return
    }
    this.avPlayer.on('stateChange', (state: string): void => {
      Logger.error(TAG, `AVPlayer state: ${state}`)
      if (state === 'initialized') {
        if (this.avPlayer !== undefined && this.prepareRequestId === this.playRequestId) {
          this.avPlayer.prepare()
        }
      } else if (state === 'prepared') {
        if (this.resolvePrepare !== undefined && this.prepareRequestId === this.playRequestId) {
          this.isPrepared = true
          this.finishPrepare(true)
        }
      } else if (state === 'playing') {
        this.backendState = BackendState.PLAYING_AV
        this.isSwitchingTrack = false
        AppStorage.setOrCreate<boolean>(AppStorageKeyConstants.KEY_IS_PLAY, true)
        this.interruptedWhilePlaying = false
        this.sessionController.setPlayState(true)
        this.startBackground()
        this.liveViewService.startLiveView()
      } else if (state === 'paused') {
        if (!this.isSwitchingTrack) {
          AppStorage.setOrCreate<boolean>(AppStorageKeyConstants.KEY_IS_PLAY, false)
          this.sessionController.setPlayState(false)
        }
        this.liveViewService.updateLiveView()
      } else if (state === 'stopped') {
        this.isPrepared = false
        if (!this.isSwitchingTrack) {
          AppStorage.setOrCreate<boolean>(AppStorageKeyConstants.KEY_IS_PLAY, false)
          this.sessionController.setPlayState(false)
        }
      } else if (state === 'completed') {
        AppStorage.setOrCreate<boolean>(AppStorageKeyConstants.KEY_IS_PLAY, false)
        this.sessionController.setPlayState(false)
        this.liveViewService.updateLiveView()
        this.handlePlaybackCompleted(this.activePlaybackGeneration)
      } else if (state === 'released') {
        this.backendState = BackendState.IDLE
        this.isPrepared = false
      }
    })

    this.avPlayer.on('timeUpdate', (time: number): void => {
      if (this.nativeMode) {
        return
      }
      if (!this.isSeeking) {
        AppStorage.setOrCreate(AppStorageKeyConstants.KEY_PROGRESS, time)
      }
      const totalMs: number = AppStorage.get<number>(AppStorageKeyConstants.KEY_TOTAL_MS_TIME) ?? 0
      if (totalMs > 0) {
        AppStorage.setOrCreate(AppStorageKeyConstants.KEY_CURRENT_TIME, this.formatTime(time))
      }
      this.sessionController.setProgressState(time)
    })

    this.avPlayer.on('durationUpdate', (duration: number): void => {
      if (this.nativeMode) {
        return
      }
      AppStorage.setOrCreate(AppStorageKeyConstants.KEY_TOTAL_MS_TIME, duration)
      AppStorage.setOrCreate(AppStorageKeyConstants.KEY_PROGRESS_MAX, duration)
      AppStorage.setOrCreate(AppStorageKeyConstants.KEY_TOTAL_TIME, this.formatTime(duration))
    })

    this.avPlayer.on('error', (err: BusinessError): void => {
      Logger.error(TAG, `AVPlayer error: code=${err.code}, message=${err.message}`)
      if (this.nativeMode) {
        return
      }
      AppStorage.setOrCreate<boolean>(AppStorageKeyConstants.KEY_IS_PLAY, false)
      this.finishPrepare(false)
    })

    this.avPlayer.on('audioInterrupt', (interruptEvent: audio.InterruptEvent): void => {
      Logger.error(TAG, `audioInterrupt: forceType=${interruptEvent.forceType}, hintType=${interruptEvent.hintType}`)
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

  async play(fileUri: string, startPositionMs: number = 0): Promise<void> {
    const requestId: number = ++this.playRequestId
    this.pendingSeekMs = startPositionMs
    await this.enqueueOperation(async (): Promise<void> => {
      await this.performPlay(fileUri, requestId, this.pendingSeekMs ?? startPositionMs)
    })
  }

  private async performPlay(fileUri: string, requestId: number, startPositionMs: number = 0): Promise<void> {
    if (!this.isCurrentGeneration(requestId)) {
      return
    }
    this.pendingSeekMs = undefined
    this.cancelPrepare()
    // 若当前处于播放状态，本次是切歌（播放中切到下一首），stop/reset 期间不应把播放状态置为暂停
    const wasPlaying: boolean = AppStorage.get<boolean>(AppStorageKeyConstants.KEY_IS_PLAY) ?? false
    this.isSwitchingTrack = wasPlaying
    const useNativePlayer: boolean = this.equalizerEnabled && nativeAudio.isEqualizerSupported()
    Logger.error(TAG, `play useNativePlayer=${useNativePlayer} eqEnabled=${this.equalizerEnabled} nativeMode=${this.nativeMode}`)
    if (useNativePlayer) {
      if (this.nativeMode && this.currentFilePath === fileUri && !nativeAudio.isCompleted() &&
        !nativeAudio.hasFailed()) {
        if (startPositionMs > 0) {
          nativeAudio.seek(startPositionMs)
        }
        nativeAudio.setVolume(this.desiredVolume)
        nativeAudio.setSpeed(this.desiredSpeed)
        nativeAudio.resume()
        this.activePlaybackGeneration = requestId
        AppStorage.setOrCreate<boolean>(AppStorageKeyConstants.KEY_IS_PLAY, true)
        this.sessionController.setPlayState(true)
        this.backendState = BackendState.PLAYING_NATIVE
        return
      }
      this.backendState = BackendState.STARTING_NATIVE
      nativeAudio.stop()
      await this.stopAvPlayerForNative(requestId)
      if (requestId !== this.playRequestId) {
        return
      }
      const nativeStarted: boolean = await this.playWithEqualizer(fileUri, requestId, startPositionMs)
      if (requestId !== this.playRequestId) {
        return
      }
      if (nativeStarted) {
        this.backendState = BackendState.PLAYING_NATIVE
        this.fallbackGeneration = -1
        return
      }
      if (!this.isCurrentGeneration(requestId)) {
        return
      }
      Logger.error(TAG, 'native player failed, fallback to AVPlayer')
    } else if (this.nativeMode) {
      nativeAudio.stop()
      this.stopNativeProgressTimer()
      this.stopNativeStartupCheck()
      this.nativeMode = false
    }
    if (requestId === this.playRequestId) {
      await this.playWithAvPlayer(fileUri, requestId, startPositionMs)
    }
  }

  async playSong(song: SongInfo, index: number): Promise<void> {
    if (!song.isAvailable) {
      Logger.error(TAG, `skip unavailable song index=${index} id=${song.id}`)
      return
    }
    this.prefetchSongCovers(index)
    AppStorage.setOrCreate('uplayer_current_title', song.title.length > 0 ? song.title : song.name)
    AppStorage.setOrCreate('uplayer_current_artist', song.artist)
    AppStorage.setOrCreate('uplayer_current_song_id', song.id)
    AppStorage.setOrCreate('uplayer_current_cover_state', 'placeholder')
    AppStorage.setOrCreate('uplayer_current_album_art', '')
    AppStorage.setOrCreate('uplayer_current_song_path', song.filePath)
    AppStorage.setOrCreate(AppStorageKeyConstants.KEY_PROGRESS, 0)
    AppStorage.setOrCreate(AppStorageKeyConstants.KEY_CURRENT_TIME, '00:00')
    AppStorage.setOrCreate(AppStorageKeyConstants.KEY_TOTAL_MS_TIME, song.duration)
    AppStorage.setOrCreate(AppStorageKeyConstants.KEY_PROGRESS_MAX, song.duration)
    AppStorage.setOrCreate(AppStorageKeyConstants.KEY_TOTAL_TIME, this.formatTime(song.duration))
    AppStorage.setOrCreate(AppStorageKeyConstants.KEY_SELECT_INDEX, index)
    this.liveViewService.updateLiveView()
    await this.play(song.uri.length > 0 ? song.uri : song.filePath)
  }

  async playSongAt(index: number): Promise<boolean> {
    const songs: SongInfo[] = DataService.getInstance().getSongs()
    if (index < 0 || index >= songs.length || !songs[index].isAvailable) {
      return false
    }
    await this.playSong(songs[index], index)
    return true
  }

  async playNextSong(naturalCompletion: boolean = false): Promise<boolean> {
    const songs: SongInfo[] = DataService.getInstance().getSongs()
    if (songs.length === 0) {
      return false
    }
    const queuedIndex: number = this.consumePlayableQueuedIndex(songs)
    if (queuedIndex >= 0) {
      return this.playSongAt(queuedIndex)
    }
    const currentIndex: number = this.getCurrentSongIndex(songs.length)
    const playMode: MusicPlayMode = DataService.getInstance().getPlayMode()
    if (naturalCompletion && playMode === MusicPlayMode.SINGLE_CYCLE &&
      currentIndex >= 0 && songs[currentIndex].isAvailable) {
      return this.playSongAt(currentIndex)
    }
    let targetIndex: number = -1
    if (playMode === MusicPlayMode.RANDOM) {
      targetIndex = this.getRandomPlayableIndex(songs, currentIndex)
    } else {
      targetIndex = this.findPlayableIndex(songs, currentIndex, 1)
    }
    return targetIndex >= 0 ? this.playSongAt(targetIndex) : false
  }

  async playPreviousSong(): Promise<boolean> {
    const songs: SongInfo[] = DataService.getInstance().getSongs()
    if (songs.length === 0) {
      return false
    }
    const currentIndex: number = this.getCurrentSongIndex(songs.length)
    const playMode: MusicPlayMode = DataService.getInstance().getPlayMode()
    const targetIndex: number = playMode === MusicPlayMode.RANDOM ?
      this.getRandomPlayableIndex(songs, currentIndex) : this.findPlayableIndex(songs, currentIndex, -1)
    return targetIndex >= 0 ? this.playSongAt(targetIndex) : false
  }

  private getCurrentSongIndex(songCount: number): number {
    const currentIndex: number = AppStorage.get<number>(AppStorageKeyConstants.KEY_SELECT_INDEX) ?? -1
    return currentIndex >= 0 && currentIndex < songCount ? currentIndex : -1
  }

  private findPlayableIndex(songs: SongInfo[], currentIndex: number, direction: number): number {
    if (songs.length === 0) {
      return -1
    }
    const startIndex: number = currentIndex >= 0 ? currentIndex : (direction > 0 ? songs.length - 1 : 0)
    for (let offset = 1; offset <= songs.length; offset++) {
      const index: number = (startIndex + direction * offset + songs.length * 2) % songs.length
      if (songs[index].isAvailable) {
        return index
      }
    }
    return -1
  }

  private getRandomPlayableIndex(songs: SongInfo[], currentIndex: number): number {
    const playableIndexes: number[] = []
    for (let i = 0; i < songs.length; i++) {
      if (songs[i].isAvailable && (i !== currentIndex || playableIndexes.length === 0)) {
        playableIndexes.push(i)
      }
    }
    if (playableIndexes.length > 1 && currentIndex >= 0) {
      const currentPosition: number = playableIndexes.indexOf(currentIndex)
      if (currentPosition >= 0) {
        playableIndexes.splice(currentPosition, 1)
      }
    }
    if (playableIndexes.length === 0) {
      return currentIndex >= 0 && songs[currentIndex].isAvailable ? currentIndex : -1
    }
    return playableIndexes[Math.floor(Math.random() * playableIndexes.length)]
  }

  private consumePlayableQueuedIndex(songs: SongInfo[]): number {
    const queueLength: number = DataService.getInstance().getPlayNextQueue().length
    for (let i = 0; i < queueLength; i++) {
      const songId: string | undefined = DataService.getInstance().shiftPlayNext()
      if (songId === undefined) {
        return -1
      }
      for (let index = 0; index < songs.length; index++) {
        if (songs[index].id === songId && songs[index].isAvailable) {
          return index
        }
      }
    }
    return -1
  }

  private handlePlaybackCompleted(generation: number): void {
    if (generation < 0 || generation !== this.playRequestId || this.completionGeneration === generation) {
      return
    }
    this.completionGeneration = generation
    this.playNextSong(true).catch((err: Error) => {
      Logger.error(TAG, `natural completion selection failed: ${JSON.stringify(err)}`)
    })
  }

  private prefetchSongCovers(index: number): void {
    const songs: SongInfo[] = DataService.getInstance().getSongs()
    if (songs.length === 0 || index < 0 || index >= songs.length) {
      return
    }
    const previousIndex: number = index <= 0 ? songs.length - 1 : index - 1
    const nextIndex: number = index >= songs.length - 1 ? 0 : index + 1
    const covers: AudioMetadataService = AudioMetadataService.getInstance()
    covers.prefetchAlbumCover(songs[index], AlbumCoverSize.MEDIUM, CoverPriority.HIGH)
    if (previousIndex !== index) {
      covers.prefetchAlbumCover(songs[previousIndex], AlbumCoverSize.SMALL, CoverPriority.LOW)
    }
    if (nextIndex !== index && nextIndex !== previousIndex) {
      covers.prefetchAlbumCover(songs[nextIndex], AlbumCoverSize.SMALL, CoverPriority.LOW)
    }
  }

  private async stopAvPlayerForNative(requestId: number): Promise<void> {
    if (this.avPlayer === undefined) {
      return
    }
    this.cancelPrepare()
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
      if (this.currentAvFile !== undefined) {
        this.closeFile(this.currentAvFile)
        this.currentAvFile = undefined
      }
      this.isPrepared = false
    } catch (err) {
      Logger.error(TAG, `stopAvPlayerForNative failed: ${JSON.stringify(err)}`)
    }
  }

  private async playWithAvPlayer(fileUri: string, requestId: number, startPositionMs: number = 0): Promise<void> {
    this.backendState = BackendState.STARTING_AV
    await this.init()
    if (this.avPlayer === undefined || requestId !== this.playRequestId) {
      return
    }
    if (this.currentFilePath === fileUri && this.isPrepared &&
      (this.avPlayer.state === 'prepared' || this.avPlayer.state === 'paused' ||
        this.avPlayer.state === 'completed')) {
      if (startPositionMs > 0) {
        this.avPlayer.seek(this.pendingSeekMs ?? startPositionMs)
      }
      this.pendingSeekMs = undefined
      this.avPlayer.setVolume(this.desiredVolume)
      this.avPlayer.setPlaybackRate(this.desiredSpeed)
      this.avPlayer.play()
      this.activePlaybackGeneration = requestId
      this.backendState = BackendState.PLAYING_AV
      this.sessionController.setAVMetadata()
      return
    }
    this.currentFilePath = fileUri
    this.isPrepared = false
    // 若当前处于播放状态，本次是切歌（播放中切到下一首），stop/reset 期间不应把播放状态置为暂停
    const wasPlaying: boolean = AppStorage.get<boolean>(AppStorageKeyConstants.KEY_IS_PLAY) ?? false
    this.isSwitchingTrack = wasPlaying
    try {
      const curState: string = this.avPlayer.state
      if (curState === 'playing' || curState === 'paused' || curState === 'prepared' || curState === 'completed') {
        await this.avPlayer.stop()
      }
      if (requestId !== this.playRequestId) {
        this.isSwitchingTrack = false
        return
      }
      if (this.avPlayer.state !== 'idle') {
        await this.avPlayer.reset()
      }
      if (requestId !== this.playRequestId) {
        this.isSwitchingTrack = false
        return
      }
      this.pendingAvFile = fs.openSync(fileUri, fs.OpenMode.READ_ONLY)
      const avFd: media.AVFileDescriptor = { fd: this.pendingAvFile.fd, offset: 0, length: 0 }
      this.prepareRequestId = requestId
      const prepared: boolean = await new Promise<boolean>((resolve: (success: boolean) => void): void => {
        this.resolvePrepare = resolve
        this.prepareTimer = setTimeout(() => {
          if (this.prepareRequestId === requestId) {
            Logger.error(TAG, `AVPlayer prepare timeout request=${requestId}`)
            this.finishPrepare(false)
          }
        }, 5000)
        if (this.avPlayer !== undefined) {
          this.avPlayer.fdSrc = avFd
        }
      })
      if (!prepared || requestId !== this.playRequestId || this.avPlayer === undefined) {
        this.isSwitchingTrack = false
        return
      }
      if (this.currentAvFile !== undefined) {
        this.closeFile(this.currentAvFile)
      }
      this.currentAvFile = this.pendingAvFile
      this.pendingAvFile = undefined
      const effectiveStartPosition: number = this.pendingSeekMs ?? startPositionMs
      if (effectiveStartPosition > 0) {
        this.avPlayer.seek(effectiveStartPosition)
      }
      this.pendingSeekMs = undefined
      this.avPlayer.setVolume(this.desiredVolume)
      this.avPlayer.setPlaybackRate(this.desiredSpeed)
      this.avPlayer.play()
      this.activePlaybackGeneration = requestId
      this.backendState = BackendState.PLAYING_AV
      this.sessionController.setAVMetadata()
    } catch (err) {
      Logger.error(TAG, `play failed: ${JSON.stringify(err)}`)
      this.isSwitchingTrack = false
      this.finishPrepare(false)
    }
  }

  private finishPrepare(success: boolean): void {
    if (this.prepareTimer !== -1) {
      clearTimeout(this.prepareTimer)
      this.prepareTimer = -1
    }
    if (!success && this.pendingAvFile !== undefined) {
      this.closeFile(this.pendingAvFile)
      this.pendingAvFile = undefined
    }
    const resolve: ((success: boolean) => void) | undefined = this.resolvePrepare
    this.resolvePrepare = undefined
    this.prepareRequestId = 0
    if (resolve !== undefined) {
      resolve(success)
    }
  }

  private cancelPrepare(): void {
    this.finishPrepare(false)
  }

  private closeFile(file: fs.File): void {
    try {
      fs.closeSync(file)
    } catch (err) {
      Logger.error(TAG, `close file failed: ${JSON.stringify(err)}`)
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

  private stopBackground(): void {
    const ctx: common.UIAbilityContext | undefined = AppStorage.get<common.UIAbilityContext>(AppStorageKeyConstants.KEY_UI_ABILITY_CONTEXT)
    if (ctx !== undefined) {
      BackgroundUtil.stopContinuousTask(ctx)
    }
  }

  async stop(): Promise<void> {
    const generation: number = ++this.playRequestId
    await this.enqueueOperation(async (): Promise<void> => {
      if (!this.isCurrentGeneration(generation)) return
      this.backendState = BackendState.STOPPING
      this.cancelPrepare()
      this.stopNativeProgressTimer()
      this.stopNativeStartupCheck()
      this.stopFade()
      nativeAudio.stop()
      this.nativeMode = false
      this.stopBackground()
      AppStorage.setOrCreate<boolean>(AppStorageKeyConstants.KEY_IS_PLAY, false)
      this.sessionController.setPlayState(false)
      if (this.avPlayer !== undefined) {
        try {
          const state: string = this.avPlayer.state
          if (state === 'playing' || state === 'paused' || state === 'prepared' || state === 'completed') {
            await this.avPlayer.stop()
          }
        } catch (err) {
          Logger.error(TAG, `stop failed: ${JSON.stringify(err)}`)
        }
      }
      this.currentFilePath = ''
      this.isPrepared = false
      this.backendState = BackendState.IDLE
    })
  }

  async seek(timeMs: number): Promise<void> {
    this.sessionController.setProgressState(timeMs)
    this.isSeeking = true
    if (this.seekingClearTimer !== -1) {
      clearTimeout(this.seekingClearTimer)
      this.seekingClearTimer = -1
    }
    this.seekingClearTimer = setTimeout(() => {
      this.seekingClearTimer = -1
      this.isSeeking = false
    }, AVPlayerService.SEEK_SETTLE_MS)
    if (this.backendState === BackendState.STARTING_NATIVE || this.backendState === BackendState.STARTING_AV) {
      this.pendingSeekMs = timeMs
      return
    }
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
    this.desiredVolume = vol
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
    this.desiredSpeed = speed
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
    const generation: number = ++this.playRequestId
    await this.enqueueOperation(async (): Promise<void> => {
      if (!this.isCurrentGeneration(generation)) return
      this.backendState = BackendState.RELEASING
      this.cancelPrepare()
      this.stopNativeProgressTimer()
      this.stopNativeStartupCheck()
      this.stopFade()
      nativeAudio.stop()
      this.nativeMode = false
      this.stopBackground()
      AppStorage.setOrCreate<boolean>(AppStorageKeyConstants.KEY_IS_PLAY, false)
      this.sessionController.setPlayState(false)
      if (this.avPlayer !== undefined) {
        try {
          await this.avPlayer.release()
        } catch (err) {
          Logger.error(TAG, `release failed: ${JSON.stringify(err)}`)
        }
        this.avPlayer = undefined
      }
      if (this.currentAvFile !== undefined) {
        this.closeFile(this.currentAvFile)
        this.currentAvFile = undefined
      }
      if (this.pendingAvFile !== undefined) {
        this.closeFile(this.pendingAvFile)
        this.pendingAvFile = undefined
      }
      this.currentFilePath = ''
      this.isPrepared = false
      this.backendState = BackendState.IDLE
    })
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

  private normalizeEqualizerBands(bands: number[]): number[] {
    const normalized: number[] = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
    for (let i = 0; i < bands.length && i < normalized.length; i++) {
      normalized[i] = Math.max(AVPlayerService.EQUALIZER_MIN_GAIN_DB,
        Math.min(AVPlayerService.EQUALIZER_MAX_GAIN_DB, Math.round(bands[i])))
    }
    return normalized
  }

  updateEqualizerBands(bands: number[]): boolean {
    this.equalizerBands = this.normalizeEqualizerBands(bands)
    if (!this.equalizerEnabled || !this.nativeMode) {
      return false
    }
    return nativeAudio.setEqualizerBands(this.equalizerBands)
  }

  async applyEqualizer(enabled: boolean, bands: number[]): Promise<void> {
    const previousEnabled: boolean = this.equalizerEnabled
    this.equalizerEnabled = enabled
    this.equalizerBands = this.normalizeEqualizerBands(bands)
    nativeAudio.setEqualizerEnable(enabled)
    if (enabled) {
      nativeAudio.setEqualizerBands(this.equalizerBands)
    }
    if (previousEnabled === enabled || this.nativeMode || !enabled) {
      return
    }
    const isPlaying: boolean = AppStorage.get<boolean>(AppStorageKeyConstants.KEY_IS_PLAY) ?? false
    if (!isPlaying || this.currentFilePath.length === 0) {
      return
    }
    const position: number = this.nativeMode ? nativeAudio.getPosition() :
      (AppStorage.get<number>(AppStorageKeyConstants.KEY_PROGRESS) ?? 0)
    const fileUri: string = this.currentFilePath
    await this.play(fileUri, position)
  }

  private async playWithEqualizer(
    fileUri: string, requestId: number, startPositionMs: number = 0): Promise<boolean> {
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
      const started: boolean = await nativeAudio.play(file.fd, size, startPositionMs)
      if (requestId !== this.playRequestId) {
        if (started) {
          nativeAudio.stop()
        }
        return false
      }
      if (!started) {
        Logger.error(TAG, 'native equalizer player start failed')
        return false
      }
      this.nativeMode = true
      this.activePlaybackGeneration = requestId
      this.backendState = BackendState.PLAYING_NATIVE
      nativeAudio.setVolume(this.desiredVolume)
      nativeAudio.setSpeed(this.desiredSpeed)
      this.currentFilePath = fileUri
      this.isPrepared = true
      AppStorage.setOrCreate<boolean>(AppStorageKeyConstants.KEY_IS_PLAY, true)
      AppStorage.setOrCreate(AppStorageKeyConstants.KEY_TOTAL_MS_TIME, nativeAudio.getDuration())
      AppStorage.setOrCreate(AppStorageKeyConstants.KEY_PROGRESS_MAX, nativeAudio.getDuration())
      AppStorage.setOrCreate(AppStorageKeyConstants.KEY_TOTAL_TIME, this.formatTime(nativeAudio.getDuration()))
      this.sessionController.setPlayState(true)
      this.sessionController.setAVMetadata()
      this.startBackground()
      this.startNativeProgressTimer(fileUri, requestId)
      this.startNativeStartupCheck(fileUri, requestId)
      return true
    } catch (err) {
      Logger.error(TAG, `playWithEqualizer failed: ${JSON.stringify(err)}`)
      return false
    } finally {
      if (file !== undefined) {
        this.closeFile(file)
      }
    }
  }

  private requestNativeFallback(fileUri: string, requestId: number, position: number, reason: string): void {
    if (!this.isCurrentGeneration(requestId) || this.fallbackGeneration === requestId) {
      return
    }
    this.fallbackGeneration = requestId
    this.enqueueOperation(async (): Promise<void> => {
      if (!this.isCurrentGeneration(requestId) || !this.nativeMode) return
      this.stopNativeProgressTimer()
      this.stopNativeStartupCheck()
      nativeAudio.stop()
      this.nativeMode = false
      this.isPrepared = false
      Logger.error(TAG, `${reason}, fallback to AVPlayer`)
      await this.playWithAvPlayer(fileUri, requestId, position)
      if (this.backendState !== BackendState.PLAYING_AV) {
        this.backendState = BackendState.IDLE
        AppStorage.setOrCreate<boolean>(AppStorageKeyConstants.KEY_IS_PLAY, false)
        this.sessionController.setPlayState(false)
      }
    })
  }

  private startNativeProgressTimer(fileUri: string, requestId: number): void {
    this.stopNativeProgressTimer()
    this.nativeProgressTimer = setInterval(() => {
      if (requestId !== this.playRequestId || !this.nativeMode) {
        this.stopNativeProgressTimer()
        return
      }
      const position: number = nativeAudio.getPosition()
      if (!this.isSeeking) {
        AppStorage.setOrCreate(AppStorageKeyConstants.KEY_PROGRESS, position)
      }
      AppStorage.setOrCreate(AppStorageKeyConstants.KEY_CURRENT_TIME, this.formatTime(position))
      this.sessionController.setProgressState(position)
      if (this.isSeeking && position !== nativeAudio.getPosition()) {
        this.isSeeking = false
        if (this.seekingClearTimer !== -1) {
          clearTimeout(this.seekingClearTimer)
          this.seekingClearTimer = -1
        }
      }
      if (nativeAudio.hasFailed()) {
        const failedPosition: number = position
        this.requestNativeFallback(fileUri, requestId, failedPosition, 'native render failed')
        return
      }
      if (nativeAudio.isCompleted()) {
        this.stopNativeProgressTimer()
        AppStorage.setOrCreate<boolean>(AppStorageKeyConstants.KEY_IS_PLAY, false)
        this.sessionController.setPlayState(false)
        this.handlePlaybackCompleted(requestId)
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
        const position: number = nativeAudio.getPosition()
        this.requestNativeFallback(fileUri, requestId, position, 'native startup timeout')
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
