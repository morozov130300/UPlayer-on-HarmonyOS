import { fileIo as fs } from '@kit.CoreFileKit'
import { BusinessError, SuppressWarnings, SuppressWarningsType } from '@kit.BasicServicesKit'
import { common } from '@kit.AbilityKit'
import Logger from '../common/utils/Logger'
import { AppStorageKeyConstants } from '../common/constants/AppStorageKeyConstants'
import { AVSessionController } from '../common/utils/mediautils/AVSessionController'
import { BackgroundUtil } from '../common/utils/BackgroundUtil'
import { LiveViewService } from '../service/LiveViewService'
import nativeAudio from 'libuplayer.so'
import { SongInfo } from '../model/SongInfo'
import { AlbumCoverSize, AudioMetadataService, CoverPriority } from './AudioMetadataService'
import { DataService, AppSettingsData } from './DataService'
import { AudioFocusService } from './AudioFocusService'
import { MusicPlayMode } from '../common/constants/PlayerConstants'
import { WindowUtil } from '../common/utils/WindowUtil'
import { showToastGlassMaterial } from '../common/utils/GlassUtil'
import { loadLyricEntries } from './LyricLoader'

const TAG = 'AVPlayerService'

enum BackendState {
  IDLE = 'idle',
  STARTING = 'starting',
  PLAYING = 'playing',
  STOPPING = 'stopping',
  RELEASING = 'releasing'
}

// 设备音效节点能力探测结果（OHAudioSuite 各类效果节点是否受支持）
export class EffectNodeSupport {
  soundField: boolean = false
  environment: boolean = false
  beautifier: boolean = false
  spaceRender: boolean = false
  generalVoiceChange: boolean = false
  noiseReduction: boolean = false
  pureVoiceChange: boolean = false
  tempoPitch: boolean = false
  separation: boolean = false
}

@SuppressWarnings({rules: [SuppressWarningsType.SYSCAP]})
export class AVPlayerService {
  private static instance: AVPlayerService = new AVPlayerService()
  private context: common.UIAbilityContext | undefined = AppStorage.get<common.UIAbilityContext>(AppStorageKeyConstants.KEY_UI_ABILITY_CONTEXT)
  private currentFilePath: string = ''
  private fadeTimer: number = -1
  private fadeStep: number = 0
  private static FADE_STEPS: number = 30
  private static FADE_INTERVAL: number = 10
  private static FADE_FLOOR: number = 0.01
  private static EQUALIZER_MIN_GAIN_DB: number = -10
  private static EQUALIZER_MAX_GAIN_DB: number = 10
  private static SEEK_SETTLE_MS: number = 2000
  private sessionController: AVSessionController = AVSessionController.getInstance()
  private liveViewService: LiveViewService = LiveViewService.getInstance()
  private equalizerEnabled: boolean = false
  private equalizerBands: number[] = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
  // OHAudioSuite 系统音效：类型 1-4；空间渲染模式 0=摆位(3值) 1=旋转(5值) 2=扩展(2值)
  private soundFieldEnabled: boolean = false
  private soundFieldType: number = 1
  private environmentEnabled: boolean = false
  private environmentType: number = 1
  private beautifierEnabled: boolean = false
  private beautifierType: number = 1
  private spaceRenderEnabled: boolean = false
  private spaceRenderMode: number = 0
  private spaceRenderValues: number[] = [0, 0, 0]
  private generalVoiceChangeEnabled: boolean = false
  private generalVoiceChangeType: number = 1
  private noiseReductionEnabled: boolean = false
  private pureVoiceChangeEnabled: boolean = false
  private pureVoiceChangeGender: number = 1
  private pureVoiceChangeType: number = 1
  private pureVoiceChangePitch: number = 0
  private tempoPitchEnabled: boolean = false
  private tempoSpeed: number = 1
  private tempoPitch: number = 1
  private separationEnabled: boolean = false
  private separationOutput: number = 1
  // 音效节点能力探测缓存（undefined = 尚未探测）：见 ensureEffectNodeSupport()
  private effectNodeSupport: EffectNodeSupport | undefined = undefined
  private nativeProgressTimer: number = -1
  private nativeStartupTimer: number = -1
  private playRequestId: number = 0
  private activePlaybackGeneration: number = -1
  private completionGeneration: number = -1
  private isSwitchingTrack: boolean = false
  private operationQueue: Promise<void> = Promise.resolve()
  private backendState: BackendState = BackendState.IDLE
  private pendingSeekMs: number | undefined = undefined
  private desiredVolume: number = 1
  private desiredSpeed: number = 1
  private isSeeking: boolean = false
  private seekingClearTimer: number = -1
  private seekFromMs: number = -1

  public static getInstance(): AVPlayerService {
    return AVPlayerService.instance
  }

  private enqueueOperation(operation: () => Promise<void>): Promise<void> {
    const self: AVPlayerService = this
    const queued: Promise<void> = new Promise<void>(async (resolve: () => void, reject: (err: BusinessError) => void): Promise<void> => {
      await self.operationQueue
      try {
        await operation()
        resolve()
      } catch (err) {
        reject(err as BusinessError)
      }
    })
    this.operationQueue = queued.catch((err: BusinessError): void => {
      Logger.error(TAG, `playback operation failed: code=${err.code}, message=${err.message}`)
    })
    return queued
  }

  private isCurrentGeneration(generation: number): boolean {
    return generation === this.playRequestId
  }

  // 原生引擎是否持有已加载的播放（播放/暂停中）；IDLE 时无任何占用
  private isEngineLoaded(): boolean {
    return this.currentFilePath.length > 0
  }

  async play(fileUri: string, startPositionMs: number = 0, startPaused: boolean = false): Promise<void> {
    const requestId: number = ++this.playRequestId
    this.pendingSeekMs = startPositionMs
    await this.enqueueOperation(async (): Promise<void> => {
      await this.performPlay(fileUri, requestId, this.pendingSeekMs ?? startPositionMs, startPaused)
    })
  }

  private async performPlay(fileUri: string, requestId: number, startPositionMs: number = 0,
    startPaused: boolean = false): Promise<void> {
    if (!this.isCurrentGeneration(requestId)) {
      return
    }
    this.pendingSeekMs = undefined
    // AudioSession 可能因「无音频流运行」被系统超时去激活，起播前按设置补激活，
    // 保证通知音到达时「不压低音量」的并发策略仍然生效
    AudioFocusService.getInstance().ensureStrategy()
    // 若当前处于播放状态，本次是切歌（播放中切到下一首），stop/reset 期间不应把播放状态置为暂停
    const wasPlaying: boolean = AppStorage.get<boolean>(AppStorageKeyConstants.KEY_IS_PLAY) ?? false
    this.isSwitchingTrack = wasPlaying
    // 同一文件且引擎仍在途：seek + resume 复用，不重建管线
    if (this.isEngineLoaded() && this.currentFilePath === fileUri && !nativeAudio.isCompleted() &&
      !nativeAudio.hasFailed()) {
      if (startPositionMs > 0) {
        nativeAudio.seek(startPositionMs)
      }
      const fadeInOutOnStart: boolean = !startPaused && (AppStorage.get<boolean>('uplayer_fade_in_out') ?? false)
      if (fadeInOutOnStart) {
        nativeAudio.setVolume(0)
      } else {
        nativeAudio.setVolume(this.desiredVolume)
      }
      nativeAudio.setSpeed(this.desiredSpeed)
      this.activePlaybackGeneration = requestId
      if (!startPaused) {
        nativeAudio.resume()
        if (fadeInOutOnStart) {
          this.fadeIn()
        }
        AppStorage.setOrCreate<boolean>(AppStorageKeyConstants.KEY_IS_PLAY, true)
        this.sessionController.setPlayState(true)
      }
      this.backendState = BackendState.PLAYING
      this.applyPendingNativeSeek()
      return
    }
    this.backendState = BackendState.STARTING
    nativeAudio.stop()
    this.stopNativeProgressTimer()
    this.stopNativeStartupCheck()
    if (requestId !== this.playRequestId) {
      return
    }
    const nativeStarted: boolean = await this.playWithEffects(fileUri, requestId, startPositionMs, startPaused)
    if (requestId !== this.playRequestId) {
      return
    }
    if (nativeStarted) {
      this.backendState = BackendState.PLAYING
      this.applyPendingNativeSeek()
      return
    }
    // 原生管线启动失败：不再回退 AVPlayer——记日志、状态复位、Toast 报错
    Logger.error(TAG, 'native player failed to start')
    this.isSwitchingTrack = false
    this.backendState = BackendState.IDLE
    this.currentFilePath = ''
    AppStorage.setOrCreate<boolean>(AppStorageKeyConstants.KEY_IS_PLAY, false)
    this.sessionController.setPlayState(false)
    this.stopBackground()
    this.notifyPlaybackFailed('播放失败，请重试')
  }

  async playSong(song: SongInfo, index: number, startPaused: boolean = false): Promise<void> {
    if (!song.isAvailable) {
      // 可访问性检查已修复（见 DataService.ets），此分支仅保留作为防御性日志；
      // 触发前检查 KEY_SONG_LIST 是否已从 activatePersistedUris 获得最新状态。
      Logger.warn(TAG, `skip unavailable song index=${index} id=${song.id} uri=${song.uri.length > 0 ? song.uri : song.filePath}`)
      return
    }
    this.prefetchSongCovers(index)
    this.prefetchSongLyrics(index)
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
    await this.play(song.uri.length > 0 ? song.uri : song.filePath, 0, startPaused)
  }

  // 播放队列：与首页可见顺序一致（由 HomeContent 同步到 KEY_SONG_LIST），
  // 未同步前回退到曲库原始顺序
  private getPlayQueue(): SongInfo[] {
    const queue: SongInfo[] | undefined = AppStorage.get<SongInfo[]>(AppStorageKeyConstants.KEY_SONG_LIST)
    return queue !== undefined ? queue : DataService.getInstance().getSongs()
  }

  async playSongAt(index: number, startPaused: boolean = false): Promise<boolean> {
    const songs: SongInfo[] = this.getPlayQueue()
    if (index < 0 || index >= songs.length || !songs[index].isAvailable) {
      return false
    }
    await this.playSong(songs[index], index, startPaused)
    return true
  }

  async playNextSong(naturalCompletion: boolean = false): Promise<boolean> {
    const songs: SongInfo[] = this.getPlayQueue()
    if (songs.length === 0) {
      return false
    }
    // 手动切歌时保持暂停态；自然播完续播保持播放
    const wasPlaying: boolean = AppStorage.get<boolean>(AppStorageKeyConstants.KEY_IS_PLAY) ?? false
    const everLoaded: boolean = this.isEngineLoaded()
    const startPaused: boolean = !naturalCompletion && everLoaded && !wasPlaying
    const queuedIndex: number = this.consumePlayableQueuedIndex(songs)
    if (queuedIndex >= 0) {
      return this.playSongAt(queuedIndex, startPaused)
    }
    const currentIndex: number = this.getCurrentSongIndex(songs.length)
    const playMode: MusicPlayMode = DataService.getInstance().getPlayMode()
    if (naturalCompletion && playMode === MusicPlayMode.SINGLE_CYCLE &&
      currentIndex >= 0 && songs[currentIndex].isAvailable) {
      return this.playSongAt(currentIndex, false)
    }
    let targetIndex: number = -1
    if (playMode === MusicPlayMode.RANDOM) {
      targetIndex = this.getRandomPlayableIndex(songs, currentIndex)
    } else {
      targetIndex = this.findPlayableIndex(songs, currentIndex, 1)
    }
    return targetIndex >= 0 ? this.playSongAt(targetIndex, startPaused) : false
  }

  async playPreviousSong(): Promise<boolean> {
    const songs: SongInfo[] = this.getPlayQueue()
    if (songs.length === 0) {
      return false
    }
    // 手动切歌时保持暂停态
    const wasPlaying: boolean = AppStorage.get<boolean>(AppStorageKeyConstants.KEY_IS_PLAY) ?? false
    const everLoaded: boolean = this.isEngineLoaded()
    const startPaused: boolean = everLoaded && !wasPlaying
    const currentIndex: number = this.getCurrentSongIndex(songs.length)
    const playMode: MusicPlayMode = DataService.getInstance().getPlayMode()
    const targetIndex: number = playMode === MusicPlayMode.RANDOM ?
      this.getRandomPlayableIndex(songs, currentIndex) : this.findPlayableIndex(songs, currentIndex, -1)
    return targetIndex >= 0 ? this.playSongAt(targetIndex, startPaused) : false
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
    const songs: SongInfo[] = this.getPlayQueue()
    if (songs.length === 0 || index < 0 || index >= songs.length) {
      return
    }
    const previousIndex: number = index <= 0 ? songs.length - 1 : index - 1
    const nextIndex: number = index >= songs.length - 1 ? 0 : index + 1
    const covers: AudioMetadataService = AudioMetadataService.getInstance()
    covers.prefetchAlbumCover(songs[index], AlbumCoverSize.MEDIUM, CoverPriority.HIGH)
    covers.prefetchAlbumCover(songs[index], AlbumCoverSize.LARGE, CoverPriority.HIGH)
    if (previousIndex !== index) {
      covers.prefetchAlbumCover(songs[previousIndex], AlbumCoverSize.SMALL, CoverPriority.LOW)
    }
    if (nextIndex !== index && nextIndex !== previousIndex) {
      covers.prefetchAlbumCover(songs[nextIndex], AlbumCoverSize.SMALL, CoverPriority.LOW)
    }
  }

  // 歌词预取：当前歌曲立刻读盘（落在 LyricLoader 在途去重里，页面 Watch 触发时共享同一请求），
  // 上一首/下一首提前入缓存，顺序切歌时 0 等待。fire-and-forget，失败不阻塞播放
  private prefetchSongLyrics(index: number): void {
    const songs: SongInfo[] = this.getPlayQueue()
    if (songs.length === 0 || index < 0 || index >= songs.length) {
      return
    }
    const previousIndex: number = index <= 0 ? songs.length - 1 : index - 1
    const nextIndex: number = index >= songs.length - 1 ? 0 : index + 1
    const targets: SongInfo[] = [songs[index]]
    if (previousIndex !== index) {
      targets.push(songs[previousIndex])
    }
    if (nextIndex !== index && nextIndex !== previousIndex) {
      targets.push(songs[nextIndex])
    }
    for (let i = 0; i < targets.length; i++) {
      loadLyricEntries(targets[i]).catch((err: Error): void => {
        Logger.warn(TAG, `prefetch lyric failed id=${targets[i].id} err=${JSON.stringify(err)}`)
      })
    }
  }

  private closeFile(file: fs.File): void {
    try {
      fs.closeSync(file)
    } catch (err) {
      Logger.error(TAG, `close file failed: ${JSON.stringify(err)}`)
    }
  }

  resume(): void {
    AudioFocusService.getInstance().ensureStrategy()
    if (!this.isEngineLoaded()) {
      return
    }
    const fadeInOut: boolean = AppStorage.get<boolean>('uplayer_fade_in_out') ?? false
    if (fadeInOut) {
      nativeAudio.setVolume(0)
      if (nativeAudio.resume()) {
        this.fadeIn()
      }
    } else {
      nativeAudio.setVolume(this.desiredVolume)
      nativeAudio.resume()
    }
    AppStorage.setOrCreate<boolean>(AppStorageKeyConstants.KEY_IS_PLAY, nativeAudio.isPlaying())
    this.sessionController.setPlayState(true)
    this.startBackground()
  }

  pause(): void {
    if (!this.isEngineLoaded()) {
      return
    }
    AppStorage.setOrCreate<boolean>(AppStorageKeyConstants.KEY_IS_PLAY, false)
    this.sessionController.setPlayState(false)
    this.stopBackground()
    const fadeInOut: boolean = AppStorage.get<boolean>('uplayer_fade_in_out') ?? false
    if (fadeInOut) {
      this.fadeOut()
    } else {
      nativeAudio.pause()
    }
  }

  private applyFadeVolume(vol: number): void {
    nativeAudio.setVolume(vol)
  }

  private finishFadePause(): void {
    nativeAudio.pause()
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
      const ratio: number = Math.min(this.fadeStep / AVPlayerService.FADE_STEPS, 1)
      const vol: number = Math.min(targetVol * Math.pow(AVPlayerService.FADE_FLOOR, 1 - ratio), targetVol)
      this.applyFadeVolume(vol)
      if (this.fadeStep >= AVPlayerService.FADE_STEPS) {
        this.stopFade()
        this.applyFadeVolume(targetVol)
      }
    }, AVPlayerService.FADE_INTERVAL)
  }

  private fadeOut(): void {
    this.stopFade()
    const startVol: number = AppStorage.get<number>(AppStorageKeyConstants.KEY_CURRENT_VOLUME) ?? 1
    this.fadeStep = 0
    this.fadeTimer = setInterval(() => {
      this.fadeStep++
      const ratio: number = Math.min(this.fadeStep / AVPlayerService.FADE_STEPS, 1)
      const vol: number = Math.max(startVol * Math.pow(AVPlayerService.FADE_FLOOR, ratio), 0)
      this.applyFadeVolume(vol)
      if (this.fadeStep >= AVPlayerService.FADE_STEPS) {
        this.stopFade()
        this.applyFadeVolume(0)
        this.finishFadePause()
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
      this.stopNativeProgressTimer()
      this.stopNativeStartupCheck()
      this.stopFade()
      nativeAudio.stop()
      this.stopBackground()
      AppStorage.setOrCreate<boolean>(AppStorageKeyConstants.KEY_IS_PLAY, false)
      this.sessionController.setPlayState(false)
      this.currentFilePath = ''
      this.backendState = BackendState.IDLE
    })
  }

  // 引擎启动完成（PLAYING）后补投递启动窗口期间积累的 seek 请求，
  // 否则 pendingSeekMs 会在启动窗口内静默丢弃
  private applyPendingNativeSeek(): void {
    if (this.pendingSeekMs === undefined) {
      return
    }
    const target: number = this.pendingSeekMs
    this.pendingSeekMs = undefined
    const seekOk: boolean = nativeAudio.seek(target)
    if (!seekOk) {
      Logger.error(TAG, `pending native seek rejected pos=${target}`)
    }
  }

  async seek(timeMs: number): Promise<void> {
    Logger.info(TAG, `seek to ${timeMs} state=${this.backendState} from=${this.getCurrentPositionMs()}`)
    this.sessionController.setProgressState(timeMs)
    this.isSeeking = true
    this.seekFromMs = this.getCurrentPositionMs()
    if (this.seekingClearTimer !== -1) {
      clearTimeout(this.seekingClearTimer)
      this.seekingClearTimer = -1
    }
    this.seekingClearTimer = setTimeout(() => {
      this.seekingClearTimer = -1
      this.isSeeking = false
    }, AVPlayerService.SEEK_SETTLE_MS)
    // 乐观更新进度：seek 生效期间进度回调被抑制，先让 UI/歌词立即跳到目标位置
    if (this.isUiActive()) {
      AppStorage.setOrCreate(AppStorageKeyConstants.KEY_PROGRESS, timeMs)
      const totalMs: number = AppStorage.get<number>(AppStorageKeyConstants.KEY_TOTAL_MS_TIME) ?? 0
      if (totalMs > 0) {
        AppStorage.setOrCreate(AppStorageKeyConstants.KEY_CURRENT_TIME, this.formatTime(timeMs))
      }
    }
    if (this.backendState === BackendState.STARTING) {
      this.pendingSeekMs = timeMs
      return
    }
    const seekOk: boolean = nativeAudio.seek(timeMs)
    if (!seekOk) {
      Logger.error(TAG, `native seek rejected pos=${timeMs}`)
    }
  }

  setSpeed(speed: number): void {
    this.desiredSpeed = speed
    if (!this.isEngineLoaded()) {
      return
    }
    nativeAudio.setSpeed(speed)
  }

  // 低功耗播放模式（OH_LowPowerAudioSink 压缩帧直通）：设置页开关入口。
  // 播放中切换：从当前位置重启当前曲目，让新链路立即生效
  applyLowPowerPlayback(enabled: boolean): void {
    nativeAudio.setLowPowerMode(enabled)
    const isPlaying: boolean = AppStorage.get<boolean>(AppStorageKeyConstants.KEY_IS_PLAY) ?? false
    if (!isPlaying || this.currentFilePath.length === 0) {
      return
    }
    const position: number = this.getCurrentPositionMs()
    this.play(this.currentFilePath, position).catch((err: Error): void => {
      Logger.error(TAG, `low-power mode switch replay failed: ${JSON.stringify(err)}`)
    })
  }

  async release(): Promise<void> {
    const generation: number = ++this.playRequestId
    await this.enqueueOperation(async (): Promise<void> => {
      if (!this.isCurrentGeneration(generation)) return
      this.backendState = BackendState.RELEASING
      this.stopNativeProgressTimer()
      this.stopNativeStartupCheck()
      this.stopFade()
      nativeAudio.stop()
      this.stopBackground()
      AppStorage.setOrCreate<boolean>(AppStorageKeyConstants.KEY_IS_PLAY, false)
      this.sessionController.setPlayState(false)
      this.currentFilePath = ''
      this.backendState = BackendState.IDLE
    })
  }

  async onForegroundRestore(): Promise<void> {
    if (!this.isEngineLoaded()) {
      return
    }
    AppStorage.setOrCreate<boolean>(AppStorageKeyConstants.KEY_IS_PLAY, nativeAudio.isPlaying())
  }

  private formatTime(ms: number): string {
    const totalSec: number = Math.floor(ms / 1000)
    const min: number = Math.floor(totalSec / 60)
    const sec: number = totalSec % 60
    const minStr: string = min < 10 ? '0' + min : '' + min
    const secStr: string = sec < 10 ? '0' + sec : '' + sec
    return minStr + ':' + secStr
  }

  private notifyPlaybackFailed(message: string): void {
    try {
      const windowUtil: WindowUtil | undefined = AppStorage.get<WindowUtil>(AppStorageKeyConstants.KEY_WINDOW_UTIL)
      if (windowUtil !== undefined) {
        showToastGlassMaterial(windowUtil.getUiContext()?.getPromptAction(), message)
      }
    } catch (e) {
      Logger.warn(TAG, `showToast failed: ${JSON.stringify(e)}`)
    }
  }

  private normalizeEqualizerBands(bands: number[]): number[] {
    const normalized: number[] = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
    for (let i = 0; i < bands.length && i < normalized.length; i++) {
      const raw: number = bands[i]
      // 双保险：非有限数（NaN/Infinity，旧版本畸形数据可能的出口）回落 0，
      // 绝不下发原生引擎——v1.0.7 修复
      normalized[i] = Number.isFinite(raw) ?
        Math.max(AVPlayerService.EQUALIZER_MIN_GAIN_DB,
          Math.min(AVPlayerService.EQUALIZER_MAX_GAIN_DB, Math.round(raw))) : 0
    }
    return normalized
  }

  updateEqualizerBands(bands: number[]): boolean {
    this.equalizerBands = this.normalizeEqualizerBands(bands)
    if (!this.equalizerEnabled) {
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
    if (previousEnabled === enabled || !enabled) {
      return
    }
    await this.reloadForNativeEffects()
  }

  // 任一音效启用即需要走原生链路（管线 Bypass/管线切换即时生效）
  anyEffectEnabled(): boolean {
    return this.equalizerEnabled || this.soundFieldEnabled || this.environmentEnabled ||
      this.beautifierEnabled || this.spaceRenderEnabled || this.generalVoiceChangeEnabled ||
      this.noiseReductionEnabled || this.pureVoiceChangeEnabled || this.tempoPitchEnabled ||
      this.separationEnabled
  }

  // 启动时把持久化设置同步进原生引擎与运行态（EntryAbility 调用）
  syncEffectsFromDisk(): void {
    const settings: AppSettingsData = DataService.getInstance().getSettings()
    this.equalizerEnabled = settings.eqEnabled
    this.equalizerBands = this.normalizeEqualizerBands(settings.eqBands)
    this.soundFieldEnabled = settings.soundFieldEnabled
    this.soundFieldType = settings.soundFieldType
    this.environmentEnabled = settings.environmentEnabled
    this.environmentType = settings.environmentType
    this.beautifierEnabled = settings.beautifierEnabled
    this.beautifierType = settings.beautifierType
    this.spaceRenderEnabled = settings.spaceRenderEnabled
    this.spaceRenderMode = settings.spaceRenderMode
    this.spaceRenderValues = settings.spaceRenderValues
    this.generalVoiceChangeEnabled = settings.generalVoiceChangeEnabled
    this.generalVoiceChangeType = settings.generalVoiceChangeType
    this.noiseReductionEnabled = settings.noiseReductionEnabled
    this.pureVoiceChangeEnabled = settings.pureVoiceChangeEnabled
    this.pureVoiceChangeGender = settings.pureVoiceChangeGender
    this.pureVoiceChangeType = settings.pureVoiceChangeType
    this.pureVoiceChangePitch = settings.pureVoiceChangePitch
    this.tempoPitchEnabled = settings.tempoPitchEnabled
    this.tempoSpeed = settings.tempoSpeed
    this.tempoPitch = settings.tempoPitch
    this.separationEnabled = settings.separationEnabled
    this.separationOutput = settings.separationOutput
    this.applyAllEffectsToNative()
  }

  // 设备音效节点能力：首次调用才打 native（同步系统 IPC，9 个节点类型 9 次调用），
  // 之后一律返回缓存。设置页只在「音效」分区按需调用一次，不再由页面打开路径无条件触发。
  ensureEffectNodeSupport(): EffectNodeSupport {
    if (this.effectNodeSupport === undefined) {
      const support: EffectNodeSupport = new EffectNodeSupport()
      support.soundField = nativeAudio.isEffectNodeSupported(203)
      support.environment = nativeAudio.isEffectNodeSupported(206)
      support.beautifier = nativeAudio.isEffectNodeSupported(205)
      support.spaceRender = nativeAudio.isEffectNodeSupported(208)
      support.generalVoiceChange = nativeAudio.isEffectNodeSupported(210)
      support.noiseReduction = nativeAudio.isEffectNodeSupported(202)
      support.pureVoiceChange = nativeAudio.isEffectNodeSupported(209)
      support.tempoPitch = nativeAudio.isEffectNodeSupported(211)
      support.separation = nativeAudio.isEffectNodeSupported(204)
      this.effectNodeSupport = support
      Logger.info(TAG, `effect node support probed: sf=${support.soundField} env=${support.environment}` +
        ` bf=${support.beautifier} sr=${support.spaceRender} gvc=${support.generalVoiceChange}` +
        ` nr=${support.noiseReduction} pvc=${support.pureVoiceChange} tp=${support.tempoPitch}` +
        ` sep=${support.separation}`)
    }
    return this.effectNodeSupport
  }

  async applyGeneralVoiceChange(enabled: boolean, type: number = 1): Promise<void> {
    const previousEnabled: boolean = this.generalVoiceChangeEnabled
    this.generalVoiceChangeEnabled = enabled
    this.generalVoiceChangeType = type
    nativeAudio.setGeneralVoiceChangeEnable(enabled)
    if (enabled) {
      nativeAudio.setGeneralVoiceChangeType(this.generalVoiceChangeType)
    }
    if (previousEnabled === enabled || !enabled) {
      return
    }
    await this.reloadForNativeEffects()
  }

  async applyNoiseReduction(enabled: boolean): Promise<void> {
    const previousEnabled: boolean = this.noiseReductionEnabled
    this.noiseReductionEnabled = enabled
    nativeAudio.setNoiseReductionEnable(enabled)
    if (previousEnabled === enabled || !enabled) {
      return
    }
    await this.reloadForNativeEffects()
  }

  async applyPureVoiceChange(enabled: boolean, gender: number = 1, type: number = 1,
    pitch: number = 0): Promise<void> {
    const previousEnabled: boolean = this.pureVoiceChangeEnabled
    this.pureVoiceChangeEnabled = enabled
    this.pureVoiceChangeGender = gender
    this.pureVoiceChangeType = type
    this.pureVoiceChangePitch = pitch
    nativeAudio.setPureVoiceChangeEnable(enabled)
    if (enabled) {
      nativeAudio.setPureVoiceChangeConfig(this.pureVoiceChangeGender, this.pureVoiceChangeType,
        this.pureVoiceChangePitch)
    }
    if (previousEnabled === enabled || !enabled) {
      return
    }
    await this.reloadForNativeEffects()
  }

  async applyTempoPitch(enabled: boolean, speed: number = 1, pitch: number = 1): Promise<void> {
    const previousEnabled: boolean = this.tempoPitchEnabled
    this.tempoPitchEnabled = enabled
    this.tempoSpeed = speed
    this.tempoPitch = pitch
    nativeAudio.setTempoPitchEnable(enabled)
    if (enabled) {
      nativeAudio.setTempoPitchConfig(this.tempoSpeed, this.tempoPitch)
    }
    if (previousEnabled === enabled || !enabled) {
      return
    }
    await this.reloadForNativeEffects()
  }

  async applySeparation(enabled: boolean, output: number = 1): Promise<void> {
    const previousEnabled: boolean = this.separationEnabled
    this.separationEnabled = enabled
    this.separationOutput = output
    nativeAudio.setSeparationEnable(enabled)
    if (enabled) {
      nativeAudio.setSeparationOutput(this.separationOutput)
    }
    if (previousEnabled === enabled || !enabled) {
      return
    }
    await this.reloadForNativeEffects()
  }

  async applySoundField(enabled: boolean, type: number = 1): Promise<void> {
    const previousEnabled: boolean = this.soundFieldEnabled
    this.soundFieldEnabled = enabled
    this.soundFieldType = type
    nativeAudio.setSoundFieldEnable(enabled)
    if (enabled) {
      nativeAudio.setSoundFieldType(this.soundFieldType)
    }
    if (previousEnabled === enabled || !enabled) {
      return
    }
    await this.reloadForNativeEffects()
  }

  async applyEnvironment(enabled: boolean, type: number = 1): Promise<void> {
    const previousEnabled: boolean = this.environmentEnabled
    this.environmentEnabled = enabled
    this.environmentType = type
    nativeAudio.setEnvironmentEnable(enabled)
    if (enabled) {
      nativeAudio.setEnvironmentType(this.environmentType)
    }
    if (previousEnabled === enabled || !enabled) {
      return
    }
    await this.reloadForNativeEffects()
  }

  async applyVoiceBeautifier(enabled: boolean, type: number = 1): Promise<void> {
    const previousEnabled: boolean = this.beautifierEnabled
    this.beautifierEnabled = enabled
    this.beautifierType = type
    nativeAudio.setVoiceBeautifierEnable(enabled)
    if (enabled) {
      nativeAudio.setVoiceBeautifierType(this.beautifierType)
    }
    if (previousEnabled === enabled || !enabled) {
      return
    }
    await this.reloadForNativeEffects()
  }

  async applySpaceRender(enabled: boolean, mode: number = 0, values: number[] = [0, 0, 0]): Promise<void> {
    const previousEnabled: boolean = this.spaceRenderEnabled
    this.spaceRenderEnabled = enabled
    this.spaceRenderMode = mode
    this.spaceRenderValues = values
    nativeAudio.setSpaceRenderEnable(enabled)
    if (enabled) {
      nativeAudio.setSpaceRenderConfig(this.spaceRenderMode, this.spaceRenderValues)
    }
    if (previousEnabled === enabled || !enabled) {
      return
    }
    await this.reloadForNativeEffects()
  }

  // 全量下发 5 类音效状态到原生引擎，ConfigureEffects 按初始态建节点并设 Bypass
  private applyAllEffectsToNative(): void {
    Logger.info(TAG, 'native apply begin')
    nativeAudio.setEqualizerEnable(this.equalizerEnabled)
    Logger.info(TAG, 'native eq enable done')
    if (this.equalizerEnabled) {
      nativeAudio.setEqualizerBands(this.equalizerBands)
      Logger.info(TAG, 'native eq bands done')
    }
    nativeAudio.setSoundFieldEnable(this.soundFieldEnabled)
    Logger.info(TAG, 'native soundField done')
    if (this.soundFieldEnabled) {
      nativeAudio.setSoundFieldType(this.soundFieldType)
    }
    nativeAudio.setEnvironmentEnable(this.environmentEnabled)
    Logger.info(TAG, 'native environment done')
    if (this.environmentEnabled) {
      nativeAudio.setEnvironmentType(this.environmentType)
    }
    nativeAudio.setVoiceBeautifierEnable(this.beautifierEnabled)
    Logger.info(TAG, 'native beautifier done')
    if (this.beautifierEnabled) {
      nativeAudio.setVoiceBeautifierType(this.beautifierType)
    }
    nativeAudio.setSpaceRenderEnable(this.spaceRenderEnabled)
    Logger.info(TAG, 'native spaceRender done')
    if (this.spaceRenderEnabled) {
      nativeAudio.setSpaceRenderConfig(this.spaceRenderMode, this.spaceRenderValues)
    }
    nativeAudio.setGeneralVoiceChangeEnable(this.generalVoiceChangeEnabled)
    Logger.info(TAG, 'native generalVoiceChange done')
    if (this.generalVoiceChangeEnabled) {
      nativeAudio.setGeneralVoiceChangeType(this.generalVoiceChangeType)
    }
    nativeAudio.setNoiseReductionEnable(this.noiseReductionEnabled)
    Logger.info(TAG, 'native noiseReduction done')
    nativeAudio.setPureVoiceChangeEnable(this.pureVoiceChangeEnabled)
    Logger.info(TAG, 'native pureVoiceChange done')
    if (this.pureVoiceChangeEnabled) {
      nativeAudio.setPureVoiceChangeConfig(this.pureVoiceChangeGender, this.pureVoiceChangeType,
        this.pureVoiceChangePitch)
      Logger.info(TAG, 'native pureVoiceChange config done')
    }
    nativeAudio.setTempoPitchEnable(this.tempoPitchEnabled)
    Logger.info(TAG, 'native tempoPitch done')
    if (this.tempoPitchEnabled) {
      nativeAudio.setTempoPitchConfig(this.tempoSpeed, this.tempoPitch)
      Logger.info(TAG, 'native tempoPitch config done')
    }
    nativeAudio.setSeparationEnable(this.separationEnabled)
    Logger.info(TAG, 'native separation done')
    if (this.separationEnabled) {
      nativeAudio.setSeparationOutput(this.separationOutput)
      Logger.info(TAG, 'native separation output done')
    }
    Logger.info(TAG, 'native apply end')
  }

  // 播放中开启音效：取实时位置重载播放，让效果链立即接入当前曲目
  private async reloadForNativeEffects(): Promise<void> {
    const isPlaying: boolean = AppStorage.get<boolean>(AppStorageKeyConstants.KEY_IS_PLAY) ?? false
    if (!isPlaying || this.currentFilePath.length === 0) {
      return
    }
    const position: number = this.getCurrentPositionMs()
    const fileUri: string = this.currentFilePath
    await this.play(fileUri, position)
  }

  private async playWithEffects(
    fileUri: string, requestId: number, startPositionMs: number = 0,
    startPaused: boolean = false): Promise<boolean> {
    this.stopNativeProgressTimer()
    this.stopNativeStartupCheck()
    let file: fs.File | undefined = undefined
    try {
      file = fs.openSync(fileUri, fs.OpenMode.READ_ONLY)
      const size: number = fs.statSync(file.fd).size
      this.applyAllEffectsToNative()
      // 低功耗链路开关在每次起播前同步进原生引擎（下次 Play 生效的策略）
      nativeAudio.setLowPowerMode(DataService.getInstance().getSettings().lowPowerPlayback)
      const fadeInOutOnStart: boolean = !startPaused && (AppStorage.get<boolean>('uplayer_fade_in_out') ?? false)
      if (startPaused || fadeInOutOnStart) {
        nativeAudio.setVolume(0)
      }
      const started: boolean = await nativeAudio.play(file.fd, size, startPositionMs)
      if (requestId !== this.playRequestId) {
        if (started) {
          nativeAudio.stop()
        }
        return false
      }
      if (!started) {
        Logger.error(TAG, 'native player start failed')
        return false
      }
      this.activePlaybackGeneration = requestId
      this.backendState = BackendState.PLAYING
      if (fadeInOutOnStart) {
        this.fadeIn()
      } else {
        nativeAudio.setVolume(this.desiredVolume)
      }
      nativeAudio.setSpeed(this.desiredSpeed)
      this.currentFilePath = fileUri
      if (startPaused) {
        // 暂停态切歌：加载后立即暂停，不进入播放态
        nativeAudio.pause()
        AppStorage.setOrCreate<boolean>(AppStorageKeyConstants.KEY_IS_PLAY, false)
      } else {
        AppStorage.setOrCreate<boolean>(AppStorageKeyConstants.KEY_IS_PLAY, true)
      }
      AppStorage.setOrCreate<number>(AppStorageKeyConstants.KEY_TOTAL_MS_TIME, nativeAudio.getDuration())
      AppStorage.setOrCreate(AppStorageKeyConstants.KEY_PROGRESS_MAX, nativeAudio.getDuration())
      AppStorage.setOrCreate(AppStorageKeyConstants.KEY_TOTAL_TIME, this.formatTime(nativeAudio.getDuration()))
      this.sessionController.setPlayState(!startPaused)
      this.sessionController.setAVMetadata()
      if (!startPaused) {
        this.startBackground()
      }
      this.startNativeProgressTimer(fileUri, requestId)
      this.startNativeStartupCheck(fileUri, requestId)
      return true
    } catch (err) {
      Logger.error(TAG, `playWithEffects failed: ${JSON.stringify(err)}`)
      return false
    } finally {
      if (file !== undefined) {
        this.closeFile(file)
      }
    }
  }

  // 原生管线播放中途失败/启动超时：无回退路径，停止播放并提示用户
  private handleNativeFailure(requestId: number, reason: string): void {
    if (!this.isCurrentGeneration(requestId)) {
      return
    }
    this.enqueueOperation(async (): Promise<void> => {
      if (!this.isCurrentGeneration(requestId)) {
        return
      }
      this.stopNativeProgressTimer()
      this.stopNativeStartupCheck()
      this.stopFade()
      nativeAudio.stop()
      this.currentFilePath = ''
      this.backendState = BackendState.IDLE
      AppStorage.setOrCreate<boolean>(AppStorageKeyConstants.KEY_IS_PLAY, false)
      this.sessionController.setPlayState(false)
      this.stopBackground()
      Logger.error(TAG, `${reason}, playback stopped`)
      this.notifyPlaybackFailed('播放出错，已停止')
    })
  }

  // 主窗口是否可见（EntryAbility 前后台写入）：隐藏时进度/时间不再写入 AppStorage，
  // 避免主窗口不可见时 UI 持续请求 vsync 收不到帧而刷告警；媒体会话进度不受影响
  private isUiActive(): boolean {
    return AppStorage.get<boolean>(AppStorageKeyConstants.KEY_UI_ACTIVE) !== false
  }

  // 实时播放位置（ms）：查原生引擎 NAPI
  public getCurrentPositionMs(): number {
    if (!this.isEngineLoaded()) {
      return 0
    }
    return nativeAudio.getPosition()
  }

  private startNativeProgressTimer(fileUri: string, requestId: number): void {
    this.stopNativeProgressTimer()
    this.nativeProgressTimer = setInterval(() => {
      if (requestId !== this.playRequestId || !this.isEngineLoaded()) {
        this.stopNativeProgressTimer()
        return
      }
      const position: number = nativeAudio.getPosition()
      if (!this.isSeeking && this.isUiActive()) {
        AppStorage.setOrCreate(AppStorageKeyConstants.KEY_PROGRESS, position)
      }
      if (this.isUiActive()) {
        AppStorage.setOrCreate(AppStorageKeyConstants.KEY_CURRENT_TIME, this.formatTime(position))
      }
      this.sessionController.setProgressState(position)
      // seek 已实际生效（位置离开 seek 前的基准）则提前解除进度抑制，不等 2s 兜底
      if (this.isSeeking && this.seekFromMs >= 0 && Math.abs(position - this.seekFromMs) > 200) {
        this.isSeeking = false
        this.seekFromMs = -1
        if (this.seekingClearTimer !== -1) {
          clearTimeout(this.seekingClearTimer)
          this.seekingClearTimer = -1
        }
      }
      if (nativeAudio.hasFailed()) {
        this.stopNativeProgressTimer()
        this.handleNativeFailure(requestId, 'native render failed')
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
      if (!this.isEngineLoaded() || nativeAudio.isReady()) {
        this.stopNativeStartupCheck()
        return
      }
      if (nativeAudio.hasFailed() || checkCount >= 20) {
        this.stopNativeStartupCheck()
        this.handleNativeFailure(requestId, 'native startup timeout')
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
