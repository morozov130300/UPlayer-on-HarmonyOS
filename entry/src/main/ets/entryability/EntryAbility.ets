import { AbilityConstant, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { deviceInfo, BusinessError } from '@kit.BasicServicesKit';
import { AppStorageKeyConstants } from '../common/constants/AppStorageKeyConstants';
import { WindowUtil } from '../common/utils/WindowUtil';
import { AVPlayerService } from '../service/AVPlayerService';
import { AppSettingsData, DataService } from '../service/DataService';
import { AVSessionController } from '../common/utils/mediautils/AVSessionController';
import { BackgroundUtil } from '../common/utils/BackgroundUtil';
import { LiveViewService } from '../service/LiveViewService';
import Logger from '../common/utils/Logger';
import { AudioMetadataService } from '../service/AudioMetadataService';
import { HoldingHandService } from '../service/HoldingHandService';
import { AudioRoutingService } from '../service/AudioRoutingService';
import { AudioSpatialService } from '../service/AudioSpatialService';
import { AudioFocusService } from '../service/AudioFocusService';
import { SongDatabase } from '../service/SongDatabase';
import { ShareService } from '../service/ShareService';
import { ColorConversion } from '../common/utils/ColorConversion';
import { preferences } from '@kit.ArkData';
import { SettingsStore } from '../common/utils/SettingsStore';
import { PoetryService } from '../service/PoetryService';
import { FormUpdateService } from '../service/FormUpdateService';

const DOMAIN = 0x0000;
const TAG = '[EntryAbility]';
// 曲库 init 竞速上限：健康设备 getRdbStore + 建表 + 全表 query 为几十毫秒级，
// 3s 留两个数量级余量；仅 RDB 服务悬挂等病理场景触发降级
const INIT_WAIT_TIMEOUT_MS: number = 3000;

export default class EntryAbility extends UIAbility {
  // 桌面播放卡片（F1）：call/router 事件携带的控制动作；冷启动时服务未就绪先暂存
  private pendingCardAction: string = '';
  private cardActionReady: boolean = false;

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    try {
      this.context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
    } catch (err) {
      hilog.error(DOMAIN, 'testTag', 'Failed to set colorMode. Cause: %{public}s', JSON.stringify(err));
    }
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onCreate');
    AppStorage.setOrCreate(AppStorageKeyConstants.KEY_UI_ABILITY_CONTEXT, this.context);
    LiveViewService.getInstance().setContext(this.context);
    this.pendingCardAction = this.extractCardAction(want);
  }

  // 两段首帧后初始化的 setTimeout 句柄：Ability 若在宏任务触发前销毁，onDestroy 里统一清除
  private initAfterFirstFrameTimer: number = -1
  private initDeferredServicesTimer: number = -1

  onDestroy(): void {
    if (this.initAfterFirstFrameTimer >= 0) {
      clearTimeout(this.initAfterFirstFrameTimer);
      this.initAfterFirstFrameTimer = -1;
    }
    if (this.initDeferredServicesTimer >= 0) {
      clearTimeout(this.initDeferredServicesTimer);
      this.initDeferredServicesTimer = -1;
    }
    try {
      DataService.getInstance().flushPendingSongWrites();
    } catch (err) {
      hilog.error(DOMAIN, 'testTag', 'flushPendingSongWrites failed: %{public}s', JSON.stringify(err));
    }
    try {
      SettingsStore.getInstance().flushPendingSaves();
    } catch (err) {
      hilog.error(DOMAIN, 'testTag', 'SettingsStore flushPendingSaves failed: %{public}s', JSON.stringify(err));
    }
    try {
      AudioMetadataService.getInstance().clearMemoryCache();
    } catch (err) {
      hilog.error(DOMAIN, 'testTag', 'clearMemoryCache failed: %{public}s', JSON.stringify(err));
    }
    try {
      PoetryService.getInstance().closeSession();
    } catch (err) {
      hilog.error(DOMAIN, 'testTag', 'PoetryService closeSession failed: %{public}s', JSON.stringify(err));
    }
    try {
      AVPlayerService.getInstance().release();
    } catch (err) {
      hilog.error(DOMAIN, 'testTag', 'AVPlayerService release failed: %{public}s', JSON.stringify(err));
    }
    try {
      AVSessionController.getInstance().unregisterSessionListener();
    } catch (err) {
      hilog.error(DOMAIN, 'testTag', 'unregisterSessionListener failed: %{public}s', JSON.stringify(err));
    }
    try {
      BackgroundUtil.stopContinuousTask(this.context);
    } catch (err) {
      hilog.error(DOMAIN, 'testTag', 'stopContinuousTask failed: %{public}s', JSON.stringify(err));
    }
    try {
      LiveViewService.getInstance().stopLiveView();
    } catch (err) {
      hilog.error(DOMAIN, 'testTag', 'stopLiveView failed: %{public}s', JSON.stringify(err));
    }
    try {
      FormUpdateService.getInstance().shutdown();
    } catch (err) {
      hilog.error(DOMAIN, 'testTag', 'FormUpdateService shutdown failed: %{public}s', JSON.stringify(err));
    }
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onDestroy');
  }

  onNewWant(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    // 桌面播放卡片（F1）热启动：call/router 事件由此分发
    const action: string = this.extractCardAction(want);
    if (action.length === 0) {
      return;
    }
    if (this.cardActionReady) {
      this.dispatchCardAction(action);
    } else {
      this.pendingCardAction = action;
    }
  }

  // 从 want.parameters 提取卡片控制动作（toggle/next/open，open 仅拉起前台无动作）
  private extractCardAction(want: Want): string {
    const raw: Object | undefined = want.parameters !== undefined ?
      want.parameters['uplayer_card_action'] : undefined;
    return typeof raw === 'string' ? raw : '';
  }

  private consumePendingCardAction(): void {
    if (this.pendingCardAction.length > 0) {
      const action: string = this.pendingCardAction;
      this.pendingCardAction = '';
      this.dispatchCardAction(action);
    }
  }

  private dispatchCardAction(action: string): void {
    Logger.info(TAG, `dispatch card action: ${action}`);
    if (action === 'toggle') {
      const playing: boolean = AppStorage.get<boolean>(AppStorageKeyConstants.KEY_IS_PLAY) ?? false;
      const songId: string = AppStorage.get<string>('uplayer_current_song_id') ?? '';
      if (playing) {
        AVPlayerService.getInstance().pause();
      } else if (songId.length > 0) {
        AVPlayerService.getInstance().resume();
      } else {
        AVPlayerService.getInstance().restoreLastPlayback().catch((err: Error): void => {
          Logger.error(TAG, `card toggle restore failed: ${JSON.stringify(err)}`);
        });
      }
    } else if (action === 'next') {
      const songId: string = AppStorage.get<string>('uplayer_current_song_id') ?? '';
      if (songId.length > 0) {
        AVPlayerService.getInstance().playNextSong();
      } else {
        AVPlayerService.getInstance().restoreLastPlayback().catch((err: Error): void => {
          Logger.error(TAG, `card next restore failed: ${JSON.stringify(err)}`);
        });
      }
    }
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageCreate');

    // 曲库数据库初始化完成后再加载 UI，保证页面首屏即可读到完整曲库；
    // 但 init 若永不 settle（RDB 服务悬挂），不能无限期卡在开屏——与超时竞速，
    // 超时则降级先加载 UI，曲库迟就绪后经 KEY_LIBRARY_REVISION 修订号自动刷新首屏
    let initTimeoutTimer: number = -1;
    const initTimeout: Promise<void> = new Promise<void>((resolve: () => void) => {
      initTimeoutTimer = setTimeout(() => {
        Logger.error(TAG, 'DataService init not settled in 3000ms, startup degraded');
        resolve();
      }, INIT_WAIT_TIMEOUT_MS);
    });
    Promise.race([
      DataService.getInstance().init(this.context).catch((err: Error) => {
        Logger.error(TAG, `DataService init failed: ${JSON.stringify(err)}`);
      }),
      initTimeout
    ]).then((): void => {
      if (initTimeoutTimer !== -1) {
        clearTimeout(initTimeoutTimer);
        initTimeoutTimer = -1;
      }

      // 预置 AppStorage 键：@StorageProp/@StorageLink 要求键在组件创建前已存在，
      // 否则绑定静默失败（音量联动 KEY_CURRENT_VOLUME / KEY_VOL_PANEL_MAX 同理）
      this.safeRun('presetAppStorageKeys', () => {
        AppStorage.setOrCreate<number>(AppStorageKeyConstants.KEY_VOL_PANEL_MAX, 15);
        AppStorage.setOrCreate<number>(AppStorageKeyConstants.KEY_CURRENT_VOLUME, 1);
      });
      // 偏好存储已迁移 PersistenceV2：其 connect 硬性要求晚于 loadContent，
      // 真实持久化设置只能在 loadContent 之后读取；此处先用默认值占位全部
      // 设置相关 AppStorage 键保证组件绑定成立，loadContent 之后再读真实持久化值覆盖
      this.safeRun('presetSettingsDefaults', () => {
        DataService.getInstance().presetAppStorageDefaults();
      });

      // loadContent 不置于任何 try 内：任何初始化故障都不再阻止主界面加载
      hilog.info(DOMAIN, 'testTag', 'startup before loadContent');
      windowStage.loadContent('pages/Index', (err) => {
        if (err.code) {
          hilog.error(DOMAIN, 'testTag', 'Failed to load the content. Cause: %{public}s', JSON.stringify(err));
          return;
        }
        hilog.info(DOMAIN, 'testTag', 'Succeeded in loading the content.');
        // ★ 开屏退场红线：启动页（startWindow）由系统在「首帧绘制完成」后才移除，
        // 而 loadContent 回调仍在 UI 线程、首帧尚未提交——回调里任何一次不返回的
        // 同步调用（音效 NAPI、系统 IPC、PersistenceV2 读盘）都会把首帧永久卡住，
        // 表现为「一直停在启动页、完全不能操作」。
        // 因此回调体内只做一件事：把全部初始化丢到下一个宏任务后立刻返回，
        // 让出 UI 线程提交首帧。try/catch 对「不返回」无效，只有离开这条路径才是兜底。
        this.initAfterFirstFrameTimer = setTimeout(() => {
          this.initAfterFirstFrame(windowStage);
        }, 0);
      });
    });
  }

  // 逐项隔离：任一项初始化抛异常只记日志，不中断后续项
  private safeRun(step: string, action: () => void): void {
    try {
      action();
    } catch (e) {
      Logger.error(TAG, `${step} failed: ${e instanceof Error ? `${e.name}: ${e.message}` : JSON.stringify(e)}`);
    }
  }

  // 首帧之后的启动初始化（第一段：依赖持久化设置、必须尽早生效的部分）
  private initAfterFirstFrame(windowStage: window.WindowStage): void {
    Logger.info(TAG, 'post-frame init begin');

    let settings: AppSettingsData = new AppSettingsData();
    this.safeRun('initToAppStorage', () => {
      settings = DataService.getInstance().initToAppStorage();
    });

    this.safeRun('applyThemeMode', () => {
      if (settings.themeMode === 'light') {
        this.context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT);
      } else if (settings.themeMode === 'dark') {
        this.context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_DARK);
      } else {
        this.context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
      }
    });

    windowStage.getMainWindow().then((mainWindow: window.Window) => {
      let uiContext = windowStage.getMainWindowSync().getUIContext();
      let windowUtil = new WindowUtil(mainWindow, uiContext);
      AppStorage.setOrCreate(AppStorageKeyConstants.KEY_WINDOW_UTIL, windowUtil);
      AppStorage.setOrCreate(AppStorageKeyConstants.KEY_WINDOW, mainWindow);
      ShareService.getInstance().initialize(mainWindow);
      const isDarkStatusBackground: boolean = settings.themeMode === 'dark' ||
        (settings.themeMode === 'system' &&
          this.context.config.colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK);
      ColorConversion.setSysBarLightBackground(isDarkStatusBackground);
      windowUtil.setAvoidArea();
      windowUtil.updateAvoidArea();
      windowUtil.updateWindowInfo();
      try {
        const isPC: boolean = deviceInfo.deviceType === '2in1';
        if (isPC) {
          windowUtil.setupImmersiveTitleButtons();
        } else {
          mainWindow.setWindowDecorVisible(false);
        }
      } catch (e) {
        Logger.error(TAG, `setWindowDecorVisible failed: code=${(e as BusinessError).code}, message=${(e as BusinessError).message}`);
      }
      mainWindow.setWindowLayoutFullScreen(true).catch((err: Error) => {
        Logger.error(TAG, `setWindowLayoutFullScreen failed: ${JSON.stringify(err)}`);
      });
    }).catch((error: Error) => {
      Logger.error(TAG, `getMainWindow failed: code=${(error as BusinessError).code}, message=${(error as BusinessError).message}`);
    });

    // 第二段再推迟一个宏任务：系统服务订阅与音效状态都涉及系统 IPC，
    // 与首帧渲染错开，任何一项卡住都不再作用于开屏
    this.initDeferredServicesTimer = setTimeout(() => {
      this.initDeferredServices(settings);
    }, 0);
  }

  // 首帧之后的启动初始化（第二段：系统服务订阅、音效运行态）
  private initDeferredServices(settings: AppSettingsData): void {
    Logger.info(TAG, 'post-frame services init begin');
    // 旧 preferences('myStore') 数据已废弃不迁移（用户确认现有设置整体重置）：
    // 读取链路已全部切换 PersistenceV2，此处一次性删除旧 store 文件
    this.safeRun('purgeLegacyPreferences', () => {
      preferences.deletePreferences(this.context, { name: 'myStore' }).catch((purgeErr: BusinessError) => {
        Logger.error(TAG, `purgeLegacyPreferences failed: ${JSON.stringify(purgeErr)}`);
      });
    });
    // 音频输出设备路由监听（耳机断开自动暂停 / 输出设备切换入口）
    this.safeRun('AudioRoutingService.init', () => {
      AudioRoutingService.getInstance().init();
    });
    // 系统空间音频状态（只读：开关由系统设置控制，应用订阅变化供设置页展示）
    this.safeRun('AudioSpatialService.init', () => {
      AudioSpatialService.getInstance().init();
    });
    // 音频会话事件订阅（会话被系统去激活/焦点状态变化可观测，日志跟踪）
    this.safeRun('AudioFocusService.init', () => {
      AudioFocusService.getInstance().init();
    });
    // 与其他音频同时播放（含通知/提示音不压低音量，同一开关）：按落库设置激活或去激活「并发播放」AudioSession
    this.safeRun('applyIgnoreNotificationDuck', () => {
      AudioFocusService.getInstance().applyIgnoreNotificationDuck(settings.ignoreNotificationDuck);
    });
    // 智感握姿：按落库设置决定是否订阅 holdingHandChanged（首页加号与设置页预览共用同一份结果）
    this.safeRun('HoldingHandService.syncWithSetting', () => {
      HoldingHandService.getInstance().syncWithSetting();
    });
    this.safeRun('AVSessionController.initAVSession', () => {
      AVSessionController.getInstance().initAVSession();
    });
    // 恢复全部音效运行态（只回填内存状态，不再在启动期打 20+ 次同步音效 NAPI）：
    // 原生下发由每次起播的 playWithEffects 全量完成，启动期推一次纯属重复且是卡开屏的元凶
    this.safeRun('syncEffectsFromDisk', () => {
      AVPlayerService.getInstance().syncEffectsFromDisk();
    });
    // 断点续播（P0-2）：冷启动恢复上次播放歌曲与进度（「启动时恢复上次播放」关则内部跳过）
    this.safeRun('restoreLastPlayback', () => {
      AVPlayerService.getInstance().restoreLastPlayback().catch((err: Error) => {
        Logger.error(TAG, `restoreLastPlayback failed: ${JSON.stringify(err)}`);
      });
    });
    // 桌面播放卡片（F1）：应用进程侧卡片更新器（发现已加桌卡片 + 1s 节流推送）
    this.safeRun('FormUpdateService.init', () => {
      FormUpdateService.getInstance().init(this.context);
    });
    // 卡片控制动作（冷启动暂存的 pendingCardAction 或本次启动 want 携带）此时服务已就绪
    this.cardActionReady = true;
    this.consumePendingCardAction();
    Logger.info(TAG, 'post-frame services init end');
  }

  onWindowStageDestroy(): void {
    ShareService.getInstance().shutdown();
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageDestroy');
  }

  onForeground(): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onForeground');
    AppStorage.setOrCreate<boolean>(AppStorageKeyConstants.KEY_UI_ACTIVE, true)
    AVPlayerService.getInstance().onForegroundRestore();
    HoldingHandService.getInstance().syncWithSetting();
    // 回前台立即检查桌面卡片并重置发现退避（后台期间用户新加卡片可被及时感知）
    this.safeRun('FormUpdateService.refreshNow', () => {
      FormUpdateService.getInstance().refreshNow();
    });
  }

  onBackground(): void {
    // 断点续播（P0-2）：退后台立即落盘当前播放位置（后台被杀最多丢一个周期 ≈5s 进度）
    try {
      AVPlayerService.getInstance().persistLastPlayback(true);
    } catch (err) {
      hilog.error(DOMAIN, 'testTag', 'persistLastPlayback failed: %{public}s', JSON.stringify(err));
    }
    DataService.getInstance().flushPendingSongWrites();
    SettingsStore.getInstance().flushPendingSaves();
    // 退到后台时收敛一次数据库 WAL，避免 wal 文件长期只增不减撑大本地数据
    void SongDatabase.getInstance().checkpoint();
    // 退到后台即退订握姿监听，避免后台持续占用传感器；回到前台由 onForeground 重新订阅。
    // 用 suspend 而非 stop：保留当前贴边结果，避免回前台时「先跳右再滑回左」抽动
    HoldingHandService.getInstance().suspend();
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onBackground');
  }

  // PC(2in1) 点 X 关窗：系统先询问是否允许关闭，未实现此回调时系统只能强关窗口
  // （日志表现为 PrepareTerminateAbility failed, do close window）。此处拦截并主动
  // terminateSelf 走应用优雅退出路径；手机/平板不触发此回调，行为不变。
  onPrepareToTerminate(): boolean {
    Logger.info(TAG, 'onPrepareToTerminate, terminating self');
    this.context.terminateSelf();
    return true;
  }
}
