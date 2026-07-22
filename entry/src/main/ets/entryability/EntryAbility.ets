import { AbilityConstant, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { AppStorageKeyConstants } from '../common/constants/AppStorageKeyConstants';
import { WindowUtil } from '../common/utils/WindowUtil';
import { MediaControlCenter } from '../common/utils/mediautils/MediaControlCenter';
import { DataService } from '../service/DataService';
import Logger from '../common/utils/Logger';

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
  }

  onDestroy(): void {
    MediaControlCenter.getInstance().release();
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageCreate');

    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, 'testTag', 'Failed to load the content. Cause: %{public}s', JSON.stringify(err));
        return;
      }
      hilog.info(DOMAIN, 'testTag', 'Succeeded in loading the content.');

      // Initialize DataService
      DataService.getInstance().initToAppStorage();

      // Initialize WindowUtil
      windowStage.getMainWindow().then((mainWindow: window.Window) => {
        let uiContext = windowStage.getMainWindowSync().getUIContext();
        let windowUtil = new WindowUtil(mainWindow, uiContext);
        AppStorage.setOrCreate(AppStorageKeyConstants.KEY_WINDOW_UTIL, windowUtil);
        AppStorage.setOrCreate(AppStorageKeyConstants.KEY_WINDOW, mainWindow);
        windowUtil.setAvoidArea();
        windowUtil.updateAvoidArea();
        windowUtil.updateWindowInfo();
      }).catch((error: Error) => {
        Logger.error(TAG, `getMainWindow failed: ${JSON.stringify(error)}`);
      });

      // Set full screen layout
      windowStage.getMainWindow().then((mainWindow: window.Window) => {
        mainWindow.setWindowLayoutFullScreen(true).catch((err: Error) => {
          Logger.error(TAG, `setWindowLayoutFullScreen failed: ${JSON.stringify(err)}`);
        });
      });
    });
  }

  onWindowStageDestroy(): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageDestroy');
  }

  onForeground(): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onForeground');
  }

  onBackground(): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onBackground');
  }
}
