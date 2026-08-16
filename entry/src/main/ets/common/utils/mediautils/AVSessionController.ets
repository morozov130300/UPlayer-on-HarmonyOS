import { common, wantAgent } from '@kit.AbilityKit';
import { avSession } from '@kit.AVSessionKit';
import { SongInfo } from '../../../model/SongInfo';
import { AVPlayerService } from '../../../service/AVPlayerService';
import { AlbumCoverLease, AlbumCoverSize, AudioMetadataService } from '../../../service/AudioMetadataService';
import Logger from '../Logger';
import { MusicPlayMode } from '../../constants/PlayerConstants';
import { DataService } from '../../../service/DataService';
import { PreferencesUtil } from '../PreferencesUtil';
import { AppStorageKeyConstants } from '../../constants/AppStorageKeyConstants';
import { image } from '@kit.ImageKit';
import { BusinessError } from '@kit.BasicServicesKit';
import WantAgent from '@ohos.app.ability.wantAgent';

const TAG = 'AVSessionController';

export class AVSessionController {
  private context: common.UIAbilityContext | undefined = undefined;
  private AVSession: avSession.AVSession | undefined = undefined;
  private songList: SongInfo[] = [];
  private musicIndex: number = 0;
  private avPlayerService: AVPlayerService | undefined = undefined;
  private metadataRequestId: number = 0;
  private metadataCoverLease: AlbumCoverLease | undefined = undefined;
  private lastProgressReportTime: number = 0;
  private lastProgressReportPosition: number = -1;
  private sessionAvailable: boolean = false;
  private playbackStateInFlight: boolean = false;
  private pendingPlaybackState: avSession.AVPlaybackState | undefined = undefined;
  private lastSubmittedPlayState: avSession.PlaybackState | undefined = undefined;
  private lastSubmittedActiveItemId: number = -1;

  private getAvPlayerService(): AVPlayerService {
    if (this.avPlayerService === undefined) {
      this.avPlayerService = AVPlayerService.getInstance();
    }
    return this.avPlayerService;
  }
  private static avSessionController: AVSessionController;

  constructor() {
    const list: SongInfo[] | undefined = AppStorage.get(AppStorageKeyConstants.KEY_SONG_LIST);
    if (list) {
      this.songList = list;
    }
  }

  public static getInstance(): AVSessionController {
    if (!AVSessionController.avSessionController) {
      AVSessionController.avSessionController = new AVSessionController();
    }
    return AVSessionController.avSessionController;
  }

  public async initAVSession(): Promise<void> {
    this.context = AppStorage.get(AppStorageKeyConstants.KEY_UI_ABILITY_CONTEXT);
    if (!this.context) {
      Logger.info(TAG, `session create failed, context is undefined`);
      return;
    }
    try {
      this.AVSession = await avSession.createAVSession(this.context, "PLAY_AUDIO", 'audio');
      this.sessionAvailable = true;
      this.setListenerForMesFromController();
      this.setInitialPlaybackState();
      this.setLaunchAbility();
      this.setAVQueueTitle();
      await this.setAVQueueItems();
      await this.setAVMetadata();
      this.getAndUpdateFavoriteState(this.musicIndex.toString());
      await this.AVSession.activate();
      Logger.info(TAG, `session create succeeded : sessionId : ${this.AVSession.sessionId}`);
    } catch (err) {
      this.sessionAvailable = false;
      this.AVSession = undefined;
      Logger.error(TAG, `session create failed: ${JSON.stringify(err)}`);
    }
  }

  private setInitialPlaybackState(): void {
    if (!this.AVSession) {
      return;
    }
    const isPlay: boolean = AppStorage.get<boolean>(AppStorageKeyConstants.KEY_IS_PLAY) ?? false;
    const playMode: MusicPlayMode = AppStorage.get<MusicPlayMode>(AppStorageKeyConstants.KEY_PLAY_MODE) ??
      MusicPlayMode.ORDER;
    let loopMode: avSession.LoopMode = avSession.LoopMode.LOOP_MODE_SEQUENCE;
    if (playMode === MusicPlayMode.SINGLE_CYCLE) {
      loopMode = avSession.LoopMode.LOOP_MODE_SINGLE;
    } else if (playMode === MusicPlayMode.RANDOM) {
      loopMode = avSession.LoopMode.LOOP_MODE_SHUFFLE;
    }
    const playbackState: avSession.AVPlaybackState = {
      state: isPlay ? avSession.PlaybackState.PLAYBACK_STATE_PLAY : avSession.PlaybackState.PLAYBACK_STATE_PAUSE,
      speed: 1.0,
      bufferedTime: 0,
      loopMode: loopMode,
      isFavorite: false,
    };
    this.queuePlaybackState(playbackState);
  }

  private mergePlaybackState(
    base: avSession.AVPlaybackState | undefined,
    update: avSession.AVPlaybackState): avSession.AVPlaybackState {
    const merged: avSession.AVPlaybackState = {};
    if (base !== undefined) {
      if (base.state !== undefined) merged.state = base.state;
      if (base.position !== undefined) merged.position = base.position;
      if (base.speed !== undefined) merged.speed = base.speed;
      if (base.bufferedTime !== undefined) merged.bufferedTime = base.bufferedTime;
      if (base.loopMode !== undefined) merged.loopMode = base.loopMode;
      if (base.isFavorite !== undefined) merged.isFavorite = base.isFavorite;
      if (base.activeItemId !== undefined) merged.activeItemId = base.activeItemId;
      if (base.extras !== undefined) merged.extras = base.extras;
    }
    if (update.state !== undefined) merged.state = update.state;
    if (update.position !== undefined) merged.position = update.position;
    if (update.speed !== undefined) merged.speed = update.speed;
    if (update.bufferedTime !== undefined) merged.bufferedTime = update.bufferedTime;
    if (update.loopMode !== undefined) merged.loopMode = update.loopMode;
    if (update.isFavorite !== undefined) merged.isFavorite = update.isFavorite;
    if (update.activeItemId !== undefined) merged.activeItemId = update.activeItemId;
    if (update.extras !== undefined) merged.extras = update.extras;
    return merged;
  }

  private queuePlaybackState(update: avSession.AVPlaybackState): void {
    if (!this.sessionAvailable || !this.AVSession) {
      return;
    }
    this.pendingPlaybackState = this.mergePlaybackState(this.pendingPlaybackState, update);
    this.submitNextPlaybackState();
  }

  private submitNextPlaybackState(): void {
    const session: avSession.AVSession | undefined = this.AVSession;
    if (!this.sessionAvailable || !session || this.playbackStateInFlight || !this.pendingPlaybackState) {
      return;
    }
    const state: avSession.AVPlaybackState = this.pendingPlaybackState;
    this.pendingPlaybackState = undefined;
    this.playbackStateInFlight = true;
    session.setAVPlaybackState(state, (err: BusinessError) => {
      this.playbackStateInFlight = false;
      if (err) {
        Logger.error(TAG, `setAVPlaybackState BusinessError: code: ${err.code}, message: ${err.message}`);
      }
      if (this.sessionAvailable && this.AVSession === session) {
        this.submitNextPlaybackState();
      }
    });
  }

  public async setAVQueueItems(): Promise<void> {
    if (!this.AVSession) {
      return;
    }
    this.refreshSongList();
    if (this.songList.length === 0) {
      return;
    }
    try {
      const queueItems: avSession.AVQueueItem[] = [];
      for (let i = 0; i < this.songList.length; i++) {
        const song: SongInfo = this.songList[i];
        const description: avSession.AVMediaDescription = {
          assetId: `${i}`,
          title: song.title,
          subtitle: song.artist,
        };
        const queueItem: avSession.AVQueueItem = {
          itemId: i + 1,
          description: description,
        };
        queueItems.push(queueItem);
      }
      await this.AVSession.setAVQueueItems(queueItems);
      Logger.info(TAG, 'setAVQueueItems successfully');
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      Logger.error(TAG, `setAVQueueItems failed: ${error.code} ${error.message}`);
    }
  }

  public setAVQueueTitle(): void {
    if (!this.AVSession) {
      return;
    }
    this.AVSession.setAVQueueTitle('UPlayer', (err: BusinessError) => {
      if (err) {
        Logger.error(TAG, `setAVQueueTitle BusinessError: code: ${err.code}, message: ${err.message}`);
      } else {
        Logger.info(TAG, 'setAVQueueTitle successfully');
      }
    });
  }

  private setLaunchAbility(): void {
    if (!this.context) {
      return;
    }
    const wantAgentInfo: wantAgent.WantAgentInfo = {
      wants: [
        {
          bundleName: this.context.abilityInfo.bundleName,
          abilityName: this.context.abilityInfo.name
        }
      ],
      operationType: wantAgent.OperationType.START_ABILITIES,
      requestCode: 0,
      wantAgentFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
    };
    wantAgent.getWantAgent(wantAgentInfo).then((agent: Object) => {
      if (this.AVSession) {
        this.AVSession.setLaunchAbility(agent);
      }
    }).catch((err: BusinessError) => {
      Logger.error(TAG, `getWantAgent failed: code: ${err.code}, message: ${err.message}`);
    });
  }

  private getDuration(): number | undefined {
    const duration: number | undefined = AppStorage.get(AppStorageKeyConstants.KEY_TOTAL_MS_TIME);
    if (!duration) {
      Logger.error(TAG, 'get duration failed');
      return undefined;
    }
    return duration;
  }

  public async setAVMetadata(): Promise<void> {
    const requestId: number = ++this.metadataRequestId;
    this.musicIndex = AppStorage.get(AppStorageKeyConstants.KEY_SELECT_INDEX) ?? 0;
    const requestedIndex: number = this.musicIndex;
    Logger.info(TAG, 'current musicIndex is:' + this.musicIndex);
    this.refreshSongList();
    if (this.musicIndex < 0 || this.musicIndex >= this.songList.length) {
      return;
    }
    try {
      if (this.context) {
        const song: SongInfo = this.songList[this.musicIndex];
        const coverLease: AlbumCoverLease | undefined = await AudioMetadataService.getInstance()
          .acquireAlbumCover(song, AlbumCoverSize.MEDIUM);
        if (requestId !== this.metadataRequestId || requestedIndex !==
          (AppStorage.get<number>(AppStorageKeyConstants.KEY_SELECT_INDEX) ?? 0)) {
          coverLease?.release();
          return;
        }
        const mediaImage: image.PixelMap | undefined = coverLease?.pixelMap;
        const metadata: avSession.AVMetadata = {
          assetId: `${this.musicIndex}`,
          title: song.title,
          artist: song.artist,
          mediaImage: mediaImage,
          duration: this.getDuration(),
          avQueueName: 'AudioRendererQueue',
          avQueueId: 'AudioRendererQueueId',
          avQueueImage: mediaImage
        };
        if (this.AVSession) {
          try {
            await this.AVSession.setAVMetadata(metadata);
            this.metadataCoverLease?.release();
            this.metadataCoverLease = coverLease;
            Logger.info(TAG, 'SetAVMetadata successfully');
          } catch (err) {
            coverLease?.release();
            const businessError: BusinessError = err as BusinessError;
            Logger.error(TAG,
              `SetAVMetadata BusinessError: code: ${businessError.code}, message: ${businessError.message}`);
          }
        } else {
          coverLease?.release();
        }
      }
    } catch (error) {
      Logger.error(TAG, `SetAVMetadata failed, code: ${(error as BusinessError).code}`);
    }
  }

  async setListenerForMesFromController(): Promise<void> {
    if (!this.AVSession) {
      return;
    }
    try {
      this.AVSession.on('play', this.onPlay);
      this.AVSession.on('pause', this.onPause);
      this.AVSession.on('playNext', this.onPlayNext);
      this.AVSession.on('playPrevious', this.onPlayPrevious);
      this.AVSession.on('seek', this.onSeek);
      this.AVSession.on('setLoopMode', this.onSetLoopMode);
      this.AVSession.on('toggleFavorite', this.onToggleFavorite);
    } catch (err) {
      Logger.error(TAG, `setListenerForMesFromController failed: ${JSON.stringify(err)}`);
    }
  }

  private refreshSongList(): void {
    const list: SongInfo[] | undefined = AppStorage.get(AppStorageKeyConstants.KEY_SONG_LIST);
    if (list) {
      this.songList = list;
    }
  }

  private onPlay: () => void = () => {
    Logger.info(TAG, `on play , do play task`);
    this.getAvPlayerService().resume();
  }

  private onPause: () => void = () => {
    Logger.info(TAG, `on pause , do pause task`);
    this.getAvPlayerService().pause();
  }

  private randomSongIndex(currentIndex: number, songCount: number): number {
    if (songCount <= 1) {
      return currentIndex;
    }
    let nextIndex: number = currentIndex;
    for (let i = 0; i < 5 && nextIndex === currentIndex; i++) {
      nextIndex = Math.floor(Math.random() * songCount);
    }
    return nextIndex === currentIndex ? (currentIndex + 1) % songCount : nextIndex;
  }

  private onPlayNext: () => void = () => {
    Logger.info(TAG, `on playNext , do playNext task`);
    this.refreshSongList();
    if (this.songList.length === 0) {
      return;
    }
    const currentIdx: number = AppStorage.get(AppStorageKeyConstants.KEY_SELECT_INDEX) ?? 0;
    const playMode: MusicPlayMode = AppStorage.get<MusicPlayMode>(AppStorageKeyConstants.KEY_PLAY_MODE) ??
      MusicPlayMode.ORDER;
    let nextIdx: number = currentIdx;
    if (playMode === MusicPlayMode.RANDOM) {
      nextIdx = this.randomSongIndex(currentIdx, this.songList.length);
    } else if (playMode === MusicPlayMode.ORDER) {
      nextIdx = currentIdx >= this.songList.length - 1 ? 0 : currentIdx + 1;
    }
    if (nextIdx >= 0 && nextIdx < this.songList.length) {
      this.getAvPlayerService().playSong(this.songList[nextIdx], nextIdx);
    }
  }

  private onPlayPrevious: () => void = () => {
    Logger.info(TAG, `on playPrevious , do playPrevious task`);
    this.refreshSongList();
    if (this.songList.length === 0) {
      return;
    }
    const currentIdx: number = AppStorage.get(AppStorageKeyConstants.KEY_SELECT_INDEX) ?? 0;
    const playMode: MusicPlayMode = AppStorage.get<MusicPlayMode>(AppStorageKeyConstants.KEY_PLAY_MODE) ??
      MusicPlayMode.ORDER;
    let prevIdx: number = currentIdx;
    if (playMode === MusicPlayMode.RANDOM) {
      prevIdx = this.randomSongIndex(currentIdx, this.songList.length);
    } else if (playMode === MusicPlayMode.ORDER) {
      prevIdx = currentIdx <= 0 ? this.songList.length - 1 : currentIdx - 1;
    }
    if (prevIdx >= 0 && prevIdx < this.songList.length) {
      this.getAvPlayerService().playSong(this.songList[prevIdx], prevIdx);
    }
  }

  private onSeek: (curMs: number) => void = (curMs: number) => {
    Logger.info(TAG, `on seek , do seek task`);
    this.getAvPlayerService().seek(curMs);
  }

  private onSetLoopMode: (loopMode: avSession.LoopMode) => void = (loopMode: avSession.LoopMode) => {
    Logger.info(TAG, `on setLoopMode , do loopMode task`);
    let playMode: MusicPlayMode = MusicPlayMode.ORDER;
    switch (loopMode) {
      case avSession.LoopMode.LOOP_MODE_SINGLE:
        playMode = MusicPlayMode.SINGLE_CYCLE;
        break;
      case avSession.LoopMode.LOOP_MODE_SEQUENCE:
        playMode = MusicPlayMode.ORDER;
        break;
      case avSession.LoopMode.LOOP_MODE_SHUFFLE:
        playMode = MusicPlayMode.RANDOM;
        break;
      default:
        break;
    }
    DataService.getInstance().setPlayMode(playMode);
  }

  private onToggleFavorite: (assetId: string) => void = (assetId: string) => {
    Logger.info(TAG, `on toggleFavorite , do toggleFavorite task`);
    const isFavorite: boolean | undefined = AppStorage.get(AppStorageKeyConstants.KEY_IS_FAVORITE);
    this.updateFavoriteState(assetId, isFavorite ? !isFavorite : true);
  }

  public setPlayModeToAVSession(currentPlayMode: MusicPlayMode): void {
    let AVSessionLoopMode: avSession.LoopMode = avSession.LoopMode.LOOP_MODE_SEQUENCE;
    switch (currentPlayMode) {
      case MusicPlayMode.SINGLE_CYCLE:
        AVSessionLoopMode = avSession.LoopMode.LOOP_MODE_SINGLE;
        break;
      case MusicPlayMode.ORDER:
        AVSessionLoopMode = avSession.LoopMode.LOOP_MODE_SEQUENCE;
        break;
      case MusicPlayMode.RANDOM:
        AVSessionLoopMode = avSession.LoopMode.LOOP_MODE_SHUFFLE;
        break;
      default:
        break;
    }
    this.setLoopModeState(AVSessionLoopMode);
  }

  private setFavoriteState(isFavorite: boolean): void {
    this.queuePlaybackState({ isFavorite });
  }

  public setProgressState(ms: number): void {
    if (!this.sessionAvailable || !this.AVSession) {
      return;
    }
    const now: number = new Date().getTime();
    const positionChanged: boolean = this.lastProgressReportPosition < 0 ||
      Math.abs(ms - this.lastProgressReportPosition) >= 1000 || ms < this.lastProgressReportPosition;
    if (!positionChanged && now - this.lastProgressReportTime < 1000) {
      return;
    }
    this.lastProgressReportTime = now;
    this.lastProgressReportPosition = ms;
    this.queuePlaybackState({
      position: {
        elapsedTime: ms,
        updateTime: now
      }
    });
  }

  public setPlayState(isPlay: boolean): void {
    if (!this.sessionAvailable || !this.AVSession) {
      return;
    }
    const currentIndex: number = AppStorage.get<number>(AppStorageKeyConstants.KEY_SELECT_INDEX) ?? 0;
    const state: avSession.PlaybackState = isPlay ?
      avSession.PlaybackState.PLAYBACK_STATE_PLAY : avSession.PlaybackState.PLAYBACK_STATE_PAUSE;
    const activeItemId: number = currentIndex + 1;
    if (state === this.lastSubmittedPlayState && activeItemId === this.lastSubmittedActiveItemId) {
      return;
    }
    this.lastSubmittedPlayState = state;
    this.lastSubmittedActiveItemId = activeItemId;
    this.lastProgressReportTime = 0;
    this.lastProgressReportPosition = -1;
    const position: number = AppStorage.get<number>(AppStorageKeyConstants.KEY_PROGRESS) ?? 0;
    this.queuePlaybackState({
      state: state,
      activeItemId: activeItemId,
      position: {
        elapsedTime: position,
        updateTime: new Date().getTime()
      }
    });
  }

  public async updateFavoriteState(assetId: string, isFavorite: boolean): Promise<void> {
    if (!this.context) {
      return;
    }
    PreferencesUtil.getInstance().preferencesPut(assetId, isFavorite);
    AppStorage.setOrCreate(AppStorageKeyConstants.KEY_IS_FAVORITE, isFavorite);
    this.setFavoriteState(isFavorite);
  }

  public async getAndUpdateFavoriteState(assetId: string): Promise<void> {
    let isFavorite = false;
    if (!this.context) {
      return;
    }
    const isHas: boolean = PreferencesUtil.getInstance().preferencesHas(assetId);
    Logger.info(TAG, `isHas: ${isHas}, assetId:${assetId}`);
    if (isHas) {
      isFavorite = PreferencesUtil.getInstance().getValue(assetId) as boolean;
    }
    AppStorage.setOrCreate(AppStorageKeyConstants.KEY_IS_FAVORITE, isFavorite);
    this.setFavoriteState(isFavorite);
  }

  public async setLoopModeState(AVSessionLoopMode: avSession.LoopMode): Promise<void> {
    this.queuePlaybackState({ loopMode: AVSessionLoopMode });
  }

  async unregisterSessionListener(): Promise<void> {
    this.metadataRequestId++;
    this.metadataCoverLease?.release();
    this.metadataCoverLease = undefined;
    const session: avSession.AVSession | undefined = this.AVSession;
    this.sessionAvailable = false;
    this.pendingPlaybackState = undefined;
    this.playbackStateInFlight = false;
    this.lastSubmittedPlayState = undefined;
    this.lastSubmittedActiveItemId = -1;
    this.AVSession = undefined;
    if (!session) {
      return;
    }
    try {
      session.off('play');
      session.off('pause');
      session.off('playNext');
      session.off('playPrevious');
      session.off('setLoopMode');
      session.off('seek');
      session.off('toggleFavorite');
      await session.destroy();
    } catch (err) {
      Logger.error(TAG, `unregisterSessionListener failed: ${JSON.stringify(err)}`);
    }
  }
}
