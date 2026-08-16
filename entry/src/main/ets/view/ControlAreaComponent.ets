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
import {
  curves, LengthMetrics, PromptAction, SymbolGlyphModifier
} from '@kit.ArkUI';
import { ContentConstants } from '../common/constants/ContentConstants';
import { MusicPlayMode, PlayerConstants, PlayModeSwitchList, VOLUME_ID } from '../common/constants/PlayerConstants';
import { StyleConstants } from '../common/constants/StyleConstants';
import Logger from '../common/utils/Logger';
import { ResourceConversion } from '../common/utils/ResourceConversion';
import { SongItem } from '../viewmodel/SongData';
import { SongDataSource } from '../viewmodel/SongDataSource';
import { MediaControlCenter } from '../common/utils/mediautils/MediaControlCenter';
import { common } from '@kit.AbilityKit';
import { PreferencesUtil } from '../common/utils/PreferencesUtil';
import { MediaTools } from '../common/utils/mediautils/MediaTools';
import { WindowInfo } from '../common/utils/WindowUtil';
import { AppStorageKeyConstants } from '../common/constants/AppStorageKeyConstants';

const TAG = 'ControlAreaComponent';

@Component
export struct ControlAreaComponent {
  @Prop mainWindowInfo: WindowInfo;
  @StorageLink(AppStorageKeyConstants.KEY_IS_PLAY) isPlay: boolean = false;
  @StorageLink(AppStorageKeyConstants.KEY_CURRENT_TIME) currentTime: string = '00:00';
  @StorageLink(AppStorageKeyConstants.KEY_TOTAL_TIME) totalTime: string = '00:00';
  @StorageLink(AppStorageKeyConstants.KEY_PROGRESS) value: number = 0;
  @StorageLink(AppStorageKeyConstants.KEY_PROGRESS_MAX) max: number = 0;
  @State playModeIndex: number = 0;
  @StorageLink(AppStorageKeyConstants.KEY_IMAGE_COLOR) imageColor: string = '';
  @StorageLink(AppStorageKeyConstants.KEY_PAGE_SHOW_TIME) pageShowTime: number = 0;
  @StorageLink(AppStorageKeyConstants.KEY_SONG_LIST) songList: SongItem[] = [];
  @State isShowPlayList: boolean = false;
  @StorageLink(AppStorageKeyConstants.KEY_PLAY_MODE) playMode: MusicPlayMode = PlayModeSwitchList[this.playModeIndex];
  @StorageLink(AppStorageKeyConstants.KEY_SELECT_INDEX) selectIndex: number = 0;
  @StorageLink(AppStorageKeyConstants.KEY_IS_SILENT_MODE) @Watch('isSilentModeChange') isSilentMode: boolean = false;
  @StorageLink(AppStorageKeyConstants.KEY_CURRENT_SPEED) speed: number = 1;
  // [Start currentVolumeChange]
  @StorageLink(AppStorageKeyConstants.KEY_CURRENT_VOLUME) @Watch('currentVolumeChange') volume: number = 0;
  // [StartExclude currentVolumeChange]
  @State isShowSpeedBuild: boolean = false;
  @State isShowVolumeBuild: boolean = false;
  @State songTimeFontSize: number = 10;
  @State songTimeFontColor: Resource = $r('app.color.play_text_color');
  @State trackThickness: number = 6;
  @Prop isReverse: boolean = false;
  private scroller: Scroller = new Scroller();
  private resourceConversion: ResourceConversion = new ResourceConversion();
  private context: common.UIAbilityContext | undefined = AppStorage.get(AppStorageKeyConstants.KEY_UI_ABILITY_CONTEXT);
  uiContext: UIContext = this.getUIContext();
  promptAction: PromptAction = this.uiContext.getPromptAction();
  @State speedSelectIndex: number = 0;
  @State speedArr: number[] = [0.5, 1, 2, 3]

  isSilentModeChange() {
    MediaControlCenter.getInstance().setSilentMode(this.isSilentMode);
  }

  // [EndExclude currentVolumeChange]
  currentVolumeChange() {
    MediaControlCenter.getInstance().setVolume(this.volume)
  }

  // [End currentVolumeChange]

  switchPlayMode() {
    if (this.playModeIndex === PlayModeSwitchList.length - 1) {
      this.playModeIndex = 0;
    } else {
      this.playModeIndex++;
    }
    this.playMode = PlayModeSwitchList[this.playModeIndex];
    Logger.info(TAG, 'playModeIndex is' + this.playModeIndex);
    this.promptAction.openToast({
      message: `${this.playMode === MusicPlayMode.ORDER ?
        this.resourceConversion.getStringValueFromResource($r('app.string.sequential_playback')) :
        this.playMode === MusicPlayMode.RANDOM ?
          this.resourceConversion.getStringValueFromResource($r('app.string.random_playback')) :
          this.resourceConversion.getStringValueFromResource($r('app.string.single_playback'))}`
    });
    MediaControlCenter.getInstance().setPlayModel(this.playMode);
  }

  @Builder
  SpeedIcon() {
    SymbolGlyph($r('sys.symbol.speed_multiple'))
      .fontSize(26)
      .renderingStrategy(SymbolRenderingStrategy.SINGLE)
      .fontColor([Color.White])
      .opacity(0.86)
      .onClick(() => {
        this.isShowSpeedBuild = true;
      })
  }

  @Builder
  VolumeIcon() {
    SymbolGlyph($r('sys.symbol.speaker_wave_2'))
      .fontSize(26)
      .renderingStrategy(SymbolRenderingStrategy.SINGLE)
      .fontColor([Color.White])
      .opacity(0.86)
      .onClick(() => {
        this.isShowVolumeBuild = true;
      })
  }

  build() {
    Column() {
      Column() {
        Column() {
          Slider({
            min: 0,
            max: this.max,
            step: 1,
            style: SliderStyle.NONE,
            value: this.value
          })
            .trackThickness(this.trackThickness)
            .selectedColor($r('app.color.slider_select'))
            .trackColor($r('app.color.slider_track'))
            .onChange((value: number, mode: SliderChangeMode) => {
              if (mode === SliderChangeMode.End) {
                MediaControlCenter.getInstance().seek(value);
                this.getUIContext()?.animateTo({ curve: curves.springMotion() }, () => {
                  this.trackThickness = 6;
                  this.songTimeFontSize = 10;
                  this.songTimeFontColor = $r('app.color.play_text_color');
                })
              }
              if (mode === SliderChangeMode.Moving) {
                this.currentTime = MediaTools.msToCountdownTime(value)
                this.getUIContext()?.animateTo({ curve: curves.springMotion() }, () => {
                  this.trackThickness = 10;
                  this.songTimeFontSize = 12;
                  this.songTimeFontColor = $r('app.color.slider_select');
                })
              }
              this.pageShowTime = 0;
            })
            .height($r('app.float.slider_height'))
            .width(StyleConstants.FULL_WIDTH)
            .hitTestBehavior(HitTestMode.Block)
          Row() {
            Text(this.currentTime)
              .fontColor(this.songTimeFontColor)
              .fontSize(this.songTimeFontSize)
              .fontFamily(PlayerConstants.FONT_FAMILY_BLACK)
              .lineHeight('14vp')
            Text(this.totalTime)
              .fontColor(this.songTimeFontColor)
              .fontSize(this.songTimeFontSize)
              .fontFamily(PlayerConstants.FONT_FAMILY_BLACK)
              .lineHeight('14vp')
          }
          .width(StyleConstants.FULL_WIDTH)
          .justifyContent(FlexAlign.SpaceBetween)
        }
        .margin({
          bottom: 12
        })

        Row() {
          Image($r('app.media.ic_public_forward'))
            .controlImageBuilder()
            .width(32)
            .onClick(() => {
              MediaControlCenter.getInstance().playPrevious();
              this.pageShowTime = 0;
            })
          Image(this.isPlay ? $r('app.media.ic_public_play') : $r('app.media.ic_public_pause'))
            .controlImageBuilder()
            .width(72)
            .onClick(() => {
              if (this.isPlay) {
                MediaControlCenter.getInstance().pause()
              } else {
                MediaControlCenter.getInstance().play()
              }
              this.pageShowTime = 0;
            })
          Image($r('app.media.ic_public_next'))
            .controlImageBuilder()
            .width(32)
            .onClick(() => {
              MediaControlCenter.getInstance().playNext();
              this.pageShowTime = 0;
            })
        }
        .width(StyleConstants.FULL_WIDTH)
        .justifyContent(FlexAlign.SpaceBetween)
        .padding({
          left: $r('app.float.control_padding'),
          right: $r('app.float.control_padding')
        })
      }

      Row() {
        SymbolGlyph(this.playMode === MusicPlayMode.ORDER ? $r('sys.symbol.order_play') :
          this.playMode === MusicPlayMode.RANDOM ? $r('sys.symbol.shuffle') : $r('sys.symbol.repeat_1'))
          .fontSize(26)
          .renderingStrategy(SymbolRenderingStrategy.SINGLE)
          .fontColor([Color.White])
          .opacity(0.86)
          .onClick(() => {
            this.switchPlayMode()
          })

        SymbolGlyph($r('sys.symbol.music_note_list'))
          .fontSize(26)
          .renderingStrategy(SymbolRenderingStrategy.SINGLE)
          .fontColor([Color.White])
          .opacity(0.86)
          .onClick(() => {
            this.isShowPlayList = true;
          })
          .bindSheet($$this.isShowPlayList, this.musicListBuilder(), {
            detents: [SheetSize.MEDIUM],
            dragBar: false,
            title: this.playListTitle(),
            showClose: true,
            preferType: SheetType.CENTER,
            onWillAppear: () => {
              Logger.info(TAG, 'musicListBuilder');
              this.scroller.scrollToIndex(this.selectIndex, false, ScrollAlign.CENTER);
            }
          })

        SymbolGlyph(this.isSilentMode ? $r('sys.symbol.bell_slash') : $r('sys.symbol.bell'))
          .fontSize(26)
          .renderingStrategy(SymbolRenderingStrategy.SINGLE)
          .fontColor([Color.White])
          .opacity(0.86)
          .onClick(() => {
            this.isSilentMode = !this.isSilentMode;
            if (this.isSilentMode) {
              this.volume = 0;
            } else {
              let preVolume: number = PreferencesUtil.getInstance().getValue(VOLUME_ID) as number;
              this.volume = preVolume ? preVolume : 0.1;
            }
          })

        SymbolGlyph($r('sys.symbol.speed_multiple'))
          .fontSize(26)
          .renderingStrategy(SymbolRenderingStrategy.SINGLE)
          .fontColor([Color.White])
          .opacity(0.86)
          .onClick(() => {
            this.isShowSpeedBuild = true;
          })
          .bindMenu(this.speedBuilder())


        SymbolGlyph($r('sys.symbol.speaker_wave_2'))
          .fontSize(26)
          .renderingStrategy(SymbolRenderingStrategy.SINGLE)
          .fontColor([Color.White])
          .opacity(0.86)
          .onClick(() => {
            this.isShowVolumeBuild = true;
          })
          .bindSheet($$this.isShowVolumeBuild, this.volumeBuilder(), {
            dragBar: false,
            height: SheetSize.FIT_CONTENT,
            preferType: this.mainWindowInfo.widthBp === WidthBreakpoint.WIDTH_SM ? SheetType.CENTER : SheetType.POPUP,
            title: this.volumeTitle(),
            showClose: true,
          })

      }
      .width(StyleConstants.FULL_WIDTH)
      .justifyContent(FlexAlign.SpaceBetween)
      .padding({
        top: $r('app.float.slider_margin_top'),
        bottom: this.isReverse ? $r('app.float.slider_margin_top') : 0
      })
    }
    .reverse(this.isReverse)
  }

  @Builder
  musicListBuilder() {
    Column() {
      List({ scroller: this.scroller }) {
        LazyForEach(new SongDataSource(this.songList), (item: SongItem, index: number) => {
          ListItem() {
            MusicListContainer({ item: item, index: index })
              .reuseId(this.context?.resourceManager.getStringSync(item.title?.id));
          }
        }, (item: SongItem, index: number) => item.toString() + index.toString())
        ListItem().height(48)
      }
      .height(StyleConstants.FULL_HEIGHT)
      .width(StyleConstants.FULL_WIDTH)
      .layoutWeight(1)
      .divider({
        color: $r('app.color.list_divider'),
        strokeWidth: $r('app.float.stroke_width'),
        startMargin: $r('app.float.list_item_padding'),
        endMargin: $r('app.float.list_item_padding')
      })
    }
  }

  @Builder
  volumeBuilder() {
    Column() {
      Row() {
        // [Start VolumeSlider]
        Slider({
          value: this.volume * 100,
          min: 0,
          max: 100,
          step: 20,
          style: SliderStyle.OutSet
        })
          .showSteps(true)
          .showTips(false)
          .layoutWeight(1)
          .onChange((value: number, mode: SliderChangeMode) => {
            this.volume = value / 100;
            // [StartExclude VolumeSlider]
            if (this.volume === 0) {
              this.isSilentMode = true
            } else {
              this.isSilentMode = false;
            }
            // [EndExclude VolumeSlider]
          })
        // [End VolumeSlider]
        Text(`${this.volume * 100}`)
      }
    }
    .padding({
      bottom: 30,
      left: 15,
      right: 15
    })
  }

  @Builder
  speedTitle() {
    Text($r('app.string.speed_setting'))
      .fontColor((this.mainWindowInfo.widthBp === WidthBreakpoint.WIDTH_SM ||
        this.mainWindowInfo.widthBp === WidthBreakpoint.WIDTH_MD) ? Color.Black : $r('sys.color.font_secondary'))
      .fontWeight(FontWeight.Bold)
      .fontSize((this.mainWindowInfo.widthBp === WidthBreakpoint.WIDTH_SM ||
        this.mainWindowInfo.widthBp === WidthBreakpoint.WIDTH_MD) ? 20 : 14)
  }

  @Builder
  speedBuilder() {
    Menu() {
      MenuItemGroup({ header: this.speedTitle() }) {
        ForEach(this.speedArr, (speed: number, index: number) => {
          MenuItem({
            content: `${speed}x`,
            symbolEndIcon: this.speed === speed ? new SymbolGlyphModifier($r('sys.symbol.checkmark')).fontSize('24vp') :
              undefined
          })
            .width('100%')
            .onClick(() => {
              this.speed = speed;
              MediaControlCenter.getInstance().setSpeed(this.speed);
            })
        })
      }
    }
    .menuItemDivider({
      strokeWidth: LengthMetrics.vp(0.5),
      mode: DividerMode.EMBEDDED_IN_MENU,
      color: 'rgba(0,0,0,0.2)'
    })
    .width(224)
  }

  @Builder
  playListTitle() {
    Text($r('app.string.play_list', this.songList.length))
      .maxLines(ContentConstants.PLAY_ALL_MAX_LINES)
      .fontColor(Color.Black)
      .fontWeight(FontWeight.Bold)
      .fontSize(20)
      .width('100%')
  }

  @Builder
  volumeTitle() {
    Text($r('app.string.volume_setting'))
      .maxLines(ContentConstants.PLAY_ALL_MAX_LINES)
      .fontColor(Color.Black)
      .fontWeight(FontWeight.Bold)
      .fontSize(20)
      .width('100%')
  }
}

@Extend(Image)
function controlImageBuilder() {
  .aspectRatio(1)
  .opacity(0.86)
  .objectFit(ImageFit.Contain)
}

@Reusable
@Component
struct MusicListContainer {
  @StorageLink(AppStorageKeyConstants.KEY_IS_PLAY) isPlay: boolean = false;
  @StorageLink(AppStorageKeyConstants.KEY_SELECT_INDEX) selectIndex: number = 0;
  item: SongItem | undefined = undefined;
  index: number | undefined = undefined;

  build() {
    Column() {
      Row() {
        Column() {
          Text(this.item!.title)
            .fontColor(this.selectIndex === this.index && this.isPlay ? Color.Red : Color.Black)
            .fontSize(16)
            .margin({ bottom: $r('app.float.list_item_title_margin') })
          Row() {
            Image(this.item!.mark)
              .width($r('app.float.list_item_image_size'))
              .height($r('app.float.list_item_image_size'))
              .margin({ right: $r('app.float.list_item_image_margin') })
            Text(this.item!.singer)
              .opacity($r('app.float.singer_opacity'))
              .fontColor(this.selectIndex === this.index && this.isPlay ? Color.Red : Color.Black)
              .fontSize(12)
          }
        }
        .alignItems(HorizontalAlign.Start)

        if (this.selectIndex === this.index && this.isPlay) {
          Column() {
            SymbolGlyph($r('sys.symbol.waveform_1'))
              .fontSize(26)
              .renderingStrategy(SymbolRenderingStrategy.SINGLE)
              .fontColor([Color.Red])
              .opacity(0.86)
          }
        }
      }
      .justifyContent(FlexAlign.SpaceBetween)
      .onClick(() => {
        MediaControlCenter.getInstance().play(this.index!)
      })
      .height($r('app.float.list_item_height'))
      .width(StyleConstants.FULL_WIDTH)
    }
    .padding({
      left: $r('app.float.list_item_padding'),
      right: $r('app.float.list_item_padding')
    })
  }
}
