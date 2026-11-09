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

// 写盘 sink 的函数签名：由 EntryAbility 注入 LogFileService.append，Logger 本身不依赖文件服务，
// 避免 common/utils 与 service 之间形成循环依赖。
type FileLogSink = (level: string, prefix: string, message: string) => void;

class Logger {
  private domain: number;
  private prefix: string;
  // 未注入/未开启日志时保持 undefined，warn/error 走零开销分支
  private fileSink: FileLogSink | undefined = undefined;

  public constructor(prefix: string) {
    this.prefix = prefix;
    this.domain = 0x0000;
  }

  // 注册写盘 sink；传 undefined 可注销。仅 WARN/ERROR 会调用它。
  public setFileSink(sink: FileLogSink | undefined): void {
    this.fileSink = sink;
  }

  private buildFormat(args: Object[]): string {
    let format: string = '';
    for (let i = 0; i < args.length; i++) {
      format += '%{public}s ';
    }
    return format.trim();
  }

  // 把 hilog 的格式化参数还原成单行文本，供日志文件使用。
  // 调用点几乎全为字符串/模板字符串；对象兜底用 JSON.stringify，循环引用退化为 String()。
  private formatArgs(args: Object[]): string {
    const parts: string[] = [];
    for (let i = 0; i < args.length; i++) {
      const arg: Object = args[i];
      let text: string = String(arg);
      if (text === '[object Object]') {
        try {
          const json: string | undefined = JSON.stringify(arg);
          if (typeof json === 'string' && json.length > 0) {
            text = json;
          }
        } catch (e) {
          text = String(arg);
        }
      }
      parts.push(text);
    }
    return parts.join(' ');
  }

  private emitFileSink(level: string, args: Object[]): void {
    const sink: FileLogSink | undefined = this.fileSink;
    if (sink === undefined) {
      return;
    }
    try {
      sink(level, this.prefix, this.formatArgs(args));
    } catch (e) {
      // 直接用 hilog，避免走 Logger.error 造成递归
      hilog.error(this.domain, this.prefix, 'file log sink failed: %{public}s', String(e));
    }
  }

  public debug(...args: Object[]): void {
    hilog.debug(this.domain, this.prefix, this.buildFormat(args), args);
  }

  public info(...args: Object[]): void {
    hilog.info(this.domain, this.prefix, this.buildFormat(args), args);
  }

  public warn(...args: Object[]): void {
    hilog.warn(this.domain, this.prefix, this.buildFormat(args), args);
    this.emitFileSink('WARN', args);
  }

  public error(...args: Object[]): void {
    hilog.error(this.domain, this.prefix, this.buildFormat(args), args);
    this.emitFileSink('ERROR', args);
  }
}

export default new Logger(BaseConstants.SAMPLE_NAME);
