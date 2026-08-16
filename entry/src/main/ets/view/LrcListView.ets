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
import { AVPlayerService } from '../service/AVPlayerService';

const NONE_LINE: number = -1;

@Component
export default struct LrcListView {
  @Prop @Watch('onTimeUpdated') lyricMilliSecondsTime: number;
  @Prop @Watch('onLyricUpdated') mLrcEntryList: Array<LrcEntry> = [];
  @State fontSize: number = 20;
  @State mCurrentLine: number = NONE_LINE;
  private scrollerForList: Scroller = new Scroller();
  @State isHasLyric: boolean = true;
  @StorageLink(AppStorageKeyConstants.KEY_IMAGE_COLOR) themeColor: string = 'rgba(0, 125, 255, 1)';
  private avPlayerService: AVPlayerService = AVPlayerService.getInstance();

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

  onLyricUpdated() {
    if (!this.hasLrc()) {
      this.isHasLyric = false;
    } else {
      this.isHasLyric = true;
    }
    this.mCurrentLine = NONE_LINE;
    this.onTimeUpdated();
  }

  smoothScrollTo(line: number) {
    this.scrollerForList.scrollToIndex(line, true, ScrollAlign.CENTER)
  }

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

  onLyricLineClick(entry: LrcEntry): void {
    this.avPlayerService.seek(entry.lineStartTime);
  }

  build() {
    Column() {
      if (this.isHasLyric) {
        /** ✅ 歌词列表：带滚动 + 淡出边缘 */
        List({ space: 20, initialIndex: 0, scroller: this.scrollerForList }) {
          ForEach(this.mLrcEntryList, (item: LrcEntry, index: number) => {
            ListItem() {
              Row() {
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
            .onClick(() => { this.onLyricLineClick(item); })
          })
        }
        .scrollBar(BarState.Off)
        /** 上下边缘淡出 80vp，增加沉浸感 */
        .fadingEdge(true, { fadingEdgeLength: LengthMetrics.vp(80) })
        .width('100%')
        .height('100%')
      } else {
        /** 无歌词时的占位提示 */
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
