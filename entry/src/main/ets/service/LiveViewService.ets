import { liveViewManager } from '@kit.LiveViewKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { common, wantAgent, WantAgent } from '@kit.AbilityKit';
import Logger from '../common/utils/Logger';
import { AppStorageKeyConstants } from '../common/constants/AppStorageKeyConstants';

const TAG = 'LiveViewService';
const LIVE_VIEW_ID: number = 1;
const LIVE_VIEW_EVENT: string = 'MUSIC';

interface LiveViewTextItem {
  text: string;
  textColor?: string;
}

interface CapsuleData {
  type: number;
  status: number;
  icon?: string;
  title: string;
  content: string;
  backgroundColor?: string;
}

interface LiveViewLayoutData {
  layoutType: liveViewManager.LayoutType;
  title: string;
  content: string;
  underlineColor?: string;
  descPic?: string;
}

interface PrimaryData {
  title: string;
  content: LiveViewTextItem[];
  keepTime: number;
  layoutData: LiveViewLayoutData;
  clickAction?: WantAgent;
  liveViewLockScreenAbilityName?: string;
  liveViewLockScreenAbilityParameters?: Record<string, string>;
}

interface LiveViewData {
  capsule: CapsuleData;
  primary: PrimaryData;
}

export class LiveViewService {
  private static instance: LiveViewService = new LiveViewService();
  private sequence: number = 0;
  private isRunning: boolean = false;
  private context: common.UIAbilityContext | undefined = undefined;
  private operationQueue: Promise<void> = Promise.resolve();
  private lastSnapshot: string = '';
  private cooldownUntil: number = 0;

  private enqueue(operation: () => Promise<void>): Promise<void> {
    const queued: Promise<void> = this.operationQueue.then(operation, operation);
    this.operationQueue = queued.catch(() => {});
    return queued;
  }

  public static getInstance(): LiveViewService {
    return LiveViewService.instance;
  }

  setContext(ctx: common.UIAbilityContext): void {
    this.context = ctx;
  }

  private async buildClickAction(): Promise<WantAgent | null> {
    if (!this.context) {
      return null;
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
      const agent: WantAgent = await wantAgent.getWantAgent(wantAgentInfo);
      return agent;
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      Logger.error(TAG, `buildClickAction failed: ${error.code} ${error.message}`);
      return null;
    }
  }

  async startLiveView(): Promise<void> {
    await this.enqueue(async (): Promise<void> => {
      if (new Date().getTime() < this.cooldownUntil) return;
      if (this.isRunning) {
        await this.performUpdate();
        return;
      }
      await this.performStart();
    });
  }

  private async performStart(): Promise<void> {
    try {
      const title: string = AppStorage.get<string>('uplayer_current_title') ?? '未播放';
      const artist: string = AppStorage.get<string>('uplayer_current_artist') ?? '';
      const isPlay: boolean = AppStorage.get<boolean>(AppStorageKeyConstants.KEY_IS_PLAY) ?? false;
      const clickAction: WantAgent | null = await this.buildClickAction();
      const textItem1: LiveViewTextItem = { text: artist.length > 0 ? artist : '未知歌手' };
      const textItem2: LiveViewTextItem = { text: isPlay ? '正在播放' : '已暂停' };
      const capsule: CapsuleData = {
        type: liveViewManager.CapsuleType.CAPSULE_TYPE_TEXT,
        status: isPlay ? 1 : 0,
        icon: 'ic_public_music',
        title: title,
        content: artist.length > 0 ? artist : '未知歌手',
        backgroundColor: '#FF1A1A1A',
      };
      const primary: PrimaryData = {
        title: title,
        content: [textItem1, textItem2],
        keepTime: 0,
        layoutData: {
          layoutType: liveViewManager.LayoutType.LAYOUT_TYPE_PICKUP,
          title: title,
          content: artist.length > 0 ? artist : '未知歌手',
          underlineColor: '#FF007DFF',
          descPic: 'ic_public_music',
        },
        clickAction: clickAction ?? undefined,
        liveViewLockScreenAbilityName: 'LiveViewExtAbility',
      };
      const data: LiveViewData = {
        capsule: capsule,
        primary: primary,
      };
      const liveView: liveViewManager.LiveView = {
        id: LIVE_VIEW_ID,
        sequence: this.sequence,
        event: LIVE_VIEW_EVENT,
        isMute: false,
        liveViewData: data,
      };
      await liveViewManager.startLiveView(liveView);
      this.isRunning = true;
      this.lastSnapshot = `${title}\n${artist}\n${isPlay}`;
      Logger.info(TAG, 'startLiveView success');
    } catch (err) {
      this.cooldownUntil = new Date().getTime() + 30000;
      const error: BusinessError = err as BusinessError;
      Logger.error(TAG, `startLiveView failed: ${error.code} ${error.message}`);
    }
  }

  async updateLiveView(): Promise<void> {
    await this.enqueue(async (): Promise<void> => {
      await this.performUpdate();
    });
  }

  private async performUpdate(): Promise<void> {
    if (!this.isRunning || new Date().getTime() < this.cooldownUntil) {
      return;
    }
    try {
      const title: string = AppStorage.get<string>('uplayer_current_title') ?? '未播放';
      const artist: string = AppStorage.get<string>('uplayer_current_artist') ?? '';
      const isPlay: boolean = AppStorage.get<boolean>(AppStorageKeyConstants.KEY_IS_PLAY) ?? false;
      const snapshot: string = `${title}\n${artist}\n${isPlay}`;
      if (snapshot === this.lastSnapshot) return;
      this.sequence++;
      const clickAction: WantAgent | null = await this.buildClickAction();
      const textItem1: LiveViewTextItem = { text: artist.length > 0 ? artist : '未知歌手' };
      const textItem2: LiveViewTextItem = { text: isPlay ? '正在播放' : '已暂停' };
      const capsule: CapsuleData = {
        type: liveViewManager.CapsuleType.CAPSULE_TYPE_TEXT,
        status: isPlay ? 1 : 0,
        icon: 'ic_public_music',
        title: title,
        content: artist.length > 0 ? artist : '未知歌手',
        backgroundColor: '#FF1A1A1A',
      };
      const primary: PrimaryData = {
        title: title,
        content: [textItem1, textItem2],
        keepTime: 0,
        layoutData: {
          layoutType: liveViewManager.LayoutType.LAYOUT_TYPE_PICKUP,
          title: title,
          content: artist.length > 0 ? artist : '未知歌手',
          underlineColor: '#FF007DFF',
          descPic: 'ic_public_music',
        },
        clickAction: clickAction ?? undefined,
        liveViewLockScreenAbilityName: 'LiveViewExtAbility',
      };
      const data: LiveViewData = {
        capsule: capsule,
        primary: primary,
      };
      const liveView: liveViewManager.LiveView = {
        id: LIVE_VIEW_ID,
        sequence: this.sequence,
        event: LIVE_VIEW_EVENT,
        isMute: false,
        liveViewData: data,
      };
      await liveViewManager.updateLiveView(liveView);
      this.lastSnapshot = snapshot;
      Logger.info(TAG, 'updateLiveView success');
    } catch (err) {
      this.cooldownUntil = new Date().getTime() + 30000;
      const error: BusinessError = err as BusinessError;
      Logger.error(TAG, `updateLiveView failed: ${error.code} ${error.message}`);
    }
  }

  async stopLiveView(): Promise<void> {
    await this.enqueue(async (): Promise<void> => {
      if (!this.isRunning) {
        this.lastSnapshot = '';
        this.cooldownUntil = 0;
        return;
      }
      await this.performStop();
    });
  }

  private async performStop(): Promise<void> {
    try {
      const capsule: CapsuleData = {
        type: liveViewManager.CapsuleType.CAPSULE_TYPE_TEXT,
        status: 0,
        title: '',
        content: '',
      };
      const primary: PrimaryData = {
        title: '',
        content: [],
        keepTime: 0,
        layoutData: {
          layoutType: liveViewManager.LayoutType.LAYOUT_TYPE_PICKUP,
          title: '',
          content: '',
          underlineColor: '#FF007DFF',
        },
      };
      const data: LiveViewData = {
        capsule: capsule,
        primary: primary,
      };
      const liveView: liveViewManager.LiveView = {
        id: LIVE_VIEW_ID,
        sequence: this.sequence,
        event: LIVE_VIEW_EVENT,
        liveViewData: data,
      };
      await liveViewManager.stopLiveView(liveView);
      this.isRunning = false;
      this.lastSnapshot = '';
      this.cooldownUntil = 0;
      Logger.info(TAG, 'stopLiveView success');
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      Logger.error(TAG, `stopLiveView failed: ${error.code} ${error.message}`);
    }
  }
}
