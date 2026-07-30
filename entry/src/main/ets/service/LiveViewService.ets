import { liveViewManager } from '@kit.LiveViewKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { common } from '@kit.AbilityKit';
import Logger from '../common/utils/Logger';
import { AppStorageKeyConstants } from '../common/constants/AppStorageKeyConstants';

const TAG = 'LiveViewService';
const LIVE_VIEW_ID: number = 1;
const LIVE_VIEW_EVENT: string = 'MUSIC';

export class LiveViewService {
  private static instance: LiveViewService = new LiveViewService();
  private sequence: number = 0;
  private isRunning: boolean = false;
  private context: common.UIAbilityContext | undefined = undefined;

  public static getInstance(): LiveViewService {
    return LiveViewService.instance;
  }

  setContext(ctx: common.UIAbilityContext): void {
    this.context = ctx;
  }

  async startLiveView(): Promise<void> {
    if (this.isRunning) {
      await this.updateLiveView();
      return;
    }
    try {
      const title: string = AppStorage.get<string>('uplayer_current_title') ?? '未播放';
      const artist: string = AppStorage.get<string>('uplayer_current_artist') ?? '';
      const isPlay: boolean = AppStorage.get<boolean>(AppStorageKeyConstants.KEY_IS_PLAY) ?? false;
      const liveView: liveViewManager.LiveView = {
        id: LIVE_VIEW_ID,
        sequence: this.sequence,
        event: LIVE_VIEW_EVENT,
        isMute: true,
        liveViewData: {
          capsule: {
            type: liveViewManager.CapsuleType.CAPSULE_TYPE_TEXT,
            status: isPlay ? 1 : 0,
            title: title,
            content: artist.length > 0 ? artist : '未知歌手',
            backgroundColor: '#1A1A1A',
            icon: 'ic_public_music',
          },
          primary: {
            title: title,
            content: [
              { text: artist.length > 0 ? artist : '未知歌手' },
              { text: isPlay ? '正在播放' : '已暂停' },
            ],
            keepTime: 0,
            liveViewLockScreenAbilityName: 'LiveViewExtAbility',
            liveViewLockScreenAbilityParameters: {},
          },
        },
      };
      await liveViewManager.startLiveView(liveView);
      this.isRunning = true;
      Logger.info(TAG, 'startLiveView success');
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      Logger.error(TAG, `startLiveView failed: ${error.code} ${error.message}`);
    }
  }

  async updateLiveView(): Promise<void> {
    if (!this.isRunning) {
      return;
    }
    try {
      this.sequence++;
      const title: string = AppStorage.get<string>('uplayer_current_title') ?? '未播放';
      const artist: string = AppStorage.get<string>('uplayer_current_artist') ?? '';
      const isPlay: boolean = AppStorage.get<boolean>(AppStorageKeyConstants.KEY_IS_PLAY) ?? false;
      const liveView: liveViewManager.LiveView = {
        id: LIVE_VIEW_ID,
        sequence: this.sequence,
        event: LIVE_VIEW_EVENT,
        liveViewData: {
          capsule: {
            type: liveViewManager.CapsuleType.CAPSULE_TYPE_TEXT,
            status: isPlay ? 1 : 0,
            title: title,
            content: artist.length > 0 ? artist : '未知歌手',
          },
          primary: {
            title: title,
            content: [
              { text: artist.length > 0 ? artist : '未知歌手' },
              { text: isPlay ? '正在播放' : '已暂停' },
            ],
          },
        },
      };
      await liveViewManager.updateLiveView(liveView);
      Logger.info(TAG, 'updateLiveView success');
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      Logger.error(TAG, `updateLiveView failed: ${error.code} ${error.message}`);
    }
  }

  async stopLiveView(): Promise<void> {
    if (!this.isRunning) {
      return;
    }
    try {
      const liveView: liveViewManager.LiveView = {
        id: LIVE_VIEW_ID,
        sequence: this.sequence,
        event: LIVE_VIEW_EVENT,
        liveViewData: {
          capsule: {
            type: liveViewManager.CapsuleType.CAPSULE_TYPE_TEXT,
            status: 0,
            title: '',
            content: '',
          },
          primary: {
            title: '',
            content: [],
            keepTime: 0,
          },
        },
      };
      await liveViewManager.stopLiveView(liveView);
      this.isRunning = false;
      Logger.info(TAG, 'stopLiveView success');
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      Logger.error(TAG, `stopLiveView failed: ${error.code} ${error.message}`);
    }
  }
}
