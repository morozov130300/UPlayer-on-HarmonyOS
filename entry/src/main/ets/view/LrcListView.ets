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

import { LrcEntry } from "../viewmodel/LrcEntry";
import { LengthMetrics } from "@kit.ArkUI";
import { AppStorageKeyConstants } from '../common/constants/AppStorageKeyConstants';

/**
 * Default number of rows.
 */
const NONE_LINE: number = -1;

@Component
export default struct LrcListView {
  /**
   * Current lyric time [ms].
   */
  @Prop @Watch('onTimeUpdated') lyricMilliSecondsTime: number;
  /**
   * Lyrics content.
   */
  @Prop @Watch('onLyricUpdated') mLrcEntryList: Array<LrcEntry> = [];
  @State fontSize: number = 20;
  @State mCurrentLine: number = NONE_LINE;
  private scrollerForList: Scroller = new Scroller();
  @State isHasLyric: boolean = true;
  @StorageLink(AppStorageKeyConstants.KEY_IMAGE_COLOR) themeColor: string = 'rgba(0, 125, 255, 1)';

  /**
   * The lyric time is updated. The lyrics need to be scrolled to the specified position.
   */
  onTimeUpdated() {
    if (!this.hasLrc()) {
      this.isHasLyric = false;
      return;
    }
    let line = this.findShowLine(this.lyricMilliSecondsTime);
    if (line !== this.mCurrentLine) {
      this.mCurrentLine = line;
      this.smoothScrollTo(line);
    }
  }

  /**
   * The lyrics have changed.
   */
  onLyricUpdated() {
    if (!this.hasLrc()) {
      this.isHasLyric = false;
    } else {
      this.isHasLyric = true;
    }
    this.mCurrentLine = NONE_LINE;
    this.onTimeUpdated();
  }

  /**
   * Animated scroll to specified position.
   * @param line
   */
  smoothScrollTo(line: number) {
    this.scrollerForList.scrollToIndex(line, true, ScrollAlign.CENTER)
  }

  /**
   * Return the row corresponding to the current time.
   * @param milliSeconds
   * @returns
   */
  findShowLine(milliSeconds: number): number {
    if (this.mLrcEntryList && this.mLrcEntryList.length > 0) {
      for (let index = 0; index < this.mLrcEntryList.length; index++) {
        if (this.mLrcEntryList[index].lineStartTime <= milliSeconds
          && this.mLrcEntryList[index].lineStartTime + this.mLrcEntryList[index].lineDuration >= milliSeconds) {
          return index;
        }
      }
    }
    return this.mCurrentLine;
  }

  hasLrc(): boolean {
    return this.mLrcEntryList && this.mLrcEntryList.length > 0;
  }

  build() {
    Column() {
      if (this.isHasLyric) {
        List({ space: 20, initialIndex: 0, scroller: this.scrollerForList }) {
          ForEach(this.mLrcEntryList, (item: LrcEntry, index: number) => {
            ListItem() {
              Row() {
                // 当前行左侧高亮指示条（使用封面主题色）
                Column()
                  .width(3)
                  .height(this.mCurrentLine === index ? 24 : 0)
                  .backgroundColor(this.themeColor)
                  .borderRadius(2)
                  .margin({ right: 12 })
                  .animation({ duration: 300, curve: Curve.EaseInOut })

                Text(item.lineWords)
                  .fontFamily('HarmonyHeiTi')
                  .fontColor(this.mCurrentLine === index ? "#FFFFFF" : "#B3ffffff")
                  .fontSize(this.mCurrentLine === index ? 24 : 20)
                  .fontWeight(FontWeight.Bold)
                  .opacity(this.mCurrentLine === index ? 1.0 : 0.7)
              }
              .alignItems(VerticalAlign.Center)
            }
          })
        }
        .scrollBar(BarState.Off)
        .fadingEdge(true, { fadingEdgeLength: LengthMetrics.vp(80) })
        .width('100%')
        .height('100%')
      } else {
        Text($r('app.string.no_lyric'))
          .fontFamily('HarmonyHeiTi')
          .fontColor("#FFFFFF")
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .width('100%')
      }
    }
    .height('100%')
  }
}
