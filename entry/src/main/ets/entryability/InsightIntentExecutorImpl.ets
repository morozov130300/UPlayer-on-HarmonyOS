import { insightIntent, InsightIntentExecutor } from '@kit.AbilityKit';
import { AVPlayerService } from '../service/AVPlayerService';
import { AppStorageKeyConstants } from '../common/constants/AppStorageKeyConstants';
import Logger from '../common/utils/Logger';

const TAG = 'InsightIntentExecutor';

export default class InsightIntentExecutorImpl extends InsightIntentExecutor {
  async onExecuteInUIAbilityBackgroundMode(intentName: string, intentParam: Record<string, Object>):
    Promise<insightIntent.ExecuteResult> {
    Logger.info(TAG, `onExecuteInUIAbilityBackgroundMode intentName=${intentName}`);
    return this.dispatchPlayIntent(intentName);
  }

  async onExecuteInUIAbilityForegroundMode(intentName: string, intentParam: Record<string, Object>):
    Promise<insightIntent.ExecuteResult> {
    Logger.info(TAG, `onExecuteInUIAbilityForegroundMode intentName=${intentName}`);
    return this.dispatchPlayIntent(intentName);
  }

  private dispatchPlayIntent(intentName: string): Promise<insightIntent.ExecuteResult> {
    if (intentName === 'PlayMusicList') {
      return this.handlePlay();
    }
    return Promise.resolve({
      code: -1,
      result: { message: 'unknown intent' }
    } as insightIntent.ExecuteResult);
  }

  private async handlePlay(): Promise<insightIntent.ExecuteResult> {
    try {
      await AVPlayerService.getInstance().resume();
      const playing: boolean = AppStorage.get<boolean>(AppStorageKeyConstants.KEY_IS_PLAY) ?? false;
      if (!playing) {
        return {
          code: -1,
          result: { message: 'background audio task unavailable' }
        } as insightIntent.ExecuteResult;
      }
      return {
        code: 0,
        result: { message: 'Intent execute succeed' }
      } as insightIntent.ExecuteResult;
    } catch (err) {
      Logger.error(TAG, `handlePlay failed: ${JSON.stringify(err)}`);
      return {
        code: -1,
        result: { message: 'execute failed' }
      } as insightIntent.ExecuteResult;
    }
  }
}
