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

/** 无歌词时的默认行号 */
const NONE_LINE: number = -1;

/**
 * 歌词列表视图
 * 接收播放进度（毫秒）和解析后的歌词数组，自动滚动到当前行并高亮
 */
@Component
export default struct LrcListView {
  /** 当前播放时间（毫秒），变化时触发滚动 */
  @Prop @Watch('onTimeUpdated') lyricMilliSecondsTime: number;
  /** 歌词条目列表，变化时重新定位 */
  @Prop @Watch('onLyricUpdated') mLrcEntryList: Array<LrcEntry> = [];
  @State fontSize: number = 20;
  /** 当前高亮的行索引 */
  @State mCurrentLine: number = NONE_LINE;
  private scrollerForList: Scroller = new Scroller();
  /** 是否有歌词 */
  @State isHasLyric: boolean = true;
  /** 主题色（从封面主色取），用于当前行左侧指示条 */
  @StorageLink(AppStorageKeyConstants.KEY_IMAGE_COLOR) themeColor: string = 'rgba(0, 125, 255, 1)';

  /** 播放进度更新 → 查找对应歌词行 → 滚动居中 */
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

  /** 歌词列表变化 → 重置行号并重新定位 */
  onLyricUpdated() {
    if (!this.hasLrc()) {
      this.isHasLyric = false;
    } else {
      this.isHasLyric = true;
    }
    this.mCurrentLine = NONE_LINE;
    this.onTimeUpdated();
  }

  /** 平滑滚动到指定行（居中） */
  smoothScrollTo(line: number) {
    this.scrollerForList.scrollToIndex(line, true, ScrollAlign.CENTER)
  }

  /** 二分查找时间对应的歌词行索引（默认保留当前行） */
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
        /** ✅ 歌词列表：带滚动 + 淡出边缘 */
        List({ space: 20, initialIndex: 0, scroller: this.scrollerForList }) {
          ForEach(this.mLrcEntryList, (item: LrcEntry, index: number) => {
            ListItem() {
              Row() {
                /** 当前行左侧高亮指示条（宽度 3vp，高度 24vp，使用封面主题色） */
                Column()
                  .width(3)
                  .height(this.mCurrentLine === index ? 24 : 0)
                  .backgroundColor(this.themeColor)
                  .borderRadius(2)
                  .margin({ right: 12 })
                  .animation({ duration: 300, curve: Curve.EaseInOut })
                /** 歌词文本：当前行白色大字号 + 粗体，其他行灰色半透明小字号 */
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
