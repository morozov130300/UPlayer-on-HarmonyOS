import { UIExtensionAbility, UIExtensionContentSession, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG = 'LiveViewExtAbility';

export default class LiveViewExtAbility extends UIExtensionAbility {
  onSessionCreate(want: Want, session: UIExtensionContentSession): void {
    hilog.info(0x0000, TAG, 'onSessionCreate');
    try {
      session.loadContent('liveview/LockScreenPage');
    } catch (error) {
      hilog.error(0x0000, TAG, `loadContent failed: ${JSON.stringify(error)}`);
    }
  }

  onSessionDestroy(session: UIExtensionContentSession): void {
    hilog.info(0x0000, TAG, 'onSessionDestroy');
  }
}
