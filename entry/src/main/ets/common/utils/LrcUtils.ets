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

import { util } from '@kit.ArkTS';
import { LrcEntry, Word } from '../../viewmodel/LrcEntry';
import Logger from './Logger';

/**
 * LRC format lyrics.
 */
// 行内时间标签：[m:ss] / [mm:ss] / [mm:ss.x|xx|xxx] / [mm:ss:xx]
// 旧实现要求分钟至少 2 位且小数位必填，会把 [0:12.34]、[00:12] 这类规范写法整行丢弃
const lrcLineRegex: RegExp = new RegExp('\\[\\d{1,3}:\\d{1,2}(?:[.:]\\d{1,3})?\\]', 'g');
// 单个标签的捕获：带小数位与不带小数位分开匹配。
// 不能只用「可选的第三个捕获组」，因为未参与匹配的组在 match 结果里是 undefined，
// 且也不该用 [.:](\\d{1,3})\\]$ 之类的尾部匹配——它会把 [00:12] 里的 :12] 误当成小数位，
// 从而把 12 秒算成 12.12 秒。
const lrcTagWithFractionRegex: RegExp = new RegExp('^\\[(\\d{1,3}):(\\d{1,2})[.:](\\d{1,3})\\]$');
const lrcTagPlainRegex: RegExp = new RegExp('^\\[(\\d{1,3}):(\\d{1,2})\\]$');
// 增强型 LRC 的逐字标签 <mm:ss.xx>，必须从正文剔除，否则会被原样渲染到界面
const lrcEnhancedWordRegex: RegExp = new RegExp('<\\d{1,3}:\\d{1,2}(?:[.:]\\d{1,3})?>', 'g');

/**
 * KRC format lyrics.
 */
const krcLineRegex = new RegExp('\\[(\\d+),(\\d+)\\](.*)');
// 真实 KRC 的逐字标签是 <0,38,0>text（< 后无空格），旧实现强制了一个空格，导致逐字数据永远解析不出来
const krcWordRegex1 = new RegExp('<\\s*(\\d+),(\\d+),(\\d+)>([^<]*)', 'g');
const krcWordRegex2 = new RegExp('<\\s*(\\d+),(\\d+),(\\d+)>(.*)');

/**
 * 把单个 LRC 时间标签换算成毫秒。无法解析时返回 NaN，由调用方跳过该标签。
 * 旧实现用两个独立正则取分钟与秒，无小数位的标签会让第二个正则返回 null，
 * String(null) -> parseFloat("null") -> NaN，从而静默产出 NaN 时间戳。
 */
function parseLrcTagToMs(tag: string): number {
  let min: number = 0;
  let sec: number = 0;
  let fractionMs: number = 0;
  const withFraction: RegExpMatchArray | null = tag.match(lrcTagWithFractionRegex);
  if (withFraction !== null) {
    min = Number.parseInt(withFraction[1]);
    sec = Number.parseInt(withFraction[2]);
    const fracText: string = withFraction[3];
    const fracValue: number = Number.parseInt(fracText);
    // 按实际位数归一化：".9" = 900ms，".98" = 980ms，".980" = 980ms
    if (Number.isFinite(fracValue) && fracText.length > 0) {
      fractionMs = fracValue / Math.pow(10, fracText.length) * 1000;
    }
  } else {
    const plain: RegExpMatchArray | null = tag.match(lrcTagPlainRegex);
    if (plain === null) {
      return Number.NaN;
    }
    min = Number.parseInt(plain[1]);
    sec = Number.parseInt(plain[2]);
  }
  if (!Number.isFinite(min) || !Number.isFinite(sec)) {
    return Number.NaN;
  }
  return (min * 60 + sec) * 1000 + fractionMs;
}


/**
 * Analysis of the lrc structure, similar to the following: [00:21.98] prime embryo outlines the blue and white pen dark to light.
 *
 * @param text
 * @returns
 * @param text
 * @returns
 */
export function parseLrcLyric(text: string): Array<LrcEntry> {
  if (!text) {
    return [];
  }
  let lyric: string[] = text.split('\n');
  let lrc: LrcEntry[] = [];
  for (let i = 0; i < lyric.length; i++) {
    let lineTime = lyric[i].match(lrcLineRegex);
    if (!lineTime || lineTime.length === 0) {
      continue;
    }
    // 剔除时间标签与逐字标签后再裁剪，顺带去掉 CRLF 行尾残留的 \r
    let lineText = lyric[i].replace(lrcLineRegex, '').replace(lrcEnhancedWordRegex, '').trim();
    // 纯时间标签的间隔行没有正文，不产出条目
    if (lineText.length === 0) {
      continue;
    }
    for (let j = 0; j < lineTime.length; j++) {
      let timeInMs = parseLrcTagToMs(lineTime[j]);
      if (!Number.isFinite(timeInMs)) {
        continue;
      }
      lrc.push({
        lineStartTime: timeInMs,
        lineDuration: 0,
        lineWords: lineText,
        words: []
      });
    }
  }
  if (lrc && lrc.length > 0) {
    lrc.sort((a, b) => {
      return a.lineStartTime - b.lineStartTime;
    })
    for (let i = 0; i < lrc.length; i++) {
      if (i === lrc.length - 1) {
        lrc[i].lineDuration = Number.MAX_VALUE;
      } else {
        lrc[i].lineDuration = lrc[i+1].lineStartTime - lrc[i].lineStartTime;
      }
    }
  }
  return lrc;
}

/**
 * Resolve the lyrics of Cool Dog, similar to the following structure.
 * [494, 228] < 0, 38, 0 > for < 38, 38, 0 > song < 76, 38, 0 >: < 114, 38, 0 > Zhou < 152, 38, 0 > Jie < 190, 38, 0 > L\n.
 *
 * @param lyricText
 * @returns
 */
export function parseKrcLyric(lyricText: string): LrcEntry[] {
  const lines: string[] = lyricText.split('\n');
  const lyricLines: LrcEntry[] = [];

  for (const line of lines) {
    const matches = line.match(krcLineRegex);
    if (matches) {
      const lineStartTime = Number.parseInt(matches[1]);
      const lineDuration = Number.parseInt(matches[2]);
      const lineWordsText = matches[3];
      const words: Word[] = [];
      const wordsMatches = lineWordsText.match(krcWordRegex1);
      let lineWords: string = '';
      if (wordsMatches) {
        for (const wordMatch of wordsMatches) {
          const wordMatches = wordMatch.match(krcWordRegex2);
          if (wordMatches) {
            const wordStartTime = Number.parseInt(wordMatches[1]);
            const wordDuration = Number.parseInt(wordMatches[2]);
            const wordText = wordMatches[4];
            lineWords += wordText;
            words.push({
              text: wordText,
              wordStartTime: wordStartTime,
              duration: wordDuration
            });
          }
        }
      }
      // 纯间奏行没有逐字内容，不产出条目，避免歌词列表出现空行；
      // KRC 每行自带 duration，跳过不影响时间轴
      if (lineWords.trim().length === 0) {
        continue;
      }
      lyricLines.push({
        lineStartTime: lineStartTime,
        lineDuration: lineDuration,
        lineWords: lineWords,
        words: words
      });
    }
  }
  lyricLines.sort((a, b) => {
    return a.lineStartTime - b.lineStartTime;
  })
  return lyricLines;
}

