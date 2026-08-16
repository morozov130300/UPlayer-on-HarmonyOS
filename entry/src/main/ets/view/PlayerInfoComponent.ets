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

/**
 * 播放器全屏页面的主容器组件
 * 负责：模糊背景（封面提取主色 + 高斯模糊 + 渐变光效）、多断点布局
 */
@Component
export struct PlayerInfoComponent {
  /** 窗口信息（断点、安全区），从父级传入并自动监听变化 */
  @ObjectLink @Watch('mainWindowInfoChange') mainWindowInfo: WindowInfo;
  /** 歌单列表 */
  @StorageLink(AppStorageKeyConstants.KEY_SONG_LIST) songList: SongItem[] = [];
  /** 当前选中歌曲索引（变化时触发 getImageColor 更新封面主色） */
  @StorageProp(AppStorageKeyConstants.KEY_SELECT_INDEX) @Watch('getImageColor') selectIndex: number = 0;
  /** 封面提取的主颜色，用于背景着色 */
  @StorageLink(AppStorageKeyConstants.KEY_IMAGE_COLOR) imageColor: string = 'rgba(0, 0, 2, 1.00)';
  @StorageLink(AppStorageKeyConstants.KEY_TOP_HEIGHT) topHeight: number = 0;
  @StorageLink(AppStorageKeyConstants.KEY_BOTTOM_HEIGHT) @Watch('bottomHeightChange') bottomHeight: number = 0;
  /** 当前封面的模糊图（PixelMap 或 Resource） */
  @State imageLabel: PixelMap | Resource = this.songList[this.selectIndex].label;
  /** 小屏歌词页是否显示控制栏 */
  @State isShowControl: boolean = true;
  /** 大屏歌词页是否显示控制栏 */
  @State isShowControlLg: boolean = false;
  @State isTablet: boolean = true;
  @State isTabletFalse: boolean = false;
  /** 页面无操作计时（秒），超过5秒自动隐藏控制栏 */
  @StorageLink(AppStorageKeyConstants.KEY_PAGE_SHOW_TIME) pageShowTime: number = 0;
  /** 页面无操作计时器 ID */
  @State intervalID: number = 0;
  /** 是否显示播放状态（从父组件传入） */
  @Link isShowPlay: boolean;
  @State message: Resource = $r('app.string.no_operate');
  /** 实际播放状态 */
  @StorageLink(AppStorageKeyConstants.KEY_IS_PLAY) isPlay: boolean = false;
  @State particleOpacity: number = 0;
  /** 上一首封面的模糊图（用于交叉淡出过渡） */
  @State prevImageLabel: PixelMap | Resource = this.imageLabel;
  /** 上一首封面的当前透明度（0 → 0.5 → 0 的淡出过程） */
  @State prevImageOpacity: number = 0;
  @State currentSwiperIndex: number = 0;
  private context: common.UIAbilityContext | undefined = AppStorage.get(AppStorageKeyConstants.KEY_UI_ABILITY_CONTEXT);

  bottomHeightChange() {
  }

  /** 窗口信息变化时：若为手机竖屏中等高度，弹出提示对话框 */
  mainWindowInfoChange() {
    Logger.info(
      `windowUtil is change,current width breakpoint is ${this.mainWindowInfo?.widthBp},height breakpoint is ${this.mainWindowInfo?.heightBp}`)
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
      /** 上一首封面的模糊背景（淡出过渡，实现封面切换的交叉溶解） */
      Image(this.prevImageLabel)
        .size(this.mainWindowInfo.heightBp !== HeightBreakpoint.HEIGHT_LG ?
          { width: PlayerConstants.BACK_IMAGE, height: '100%' } :
          { width: '100%', height: PlayerConstants.BACK_IMAGE })
        .objectFit(ImageFit.Cover)
        .opacity(this.prevImageOpacity)

      /** 当前封面的模糊背景 */
      Image(this.imageLabel)
        .size(this.mainWindowInfo.heightBp !== HeightBreakpoint.HEIGHT_LG ?
          { width: PlayerConstants.BACK_IMAGE, height: '100%' } :
          { width: '100%', height: PlayerConstants.BACK_IMAGE })
        .objectFit(ImageFit.Cover)
        .opacity(0.5)

      /** 径向渐变：中央柔光，边缘暗化 */
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

      /** 动态流光效果（播放时可见，水平方向扫光） */
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

      /** 顶部向下柔光渐变 */
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

      /** 底部向上柔光渐变（暗角） */
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

      // 统一容器：按断点不同处理顶部栏
      Column() {
        // MD+ 断点：全局顶部栏 + 左右双栏
        if (this.mainWindowInfo.widthBp !== WidthBreakpoint.WIDTH_SM) {
          Row() {
            Row() {
              SymbolGlyph($r('sys.symbol.chevron_left'))
                .fontSize(32)
                .fontColor([Color.White])
                .opacity(0.8)
            }
            .width(56)
            .height(56)
            .justifyContent(FlexAlign.Center)
            .borderRadius(28)
            .onClick(() => {
              this.getUIContext()?.getRouter().back()
            })

            Blank()
          }
          .width('100%')
          .height(56)

          Row() {
            Column() {
              MusicInfoComponent({ mainWindowInfo: this.mainWindowInfo })
            }
            .padding(this.mainWindowInfo.widthBp === WidthBreakpoint.WIDTH_MD ? 24 : 80)
            .width('50%')
            Column() {
              LyricsComponent({ isShowControl: this.isShowControlLg, mainWindowInfo: this.mainWindowInfo })
            }
            .width('50%')
            .padding(this.mainWindowInfo.widthBp === WidthBreakpoint.WIDTH_MD ? 24 : 80)
          }
          .layoutWeight(1)
          .width('100%')
        } else {
          // SM 断点：Swiper + 浮动返回按钮 + 指示器（同容器，可对齐）
          Swiper() {
            // 第一页：专辑封面 + 浮动返回按钮
            Stack() {
              Column() {
                MusicInfoComponent({ mainWindowInfo: this.mainWindowInfo, isReverse: true })
              }
              .padding({
                top: $r('app.float.music_component_top'),
                bottom: $r('app.float.music_component_bottom'),
                left: $r('app.float.common_padding'),
                right: $r('app.float.common_padding')
              })
              .width('100%')
              .height('100%')

              // 浮动返回按钮，绝对定位无左侧额外留白
              Row() {
                SymbolGlyph($r('sys.symbol.chevron_left'))
                  .fontSize(32)
                  .fontColor([Color.White])
                  .opacity(0.8)
              }
              .width(56)
              .height(56)
              .justifyContent(FlexAlign.Center)
              .borderRadius(28)
              .onClick(() => {
                this.getUIContext()?.getRouter().back()
              })
              .position({ x: 8, y: 0 })
            }

            // 第二页：歌词组件 + 浮动返回按钮
            Stack() {
              Column() {
                LyricsComponent({ isShowControl: this.isShowControl, mainWindowInfo: this.mainWindowInfo })
              }
              .padding({
                top: $r('app.float.music_component_top'),
                left: $r('app.float.common_padding'),
                right: $r('app.float.common_padding'),
                bottom: $r('app.float.music_component_bottom'),
              })
              .width('100%')
              .height('100%')

              Row() {
                SymbolGlyph($r('sys.symbol.chevron_left'))
                  .fontSize(32)
                  .fontColor([Color.White])
                  .opacity(0.8)
              }
              .width(40)
              .height(56)
              .justifyContent(FlexAlign.Center)
              .borderRadius(28)
              .onClick(() => {
                this.getUIContext()?.getRouter().back()
              })
              .position({ x: 8, y: 0 })
            }
          }
          .layoutWeight(1)
          .loop(false)
          .curve(curves.springMotion(0.5, 0.8))
          //指示器，与浮动返回按钮同排（y=0）
          .indicator(
            new DotIndicator()
              .top(8)
              .color(this.getDotColor(false))
              .selectedColor(this.getDotColor(true))
              .itemWidth(6)
              .itemHeight(6)
              .selectedItemWidth(14)
              .selectedItemHeight(6)
          )
          // 切页回调：切到歌词页显示控制栏，5 秒无操作自动隐藏（带弹性动画）
          .onChange((index: number) => {
            this.currentSwiperIndex = index;
            if (index === 1) {
              this.getUIContext()?.animateTo({ curve: curves.springMotion(0.5, 0.8) }, () => {
                this.isShowControl = true;
              })
              this.intervalID = setInterval(() => {
                this.pageShowTime += 1;
                if (this.pageShowTime > 5) {
                  this.getUIContext()?.animateTo({ curve: curves.springMotion(0.5, 0.8) }, () => {
                    this.isShowControl = false;
                  })
                  clearInterval(this.intervalID);
                }
              }, 1000);
            } else {
              this.pageShowTime = 0;
              clearInterval(this.intervalID);
            }
          })
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

  /** 判断封面主色是否为亮色（用于指示器自适应颜色） */
  private isBackgroundLight(colorStr: string): boolean {
    const match = colorStr.match(/rgba\((\d+),\s*(\d+),\s*(\d+)/)
    if (match) {
      const r = parseInt(match[1]), g = parseInt(match[2]), b = parseInt(match[3])
      return 0.299 * r + 0.587 * g + 0.114 * b > 128
    }
    return false
  }

  /** 获取指示器颜色：isSelected=true 返回选中色，否则返回未选中色 */
  private getDotColor(isSelected: boolean): ResourceColor {
    const isLight = this.isBackgroundLight(this.imageColor)
    if (isSelected) {
      return isLight ? '#333333' : '#FFFFFF'
    }
    return isLight ? '#AAAAAA' : '#666666'
  }

  /**
   * 从当前封面图中提取主色 + 生成模糊图
   * 流程：getMediaContent → createPixelMap → createColorPicker(取主色) → blur(高斯模糊) → 交叉淡出
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
          /** 从取色器中提取占比最大的颜色 → 转为 RGBA 字符串 */
          effectKit.createColorPicker(pixelMap, (error, colorPicker) => {
            if (error) {
              Logger.error('Failed to create color picker.');
            } else {
              let color = colorPicker.getLargestProportionColor();
              let colorArr = ColorConversion.dealColor(color.red, color.green, color.blue);
              this.imageColor = `rgba(${colorArr[0]}, ${colorArr[1]}, ${colorArr[2]}, 1)`;
            }
          })
          /** 对封面做高斯模糊 → 保存模糊图用于背景 */
          let headFilter = effectKit.createEffect(pixelMap);
          if (headFilter !== null) {
            headFilter.blur(PlayerConstants.IMAGE_BLUR);
            headFilter.getEffectPixelMap().then((value) => {
              /** 先用旧封面淡出到 0.5，再切换到新封面，然后旧封面完全淡出 */
              this.prevImageLabel = this.imageLabel;
              this.getUIContext()?.animateTo({ duration: 600, curve: Curve.EaseOut }, () => {
                this.prevImageOpacity = 0.5;
              });
              this.imageLabel = value;
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
