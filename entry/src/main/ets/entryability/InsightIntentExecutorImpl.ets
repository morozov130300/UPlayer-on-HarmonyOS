import { insightIntent, InsightIntentExecutor } from '@kit.AbilityKit';
import { AVPlayerService } from '../service/AVPlayerService';
import Logger from '../common/utils/Logger';

const TAG = 'InsightIntentExecutor';

export default class InsightIntentExecutorImpl extends InsightIntentExecutor {
  async onExecuteInUIAbilityBackgroundMode(intentName: string, intentParam: Record<string, Object>):
    Promise<insightIntent.ExecuteResult> {
    Logger.info(TAG, `onExecuteInUIAbilityBackgroundMode intentName=${intentName}`);
    if (intentName === 'PlayMusicList') {
      const entityId: string = (typeof intentParam.entityId === 'string') ? intentParam.entityId : '';
      return this.handlePlay(entityId);
    }
    return Promise.resolve({
      code: -1,
      result: { message: 'unknown intent' }
    } as insightIntent.ExecuteResult);
  }

  async onExecuteInUIAbilityForegroundMode(intentName: string, intentParam: Record<string, Object>):
    Promise<insightIntent.ExecuteResult> {
    Logger.info(TAG, `onExecuteInUIAbilityForegroundMode intentName=${intentName}`);
    if (intentName === 'PlayMusicList') {
      const entityId: string = (typeof intentParam.entityId === 'string') ? intentParam.entityId : '';
      return this.handlePlay(entityId);
    }
    return Promise.resolve({
      code: -1,
      result: { message: 'unknown intent' }
    } as insightIntent.ExecuteResult);
  }

  private handlePlay(entityId: string): Promise<insightIntent.ExecuteResult> {
    try {
      const avPlayerService: AVPlayerService = AVPlayerService.getInstance();
      avPlayerService.resume();
      return Promise.resolve({
        code: 0,
        result: { message: 'Intent execute succeed' }
      } as insightIntent.ExecuteResult);
    } catch (err) {
      Logger.error(TAG, `handlePlay failed: ${JSON.stringify(err)}`);
      return Promise.resolve({
        code: -1,
        result: { message: 'execute failed' }
      } as insightIntent.ExecuteResult);
    }
  }
}
