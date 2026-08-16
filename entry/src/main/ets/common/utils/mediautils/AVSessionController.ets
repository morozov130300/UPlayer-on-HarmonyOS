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

  public setProgressState(ms: number): void {
    if (this.AVSession) {
      this.AVSession.setAVPlaybackState({
        position: {
          elapsedTime: ms,
          updateTime: new Date().getTime()
        }
      }, (err: BusinessError) => {
        if (err) {
          Logger.error(TAG, `setProgressState BusinessError: code: ${err.code}, message: ${err.message}`);
        } else {
          Logger.info(TAG, 'setProgressState successfully');
        }
      });
    }
  }

  public setPlayState(isPlay: boolean): void {
    if (!this.AVSession) {
      Logger.error(TAG, 'AVSession is undefined');
      return;
    }
    const currentIndex: number = AppStorage.get<number>(AppStorageKeyConstants.KEY_SELECT_INDEX) ?? 0;
    this.AVSession.setAVPlaybackState({
      state: isPlay ? avSession.PlaybackState.PLAYBACK_STATE_PLAY : avSession.PlaybackState.PLAYBACK_STATE_PAUSE,
      activeItemId: currentIndex + 1,
    }, (err: BusinessError) => {
      if (err) {
        Logger.error(TAG, `setPlayState BusinessError: code: ${err.code}, message: ${err.message}`);
      } else {
        Logger.info(TAG, 'setPlayState successfully');
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
    this.metadataRequestId++;
    this.metadataCoverLease?.release();
    this.metadataCoverLease = undefined;
    if (!this.AVSession) {
      return;
    }
    try {
      this.AVSession.off('play');
      this.AVSession.off('pause');
      this.AVSession.off('playNext');
      this.AVSession.off('playPrevious');
      this.AVSession.off('setLoopMode');
      this.AVSession.off('seek');
      this.AVSession.off('toggleFavorite');
      this.AVSession.destroy();
    } catch (err) {
      Logger.error(TAG, `unregisterSessionListener failed: ${JSON.stringify(err)}`);
    }
  }
}
