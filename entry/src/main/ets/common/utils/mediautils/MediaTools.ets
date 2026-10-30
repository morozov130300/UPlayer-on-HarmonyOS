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

import { image } from '@kit.ImageKit';
import { common } from '@kit.AbilityKit';
import { resourceManager } from '@kit.LocalizationKit';
import Logger from '../Logger';


const TAG = 'MediaTools';
export class MediaTools {
  static async getPixelMapFromResource(context: common.UIAbilityContext,
    name: resourceManager.Resource): Promise<PixelMap> {
    try {
      let resourceMgr = context.resourceManager;
      let fileData: Uint8Array = await resourceMgr.getMediaContent(name.id);
      let imageSource = image.createImageSource(fileData.buffer as ArrayBuffer);
      return await imageSource.createPixelMap();
    } catch (err) {
      Logger.error(TAG, `getPixelMapFromResource failed: ${JSON.stringify(err)}`);
      throw new Error(`getPixelMapFromResource failed: ${JSON.stringify(err)}`);
    }
  }

  /**
   * @param {string} value - Data value
   * @return {string} - If the date is less than two digits, add 0
   */
  private static fill(value: number): string {
    return value.toString().padStart(2, '0');
  }

  static msToCountdownTime(ms: number): string {
    if (!ms) {
      return '00:00';
    }
    const days = Math.floor(ms / (1000 * 60 * 60 * 24));
    const hours = Math.floor((ms % (1000 * 60 * 60 * 24)) / (1000 * 60 * 60));
    const minutes = Math.floor((ms % (1000 * 60 * 60)) / (1000 * 60));
    const seconds = Math.floor((ms % (1000 * 60)) / 1000);
    return `${(days ? MediaTools.fill(days) + ':' : '')}${(hours ? MediaTools.fill(hours) + ':' : '')}
      ${MediaTools.fill(minutes)}:${MediaTools.fill(seconds)} `.trim();
  }

  /**
   * 播放进度 mm:ss（不进位到小时，分钟超过 59 原样显示，如 75:30）；
   * AVPlayerService 进度/总时长显示用
   */
  static msToMmss(ms: number): string {
    const totalSec: number = Math.floor(ms / 1000)
    const min: number = Math.floor(totalSec / 60)
    const sec: number = totalSec % 60
    const minStr: string = min < 10 ? '0' + min : '' + min
    const secStr: string = sec < 10 ? '0' + sec : '' + sec
    return minStr + ':' + secStr
  }

  /**
   * 定时器倒计时：超过 1 小时 h:mm:ss，否则 mm:ss；ControlAreaComponent 定时剩余显示用
   */
  static secondsToHms(totalSeconds: number): string {
    const h: number = Math.floor(totalSeconds / 3600)
    const m: number = Math.floor((totalSeconds % 3600) / 60)
    const s: number = totalSeconds % 60
    const mm: string = m < 10 ? '0' + m : '' + m
    const ss: string = s < 10 ? '0' + s : '' + s
    if (h > 0) {
      return `${h}:${mm}:${ss}`
    }
    return `${mm}:${ss}`
  }
}
