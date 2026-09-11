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
import { wantAgent, common } from '@kit.AbilityKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { BusinessError } from '@kit.BasicServicesKit';
import Logger from './Logger';

const TAG = 'BackgroundUtil';

enum ContinuousTaskState {
  STOPPED,
  STARTING,
  RUNNING,
  STOPPING
}

// [Start BackgroundUtil]
export class BackgroundUtil {
  private static state: ContinuousTaskState = ContinuousTaskState.STOPPED;
  private static operation: Promise<void> = Promise.resolve();
  private static stopQueued: boolean = false;
  private static startQueued: boolean = false;

  /**
   * Start background task.
   *
   * @param context
   */
  public static startContinuousTask(context?: common.UIAbilityContext): void {
    if (!context) {
      Logger.error(TAG, 'startContinuousTask failed', `context undefined`);
      return;
    }
    if (BackgroundUtil.state === ContinuousTaskState.STARTING ||
      BackgroundUtil.state === ContinuousTaskState.RUNNING) {
      return;
    }
    if (BackgroundUtil.state === ContinuousTaskState.STOPPING) {
      BackgroundUtil.startQueued = true;
      return;
    }
    BackgroundUtil.state = ContinuousTaskState.STARTING;
    BackgroundUtil.stopQueued = false;
    BackgroundUtil.startQueued = false;
    BackgroundUtil.operation = BackgroundUtil.operation.then(async () => {
      if (BackgroundUtil.state !== ContinuousTaskState.STARTING) {
        return;
      }
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
        const wantAgentObj: Object = await wantAgent.getWantAgent(wantAgentInfo);
        await backgroundTaskManager.startBackgroundRunning(context,
          backgroundTaskManager.BackgroundMode.AUDIO_PLAYBACK, wantAgentObj);
        BackgroundUtil.state = ContinuousTaskState.RUNNING;
        Logger.info(TAG, 'startBackgroundRunning succeeded');
        if (BackgroundUtil.stopQueued) {
          BackgroundUtil.stopQueued = false;
          BackgroundUtil.stopContinuousTask(context);
        }
      } catch (error) {
        BackgroundUtil.state = ContinuousTaskState.STOPPED;
        BackgroundUtil.stopQueued = false;
        const businessError: BusinessError = error as BusinessError;
        Logger.error(TAG, `startBackgroundRunning failed Cause: code ${businessError.code}`);
      }
    });
  }

  /**
   * Stop background task.
   *
   * @param context
   */
  public static stopContinuousTask(context?: common.UIAbilityContext): void {
    if (!context || BackgroundUtil.state === ContinuousTaskState.STOPPED ||
      BackgroundUtil.state === ContinuousTaskState.STOPPING) {
      return;
    }
    if (BackgroundUtil.state === ContinuousTaskState.STARTING) {
      BackgroundUtil.stopQueued = true;
      return;
    }
    BackgroundUtil.state = ContinuousTaskState.STOPPING;
    BackgroundUtil.operation = BackgroundUtil.operation.then(async () => {
      if (BackgroundUtil.state !== ContinuousTaskState.STOPPING) {
        return;
      }
      try {
        await backgroundTaskManager.stopBackgroundRunning(context);
        BackgroundUtil.state = ContinuousTaskState.STOPPED;
        Logger.info(TAG, 'stopBackgroundRunning succeeded');
        if (BackgroundUtil.startQueued) {
          BackgroundUtil.startQueued = false;
          BackgroundUtil.startContinuousTask(context);
        }
      } catch (error) {
        BackgroundUtil.state = ContinuousTaskState.RUNNING;
        BackgroundUtil.startQueued = false;
        const businessError: BusinessError = error as BusinessError;
        Logger.error(TAG, `stopBackgroundRunning failed Cause: code ${businessError.code}`);
      }
    });
  }
}

// [Start BackgroundUtil]
