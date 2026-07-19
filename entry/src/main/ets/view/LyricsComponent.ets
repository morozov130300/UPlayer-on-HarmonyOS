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

import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { ControlAreaComponent } from './ControlAreaComponent';
import { PlayerConstants } from '../common/constants/PlayerConstants';
import { StyleConstants } from '../common/constants/StyleConstants';
import { LyricFile, LyricScrollEffect, LyricTopPosition } from '../common/constants/LyricConst';
import { LrcEntry } from '../viewmodel/LrcEntry';
import { SongItem } from '../viewmodel/SongData';
import { parseKrcLyric, parseLrcLyric } from '../common/utils/LrcUtils';
import { WindowInfo } from '../common/utils/WindowUtil';
import Logger from '../common/utils/Logger';
import LrcListView from './LrcListView';
import { AppStorageKeyConstants } from '../common/constants/AppStorageKeyConstants';

@Component
export struct LyricsComponent {
  @Prop mainWindowInfo: WindowInfo;
  @StorageLink(AppStorageKeyConstants.KEY_PROGRESS) time: number = 0;
  @State progress: number = 0.01;
  @State progressText: string = '';
  @State lyricScrollEffect: LyricScrollEffect = LyricScrollEffect.Line;
  @State mLrcEntryList: Array<LrcEntry> = [];
  @StorageLink(AppStorageKeyConstants.KEY_SONG_LIST) songList: SongItem[] = [];
  @StorageProp(AppStorageKeyConstants.KEY_SELECT_INDEX) @Watch('getLrcEntryList') selectIndex: number = 0;
  @StorageLink(AppStorageKeyConstants.KEY_IS_PLAY) isPlay: boolean = false;
  @Link isShowControl: boolean;
  @State intervalID: number = 0;
  @State pageShowTime: number = 0;
  private context: common.UIAbilityContext | undefined = AppStorage.get(AppStorageKeyConstants.KEY_UI_ABILITY_CONTEXT);

  aboutToAppear() {
    this.getLrcEntryList();
  }

  getLrcEntryList() {
    this.mLrcEntryList = [];
    if (!this.context) {
      return;
    }
    if (!this.songList || this.selectIndex < 0 || this.selectIndex >= this.songList.length) {
      return;
    }
    this.context.resourceManager.getRawFileContent(this.songList[this.selectIndex].lyric)
      .then((value: Uint8Array) => {
        let textDecoder = util.TextDecoder.create(PlayerConstants.ENCODING, { ignoreBOM: true });
        let stringData = textDecoder.decodeToString(value, { stream: false });
        if (this.songList[this.selectIndex].lyric.endsWith(LyricFile.KRC)) {
          this.mLrcEntryList = parseKrcLyric(stringData);
        } else if (this.songList[this.selectIndex].lyric.endsWith(LyricFile.LRC)) {
          this.mLrcEntryList = parseLrcLyric(stringData);
        }
        Logger.info('mLrcEntryList', `mLrcEntryList: ${JSON.stringify(this.mLrcEntryList)}`)
      })
  }

  build() {
    Column() {
      if (this.mainWindowInfo.widthBp === WidthBreakpoint.WIDTH_SM) {
        Row() {
          Image(this.songList && this.selectIndex >= 0 && this.selectIndex < this.songList.length ?
            this.songList[this.selectIndex].label : $r('app.media.ic_public_music'))
            .width(48)
            .height(48)
            .borderRadius($r('app.float.label_border'))
            .margin({
              right: 16
            })
          Column() {
            Text(this.songList && this.selectIndex < this.songList.length ?
              this.songList[this.selectIndex].title : $r('app.string.page_show'))
              .fontSize(20)
              .fontColor(Color.White)
              .fontWeight(PlayerConstants.FONT_WEIGHT_700)
              .fontFamily(PlayerConstants.FONT_FAMILY_BOLD)
            Row() {
              Text(this.songList && this.selectIndex < this.songList.length ?
                this.songList[this.selectIndex].singer : $r('app.string.page_show'))
                .fontSize(16)
                .fontColor($r('sys.color.ohos_id_color_text_hint_contrary'))
                .fontWeight(PlayerConstants.FONT_WEIGHT_500)
                .fontFamily(PlayerConstants.FONT_FAMILY_MEDIUM)
                .margin({
                  top: $r('app.float.singer_margin_top')
                })
              if (this.selectIndex === 0) {
                Row() {
                  Text($r('app.string.Ultra_high_definition_audio'))
                    .fontSize(10)
                    .fontColor('rgba(255,229,196,1)')
                }.padding(3)
                .border({
                  width: 1,
                  color: 'rgba(255,229,196,1)'
                })
                .borderRadius(4)
                .margin({
                  right: 8,
                  left: 12
                })

                Row() {
                  Text($r('app.string.Spatial_audio'))
                    .fontSize(10)
                    .fontColor('rgba(255,229,196,1)')
                }.padding(3)
                .border({
                  width: 1,
                  color: 'rgba(255,229,196,1)'
                })
                .borderRadius(4)
                .margin({
                  right: 4
                })
              }
            }

          }
          .height(48)
          .alignItems(HorizontalAlign.Start)
          .justifyContent(FlexAlign.SpaceBetween)
        }
        .width(StyleConstants.FULL_WIDTH)
        .justifyContent(FlexAlign.Start)
        .margin({
          bottom: $r('app.float.info_margin_bottom')
        })
      }
      LrcListView({
        lyricMilliSecondsTime: this.time,
        mLrcEntryList: this.mLrcEntryList,
      })
        .layoutWeight(1)

      if (this.isShowControl) {
        ControlAreaComponent({ mainWindowInfo: this.mainWindowInfo })
          .margin({
            top: $r('app.float.control_lyric_margin'),
          })
          .transition({
            type: TransitionType.Insert,
            translate: { x: 0, y: 40 },
            opacity: 0
          })
          .transition({
            type: TransitionType.Delete,
            translate: { x: 0, y: 40 },
            opacity: 0
          })
      }
    }
    .onClick(() => {
      this.pageShowTime = 0;
    })
  }
}
