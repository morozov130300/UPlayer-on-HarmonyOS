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
import { curves } from '@kit.ArkUI';
import { AppStorageKeyConstants } from '../common/constants/AppStorageKeyConstants';
import { PlayerConstants } from '../common/constants/PlayerConstants';
import { StyleConstants } from '../common/constants/StyleConstants';
import { AVSessionController } from '../common/utils/mediautils/AVSessionController';
import { WindowInfo } from '../common/utils/WindowUtil';
import { SongItem } from '../viewmodel/SongData';
import { ControlAreaComponent } from './ControlAreaComponent';

/**
 * 音乐信息组件
 * 包含：专辑封面（旋转光晕环动画）+ 歌名/歌手 + 收藏按钮 + 控制栏
 */
@Component
export struct MusicInfoComponent {
  @State currentTabIndex: number = 0;
  @Prop mainWindowInfo: WindowInfo;
  @Prop isReverse: boolean = false;
  @StorageLink(AppStorageKeyConstants.KEY_SONG_LIST) songList: SongItem[] = [];
  @StorageProp(AppStorageKeyConstants.KEY_SELECT_INDEX) selectIndex: number = 0;
  @State isShowControl: boolean = false;
  /** 是否已收藏 */
  @StorageLink(AppStorageKeyConstants.KEY_IS_FAVORITE) isFavorite: boolean = false;
  /** 收藏按钮弹性缩放值 */
  @State favoriteScale: number = 1.0;
  @StorageLink(AppStorageKeyConstants.KEY_IS_PLAY) isPlay: boolean = false;
  /** 封面外圈光晕旋转角度 */
  @State glowRotation: number = 0;
  /** 光晕旋转定时器 ID */
  @State glowTimer: number = -1;

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

  aboutToAppear() {
    if (this.isPlay) {
      this.startGlowAnimation()
    }
  }

  aboutToDisappear() {
    this.stopGlowAnimation()
  }

  /** 启动外圈光晕旋转动画（每 3 秒转一圈，线性匀速） */
  startGlowAnimation() {
    this.stopGlowAnimation()
    this.glowTimer = setInterval(() => {
      this.getUIContext()?.animateTo({ duration: 3000, curve: Curve.Linear }, () => {
        this.glowRotation = (this.glowRotation + 360) % 360
      })
    }, 3000)
  }

  /** 停止光晕旋转 */
  stopGlowAnimation() {
    if (this.glowTimer !== -1) {
      clearInterval(this.glowTimer)
      this.glowTimer = -1
    }
  }

  /** ✅ 专辑封面区域：旋转光晕环 + 外圈辉光 + 封面图 */
  @Builder
  CoverInfo() {
    Row() {
      Stack() {
        /** 最外层：旋转的蓝色径向渐变光晕环（播放时可见） */
        Column()
          .width('103%')
          .aspectRatio(1)
          .borderRadius(12)
          .radialGradient({
            center: ['50%', '50%'], radius: '100%',
            colors: [
              ['rgba(0,125,255,0)', 0.6],
              ['rgba(0,125,255,0.15)', 0.85],
              ['rgba(0,125,255,0.3)', 1.0],
            ]
          })
          .rotate({ angle: this.glowRotation })
          .opacity(this.isPlay ? 0.8 : 0)
          .animation({ duration: 500, curve: Curve.EaseInOut })
        /** 中间层：外圈辉光阴影（播放时扩散增强） */
        Column()
          .width('101%')
          .aspectRatio(1)
          .borderRadius(9)
          .shadow({
            radius: this.isPlay ? 30 : 15,
            color: this.isPlay ? '#44007DFF' : $r('app.color.shadow_color'),
            offsetX: 0, offsetY: 0
          })
          .animation({ duration: 800, curve: Curve.EaseInOut })
        /** 内层：专辑封面（带圆角和阴影） */
        Image(this.songList && this.selectIndex >= 0 && this.selectIndex < this.songList.length ?
          this.songList[this.selectIndex].label : $r('app.media.ic_public_music'))
          .width('100%')
          .aspectRatio(1)
          .borderRadius(8)
          .constraintSize({ maxWidth: '100%', maxHeight: '50%' })
          .shadow({ radius: $r('app.float.shadow_radius'), color: $r('app.color.shadow_color'), offsetX: 0, offsetY: 8 })
          .animation({ duration: 500, curve: Curve.EaseInOut })
      }
      .width('100%')
      .constraintSize({ maxWidth: '100%', maxHeight: '50%' })
    }
    .justifyContent(FlexAlign.Center)
    .width('100%')
  }

  /** ✅ 歌曲信息区域：歌名 + 歌手(含音质角标) + 收藏按钮 */
  @Builder
  MusicInfo() {
    Row() {
      Column() {
        /** 歌名 */
        Row() {
          Text(this.songList && this.selectIndex < this.songList.length ?
            this.songList[this.selectIndex].title : $r('app.string.page_show'))
            .fontSize($r('app.float.title_font_play'))
            .fontColor(Color.White).opacity(0.86)
            .fontWeight(FontWeight.Bold)
            .fontFamily(PlayerConstants.FONT_FAMILY_BOLD)
        }
        /** 歌手 + 音质角标（第一首歌有"高清音频"和"空间音频"标签） */
        Row() {
          Text(this.songList && this.selectIndex < this.songList.length ?
            this.songList[this.selectIndex].singer : $r('app.string.page_show'))
            .textAlign(TextAlign.Start)
            .fontSize(16)
            .fontColor($r('app.color.play_text_color'))
            .fontFamily(PlayerConstants.FONT_FAMILY_BLACK)
            .fontWeight(FontWeight.Regular)
          if (this.selectIndex === 0) {
            Row() {
              Text($r('app.string.Ultra_high_definition_audio'))
                .fontSize(10).fontColor('rgba(255,229,196,1)')
            }.padding(3)
            .border({ width: 1, color: 'rgba(255,229,196,1)' }).borderRadius(4)
            .margin({ right: 8, left: 12 })
            Row() {
              Text($r('app.string.Spatial_audio'))
                .fontSize(10).fontColor('rgba(255,229,196,1)')
            }.padding(3)
            .border({ width: 1, color: 'rgba(255,229,196,1)' }).borderRadius(4)
            .margin({ right: 4 })
          }
        }
        .padding({ top: 2, bottom: 2 })
      }
      .alignItems(HorizontalAlign.Start)
      .padding({ bottom: 10 })

      /** ✅ 收藏按钮（心形图标，带弹跳动画 + AVSession 同步） */
      SymbolGlyph(this.isFavorite ? $r('sys.symbol.heart_fill') : $r('sys.symbol.heart'))
        .fontSize(26)
        .renderingStrategy(SymbolRenderingStrategy.SINGLE)
        .fontColor([this.isFavorite ? Color.Red : Color.White])
        .opacity(0.86)
        .scale({ x: this.favoriteScale, y: this.favoriteScale })
        .onClick(() => {
          this.isFavorite = !this.isFavorite;
          this.getUIContext()?.animateTo({ curve: curves.springMotion() }, () => {
            this.favoriteScale = 1.3
          })
          setTimeout(() => {
            this.getUIContext()?.animateTo({ curve: curves.springMotion() }, () => {
              this.favoriteScale = 1.0
            })
          }, 150)
          AVSessionController.getInstance().updateFavoriteState(this.selectIndex.toString(), this.isFavorite)
        })
    }
    .width('100%')
    .justifyContent(FlexAlign.SpaceBetween)
    .alignItems(VerticalAlign.Top)
    .margin({ top: $r('app.float.music_info_margin_top') })
  }
}
