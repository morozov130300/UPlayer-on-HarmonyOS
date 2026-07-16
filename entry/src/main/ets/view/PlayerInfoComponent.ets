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

import { BusinessError } from '@kit.BasicServicesKit';
import { effectKit } from '@kit.ArkGraphics2D';
import { image } from '@kit.ImageKit';
import { common } from '@kit.AbilityKit';
import { LyricsComponent } from './LyricsComponent';
import { MusicInfoComponent } from './MusicInfoComponent';
import { StyleConstants } from '../common/constants/StyleConstants';
import { PlayerConstants } from '../common/constants/PlayerConstants';
import { SongItem } from '../viewmodel/SongData';
import Logger from '../common/utils/Logger';
import { ColorConversion } from '../common/utils/ColorConversion';
import { WindowInfo } from '../common/utils/WindowUtil';
import { PromptActionClassNew } from '../viewmodel/PromptActionClassNew';
import { AppStorageKeyConstants } from '../common/constants/AppStorageKeyConstants';

const TAG = 'PlayerInfoComponent'

@Component
export struct PlayerInfoComponent {
  @ObjectLink @Watch('mainWindowInfoChange') mainWindowInfo: WindowInfo;
  @StorageLink(AppStorageKeyConstants.KEY_SONG_LIST) songList: SongItem[] = [];
  @StorageProp(AppStorageKeyConstants.KEY_SELECT_INDEX) @Watch('getImageColor') selectIndex: number = 0;
  @StorageLink(AppStorageKeyConstants.KEY_IMAGE_COLOR) imageColor: string = 'rgba(0, 0, 2, 1.00)';
  @StorageLink(AppStorageKeyConstants.KEY_TOP_HEIGHT) topHeight: number = 0;
  @StorageLink(AppStorageKeyConstants.KEY_BOTTOM_HEIGHT) @Watch('bottomHeightChange') bottomHeight: number = 0;
  @State imageLabel: PixelMap | Resource = this.songList[this.selectIndex].label;
  @State isShowControl: boolean = true;
  @State isShowControlLg: boolean = false;
  @State isTablet: boolean = true;
  @State isTabletFalse: boolean = false;
  @StorageLink(AppStorageKeyConstants.KEY_PAGE_SHOW_TIME) pageShowTime: number = 0;
  @State intervalID: number = 0;
  @Link isShowPlay: boolean;
  @State message: Resource = $r('app.string.no_operate');
  private context: common.UIAbilityContext | undefined = AppStorage.get(AppStorageKeyConstants.KEY_UI_ABILITY_CONTEXT);

  bottomHeightChange(){

  }

  mainWindowInfoChange() {
    Logger.info(`windowUtil is change,current width breakpoint is ${this.mainWindowInfo?.widthBp},height breakpoint is ${this.mainWindowInfo?.heightBp}`)
    if (this.mainWindowInfo.heightBp === HeightBreakpoint.HEIGHT_MD &&
      this.mainWindowInfo.widthBp === WidthBreakpoint.WIDTH_SM) {
      PromptActionClassNew.openDialog();
    } else {
      PromptActionClassNew.closeDialog();
    }
  }

  aboutToAppear(): void {
    this.getImageColor();
  }

  aboutToDisappear(): void {
    clearInterval(this.intervalID);
  }

  build() {
    Stack() {
      Image(this.imageLabel)
        .size(this.mainWindowInfo.heightBp !== HeightBreakpoint.HEIGHT_LG ?
          {
            width: PlayerConstants.BACK_IMAGE,
            height: '100%',
          } :
          {
            width: '100%',
            height: PlayerConstants.BACK_IMAGE
          })
        .objectFit(ImageFit.Cover)
        .opacity(0.5)
      Row() {
        if (this.mainWindowInfo.widthBp !== WidthBreakpoint.WIDTH_SM) {
          Row() {
            Column() {
              MusicInfoComponent({ mainWindowInfo: this.mainWindowInfo })
            }
            .padding(this.mainWindowInfo.widthBp === WidthBreakpoint.WIDTH_MD ? 24 : 80)
            .width('50%')

            Column() {
              LyricsComponent({
                isShowControl: this.isShowControlLg,
                mainWindowInfo: this.mainWindowInfo
              })
            }
            .width('50%')
            .padding(this.mainWindowInfo.widthBp === WidthBreakpoint.WIDTH_MD ? 24 : 80)
          }
          .width('100%')
        } else {
          Stack({ alignContent: Alignment.TopStart }) {
            Swiper() {
              Column() {
                MusicInfoComponent({ mainWindowInfo: this.mainWindowInfo, isReverse: true })
              }
              .padding({
                top: 56,
                bottom: $r('app.float.music_component_bottom'),
                left: $r('app.float.common_padding'),
                right: $r('app.float.common_padding')
              })
              .width('100%')
              .height('100%')

              Column() {
                LyricsComponent({ isShowControl: this.isShowControl, mainWindowInfo: this.mainWindowInfo })
              }
              .padding({
                top: 56,
                left: $r('app.float.common_padding'),
                right: $r('app.float.common_padding'),
                bottom: $r('app.float.music_component_bottom'),
              })
              .width('100%')
              .height('100%')

            }
            .height(StyleConstants.FULL_HEIGHT)
            .indicator(
              new DotIndicator()
                .top($r('app.float.options_padding'))
                .selectedColor($r('app.color.select_swiper'))
                .color($r('app.color.slider_track'))
            )
            .clip(false)
            .loop(false)
            .onChange((index: number) => {
              if (index === 1) {
                this.isShowControl = true;
                this.intervalID = setInterval(() => {
                  this.pageShowTime += 1;
                  if (this.pageShowTime > 5) {
                    this.isShowControl = false;
                    clearInterval(this.intervalID);
                  }
                }, 1000);
              } else {
                this.pageShowTime = 0;
                clearInterval(this.intervalID);
              }
            })
          }
          .height(StyleConstants.FULL_HEIGHT)
        }
      }
      .padding({
        bottom: this.bottomHeight,
        top: this.topHeight
      })
    }
    .height(StyleConstants.FULL_HEIGHT)
    .width(StyleConstants.FULL_WIDTH)
    .backgroundColor(this.imageColor)
  }

  /**
   * Get largest proportion color of an image.
   */
  getImageColor() {
    if (!this.context) {
      return;
    }
    ColorConversion.setSysBarLightBackground(this.songList[this.selectIndex].isDarkBackground);
    this.context.resourceManager.getMediaContent(this.songList[this.selectIndex].label.id)
      .then((value: Uint8Array) => {
        let buffer = value.buffer as ArrayBuffer;
        image.createImageSource(buffer).createPixelMap().then((pixelMap) => {
          effectKit.createColorPicker(pixelMap, (error, colorPicker) => {
            if (error) {
              Logger.error('Failed to create color picker.');
            } else {
              let color = colorPicker.getLargestProportionColor();
              let colorArr = ColorConversion.dealColor(color.red, color.green, color.blue);
              this.imageColor = `rgba(${colorArr[0]}, ${colorArr[1]}, ${colorArr[2]}, 1)`;
            }
          })
          let headFilter = effectKit.createEffect(pixelMap);
          if (headFilter !== null) {
            headFilter.blur(PlayerConstants.IMAGE_BLUR);
            headFilter.getEffectPixelMap().then((value) => {
              this.imageLabel = value;
            })
          }
        })
          .catch((error: BusinessError) => {
            Logger.error(`${error.code} + ${error.message}`);
          })
      })
      .catch((error: BusinessError) => {
        Logger.error(`${error.code} + ${error.message}`);
      })
  }
}
