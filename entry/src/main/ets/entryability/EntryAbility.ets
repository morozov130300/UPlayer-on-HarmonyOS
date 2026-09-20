import { AbilityConstant, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { deviceInfo } from '@kit.BasicServicesKit';
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
import { ShareService } from '../service/ShareService';
import { ColorConversion } from '../common/utils/ColorConversion';
import { PreferencesUtil } from '../common/utils/PreferencesUtil';

const DOMAIN = 0x0000;
const TAG = '[EntryAbility]';

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
    DataService.getInstance().flushPendingSongWrites();
    PreferencesUtil.getInstance().flushNow();
    AudioMetadataService.getInstance().clearMemoryCache();
    AVPlayerService.getInstance().release();
    AVSessionController.getInstance().unregisterSessionListener();
    BackgroundUtil.stopContinuousTask(this.context);
    LiveViewService.getInstance().stopLiveView();
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageCreate');

    // 曲库数据库初始化完成后再加载 UI，保证页面首屏即可读到完整曲库
    DataService.getInstance().init(this.context).catch((err: Error) => {
      Logger.error(TAG, `DataService init failed: ${JSON.stringify(err)}`);
    }).then((): void => {
    const settings: AppSettingsData = DataService.getInstance().initToAppStorage();
    // 智感握姿：按落库设置决定是否订阅 holdingHandChanged（首页加号与设置页预览共用同一份结果）
    HoldingHandService.getInstance().syncWithSetting();
    AVSessionController.getInstance().initAVSession();

    AVPlayerService.getInstance().applyEqualizer(settings.eqEnabled, settings.eqBands);
    try {
      if (settings.themeMode === 'light') {
        this.context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT);
      } else if (settings.themeMode === 'dark') {
        this.context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_DARK);
      } else {
        this.context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
      }
    } catch (e) {
      Logger.error(TAG, 'applyThemeMode failed: ' + JSON.stringify(e));
    }

    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, 'testTag', 'Failed to load the content. Cause: %{public}s', JSON.stringify(err));
        return;
      }
      hilog.info(DOMAIN, 'testTag', 'Succeeded in loading the content.');

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
          Logger.error(TAG, 'setWindowDecorVisible failed: ' + JSON.stringify(e));
        }
      }).catch((error: Error) => {
        Logger.error(TAG, `getMainWindow failed: ${JSON.stringify(error)}`);
      });

      windowStage.getMainWindow().then((mainWindow: window.Window) => {
        const isPC: boolean = deviceInfo.deviceType === '2in1';
        mainWindow.setWindowLayoutFullScreen(true).catch((err: Error) => {
          Logger.error(TAG, `setWindowLayoutFullScreen failed: ${JSON.stringify(err)}`);
        });
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
    AVPlayerService.getInstance().onForegroundRestore();
    HoldingHandService.getInstance().syncWithSetting();
  }

  onBackground(): void {
    DataService.getInstance().flushPendingSongWrites();
    PreferencesUtil.getInstance().flushNow();
    // 退到后台即退订握姿监听，避免后台持续占用传感器；回到前台由 onForeground 重新订阅
    HoldingHandService.getInstance().stop();
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onBackground');
  }
}
