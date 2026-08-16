import { common, wantAgent } from '@kit.AbilityKit';
import { avSession } from '@kit.AVSessionKit';
import { SongInfo } from '../../../model/SongInfo';
import { AVPlayerService } from '../../../service/AVPlayerService';
import { AudioMetadataService } from '../../../service/AudioMetadataService';
import Logger from '../Logger';
import { MusicPlayMode } from '../../constants/PlayerConstants';
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
  private lastProgressUpdateTime: number = 0;
  private lastProgressPosition: number = -1;
  private progressUpdateInFlight: boolean = false;
  private pendingProgressPosition: number | undefined = undefined;
  private playbackUpdateInFlight: boolean = false;
  private pendingPlayState: boolean | undefined = undefined;
  private sessionGeneration: number = 0;
  private destroyed: boolean = false;
  private currentMediaImage: image.PixelMap | undefined = undefined;
  private static readonly PROGRESS_UPDATE_INTERVAL_MS: number = 1000;

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
    this.destroyed = false;
    const generation: number = ++this.sessionGeneration;
    this.context = AppStorage.get(AppStorageKeyConstants.KEY_UI_ABILITY_CONTEXT);
    if (!this.context) {
      Logger.info(TAG, `session create failed, context is undefined`);
      return;
    }
    try {
      const session: avSession.AVSession = await avSession.createAVSession(this.context, "PLAY_AUDIO", 'audio');
      if (this.destroyed || generation !== this.sessionGeneration) {
        session.destroy();
        return;
      }
      this.AVSession = session;
      await this.AVSession.activate();
      Logger.info(TAG, `session create succeeded : sessionId : ${this.AVSession.sessionId}`);
    } catch (err) {
      Logger.error(TAG, `session create failed: ${JSON.stringify(err)}`);
      return;
    }
    this.setListenerForMesFromController();
    this.setInitialPlaybackState();
    this.setLaunchAbility();
    this.setAVQueueTitle();
    await this.setAVQueueItems();
    await this.setAVMetadata();
    this.getAndUpdateFavoriteState(this.musicIndex.toString());
  }

  private setInitialPlaybackState(): void {
    if (!this.AVSession) {
      return;
    }
    const isPlay: boolean = AppStorage.get<boolean>(AppStorageKeyConstants.KEY_IS_PLAY) ?? false;
    const playbackState: avSession.AVPlaybackState = {
      state: isPlay ? avSession.PlaybackState.PLAYBACK_STATE_PLAY : avSession.PlaybackState.PLAYBACK_STATE_PAUSE,
      speed: 1.0,
      bufferedTime: 0,
      loopMode: avSession.LoopMode.LOOP_MODE_SEQUENCE,
      isFavorite: false,
    };
    this.AVSession.setAVPlaybackState(playbackState, (err: BusinessError) => {
      if (err) {
        Logger.error(TAG, `setInitialPlaybackState BusinessError: code: ${err.code}, message: ${err.message}`);
      } else {
        Logger.info(TAG, 'setInitialPlaybackState successfully');
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
        // 按需从音频文件提取封面，不再使用缓存文件
        let mediaImage: image.PixelMap | undefined = undefined;
        mediaImage = await this.extractCoverFromSong(song);
        if (requestId !== this.metadataRequestId || requestedIndex !==
          (AppStorage.get<number>(AppStorageKeyConstants.KEY_SELECT_INDEX) ?? 0)) {
          if (mediaImage !== undefined) {
            mediaImage.release();
          }
          return;
        }
        const metadata: avSession.AVMetadata = {
          assetId: `${this.musicIndex}`,
          title: song.title,
          artist: song.artist,
          duration: this.getDuration(),
          avQueueName: 'AudioRendererQueue',
          avQueueId: 'AudioRendererQueueId'
        };
        if (mediaImage !== undefined) {
          metadata.mediaImage = mediaImage;
          metadata.avQueueImage = mediaImage;
        }
        const session: avSession.AVSession | undefined = this.AVSession;
        if (session && !this.destroyed) {
          await session.setAVMetadata(metadata);
          if (requestId !== this.metadataRequestId || session !== this.AVSession || this.destroyed) {
            if (mediaImage !== undefined) {
              mediaImage.release();
            }
            return;
          }
          const previousImage: image.PixelMap | undefined = this.currentMediaImage;
          this.currentMediaImage = mediaImage;
          if (previousImage !== undefined && previousImage !== mediaImage) {
            previousImage.release();
          }
          Logger.info(TAG, 'SetAVMetadata successfully');
        } else if (mediaImage !== undefined) {
          mediaImage.release();
        }
      }
    } catch (error) {
      Logger.error(TAG, `SetAVMetadata failed, code: ${(error as BusinessError).code}`);
    }
  }

  // 从音频文件直接提取封面PixelMap
  private async extractCoverFromSong(song: SongInfo): Promise<image.PixelMap | undefined> {
    const metadataService: AudioMetadataService = AudioMetadataService.getInstance();
    return await metadataService.fetchAlbumCover(song);
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
    this.refreshSongList();
    const currentIdx: number = AppStorage.get(AppStorageKeyConstants.KEY_SELECT_INDEX) ?? 0;
    let nextIdx: number = currentIdx + 1;
    if (nextIdx >= this.songList.length) {
      nextIdx = 0;
    }
    if (nextIdx < this.songList.length) {
      this.getAvPlayerService().playSong(this.songList[nextIdx], nextIdx);
    }
  }

  private onPlayPrevious: () => void = () => {
    Logger.info(TAG, `on playPrevious , do playPrevious task`);
    this.refreshSongList();
    const currentIdx: number = AppStorage.get(AppStorageKeyConstants.KEY_SELECT_INDEX) ?? 0;
    let prevIdx: number = currentIdx - 1;
    if (prevIdx < 0) {
      prevIdx = this.songList.length - 1;
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
    AppStorage.setOrCreate(AppStorageKeyConstants.KEY_PLAY_MODE, playMode);
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
    if (this.AVSession) {
      this.AVSession.setAVPlaybackState({ isFavorite }, (err: BusinessError) => {
        if (err) {
          Logger.error(TAG, `setFavoriteState BusinessError: code: ${err.code}, message: ${err.message}`);
        } else {
          Logger.info(TAG, 'setFavoriteState successfully');
        }
      });
    }
  }

  public setProgressState(ms: number, force: boolean = false): void {
    if (!this.AVSession) {
      return;
    }
    const now: number = new Date().getTime();
    if (this.progressUpdateInFlight) {
      this.pendingProgressPosition = ms;
      return;
    }
    if (!force && now - this.lastProgressUpdateTime < AVSessionController.PROGRESS_UPDATE_INTERVAL_MS &&
      Math.abs(ms - this.lastProgressPosition) < AVSessionController.PROGRESS_UPDATE_INTERVAL_MS) {
      this.pendingProgressPosition = ms;
      return;
    }
    this.sendProgressState(ms, now);
  }

  private sendProgressState(ms: number, updateTime: number): void {
    if (!this.AVSession || this.destroyed) {
      return;
    }
    const session: avSession.AVSession = this.AVSession;
    const generation: number = this.sessionGeneration;
    this.progressUpdateInFlight = true;
    session.setAVPlaybackState({
      position: {
        elapsedTime: ms,
        updateTime: updateTime
      }
    }, (err: BusinessError) => {
      this.progressUpdateInFlight = false;
      if (generation !== this.sessionGeneration || session !== this.AVSession || this.destroyed) {
        this.pendingProgressPosition = undefined;
        return;
      }
      if (err) {
        Logger.error(TAG, `setProgressState BusinessError: code: ${err.code}, message: ${err.message}`);
      } else {
        this.lastProgressUpdateTime = updateTime;
        this.lastProgressPosition = ms;
      }
      const pendingPosition: number | undefined = this.pendingProgressPosition;
      this.pendingProgressPosition = undefined;
      if (pendingPosition !== undefined) {
        this.setProgressState(pendingPosition);
      }
    });
  }

  public setPlayState(isPlay: boolean): void {
    if (!this.AVSession || this.destroyed) {
      return;
    }
    if (this.playbackUpdateInFlight) {
      this.pendingPlayState = isPlay;
      return;
    }
    const session: avSession.AVSession = this.AVSession;
    const generation: number = this.sessionGeneration;
    const currentIndex: number = AppStorage.get<number>(AppStorageKeyConstants.KEY_SELECT_INDEX) ?? 0;
    this.playbackUpdateInFlight = true;
    session.setAVPlaybackState({
      state: isPlay ? avSession.PlaybackState.PLAYBACK_STATE_PLAY : avSession.PlaybackState.PLAYBACK_STATE_PAUSE,
      activeItemId: currentIndex + 1,
    }, (err: BusinessError) => {
      this.playbackUpdateInFlight = false;
      if (generation !== this.sessionGeneration || session !== this.AVSession || this.destroyed) {
        this.pendingPlayState = undefined;
        return;
      }
      if (err) {
        Logger.error(TAG, `setPlayState BusinessError: code: ${err.code}, message: ${err.message}`);
      } else {
        const position: number = AppStorage.get<number>(AppStorageKeyConstants.KEY_PROGRESS) ?? 0;
        this.setProgressState(position, true);
      }
      const pendingState: boolean | undefined = this.pendingPlayState;
      this.pendingPlayState = undefined;
      if (pendingState !== undefined && pendingState !== isPlay) {
        this.setPlayState(pendingState);
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
    if (this.AVSession) {
      this.AVSession.setAVPlaybackState({ loopMode: AVSessionLoopMode }, (err: BusinessError) => {
        if (err) {
          Logger.error(TAG, `setLoopModeState BusinessError: code: ${err.code}, message: ${err.message}`);
        } else {
          Logger.info(TAG, 'setLoopModeState successfully');
        }
      });
    }
  }

  async unregisterSessionListener(): Promise<void> {
    const session: avSession.AVSession | undefined = this.AVSession;
    if (!session) {
      return;
    }
    this.destroyed = true;
    this.sessionGeneration++;
    this.metadataRequestId++;
    this.AVSession = undefined;
    this.pendingPlayState = undefined;
    this.pendingProgressPosition = undefined;
    this.playbackUpdateInFlight = false;
    this.progressUpdateInFlight = false;
    try {
      session.off('play');
      session.off('pause');
      session.off('playNext');
      session.off('playPrevious');
      session.off('setLoopMode');
      session.off('seek');
      session.off('toggleFavorite');
      session.destroy();
      if (this.currentMediaImage !== undefined) {
        this.currentMediaImage.release();
        this.currentMediaImage = undefined;
      }
    } catch (err) {
      Logger.error(TAG, `unregisterSessionListener failed: ${JSON.stringify(err)}`);
    }
  }
}
