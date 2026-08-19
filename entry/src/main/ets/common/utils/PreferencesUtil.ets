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

import { preferences } from '@kit.ArkData';
import Logger from './Logger';
import { common } from '@kit.AbilityKit';
import { AppStorageKeyConstants } from '../constants/AppStorageKeyConstants';

const TAG = 'PreferencesUtil';
const MY_STORE = 'myStore';

export class PreferencesUtil {
  private static preferencesUtil: PreferencesUtil;
  private context: common.UIAbilityContext | undefined = AppStorage.get(AppStorageKeyConstants.KEY_UI_ABILITY_CONTEXT);
  preferences: preferences.Preferences | undefined;
  private flushTimer: number = -1;
  private flushChain: Promise<void> = Promise.resolve();

  constructor() {
    let options: preferences.Options = { name: MY_STORE };
    this.preferences = preferences.getPreferencesSync(this.context, options);
  }

  public static getInstance(): PreferencesUtil {
    if (!PreferencesUtil.preferencesUtil) {
      PreferencesUtil.preferencesUtil = new PreferencesUtil();
    }
    return PreferencesUtil.preferencesUtil;
  }

  // Delete the data of the preferences
  preferencesPut(key: string, value: preferences.ValueType, immediate: boolean = true): void {
    if (!this.preferences) {
      Logger.info(TAG, 'preferences is undefined');
      return;
    }
    try {
      this.preferences.putSync(key, value);
      if (immediate) {
        this.flushNow();
      } else {
        this.scheduleFlush();
      }
    } catch (err) {
      Logger.error(TAG, `preferencesPut failed: ${JSON.stringify(err)}`);
    }
  }

  flushNow(): Promise<void> {
    if (this.flushTimer !== -1) {
      clearTimeout(this.flushTimer);
      this.flushTimer = -1;
    }
    this.flushChain = this.flushChain.then((): Promise<void> => {
      if (this.preferences === undefined) {
        return Promise.resolve();
      }
      return this.preferences.flush();
    }).catch((err: Error): void => {
      Logger.error(TAG, `preferences flush failed: ${JSON.stringify(err)}`);
    });
    return this.flushChain;
  }

  private scheduleFlush(): void {
    if (this.flushTimer !== -1) {
      clearTimeout(this.flushTimer);
    }
    this.flushTimer = setTimeout(() => {
      this.flushTimer = -1;
      this.flushNow();
    }, 300);
  }

  // Determine whether there is a certain data in the preferences
  preferencesHas(key: string): boolean {
    if (!this.preferences) {
      Logger.info(TAG, 'preferences is undefined');
      return false;
    }
    try {
      return this.preferences.hasSync(key);
    } catch (err) {
      Logger.error(TAG, `preferencesHas failed: ${JSON.stringify(err)}`);
      return false;
    }
  }

  removePreferencesFromCache(): void {
    try {
      preferences.removePreferencesFromCache(this.context, MY_STORE);
    } catch (err) {
      Logger.error(TAG, `removePreferencesFromCache failed: ${JSON.stringify(err)}`);
    }
  }

  getValue(key: string): preferences.ValueType | undefined {
    if (!this.preferences) {
      Logger.info(TAG, 'preferences is undefined');
      return undefined;
    }
    try {
      return this.preferences.getSync(key, undefined);
    } catch (err) {
      Logger.error(TAG, `getValue failed: ${JSON.stringify(err)}`);
      return undefined;
    }
  }

  // Remove data by key
  removeKey(key: string): void {
    if (!this.preferences) {
      Logger.info(TAG, 'preferences is undefined');
      return;
    }
    try {
      this.preferences.deleteSync(key);
      this.flushNow();
    } catch (err) {
      Logger.error(TAG, `removeKey failed: ${JSON.stringify(err)}`);
    }
  }
}
