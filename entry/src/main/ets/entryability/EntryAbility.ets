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

const DOMAIN = 0x0000;
const TAG = '[EntryAbility]';
// 曲库 init 竞速上限：健康设备 getRdbStore + 建表 + 全表 query 为几十毫秒级，
// 3s 留两个数量级余量；仅 RDB 服务悬挂等病理场景触发降级
const INIT_WAIT_TIMEOUT_MS: number = 3000;

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    try {
      this.context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
    } catch (err) {
      hilog.error(DOMAIN, 'testTag', 'Failed to set colorMode. Cause: %{public}s', JSON.stringify(err));
    }
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onCreate');
    AppStorage.setOrCreate(AppStorageKeyConstants.KEY_UI_ABILITY_CONTEXT, this.context);
    LiveViewService.getInstance().setContext(this.context);
  }

  onDestroy(): void {
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
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onDestroy');
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

      // 逐项隔离：任一项初始化抛异常只记日志，不中断后续项、不阻断 loadContent
      const safeRun = (step: string, action: () => void): void => {
        try {
          action();
        } catch (e) {
          Logger.error(TAG, `${step} failed: ${e instanceof Error ? `${e.name}: ${e.message}` : JSON.stringify(e)}`);
        }
      };

      // 预置 AppStorage 键：@StorageProp/@StorageLink 要求键在组件创建前已存在，
      // 否则绑定静默失败（音量联动 KEY_CURRENT_VOLUME / KEY_VOL_PANEL_MAX 同理）
      safeRun('presetAppStorageKeys', () => {
        AppStorage.setOrCreate<number>(AppStorageKeyConstants.KEY_VOL_PANEL_MAX, 15);
        AppStorage.setOrCreate<number>(AppStorageKeyConstants.KEY_CURRENT_VOLUME, 1);
      });
      // 偏好存储已迁移 PersistenceV2：其 connect 硬性要求晚于 loadContent，
      // 真实持久化设置只能在 loadContent 之后读取；此处先用默认值占位全部
      // 设置相关 AppStorage 键保证组件绑定成立，loadContent 回调里再由
      // initToAppStorage 用真实持久化值覆盖
      safeRun('presetSettingsDefaults', () => {
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

        // ── 以下初始化依赖持久化设置，全部后移到 loadContent 之后执行 ──
        let settings: AppSettingsData = new AppSettingsData();
        safeRun('initToAppStorage', () => {
          settings = DataService.getInstance().initToAppStorage();
        });
        // 旧 preferences('myStore') 数据已废弃不迁移（用户确认现有设置整体重置）：
        // 读取链路已全部切换 PersistenceV2，此处一次性删除旧 store 文件
        safeRun('purgeLegacyPreferences', () => {
          preferences.deletePreferences(this.context, { name: 'myStore' }).catch((purgeErr: BusinessError) => {
            Logger.error(TAG, `purgeLegacyPreferences failed: ${JSON.stringify(purgeErr)}`);
          });
        });
        // 音频输出设备路由监听（耳机断开自动暂停 / 输出设备切换入口）
        safeRun('AudioRoutingService.init', () => {
          AudioRoutingService.getInstance().init();
        });
        // 系统空间音频状态（只读：开关由系统设置控制，应用订阅变化供设置页展示）
        safeRun('AudioSpatialService.init', () => {
          AudioSpatialService.getInstance().init();
        });
        // 音频会话事件订阅（会话被系统去激活/焦点状态变化可观测，日志跟踪）
        safeRun('AudioFocusService.init', () => {
          AudioFocusService.getInstance().init();
        });
        // 通知/提示音不压低音量：按落库设置激活或去激活「并发播放」AudioSession
        safeRun('applyIgnoreNotificationDuck', () => {
          AudioFocusService.getInstance().applyIgnoreNotificationDuck(settings.ignoreNotificationDuck);
        });
        // 智感握姿：按落库设置决定是否订阅 holdingHandChanged（首页加号与设置页预览共用同一份结果）
        safeRun('HoldingHandService.syncWithSetting', () => {
          HoldingHandService.getInstance().syncWithSetting();
        });
        safeRun('AVSessionController.initAVSession', () => {
          AVSessionController.getInstance().initAVSession();
        });

        try {
          if (settings.themeMode === 'light') {
            this.context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT);
          } else if (settings.themeMode === 'dark') {
            this.context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_DARK);
          } else {
            this.context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
          }
        } catch (e) {
          hilog.error(DOMAIN, 'testTag', 'applyThemeMode failed: ' + JSON.stringify(e));
        }

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
        }).catch((error: Error) => {
          Logger.error(TAG, `getMainWindow failed: code=${(error as BusinessError).code}, message=${(error as BusinessError).message}`);
        });

        windowStage.getMainWindow().then((mainWindow: window.Window) => {
          mainWindow.setWindowLayoutFullScreen(true).catch((err: Error) => {
            Logger.error(TAG, `setWindowLayoutFullScreen failed: ${JSON.stringify(err)}`);
          });
        });

        // 恢复全部音效运行态（均衡器 + 声场/环境/美声/空间渲染/变声/变速/音源分离）：
        // 状态推入原生引擎，播放启动时 playWithEffects 按持久化状态全量下发。
        // 置于 loadContent 之后：即使某个同步 NAPI 被 AudioSuite 系统 IPC 拖住不返回，
        // 主界面已加载，不会再卡开屏（try/catch 对「不返回」无效，只有后移能兜底）
        safeRun('syncEffectsFromDisk', () => {
          AVPlayerService.getInstance().syncEffectsFromDisk();
        });
      });
    });
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
  }

  onBackground(): void {
    DataService.getInstance().flushPendingSongWrites();
    SettingsStore.getInstance().flushPendingSaves();
    // 退到后台时收敛一次数据库 WAL，避免 wal 文件长期只增不减撑大本地数据
    void SongDatabase.getInstance().checkpoint();
    // 退到后台即退订握姿监听，避免后台持续占用传感器；回到前台由 onForeground 重新订阅。
    // 用 suspend 而非 stop：保留当前贴边结果，避免回前台时「先跳右再滑回左」抽动
    HoldingHandService.getInstance().suspend();
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onBackground');
  }
}
