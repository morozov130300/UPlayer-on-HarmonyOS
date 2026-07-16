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
import { AppStorageKeyConstants } from '../common/constants/AppStorageKeyConstants';
import { PlayerConstants } from '../common/constants/PlayerConstants';
import { StyleConstants } from '../common/constants/StyleConstants';
import { AVSessionController } from '../common/utils/mediautils/AVSessionController';
import { WindowInfo } from '../common/utils/WindowUtil';
import { SongItem } from '../viewmodel/SongData';
import { ControlAreaComponent } from './ControlAreaComponent';

@Component
export struct MusicInfoComponent {
  @State currentTabIndex: number = 0;
  @Prop mainWindowInfo: WindowInfo;
  @Prop isReverse: boolean = false;
  @StorageLink(AppStorageKeyConstants.KEY_SONG_LIST) songList: SongItem[] = [];
  @StorageProp(AppStorageKeyConstants.KEY_SELECT_INDEX) selectIndex: number = 0;
  @State isShowControl: boolean = false;
  @StorageLink(AppStorageKeyConstants.KEY_IS_FAVORITE) isFavorite: boolean = false;

  build() {
    Column() {
      this.CoverInfo()
      this.MusicInfo()
      Blank()
      ControlAreaComponent({ isReverse: this.isReverse, mainWindowInfo: this.mainWindowInfo })
    }
    .height(StyleConstants.FULL_HEIGHT)
    .width(StyleConstants.FULL_HEIGHT)
  }

  @Builder
  CoverInfo() {
    Row() {
      Image(this.songList[this.selectIndex].label)
        .width(StyleConstants.FULL_WIDTH)
        .aspectRatio(1)
        .borderRadius(8)
        .constraintSize({
          maxWidth: '100%',
          maxHeight: '50%'
        })
        .shadow({
          radius: $r('app.float.shadow_radius'),
          color: $r('app.color.shadow_color'),
          offsetX: 0,
          offsetY: 8
        })
    }
    .justifyContent(FlexAlign.Center)
    .width('100%')
  }

  @Builder
  MusicInfo() {
    Row() {
      Column() {
        Row() {
          Text(this.songList[this.selectIndex].title)
            .fontSize($r('app.float.title_font_play'))
            .fontColor(Color.White)
            .opacity(0.86)
            .fontWeight(FontWeight.Bold)
            .fontFamily(PlayerConstants.FONT_FAMILY_BOLD)
        }

        Row() {
          Text(this.songList[this.selectIndex].singer)
            .textAlign(TextAlign.Start)
            .fontSize(16)
            .fontColor($r('app.color.play_text_color'))
            .fontFamily(PlayerConstants.FONT_FAMILY_BLACK)
            .fontWeight(FontWeight.Regular)

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
        .padding({
          top: 2,
          bottom: 2
        })
      }
      .alignItems(HorizontalAlign.Start)
      .padding({
        bottom: 10
      })

      SymbolGlyph(this.isFavorite ? $r('sys.symbol.heart_fill') : $r('sys.symbol.heart'))
        .fontSize(26)
        .renderingStrategy(SymbolRenderingStrategy.SINGLE)
        .fontColor([this.isFavorite ? Color.Red : Color.White])
        .opacity(0.86)
        .onClick(() => {
          this.isFavorite = !this.isFavorite;
          AVSessionController.getInstance().updateFavoriteState(this.selectIndex.toString(), this.isFavorite)
        })
    }
    .width('100%')
    .justifyContent(FlexAlign.SpaceBetween)
    .alignItems(VerticalAlign.Top)
    .margin({ top: $r('app.float.music_info_margin_top') })
  }
}
