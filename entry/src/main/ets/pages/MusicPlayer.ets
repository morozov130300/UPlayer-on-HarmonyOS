import media from '@ohos.multimedia.media';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { avSession } from '@kit.AVSessionKit';
import { common } from '@kit.AbilityKit';

/**
 * 全局音频播放器管理器（单例）
 *
 * 职责：
 * 1. 提升 avPlayer 作用域 —— 实例存储在单例中，不随页面销毁而释放
 * 2. 管理长时任务（AUDIO_PLAYBACK）—— 确保应用切到后台后仍可继续播放
 * 3. 管理 AVSession —— 接入系统控制中心，支持锁屏/通知栏控制
 */
export class AudioPlayerManager {
  private static readonly instance_: AudioPlayerManager = new AudioPlayerManager();

  private avPlayer_: media.AVPlayer | null = null;
  private avSession_: avSession.AVSession | null = null;
  private isInitialized_: boolean = false;

  private constructor() {}

  static getInstance(): AudioPlayerManager {
    return AudioPlayerManager.instance_;
  }

  get avPlayer(): media.AVPlayer | null {
    return this.avPlayer_;
  }

  get avSession(): avSession.AVSession | null {
    return this.avSession_;
  }

  get isInitialized(): boolean {
    return this.isInitialized_;
  }

  /**
   * 初始化播放器管理器（幂等，重复调用只生效一次）
   *
   * @param context UIAbilityContext，用于申请长时任务和创建 AVSession
   */
  async init(context: common.UIAbilityContext): Promise<void> {
    if (this.isInitialized_) {
      console.info('AudioPlayerManager already initialized, skip');
      return;
    }
    try {
      // 1. 创建 AVPlayer
      this.avPlayer_ = await media.createAVPlayer();

      this.avPlayer_.on('stateChange', (state: string) => {
        console.info(`AudioPlayerManager state: ${state}`);
      });

      // 2. 申请长时任务（AUDIO_PLAYBACK），确保后台继续播放
      await this.startBackgroundTask(context);

      // 3. 创建 AVSession，接入系统控制中心
      await this.createAVSession(context);

      this.isInitialized_ = true;
      console.info('AudioPlayerManager init success');
    } catch (error) {
      console.error('AudioPlayerManager init error:', JSON.stringify(error));
    }
  }

  /** 申请后台长时任务 */
  private async startBackgroundTask(context: common.UIAbilityContext): Promise<void> {
    try {
      const request: backgroundTaskManager.ContinuousTaskRequest =
        new backgroundTaskManager.ContinuousTaskRequest();
      request.backgroundTaskModes = [backgroundTaskManager.BackgroundTaskMode.MODE_AUDIO_PLAYBACK];
      await backgroundTaskManager.startBackgroundRunning(context, request);
      console.info('Background task started (AUDIO_PLAYBACK)');
    } catch (error) {
      console.error('startBackgroundTask error:', JSON.stringify(error));
    }
  }

  /** 创建并激活 AVSession */
  private async createAVSession(context: common.UIAbilityContext): Promise<void> {
    try {
      this.avSession_ = await avSession.createAVSession(context, 'UPlayer', 'audio');

      // 设置初始媒体元数据
      this.avSession_.setAVMetadata({
        assetId: 'default',
        title: '音乐播放',
      });

      // 激活会话，使其出现在系统控制中心
      await this.avSession_.activate();

      // 监听系统控制中心的播放控制命令
      this.avSession_.on('play', () => {
        console.info('AVSession on play');
        this.play();
      });
      this.avSession_.on('pause', () => {
        console.info('AVSession on pause');
        this.pause();
      });
      this.avSession_.on('stop', () => {
        console.info('AVSession on stop');
        this.stop();
      });

      console.info('AVSession created and activated');
    } catch (error) {
      console.error('createAVSession error:', JSON.stringify(error));
    }
  }

  /** 播放 */
  async play(): Promise<void> {
    if (!this.avPlayer_) return;
    try {
      await this.avPlayer_.play();
      await this.syncPlaybackState(avSession.PlaybackState.PLAYBACK_STATE_PLAY);
    } catch (error) {
      console.error('play error:', JSON.stringify(error));
    }
  }

  /** 暂停 */
  async pause(): Promise<void> {
    if (!this.avPlayer_) return;
    try {
      await this.avPlayer_.pause();
      await this.syncPlaybackState(avSession.PlaybackState.PLAYBACK_STATE_PAUSE);
    } catch (error) {
      console.error('pause error:', JSON.stringify(error));
    }
  }

  /** 停止 */
  async stop(): Promise<void> {
    if (!this.avPlayer_) return;
    try {
      await this.avPlayer_.reset();
      await this.syncPlaybackState(avSession.PlaybackState.PLAYBACK_STATE_STOP);
    } catch (error) {
      console.error('stop error:', JSON.stringify(error));
    }
  }

  /** 将播放状态同步到 AVSession（控制中心） */
  private async syncPlaybackState(state: avSession.PlaybackState): Promise<void> {
    if (!this.avSession_) return;
    try {
      await this.avSession_.setAVPlaybackState({
        state: state,
      });
    } catch (error) {
      console.error('syncPlaybackState error:', JSON.stringify(error));
    }
  }

  /**
   * 释放所有资源（应用退出时调用）
   * 注意：不要在每个页面的 aboutToDisappear 中调用此方法
   */
  release(): void {
    try {
      if (this.avSession_) {
        this.avSession_.deactivate();
        this.avSession_.destroy();
        this.avSession_ = null;
      }
    } catch (error) {
      console.error('release AVSession error:', JSON.stringify(error));
    }
    try {
      if (this.avPlayer_) {
        this.avPlayer_.release();
        this.avPlayer_ = null;
      }
    } catch (error) {
      console.error('release AVPlayer error:', JSON.stringify(error));
    }
    this.isInitialized_ = false;
    console.info('AudioPlayerManager released');
  }
}

@Entry
@Component
struct MusicPlayer {
  private playerManager: AudioPlayerManager = AudioPlayerManager.getInstance();

  async aboutToAppear() {
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      await this.playerManager.init(context);

      // 准备播放
      if (this.playerManager.avPlayer) {
        await this.playerManager.avPlayer.prepare();
      }
    } catch (error) {
      console.error('MusicPlayer aboutToAppear error:', JSON.stringify(error));
    }
  }

  aboutToDisappear() {
    // 不释放播放器，由全局单例 AudioPlayerManager 统一管理生命周期
    // 页面销毁后 avPlayer 仍然存活，确保后台播放不中断
    console.info('MusicPlayer aboutToDisappear: player kept alive by AudioPlayerManager');
  }

  // 页面转场动画：从底部滑入，返回时向底部滑出
  pageTransition() {
    PageTransitionEnter({ duration: 350, curve: Curve.EaseInOut })
      .slide(SlideEffect.Bottom)
    PageTransitionExit({ duration: 350, curve: Curve.EaseInOut })
      .slide(SlideEffect.Bottom)
  }

  build() {
    Column() {
      Text('音乐播放器')
        .fontSize(24)

      Button('播放')
        .onClick(() => this.play())

      Button('暂停')
        .onClick(() => this.pause())
    }
    .width('100%')
    .height('100%')
    .expandSafeArea()
    .backgroundColor($r('app.color.music_player_bg'))
  }

  async play() {
    await this.playerManager.play();
  }

  async pause() {
    await this.playerManager.pause();
  }
}
