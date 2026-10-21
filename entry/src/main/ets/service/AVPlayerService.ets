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
import { SettingsStore } from '../common/utils/SettingsStore'

const TAG = 'AVPlayerService'
// 断点续播（P0-2）：上次播放歌曲/位置持久化键
const KEY_LAST_SONG_ID: string = 'uplayer_last_song_id'
const KEY_LAST_POSITION_MS: string = 'uplayer_last_position_ms'

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
  // ReplayGain（P2-1）：按歌曲暂存的定增益（stageReplayGain 计算，playWithEffects 下发）
  private replayGainEnabled: boolean = false
  private replayGainDb: number = 0
  // 音效节点能力探测缓存（undefined = 尚未探测）：见 ensureEffectNodeSupport()
  private effectNodeSupport: EffectNodeSupport | undefined = undefined
  private nativeProgressTimer: number = -1
  private nativeStartupTimer: number = -1
  // 断点续播（P0-2）：进度定时器周期性落盘位置的 tick 计数（每 20 tick ≈ 5s 一次防抖写）
  private lastPlaybackPersistTickCount: number = 0
  private playRequestId: number = 0
  private activePlaybackGeneration: number = -1
  private completionGeneration: number = -1
  private isSwitchingTrack: boolean = false
  private operationQueue: Promise<void> = Promise.resolve()
  private backendState: BackendState = BackendState.IDLE
  private pendingSeekMs: number | undefined = undefined
  // 强制下次 play 绕过同文件复用分支重建管线（低功耗开关切换/运行期回退时使用）
  private forcePipelineRebuild: boolean = false
  private desiredVolume: number = 1
  private desiredSpeed: number = 1
  private isSeeking: boolean = false
  private seekingClearTimer: number = -1
  private seekFromMs: number = -1
  // 按歌曲数定时（P0-1）：最后一首曲尾淡出已触发标志，防止进度定时器重复启动淡出；
  // 每次 play 新曲目/seek 打断时复位
  private timerSongTailFadeStarted: boolean = false

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
    this.timerSongTailFadeStarted = false
    this.lastPlaybackPersistTickCount = 0
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
    // 保证「与其他音频同时播放（含通知不压低音量）」的并发策略仍然生效
    AudioFocusService.getInstance().ensureStrategy()
    // 若当前处于播放状态，本次是切歌（播放中切到下一首），stop/reset 期间不应把播放状态置为暂停
    const wasPlaying: boolean = AppStorage.get<boolean>(AppStorageKeyConstants.KEY_IS_PLAY) ?? false
    this.isSwitchingTrack = wasPlaying
    // 同一文件且引擎仍在途：seek + resume 复用，不重建管线（低功耗切换/运行期回退要求重建时跳过）
    if (!this.forcePipelineRebuild && this.isEngineLoaded() && this.currentFilePath === fileUri &&
      !nativeAudio.isCompleted() && !nativeAudio.hasFailed()) {
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
      // 复用分支同样要把进度/启动看护定时器迁移到新代次：requestId 已自增，
      // 旧定时器会因代次不匹配自杀，不在此重启则音效开关后进度条/歌词全部冻结
      this.startNativeProgressTimer(fileUri, requestId)
      this.startNativeStartupCheck(fileUri, requestId)
      this.applyPendingNativeSeek()
      return
    }
    this.backendState = BackendState.STARTING
    this.forcePipelineRebuild = false
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

  async playSong(song: SongInfo, index: number, startPaused: boolean = false,
    startMs: number = 0): Promise<void> {
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
    AppStorage.setOrCreate(AppStorageKeyConstants.KEY_PROGRESS, startMs > 0 ? startMs : 0)
    AppStorage.setOrCreate(AppStorageKeyConstants.KEY_CURRENT_TIME, '00:00')
    AppStorage.setOrCreate(AppStorageKeyConstants.KEY_TOTAL_MS_TIME, song.duration)
    AppStorage.setOrCreate(AppStorageKeyConstants.KEY_PROGRESS_MAX, song.duration)
    AppStorage.setOrCreate(AppStorageKeyConstants.KEY_TOTAL_TIME, this.formatTime(song.duration))
    AppStorage.setOrCreate(AppStorageKeyConstants.KEY_SELECT_INDEX, index)
    // 断点续播（P0-2）：切歌即记录新歌曲为「上次播放」，位置从 0（或续播起点）开始；
    // 防抖中的旧位置落盘会被本次覆盖为最新值，不会写入新歌配旧位置
    SettingsStore.getInstance().set(KEY_LAST_SONG_ID, song.id, true)
    SettingsStore.getInstance().set(KEY_LAST_POSITION_MS, startMs > 0 ? startMs.toString() : '0', true)
    this.liveViewService.updateLiveView()
    this.stageReplayGain(song)
    await this.play(song.uri.length > 0 ? song.uri : song.filePath, startMs, startPaused)
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
    // P0-4：自然完曲计数（随机/单曲循环同样经此路径，符合"自然完曲"定义）；
    // 先记统计再切歌——切歌后 uplayer_current_song_id 已指向下一首
    const completedSongId: string = AppStorage.get<string>('uplayer_current_song_id') ?? ''
    if (completedSongId.length > 0) {
      DataService.getInstance().recordPlayStats(completedSongId)
    }
    // 按歌曲数定时递减（P0-1）：最后一首曲尾淡出触发时不会走到这里（淡出完成已直接 stop），
    // 走到本分支说明淡出时长为 0（立即停止）或曲尾淡出窗口未命中（seek 打断后自然完曲）
    const songsRemaining: number =
      AppStorage.get<number>(AppStorageKeyConstants.KEY_TIMER_SONGS_REMAINING) ?? 0
    if (songsRemaining > 0) {
      const nextRemaining: number = songsRemaining - 1
      AppStorage.setOrCreate(AppStorageKeyConstants.KEY_TIMER_SONGS_REMAINING, nextRemaining)
      if (nextRemaining <= 0) {
        this.timerSongTailFadeStarted = false
        this.stop().catch((err: Error): void => {
          Logger.error(TAG, `timer songs stop failed: ${JSON.stringify(err)}`)
        })
        return
      }
    }
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
    // 原生 Resume 失败已回滚暂停态（如渲染器 Start 失败），此处以原生实际状态为准，
    // 避免 AVSession/播放态谎报「播放中」而进度冻结
    const playing: boolean = nativeAudio.isPlaying()
    AppStorage.setOrCreate<boolean>(AppStorageKeyConstants.KEY_IS_PLAY, playing)
    this.sessionController.setPlayState(playing)
    this.startBackground()
  }

  pause(): void {
    if (!this.isEngineLoaded()) {
      return
    }
    // 断点续播（P0-2）：暂停即落盘当前位置（淡出暂停路径位置不变）
    this.persistLastPlayback(true)
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

  // 定时停止淡出时长（ms）：设置页滑条 0-10 秒，0=立即停止不淡出
  private getTimerFadeMs(): number {
    const seconds: number =
      AppStorage.get<number>(AppStorageKeyConstants.KEY_TIMER_FADE_SECONDS) ?? 3
    if (!Number.isFinite(seconds) || seconds < 0) {
      return 3000
    }
    return Math.min(seconds, 10) * 1000
  }

  // 定长淡出到静音后回调（定时停止共用）：曲线复用 fadeOut 的指数衰减，步数固定 30 档，
  // 间隔按时长伸缩；期间用户起新播放/暂停会经 stopFade/fadeIn 打断本定时器，回调不再触发
  private fadeOutWithDuration(fadeMs: number, onFinished: () => void): void {
    this.stopFade()
    if (fadeMs <= 0) {
      onFinished()
      return
    }
    const startVol: number = AppStorage.get<number>(AppStorageKeyConstants.KEY_CURRENT_VOLUME) ?? 1
    const intervalMs: number = fadeMs / AVPlayerService.FADE_STEPS
    this.fadeStep = 0
    this.fadeTimer = setInterval(() => {
      this.fadeStep++
      const ratio: number = Math.min(this.fadeStep / AVPlayerService.FADE_STEPS, 1)
      this.applyFadeVolume(Math.max(startVol * Math.pow(AVPlayerService.FADE_FLOOR, ratio), 0))
      if (this.fadeStep >= AVPlayerService.FADE_STEPS) {
        this.stopFade()
        this.applyFadeVolume(0)
        onFinished()
      }
    }, intervalMs)
  }

  // 定时停止（时间模式到期入口，ControlAreaComponent 调用）：按设置淡出时长平滑降至静音后停止；
  // 淡出期间用户手动起新播放会改变代次，回调校验后代次不一致则放弃停止
  fadeOutAndStop(): void {
    const generation: number = this.playRequestId
    this.fadeOutWithDuration(this.getTimerFadeMs(), (): void => {
      if (generation !== this.playRequestId) {
        return
      }
      this.stop().catch((err: Error): void => {
        Logger.error(TAG, `timer fade stop failed: ${JSON.stringify(err)}`)
      })
    })
  }

  // 按歌曲数定时：最后一首进入曲尾淡出窗口（剩余时长 <= 淡出时长）时由进度定时器触发，
  // 淡出完成后清零计数并停止；seek 打断由 seek() 复位标志并恢复音量，下次进窗口可重新触发
  private startTimerSongTailFade(fadeMs: number): void {
    this.timerSongTailFadeStarted = true
    const generation: number = this.playRequestId
    this.fadeOutWithDuration(fadeMs, (): void => {
      if (!this.timerSongTailFadeStarted || generation !== this.playRequestId) {
        return
      }
      this.timerSongTailFadeStarted = false
      AppStorage.setOrCreate(AppStorageKeyConstants.KEY_TIMER_SONGS_REMAINING, 0)
      this.stop().catch((err: Error): void => {
        Logger.error(TAG, `timer songs fade stop failed: ${JSON.stringify(err)}`)
      })
    })
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

  // 断点续播（P0-2）：持久化当前歌曲与播放位置；immediate=false 走 300ms 防抖合并落盘
  // （进度定时器周期调用），true 立即落盘（暂停/停止/切歌）
  persistLastPlayback(immediate: boolean = false): void {
    const songId: string = AppStorage.get<string>('uplayer_current_song_id') ?? ''
    if (songId.length === 0) {
      return
    }
    SettingsStore.getInstance().set(KEY_LAST_SONG_ID, songId, immediate)
    SettingsStore.getInstance().set(KEY_LAST_POSITION_MS, this.getCurrentPositionMs().toString(), immediate)
  }

  // 断点续播（P0-2）：冷启动恢复上次播放歌曲与进度（EntryAbility 首帧后调用一次）；
  // 「启动时恢复上次播放」关则跳过；「恢复后自动播放」决定恢复后是否直接起播；
  // 位置越界或距曲尾不足 2s 时从头播放
  async restoreLastPlayback(): Promise<void> {
    const settings: AppSettingsData = DataService.getInstance().getSettings()
    if (!settings.resumePlaybackOnStart) {
      return
    }
    const songId: string = SettingsStore.getInstance().get(KEY_LAST_SONG_ID, '')
    if (songId.length === 0) {
      return
    }
    const songs: SongInfo[] = DataService.getInstance().getSongs()
    let index: number = -1
    for (let i = 0; i < songs.length; i++) {
      if (songs[i].id === songId) {
        index = i
        break
      }
    }
    if (index < 0 || !songs[index].isAvailable) {
      Logger.info(TAG, `restoreLastPlayback: song ${songId} missing or unavailable`)
      return
    }
    const parsedPos: number = parseInt(SettingsStore.getInstance().get(KEY_LAST_POSITION_MS, '0'))
    let startMs: number = Number.isFinite(parsedPos) && parsedPos > 0 ? parsedPos : 0
    if (startMs + 2000 >= songs[index].duration) {
      startMs = 0
    }
    const startPaused: boolean = !settings.autoPlayAfterResume
    Logger.info(TAG, `restoreLastPlayback: id=${songId} pos=${startMs} autoPlay=${settings.autoPlayAfterResume}`)
    await this.playSong(songs[index], index, startPaused, startMs)
  }

  async stop(): Promise<void> {
    const generation: number = ++this.playRequestId
    await this.enqueueOperation(async (): Promise<void> => {
      if (!this.isCurrentGeneration(generation)) return
      this.backendState = BackendState.STOPPING
      this.stopNativeProgressTimer()
      this.stopNativeStartupCheck()
      this.stopFade()
      // 断点续播（P0-2）：停止前记录当前位置，下次冷启动可从停止处续播
      this.persistLastPlayback(true)
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
    // 按歌曲数定时曲尾淡出被 seek 打断：中止淡出并恢复音量，复位标志后窗口再次命中可重新淡出
    if (this.timerSongTailFadeStarted) {
      this.timerSongTailFadeStarted = false
      this.stopFade()
      if (this.isEngineLoaded()) {
        nativeAudio.setVolume(this.desiredVolume)
      }
    }
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
  // 播放中切换：绕过同文件复用分支，从当前位置重建管线，让新链路立即生效
  applyLowPowerPlayback(enabled: boolean): void {
    nativeAudio.setLowPowerMode(enabled)
    const isPlaying: boolean = AppStorage.get<boolean>(AppStorageKeyConstants.KEY_IS_PLAY) ?? false
    if (!isPlaying || this.currentFilePath.length === 0) {
      return
    }
    this.forcePipelineRebuild = true
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
    this.equalizerEnabled = enabled
    this.equalizerBands = this.normalizeEqualizerBands(bands)
    nativeAudio.setEqualizerEnable(enabled)
    if (enabled) {
      nativeAudio.setEqualizerBands(this.equalizerBands)
    }
  }

  // 任一音效启用即需要走原生链路（管线 Bypass/管线切换即时生效）
  anyEffectEnabled(): boolean {
    return this.equalizerEnabled || this.soundFieldEnabled || this.environmentEnabled ||
      this.beautifierEnabled || this.spaceRenderEnabled || this.generalVoiceChangeEnabled ||
      this.noiseReductionEnabled || this.pureVoiceChangeEnabled || this.tempoPitchEnabled ||
      this.separationEnabled
  }

  // 启动时把持久化设置读回内存运行态（EntryAbility 在首帧之后调用）。
  // 这里刻意不调用 applyAllEffectsToNative()：那是 20+ 次同步音效 NAPI（内部会创建
  // AudioSuite 引擎/管线并逐个节点下发），一旦被系统 IPC 拖住不返回就会冻住 UI 线程；
  // 原生侧的下发由每次起播的 playWithEffects 全量完成，启动期再推一次纯属重复。
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
    this.generalVoiceChangeEnabled = enabled
    this.generalVoiceChangeType = type
    nativeAudio.setGeneralVoiceChangeEnable(enabled)
    if (enabled) {
      nativeAudio.setGeneralVoiceChangeType(this.generalVoiceChangeType)
    }
  }

  async applyNoiseReduction(enabled: boolean): Promise<void> {
    this.noiseReductionEnabled = enabled
    nativeAudio.setNoiseReductionEnable(enabled)
  }

  async applyPureVoiceChange(enabled: boolean, gender: number = 1, type: number = 1,
    pitch: number = 0): Promise<void> {
    this.pureVoiceChangeEnabled = enabled
    this.pureVoiceChangeGender = gender
    this.pureVoiceChangeType = type
    this.pureVoiceChangePitch = pitch
    nativeAudio.setPureVoiceChangeEnable(enabled)
    if (enabled) {
      nativeAudio.setPureVoiceChangeConfig(this.pureVoiceChangeGender, this.pureVoiceChangeType,
        this.pureVoiceChangePitch)
    }
  }

  async applyTempoPitch(enabled: boolean, speed: number = 1, pitch: number = 1): Promise<void> {
    this.tempoPitchEnabled = enabled
    this.tempoSpeed = speed
    this.tempoPitch = pitch
    nativeAudio.setTempoPitchEnable(enabled)
    if (enabled) {
      nativeAudio.setTempoPitchConfig(this.tempoSpeed, this.tempoPitch)
    }
  }

  async applySeparation(enabled: boolean, output: number = 1): Promise<void> {
    this.separationEnabled = enabled
    this.separationOutput = output
    nativeAudio.setSeparationEnable(enabled)
    if (enabled) {
      nativeAudio.setSeparationOutput(this.separationOutput)
    }
  }

  async applySoundField(enabled: boolean, type: number = 1): Promise<void> {
    this.soundFieldEnabled = enabled
    this.soundFieldType = type
    nativeAudio.setSoundFieldEnable(enabled)
    if (enabled) {
      nativeAudio.setSoundFieldType(this.soundFieldType)
    }
  }

  async applyEnvironment(enabled: boolean, type: number = 1): Promise<void> {
    this.environmentEnabled = enabled
    this.environmentType = type
    nativeAudio.setEnvironmentEnable(enabled)
    if (enabled) {
      nativeAudio.setEnvironmentType(this.environmentType)
    }
  }

  async applyVoiceBeautifier(enabled: boolean, type: number = 1): Promise<void> {
    this.beautifierEnabled = enabled
    this.beautifierType = type
    nativeAudio.setVoiceBeautifierEnable(enabled)
    if (enabled) {
      nativeAudio.setVoiceBeautifierType(this.beautifierType)
    }
  }

  async applySpaceRender(enabled: boolean, mode: number = 0, values: number[] = [0, 0, 0]): Promise<void> {
    this.spaceRenderEnabled = enabled
    this.spaceRenderMode = mode
    this.spaceRenderValues = values
    nativeAudio.setSpaceRenderEnable(enabled)
    if (enabled) {
      nativeAudio.setSpaceRenderConfig(this.spaceRenderMode, this.spaceRenderValues)
    }
  }

  // ReplayGain（P2-1）：按设置模式解析当前歌曲标签增益（库值 = round(db*100) centi-dB）
  // 并叠加预增益，暂存待 playWithEffects 下发；模式关/无标签按 0dB 处理
  private stageReplayGain(song: SongInfo): void {
    const settings: AppSettingsData = DataService.getInstance().getSettings()
    const mode: string = settings.replayGainMode
    if (mode !== 'track' && mode !== 'album') {
      this.replayGainEnabled = false
      this.replayGainDb = 0
      return
    }
    let tagCentiDb: number = song.rgTrackGain
    if (mode === 'album') {
      tagCentiDb = song.rgAlbumGain !== 0 ? song.rgAlbumGain : tagCentiDb
    }
    this.replayGainEnabled = true
    this.replayGainDb = tagCentiDb / 100 + settings.replayGainPreGainDb
  }

  // 设置页实时生效：重算当前歌曲 RG 并直接下发原生（未加载引擎时只更新暂存值，
  // 下次起播由 playWithEffects 一并推送）
  applyReplayGainSettings(): void {
    const songId: string = AppStorage.get<string>('uplayer_current_song_id') ?? ''
    if (songId.length === 0) {
      return
    }
    const song: SongInfo | undefined = DataService.getInstance().getSongById(songId)
    if (song === undefined) {
      return
    }
    this.stageReplayGain(song)
    nativeAudio.setReplayGainEnable(this.replayGainEnabled)
    if (this.replayGainEnabled) {
      nativeAudio.setReplayGainDb(this.replayGainDb)
    }
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
      // ReplayGain（P2-1）：按歌曲暂存的定增益同步进原生引擎（所有输出路径统一应用）
      nativeAudio.setReplayGainEnable(this.replayGainEnabled)
      if (this.replayGainEnabled) {
        nativeAudio.setReplayGainDb(this.replayGainDb)
      }
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
      // 断点续播（P0-2）：每 20 tick（约 5s）防抖落盘一次播放位置，避免每 250ms 写盘
      this.lastPlaybackPersistTickCount++
      if (this.lastPlaybackPersistTickCount >= 20) {
        this.lastPlaybackPersistTickCount = 0
        this.persistLastPlayback(false)
      }
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
      // 低功耗链路运行期报错：native 侧已停喂并阻止低功耗重启，这里重建正常管线续播
      if (nativeAudio.consumeLowPowerRuntimeError()) {
        this.stopNativeProgressTimer()
        Logger.warn(TAG, 'low-power sink runtime error, rebuilding full pipeline')
        const fallbackUri: string = this.currentFilePath
        const fallbackPosition: number = position
        if (fallbackUri.length > 0) {
          this.forcePipelineRebuild = true
          this.play(fallbackUri, fallbackPosition).catch((err: Error): void => {
            Logger.error(TAG, `low-power runtime error fallback replay failed: ${JSON.stringify(err)}`)
          })
        }
        return
      }
      if (nativeAudio.hasFailed()) {
        this.stopNativeProgressTimer()
        this.handleNativeFailure(requestId, 'native render failed')
        return
      }
      // 按歌曲数定时（P0-1）：最后一首且进入曲尾淡出窗口时平滑淡出后停止（播放态且非 seek 中）
      if (!this.timerSongTailFadeStarted && !this.isSeeking &&
        (AppStorage.get<boolean>(AppStorageKeyConstants.KEY_IS_PLAY) ?? false)) {
        const songsRemaining: number =
          AppStorage.get<number>(AppStorageKeyConstants.KEY_TIMER_SONGS_REMAINING) ?? 0
        if (songsRemaining === 1) {
          const tailFadeMs: number = this.getTimerFadeMs()
          const durationMs: number = nativeAudio.getDuration()
          const tailMs: number = durationMs - position
          if (tailFadeMs > 0 && durationMs > 0 && tailMs > 0 && tailMs <= tailFadeMs) {
            this.startTimerSongTailFade(tailFadeMs)
          }
        }
      }
      // 仅播放态允许自然播完自动切歌：暂停态下 isCompleted 为真属于异常
      // （历史缺陷：暂停中管线隐形跑完本曲），此时不得自动播下一首
      if (nativeAudio.isCompleted() &&
        (AppStorage.get<boolean>(AppStorageKeyConstants.KEY_IS_PLAY) ?? false)) {
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
