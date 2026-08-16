import { liveViewManager } from '@kit.LiveViewKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { common, wantAgent, WantAgent } from '@kit.AbilityKit';
import Logger from '../common/utils/Logger';
import { AppStorageKeyConstants } from '../common/constants/AppStorageKeyConstants';

const TAG = 'LiveViewService';
const LIVE_VIEW_ID: number = 1;
const LIVE_VIEW_EVENT: string = 'MUSIC';

export class LiveViewService {
  private static instance: LiveViewService = new LiveViewService();
  private sequence: number = 0;
  private isRunning: boolean = false;
  private disabledForSession: boolean = false;
  private failureLogged: boolean = false;
  private context: common.UIAbilityContext | undefined = undefined;

  public static getInstance(): LiveViewService {
    return LiveViewService.instance;
  }

  setContext(ctx: common.UIAbilityContext): void {
    this.context = ctx;
  }

  private async buildClickAction(): Promise<WantAgent | undefined> {
    if (!this.context) {
      return undefined;
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
    try {
      return await wantAgent.getWantAgent(wantAgentInfo);
    } catch (err) {
      this.disableForSession('buildClickAction', err as BusinessError);
      return undefined;
    }
  }

  private async buildLiveView(stopped: boolean = false): Promise<liveViewManager.LiveView> {
    const title: string = stopped ? '' : (AppStorage.get<string>('uplayer_current_title') ?? '未播放');
    const artist: string = stopped ? '' : (AppStorage.get<string>('uplayer_current_artist') ?? '');
    const isPlay: boolean = !stopped && (AppStorage.get<boolean>(AppStorageKeyConstants.KEY_IS_PLAY) ?? false);
    const clickAction: WantAgent | undefined = stopped ? undefined : await this.buildClickAction();
    return {
      id: LIVE_VIEW_ID,
      sequence: this.sequence,
      event: LIVE_VIEW_EVENT,
      isMute: false,
      liveViewData: {
        capsule: {
          type: liveViewManager.CapsuleType.CAPSULE_TYPE_TEXT,
          status: isPlay ? 1 : 0,
          icon: stopped ? undefined : 'ic_public_music',
          title: title,
          content: stopped ? '' : (artist.length > 0 ? artist : '未知歌手'),
          backgroundColor: stopped ? undefined : '#1A1A1A',
        },
        primary: {
          title: title,
          content: stopped ? [] : [
            { text: artist.length > 0 ? artist : '未知歌手' },
            { text: isPlay ? '正在播放' : '已暂停' }
          ],
          keepTime: 0,
          layoutData: {
            layoutType: liveViewManager.LayoutType.LAYOUT_TYPE_DEFAULT
          },
          clickAction: clickAction,
          liveViewLockScreenAbilityName: stopped ? undefined : 'LiveViewExtAbility',
          liveViewLockScreenAbilityParameters: stopped ? undefined : {},
        }
      }
    };
  }

  private disableForSession(operation: string, error: BusinessError): void {
    this.disabledForSession = true;
    this.isRunning = false;
    if (!this.failureLogged) {
      this.failureLogged = true;
      Logger.error(TAG, `${operation} failed: ${error.code} ${error.message}`);
    }
  }

  async startLiveView(): Promise<void> {
    if (this.disabledForSession) {
      return;
    }
    if (this.isRunning) {
      await this.updateLiveView();
      return;
    }
    try {
      if (!await liveViewManager.isLiveViewEnabled()) {
        this.disabledForSession = true;
        return;
      }
      this.sequence = 0;
      await liveViewManager.startLiveView(await this.buildLiveView());
      this.isRunning = true;
      Logger.info(TAG, 'startLiveView success');
    } catch (err) {
      this.disableForSession('startLiveView', err as BusinessError);
    }
  }

  async updateLiveView(): Promise<void> {
    if (!this.isRunning || this.disabledForSession) {
      return;
    }
    try {
      this.sequence++;
      await liveViewManager.updateLiveView(await this.buildLiveView());
    } catch (err) {
      this.disableForSession('updateLiveView', err as BusinessError);
    }
  }

  async stopLiveView(): Promise<void> {
    if (!this.isRunning) {
      this.disabledForSession = false;
      this.failureLogged = false;
      return;
    }
    try {
      this.sequence++;
      await liveViewManager.stopLiveView(await this.buildLiveView(true));
      Logger.info(TAG, 'stopLiveView success');
    } catch (err) {
      this.disableForSession('stopLiveView', err as BusinessError);
    } finally {
      this.isRunning = false;
      this.disabledForSession = false;
      this.failureLogged = false;
    }
  }
}
