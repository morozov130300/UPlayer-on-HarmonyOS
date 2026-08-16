/*
 * Copyright (c) 2026 Huawei Device Co., Ltd.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */
import { wantAgent, common, WantAgent } from '@kit.AbilityKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { BusinessError } from '@kit.BasicServicesKit';
import Logger from './Logger';

const TAG = 'BackgroundUtil';

// [Start BackgroundUtil]
export class BackgroundUtil {
  private static isRunning: boolean = false;
  private static startPromise: Promise<boolean> | undefined = undefined;
  private static stopPromise: Promise<boolean> | undefined = undefined;

  public static startContinuousTask(context?: common.UIAbilityContext): Promise<boolean> {
    if (!context) {
      Logger.error(TAG, 'startContinuousTask failed', 'context undefined');
      return Promise.resolve(false);
    }
    if (BackgroundUtil.isRunning) {
      return Promise.resolve(true);
    }
    if (BackgroundUtil.startPromise !== undefined) {
      return BackgroundUtil.startPromise;
    }
    BackgroundUtil.startPromise = BackgroundUtil.start(context);
    return BackgroundUtil.startPromise;
  }

  private static async start(context: common.UIAbilityContext): Promise<boolean> {
    const wantAgentInfo: wantAgent.WantAgentInfo = {
      wants: [
        {
          bundleName: context.abilityInfo.bundleName,
          abilityName: context.abilityInfo.name
        }
      ],
      operationType: wantAgent.OperationType.START_ABILITY,
      requestCode: 0,
      wantAgentFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
    };
    try {
      const agent: WantAgent = await wantAgent.getWantAgent(wantAgentInfo);
      await backgroundTaskManager.startBackgroundRunning(context,
        backgroundTaskManager.BackgroundMode.AUDIO_PLAYBACK, agent);
      BackgroundUtil.isRunning = true;
      Logger.info(TAG, 'startBackgroundRunning succeeded');
      return true;
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      Logger.error(TAG, `startBackgroundRunning failed: code ${error.code}, message ${error.message}`);
      return false;
    } finally {
      BackgroundUtil.startPromise = undefined;
    }
  }

  public static stopContinuousTask(context?: common.UIAbilityContext): Promise<boolean> {
    if (!context || (!BackgroundUtil.isRunning && BackgroundUtil.startPromise === undefined)) {
      return Promise.resolve(true);
    }
    if (BackgroundUtil.stopPromise !== undefined) {
      return BackgroundUtil.stopPromise;
    }
    BackgroundUtil.stopPromise = BackgroundUtil.stop(context);
    return BackgroundUtil.stopPromise;
  }

  private static async stop(context: common.UIAbilityContext): Promise<boolean> {
    if (BackgroundUtil.startPromise !== undefined) {
      await BackgroundUtil.startPromise;
    }
    if (!BackgroundUtil.isRunning) {
      BackgroundUtil.stopPromise = undefined;
      return true;
    }
    try {
      await backgroundTaskManager.stopBackgroundRunning(context);
      BackgroundUtil.isRunning = false;
      Logger.info(TAG, 'stopBackgroundRunning succeeded');
      return true;
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      Logger.error(TAG, `stopBackgroundRunning failed: code ${error.code}, message ${error.message}`);
      return false;
    } finally {
      BackgroundUtil.stopPromise = undefined;
    }
  }
}

// [Start BackgroundUtil]
