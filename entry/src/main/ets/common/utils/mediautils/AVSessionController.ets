import { common, wantAgent } from '@kit.AbilityKit';
import { avSession } from '@kit.AVSessionKit';
import { SongInfo } from '../../../model/SongInfo';
import { AVPlayerService } from '../../../service/AVPlayerService';
import { AlbumCoverLease, AlbumCoverSize, AudioMetadataService, CoverPriority } from '../../../service/AudioMetadataService';
import Logger from '../Logger';
import { MusicPlayMode } from '../../constants/PlayerConstants';
import { DataService } from '../../../service/DataService';
import { AppStorageKeyConstants } from '../../constants/AppStorageKeyConstants';
import { BusinessError } from '@kit.BasicServicesKit';
import WantAgent from '@ohos.app.ability.wantAgent';
import { image } from '@kit.ImageKit';
import { MediaTools } from './MediaTools';

const TAG = 'AVSessionController';

export class AVSessionController {
  private context: common.UIAbilityContext | undefined = undefined;
  private AVSession: avSession.AVSession | undefined = undefined;
  private songList: SongInfo[] = [];
  private musicIndex: number = 0;
  private avPlayerService: AVPlayerService | undefined = undefined;
  private metadataRequestId: number = 0;
  private metadataCoverLease: AlbumCoverLease | undefined = undefined;
  private metadataPlaceholderMap: image.PixelMap | undefined = undefined;
  private lastProgressReportTime: number = 0;
  private lastProgressReportPosition: number = -1;
  private sessionAvailable: boolean = false;
  private playbackStateInFlight: boolean = false;
  private pendingPlaybackState: avSession.AVPlaybackState | undefined = undefined;
  private lastSubmittedPlayState: avSession.PlaybackState | undefined = undefined;
  private lastSubmittedActiveItemId: number = -1;
  private playbackRetryTimer: number = -1;
  private playbackRetryAttempt: number = 0;
  private playbackGeneration: number = 0;
  private lastQueueRevision: number = -1;
  private coverRetryAttempt: number = 0;
  private coverRetryTimer: number = -1;

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
      this.setAVMetadata();
      this.getAndUpdateFavoriteState(this.musicIndex.toString());
      await this.AVSession.activate();
      this.setAVQueueItems();
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
    const loopMode: avSession.LoopMode = this.playModeToLoopMode(playMode);
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
    if (!this.sessionAvailable || !session || this.playbackStateInFlight || !this.pendingPlaybackState ||
      this.playbackRetryTimer !== -1) {
      return;
    }
    const state: avSession.AVPlaybackState = this.pendingPlaybackState;
    this.pendingPlaybackState = undefined;
    this.playbackStateInFlight = true;
    const generation: number = this.playbackGeneration;
    session.setAVPlaybackState(state, (err: BusinessError) => {
      if (generation !== this.playbackGeneration || this.AVSession !== session) return;
      this.playbackStateInFlight = false;
      if (err) {
        this.pendingPlaybackState = this.mergePlaybackState(state, this.pendingPlaybackState ?? {});
        const delay: number = Math.min(8000, 500 * Math.pow(2, this.playbackRetryAttempt));
        this.playbackRetryAttempt = Math.min(this.playbackRetryAttempt + 1, 5);
        Logger.error(TAG, `setAVPlaybackState failed: code=${err.code}, retryMs=${delay}`);
        this.playbackRetryTimer = setTimeout(() => {
          this.playbackRetryTimer = -1;
          this.submitNextPlaybackState();
        }, delay);
        return;
      }
      this.playbackRetryAttempt = 0;
      if (state.state !== undefined) this.lastSubmittedPlayState = state.state;
      if (state.activeItemId !== undefined) this.lastSubmittedActiveItemId = state.activeItemId;
      this.submitNextPlaybackState();
    });
  }

  public async setAVQueueItems(): Promise<void> {
    if (!this.AVSession) {
      return;
    }
    this.refreshSongList();
    const revision: number = AppStorage.get<number>(AppStorageKeyConstants.KEY_LIBRARY_REVISION) ?? 0;
    if (revision === this.lastQueueRevision) {
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
      this.lastQueueRevision = revision;
      Logger.info(TAG, 'setAVQueueItems successfully');
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      Logger.error(TAG, `setAVQueueItems failed: ${error.code} ${error.message}`);
    }
  }

  public clearCurrentMedia(): void {
    this.metadataRequestId++;
    if (this.coverRetryTimer !== -1) {
      clearTimeout(this.coverRetryTimer);
      this.coverRetryTimer = -1;
    }
    this.coverRetryAttempt = 0;
    const previousCoverLease: AlbumCoverLease | undefined = this.metadataCoverLease;
    const previousPlaceholderMap: image.PixelMap | undefined = this.metadataPlaceholderMap;
    this.metadataCoverLease = undefined;
    this.metadataPlaceholderMap = undefined;
    const session: avSession.AVSession | undefined = this.AVSession;
    if (session === undefined) {
      previousCoverLease?.release();
      previousPlaceholderMap?.release();
      return;
    }
    const metadata: avSession.AVMetadata = {
      assetId: 'uplayer-empty-media'
    };
    session.setAVMetadata(metadata).then(() => {
      previousCoverLease?.release();
      previousPlaceholderMap?.release();
    }).catch((err: BusinessError) => {
      previousCoverLease?.release();
      previousPlaceholderMap?.release();
      Logger.error(TAG, `clearCurrentMedia failed: code=${err.code}, message=${err.message}`);
    });
    this.queuePlaybackState({
      state: avSession.PlaybackState.PLAYBACK_STATE_PAUSE,
      activeItemId: 0,
      position: {
        elapsedTime: 0,
        updateTime: new Date().getTime()
      }
    });
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
    if (!duration || duration <= 0) {
      return undefined;
    }
    return duration;
  }

  private async loadDefaultArtwork(): Promise<image.PixelMap | undefined> {
    if (this.context === undefined) {
      return undefined;
    }
    try {
      return await MediaTools.getPixelMapFromResource(this.context, $r('app.media.ic_public_music'));
    } catch (err) {
      Logger.error(TAG, `loadDefaultArtwork failed: ${JSON.stringify(err)}`);
      return undefined;
    }
  }

  private createMetadata(song: SongInfo, requestedIndex: number, duration: number | undefined,
    artwork: image.PixelMap | undefined): avSession.AVMetadata {
    const metadata: avSession.AVMetadata = {
      assetId: song.id.length > 0 ? song.id : `${requestedIndex}`,
      avQueueName: 'AudioRendererQueue',
      avQueueId: 'AudioRendererQueueId'
    };
    if (song.title.length > 0) metadata.title = song.title;
    if (song.artist.length > 0) metadata.artist = song.artist;
    if (duration !== undefined && duration > 0) metadata.duration = duration;
    if (artwork !== undefined) {
      metadata.mediaImage = artwork;
      metadata.avQueueImage = artwork;
    }
    return metadata;
  }

  public async setAVMetadata(): Promise<void> {
    const requestId: number = ++this.metadataRequestId;
    if (this.coverRetryTimer !== -1) {
      clearTimeout(this.coverRetryTimer);
      this.coverRetryTimer = -1;
    }
    this.coverRetryAttempt = 0;
    this.musicIndex = AppStorage.get(AppStorageKeyConstants.KEY_SELECT_INDEX) ?? 0;
    const requestedIndex: number = this.musicIndex;
    this.refreshSongList();
    const session: avSession.AVSession | undefined = this.AVSession;
    if (!session || this.musicIndex < 0 || this.musicIndex >= this.songList.length) {
      return;
    }
    const song: SongInfo = this.songList[this.musicIndex];
    const requestedSongId: string = song.id;
    const duration: number | undefined = this.getDuration();
    const defaultArtwork: image.PixelMap | undefined = await this.loadDefaultArtwork();
    if (requestId !== this.metadataRequestId || requestedIndex !==
      (AppStorage.get<number>(AppStorageKeyConstants.KEY_SELECT_INDEX) ?? 0) || this.AVSession !== session) {
      defaultArtwork?.release();
      return;
    }
    const metadata: avSession.AVMetadata = this.createMetadata(song, requestedIndex, duration, defaultArtwork);
    try {
      await session.setAVMetadata(metadata);
      this.metadataCoverLease?.release();
      this.metadataCoverLease = undefined;
      this.metadataPlaceholderMap?.release();
      this.metadataPlaceholderMap = defaultArtwork;
      AppStorage.setOrCreate('uplayer_current_cover_state', 'placeholder');
      Logger.info(TAG, 'SetAVMetadata placeholder successfully');
    } catch (err) {
      defaultArtwork?.release();
      const businessError: BusinessError = err as BusinessError;
      Logger.error(TAG, `SetAVMetadata placeholder failed: code=${businessError.code}, message=${businessError.message}`);
      return;
    }
    AudioMetadataService.getInstance().acquireAlbumCover(song, AlbumCoverSize.MEDIUM, CoverPriority.HIGH)
      .then(async (coverLease: AlbumCoverLease | undefined): Promise<void> => {
        if (coverLease === undefined) {
          await this.restorePlaceholderMetadata(session, song, requestedIndex, duration, requestId);
          return;
        }
        const currentIndex: number = AppStorage.get<number>(AppStorageKeyConstants.KEY_SELECT_INDEX) ?? -1;
        this.refreshSongList();
        const currentSongId: string = currentIndex >= 0 && currentIndex < this.songList.length ?
          this.songList[currentIndex].id : '';
        if (requestId !== this.metadataRequestId || requestedIndex !== currentIndex ||
          requestedSongId !== currentSongId || this.AVSession !== session) {
          coverLease.release();
          return;
        }
        await this.submitCoverWithRetry(session, song, requestedIndex, duration, coverLease, requestId);
      }).catch(async (err: Error): Promise<void> => {
        Logger.error(TAG, `SetAVMetadata cover load failed: ${JSON.stringify(err)}`);
        await this.restorePlaceholderMetadata(session, song, requestedIndex, duration, requestId);
      });
  }

  private isMetadataRequestCurrent(session: avSession.AVSession, songId: string, requestedIndex: number,
    requestId: number): boolean {
    if (requestId !== this.metadataRequestId || this.AVSession !== session) {
      return false;
    }
    const currentIndex: number = AppStorage.get<number>(AppStorageKeyConstants.KEY_SELECT_INDEX) ?? -1;
    this.refreshSongList();
    return currentIndex === requestedIndex && currentIndex >= 0 && currentIndex < this.songList.length &&
      this.songList[currentIndex].id === songId;
  }

  private async restorePlaceholderMetadata(session: avSession.AVSession, song: SongInfo, requestedIndex: number,
    duration: number | undefined, requestId: number): Promise<void> {
    if (!this.isMetadataRequestCurrent(session, song.id, requestedIndex, requestId)) {
      return;
    }
    const artwork: image.PixelMap | undefined = await this.loadDefaultArtwork();
    if (!this.isMetadataRequestCurrent(session, song.id, requestedIndex, requestId)) {
      artwork?.release();
      return;
    }
    try {
      await session.setAVMetadata(this.createMetadata(song, requestedIndex, duration, artwork));
      this.metadataPlaceholderMap?.release();
      this.metadataPlaceholderMap = artwork;
      AppStorage.setOrCreate('uplayer_current_cover_state', 'placeholder');
    } catch (err) {
      artwork?.release();
      const businessError: BusinessError = err as BusinessError;
      Logger.error(TAG, `restorePlaceholderMetadata failed: code=${businessError.code}, message=${businessError.message}`);
    }
  }

  private async submitCoverWithRetry(session: avSession.AVSession, song: SongInfo, requestedIndex: number,
    duration: number | undefined, coverLease: AlbumCoverLease, requestId: number): Promise<void> {
    const coverMetadata: avSession.AVMetadata =
      this.createMetadata(song, requestedIndex, duration, coverLease.pixelMap);
    try {
      await session.setAVMetadata(coverMetadata);
      this.metadataCoverLease?.release();
      this.metadataCoverLease = coverLease;
      this.metadataPlaceholderMap?.release();
      this.metadataPlaceholderMap = undefined;
      AppStorage.setOrCreate('uplayer_current_cover_state', 'embedded');
      this.coverRetryAttempt = 0;
      Logger.info(TAG, 'SetAVMetadata cover successfully');
    } catch (err) {
      coverLease.release();
      const businessError: BusinessError = err as BusinessError;
      Logger.error(TAG, `SetAVMetadata cover failed: code=${businessError.code}, message=${businessError.message}`);
      if (this.coverRetryAttempt < 2 &&
        this.isMetadataRequestCurrent(session, song.id, requestedIndex, requestId)) {
        this.coverRetryAttempt++;
        const delay: number = 500 * Math.pow(2, this.coverRetryAttempt - 1);
        this.coverRetryTimer = setTimeout(() => {
          this.coverRetryTimer = -1;
          if (this.isMetadataRequestCurrent(session, song.id, requestedIndex, requestId)) {
            AudioMetadataService.getInstance().acquireAlbumCover(song, AlbumCoverSize.MEDIUM, CoverPriority.HIGH)
              .then(async (retryLease: AlbumCoverLease | undefined): Promise<void> => {
                if (retryLease === undefined) {
                  await this.restorePlaceholderMetadata(session, song, requestedIndex, duration, requestId);
                  return;
                }
                if (!this.isMetadataRequestCurrent(session, song.id, requestedIndex, requestId)) {
                  retryLease.release();
                  return;
                }
                await this.submitCoverWithRetry(session, song, requestedIndex, duration, retryLease, requestId);
              }).catch(async (retryErr: Error): Promise<void> => {
                Logger.error(TAG, `SetAVMetadata cover retry load failed: ${JSON.stringify(retryErr)}`);
                await this.restorePlaceholderMetadata(session, song, requestedIndex, duration, requestId);
              });
          }
        }, delay);
      } else {
        await this.restorePlaceholderMetadata(session, song, requestedIndex, duration, requestId);
      }
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

  private onPlayNext: () => void = () => {
    Logger.info(TAG, `on playNext , do playNext task`);
    this.getAvPlayerService().playNextSong();
  }

  private onPlayPrevious: () => void = () => {
    Logger.info(TAG, `on playPrevious , do playPrevious task`);
    this.getAvPlayerService().playPreviousSong();
  }

  private onSeek: (curMs: number) => void = (curMs: number) => {
    Logger.info(TAG, `on seek , do seek task`);
    this.getAvPlayerService().seek(curMs);
  }

  private playModeToLoopMode(playMode: MusicPlayMode): avSession.LoopMode {
    if (playMode === MusicPlayMode.SINGLE_CYCLE) {
      return avSession.LoopMode.LOOP_MODE_SINGLE;
    }
    if (playMode === MusicPlayMode.RANDOM) {
      return avSession.LoopMode.LOOP_MODE_SHUFFLE;
    }
    return avSession.LoopMode.LOOP_MODE_SEQUENCE;
  }

  private loopModeToPlayMode(loopMode: avSession.LoopMode): MusicPlayMode | undefined {
    if (loopMode === avSession.LoopMode.LOOP_MODE_SINGLE) {
      return MusicPlayMode.SINGLE_CYCLE;
    }
    if (loopMode === avSession.LoopMode.LOOP_MODE_SEQUENCE) {
      return MusicPlayMode.ORDER;
    }
    if (loopMode === avSession.LoopMode.LOOP_MODE_SHUFFLE) {
      return MusicPlayMode.RANDOM;
    }
    return undefined;
  }

  public updatePlayMode(playMode: MusicPlayMode): void {
    DataService.getInstance().setPlayMode(playMode);
    this.setLoopModeState(this.playModeToLoopMode(playMode));
  }

  private onSetLoopMode: (loopMode: avSession.LoopMode) => void = (loopMode: avSession.LoopMode) => {
    Logger.info(TAG, `on setLoopMode , do loopMode task`);
    const playMode: MusicPlayMode | undefined = this.loopModeToPlayMode(loopMode);
    if (playMode === undefined) {
      const currentMode: MusicPlayMode = DataService.getInstance().getPlayMode();
      this.setLoopModeState(this.playModeToLoopMode(currentMode));
      return;
    }
    this.updatePlayMode(playMode);
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
    if (state === this.lastSubmittedPlayState && activeItemId === this.lastSubmittedActiveItemId &&
      this.pendingPlaybackState === undefined && !this.playbackStateInFlight) {
      return;
    }
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

  private findSongByAssetId(assetId: string): SongInfo | undefined {
    const songs: SongInfo[] = DataService.getInstance().getSongs();
    for (let i = 0; i < songs.length; i++) {
      if (songs[i].id === assetId || `${i}` === assetId) {
        return songs[i];
      }
    }
    return undefined;
  }

  public async updateFavoriteState(assetId: string, isFavorite: boolean): Promise<void> {
    const song: SongInfo | undefined = this.findSongByAssetId(assetId);
    if (song !== undefined && song.isFavorite !== isFavorite) {
      DataService.getInstance().toggleFavorite(song.id);
    }
    AppStorage.setOrCreate(AppStorageKeyConstants.KEY_IS_FAVORITE, isFavorite);
    this.setFavoriteState(isFavorite);
  }

  public async getAndUpdateFavoriteState(assetId: string): Promise<void> {
    const song: SongInfo | undefined = this.findSongByAssetId(assetId);
    const isFavorite: boolean = song !== undefined ? song.isFavorite : false;
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
    this.metadataPlaceholderMap?.release();
    this.metadataPlaceholderMap = undefined;
    if (this.coverRetryTimer !== -1) {
      clearTimeout(this.coverRetryTimer);
      this.coverRetryTimer = -1;
    }
    this.coverRetryAttempt = 0;
    const session: avSession.AVSession | undefined = this.AVSession;
    this.sessionAvailable = false;
    this.playbackGeneration++;
    if (this.playbackRetryTimer !== -1) {
      clearTimeout(this.playbackRetryTimer);
      this.playbackRetryTimer = -1;
    }
    this.playbackRetryAttempt = 0;
    this.pendingPlaybackState = undefined;
    this.playbackStateInFlight = false;
    this.lastSubmittedPlayState = undefined;
    this.lastSubmittedActiveItemId = -1;
    this.lastQueueRevision = -1;
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
