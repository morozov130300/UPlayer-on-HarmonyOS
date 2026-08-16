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
import { ShareService } from '../service/ShareService';
import { ColorConversion } from '../common/utils/ColorConversion';

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
    const dataService: DataService = DataService.getInstance();
    const songs = dataService.getSongs();
    AudioMetadataService.getInstance().migrateLegacyCovers(this.context, songs).then((changed: boolean) => {
      if (changed) {
        dataService.saveSongs(songs);
      } else {
        AudioMetadataService.getInstance().cleanupCoverCache(this.context, songs);
      }
    }).catch((err: Error) => {
      Logger.warn(TAG, `migrateLegacyCovers failed: ${JSON.stringify(err)}`);
    });
  }

  onDestroy(): void {
    AudioMetadataService.getInstance().clearMemoryCache();
    AVPlayerService.getInstance().release();
    AVSessionController.getInstance().unregisterSessionListener();
    BackgroundUtil.stopContinuousTask(this.context);
    LiveViewService.getInstance().stopLiveView();
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageCreate');

    const settings: AppSettingsData = DataService.getInstance().initToAppStorage();
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
        AppStorage.setOrCreate('windowClass', mainWindow);
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
        if (!isPC) {
          mainWindow.setWindowLayoutFullScreen(true).catch((err: Error) => {
            Logger.error(TAG, `setWindowLayoutFullScreen failed: ${JSON.stringify(err)}`);
          });
        }
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
  }

  onBackground(): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onBackground');
  }
}
