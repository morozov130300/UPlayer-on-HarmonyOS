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
import { curves } from '@kit.ArkUI';
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
  @StorageLink(AppStorageKeyConstants.KEY_IS_PLAY) isPlay: boolean = false;
  @State particleOpacity: number = 0;
  @State prevImageLabel: PixelMap | Resource = this.imageLabel;
  @State prevImageOpacity: number = 0;
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
      // 上一首模糊背景（淡出过渡）
      Image(this.prevImageLabel)
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
        .opacity(this.prevImageOpacity)

      // 当前模糊背景
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

      // 径向渐变光晕：中央柔光，边缘暗化
      Column()
        .width('100%')
        .height('100%')
        .radialGradient({
          center: ['50%', '50%'],
          radius: '80%',
          colors: [
            ['rgba(255,255,255,0.08)', 0.0],
            ['rgba(0,0,0,0.3)', 1.0],
          ]
        })

      // 动态流光效果
      Column()
        .width('100%')
        .height('100%')
        .linearGradient({
          direction: GradientDirection.Right,
          colors: [
            ['rgba(255,255,255,0)', 0.0],
            ['rgba(255,255,255,0.03)', 0.3],
            ['rgba(255,255,255,0.06)', 0.5],
            ['rgba(255,255,255,0.03)', 0.7],
            ['rgba(255,255,255,0)', 1.0],
          ]
        })
        .opacity(this.isPlay ? 0.6 : 0)
        .animation({ duration: 1500, curve: Curve.EaseInOut })

      // 顶部柔光：上方向下渐变
      Column()
        .width('100%')
        .height('40%')
        .linearGradient({
          direction: GradientDirection.Bottom,
          colors: [
            ['rgba(255,255,255,0.06)', 0.0],
            ['rgba(255,255,255,0)', 1.0],
          ]
        })
        .position({ top: 0 })

      // 底部柔光：下方向上渐变
      Column()
        .width('100%')
        .height('30%')
        .linearGradient({
          direction: GradientDirection.Top,
          colors: [
            ['rgba(0,0,0,0.15)', 0.0],
            ['rgba(0,0,0,0)', 1.0],
          ]
        })
        .position({ bottom: 0 })
        .opacity(0.6)
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
                .itemWidth(8)
                .selectedItemWidth(20)
            )
            .clip(false)
            .loop(false)
            .curve(curves.springMotion(0.2, 0.8))
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
    .animation({ duration: 800, curve: Curve.EaseInOut })
  }

  /**
   * Get largest proportion color of an image.
   */
  getImageColor() {
    if (!this.context) {
      return;
    }
    if (!this.songList || this.selectIndex < 0 || this.selectIndex >= this.songList.length) {
      Logger.error('getImageColor: selectIndex out of bounds');
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
              // 先保存当前封面，用于交叉淡出
              this.prevImageLabel = this.imageLabel;
              this.getUIContext()?.animateTo({ duration: 600, curve: Curve.EaseOut }, () => {
                this.prevImageOpacity = 0.5;
              });
              this.imageLabel = value;
              // 新封面显示后，旧封面淡出
              setTimeout(() => {
                this.getUIContext()?.animateTo({ duration: 800, curve: Curve.EaseOut }, () => {
                  this.prevImageOpacity = 0;
                });
              }, 100);
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
