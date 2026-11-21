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
  private static startWaiters: Array<(started: boolean) => void> = [];
  private static stopWaiters: Array<() => void> = [];
  private static stopQueued: boolean = false;
  private static startQueued: boolean = false;

  /**
   * Start background task.
   *
   * @param context
   */
  public static startContinuousTask(context?: common.UIAbilityContext): Promise<boolean> {
    if (!context) {
      Logger.error(TAG, 'startContinuousTask failed: context undefined');
      return Promise.resolve(false);
    }
    if (BackgroundUtil.state === ContinuousTaskState.RUNNING) {
      return Promise.resolve(true);
    }
    const started: Promise<boolean> = new Promise<boolean>((resolve: (started: boolean) => void): void => {
      BackgroundUtil.startWaiters.push(resolve);
    });
    if (BackgroundUtil.state === ContinuousTaskState.STARTING) {
      return started;
    }
    if (BackgroundUtil.state === ContinuousTaskState.STOPPING) {
      BackgroundUtil.startQueued = true;
      return started;
    }
    BackgroundUtil.state = ContinuousTaskState.STARTING;
    BackgroundUtil.stopQueued = false;
    BackgroundUtil.startQueued = false;
    BackgroundUtil.operation = BackgroundUtil.operation.then(async () => {
      if (BackgroundUtil.state !== ContinuousTaskState.STARTING) {
        BackgroundUtil.resolveStartWaiters(false);
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
          try {
            await backgroundTaskManager.stopBackgroundRunning(context);
            BackgroundUtil.state = ContinuousTaskState.STOPPED;
            Logger.info(TAG, 'stopBackgroundRunning succeeded after queued stop');
          } catch (stopError) {
            BackgroundUtil.state = ContinuousTaskState.RUNNING;
            const stopBusinessError: BusinessError = stopError as BusinessError;
            Logger.error(TAG, `queued stopBackgroundRunning failed Cause: code ${stopBusinessError.code}`);
          }
          BackgroundUtil.resolveStartWaiters(false);
          BackgroundUtil.resolveStopWaiters();
          return;
        }
        BackgroundUtil.resolveStartWaiters(true);
      } catch (error) {
        BackgroundUtil.state = ContinuousTaskState.STOPPED;
        BackgroundUtil.stopQueued = false;
        BackgroundUtil.resolveStartWaiters(false);
        const businessError: BusinessError = error as BusinessError;
        Logger.error(TAG, `startBackgroundRunning failed Cause: code ${businessError.code}`);
      }
    });
    return started;
  }

  private static resolveStartWaiters(started: boolean): void {
    const waiters: Array<(started: boolean) => void> = BackgroundUtil.startWaiters;
    BackgroundUtil.startWaiters = [];
    for (let i = 0; i < waiters.length; i++) {
      waiters[i](started);
    }
  }

  /**
   * Stop background task.
   *
   * @param context
   */
  public static stopContinuousTask(context?: common.UIAbilityContext): Promise<void> {
    if (!context || BackgroundUtil.state === ContinuousTaskState.STOPPED) {
      return Promise.resolve();
    }
    const stopped: Promise<void> = new Promise<void>((resolve: () => void): void => {
      BackgroundUtil.stopWaiters.push(resolve);
    });
    if (BackgroundUtil.state === ContinuousTaskState.STOPPING) {
      return stopped;
    }
    if (BackgroundUtil.state === ContinuousTaskState.STARTING) {
      BackgroundUtil.stopQueued = true;
      return stopped;
    }
    BackgroundUtil.state = ContinuousTaskState.STOPPING;
    BackgroundUtil.operation = BackgroundUtil.operation.then(async () => {
      if (BackgroundUtil.state !== ContinuousTaskState.STOPPING) {
        BackgroundUtil.resolveStopWaiters();
        return;
      }
      try {
        await backgroundTaskManager.stopBackgroundRunning(context);
        BackgroundUtil.state = ContinuousTaskState.STOPPED;
        Logger.info(TAG, 'stopBackgroundRunning succeeded');
        BackgroundUtil.resolveStopWaiters();
        if (BackgroundUtil.startQueued) {
          BackgroundUtil.startQueued = false;
          void BackgroundUtil.startContinuousTask(context);
        }
      } catch (error) {
        BackgroundUtil.state = ContinuousTaskState.RUNNING;
        BackgroundUtil.startQueued = false;
        BackgroundUtil.resolveStopWaiters();
        const businessError: BusinessError = error as BusinessError;
        Logger.error(TAG, `stopBackgroundRunning failed Cause: code ${businessError.code}`);
      }
    });
    return stopped;
  }

  private static resolveStopWaiters(): void {
    const waiters: Array<() => void> = BackgroundUtil.stopWaiters;
    BackgroundUtil.stopWaiters = [];
    for (let i = 0; i < waiters.length; i++) {
      waiters[i]();
    }
  }
}

// [Start BackgroundUtil]
