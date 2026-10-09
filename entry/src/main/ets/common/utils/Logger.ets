/*
 * Copyright (c) 2024 Huawei Device Co., Ltd.
 * Licensed under the Apache License, Version 2.0 (the 'License');
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

import { hilog } from '@kit.PerformanceAnalysisKit';
import { BaseConstants } from '../constants/BaseConstants';

class Logger {
  private domain: number;
  private prefix: string;

  public constructor(prefix: string) {
    this.prefix = prefix;
    this.domain = 0x0000;
  }

  private buildFormat(args: Object[]): string {
    let format: string = '';
    for (let i = 0; i < args.length; i++) {
      format += '%{public}s ';
    }
    return format.trim();
  }

  public debug(...args: Object[]): void {
    hilog.debug(this.domain, this.prefix, this.buildFormat(args), args);
  }

  public info(...args: Object[]): void {
    hilog.info(this.domain, this.prefix, this.buildFormat(args), args);
  }

  public warn(...args: Object[]): void {
    hilog.warn(this.domain, this.prefix, this.buildFormat(args), args);
  }

  public error(...args: Object[]): void {
    hilog.error(this.domain, this.prefix, this.buildFormat(args), args);
  }
}

export default new Logger(BaseConstants.SAMPLE_NAME);
