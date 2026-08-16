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

/**
 * ✅ 播放器控制区域组件
 * 包含：进度条、时间显示、播放/暂停、上下曲、播放模式、歌单、静音、倍速、音量
 */
@Component
export struct ControlAreaComponent {
  @Prop mainWindowInfo: WindowInfo;
  /** 是否正在播放（与 MediaControlCenter 联动） */
  @StorageLink(AppStorageKeyConstants.KEY_IS_PLAY) isPlay: boolean = false;
  /** 当前播放时间（文本格式 mm:ss） */
  @StorageLink(AppStorageKeyConstants.KEY_CURRENT_TIME) currentTime: string = '00:00';
  /** 总时长（文本格式 mm:ss） */
  @StorageLink(AppStorageKeyConstants.KEY_TOTAL_TIME) totalTime: string = '00:00';
  /** 当前进度（毫秒） */
  @StorageLink(AppStorageKeyConstants.KEY_PROGRESS) value: number = 0;
  /** 进度条最大值（毫秒） */
  @StorageLink(AppStorageKeyConstants.KEY_PROGRESS_MAX) max: number = 0;
  /** 播放模式索引（0=顺序 1=随机 2=单曲循环） */
  @State playModeIndex: number = 0;
  /** 封面主色（给进度条/弹窗等做主题色参考） */
  @StorageLink(AppStorageKeyConstants.KEY_IMAGE_COLOR) imageColor: string = '';
  /** 页面无操作累计时间（秒） */
  @StorageLink(AppStorageKeyConstants.KEY_PAGE_SHOW_TIME) pageShowTime: number = 0;
  @StorageLink(AppStorageKeyConstants.KEY_SONG_LIST) songList: SongItem[] = [];
  /** 是否显示歌单 Sheet */
  @State isShowPlayList: boolean = false;
  /** 当前播放模式枚举值 */
  @StorageLink(AppStorageKeyConstants.KEY_PLAY_MODE) playMode: MusicPlayMode = PlayModeSwitchList[this.playModeIndex];
  @StorageLink(AppStorageKeyConstants.KEY_SELECT_INDEX) selectIndex: number = 0;
  /** 是否静音（变化时自动同步到 MediaControlCenter） */
  @StorageLink(AppStorageKeyConstants.KEY_IS_SILENT_MODE) @Watch('isSilentModeChange') isSilentMode: boolean = false;
  /** 播放速度 */
  @StorageLink(AppStorageKeyConstants.KEY_CURRENT_SPEED) speed: number = 1;
  /** 音量（0~1，变化时自动同步到 MediaControlCenter） */
  @StorageLink(AppStorageKeyConstants.KEY_CURRENT_VOLUME) @Watch('currentVolumeChange') volume: number = 0;
  @State isShowSpeedBuild: boolean = false;
  @State isShowVolumeBuild: boolean = false;
  /** 进度条操作时的动态样式：字号、粗细、发光 */
  @State songTimeFontSize: number = 10;
  @State songTimeFontColor: Resource = $r('app.color.play_text_color');
  @State trackThickness: number = 6;
  @State playBtnScale: number = 1.0;
  @State sliderGlow: number = 0;
  /** 是否反向布局（小屏模式下控制栏在歌词页时反向） */
  @Prop isReverse: boolean = false;
  private scroller: Scroller = new Scroller();
  private resourceConversion: ResourceConversion = new ResourceConversion();
  private context: common.UIAbilityContext | undefined = AppStorage.get(AppStorageKeyConstants.KEY_UI_ABILITY_CONTEXT);
  uiContext: UIContext = this.getUIContext();
  promptAction: PromptAction = this.uiContext.getPromptAction();
  @State speedSelectIndex: number = 0;
  /** 倍速选项列表 */
  @State speedArr: number[] = [0.5, 1, 2, 3]
  @State silentScale: number = 1.0;
  @State playlistScale: number = 1.0;
  @State playModeScale: number = 1.0;
  @State speedScale: number = 1.0;

  /** 静音状态变化时同步到 MediaControlCenter */
  isSilentModeChange() {
    MediaControlCenter.getInstance().setSilentMode(this.isSilentMode);
  }

  /** 音量值变化时同步到 MediaControlCenter */
  currentVolumeChange() {
    MediaControlCenter.getInstance().setVolume(this.volume)
  }

  /** 切换播放模式（顺序 → 随机 → 单曲循环），带动画和 Toast 提示 */
  switchPlayMode() {
    if (this.playModeIndex === PlayModeSwitchList.length - 1) {
      this.playModeIndex = 0;
    } else {
      this.playModeIndex++;
    }
    this.playMode = PlayModeSwitchList[this.playModeIndex];
    Logger.info(TAG, 'playModeIndex is' + this.playModeIndex);
    try {
      this.promptAction.openToast({
        message: `${this.playMode === MusicPlayMode.ORDER ?
          this.resourceConversion.getStringValueFromResource($r('app.string.sequential_playback')) :
          this.playMode === MusicPlayMode.RANDOM ?
            this.resourceConversion.getStringValueFromResource($r('app.string.random_playback')) :
            this.resourceConversion.getStringValueFromResource($r('app.string.single_playback'))}`
      });
    } catch (err) {
      Logger.error(TAG, `openToast failed: ${JSON.stringify(err)}`);
    }
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
        /** ✅ 进度条 + 时间显示 */
        Column() {
          Slider({
            min: 0, max: this.max, step: 1, style: SliderStyle.NONE, value: this.value
          })
            .trackThickness(this.trackThickness)
            .selectedColor($r('app.color.slider_select'))
            .trackColor($r('app.color.slider_track'))
            .enabled(this.max > 0)
            .shadow({ radius: this.sliderGlow, color: '#33007DFF' })
            /** 拖拽结束时：seek + 样式恢复；拖拽中：实时更新时间 + 样式放大 */
            .onChange((value: number, mode: SliderChangeMode) => {
              if (mode === SliderChangeMode.End) {
                MediaControlCenter.getInstance().seek(value);
                this.getUIContext()?.animateTo({ curve: curves.springMotion() }, () => {
                  this.trackThickness = 6;
                  this.songTimeFontSize = 10;
                  this.songTimeFontColor = $r('app.color.play_text_color');
                  this.sliderGlow = 0;
                })
              }
              if (mode === SliderChangeMode.Moving) {
                this.currentTime = MediaTools.msToCountdownTime(value)
                this.getUIContext()?.animateTo({ curve: curves.springMotion() }, () => {
                  this.trackThickness = 10;
                  this.songTimeFontSize = 12;
                  this.songTimeFontColor = $r('app.color.slider_select');
                  this.sliderGlow = 8;
                })
              }
              this.pageShowTime = 0;
            })
            .height($r('app.float.slider_height'))
            .width(StyleConstants.FULL_WIDTH)
            .hitTestBehavior(HitTestMode.Block)
          /** 当前时间（左） / 总时长（右） */
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
        .margin({ bottom: 12 })

        /** ✅ 播放控制：上一曲 → 播放/暂停 → 下一曲 */
        Row() {
          Image($r('app.media.ic_public_forward'))
            .controlImageBuilder()
            .width(32)
            .hoverEffect(HoverEffect.Scale)
            .onClick(() => {
              MediaControlCenter.getInstance().playPrevious();
              this.pageShowTime = 0;
            })
          /** 播放/暂停按钮：播放中显示 ic_public_play（暂停图标），未播放显示 ic_public_pause（播放图标） */
          Image(this.isPlay ? $r('app.media.ic_public_play') : $r('app.media.ic_public_pause'))
            .controlImageBuilder()
            .width(72)
            .scale({ x: this.playBtnScale, y: this.playBtnScale })
            .shadow({ radius: 10, color: '#22007DFF' })
            .hoverEffect(HoverEffect.Scale)
            /** 点击时弹簧缩放动画 → 切换播放/暂停 */
            .onClick(() => {
              this.getUIContext()?.animateTo({ curve: curves.springMotion() }, () => {
                this.playBtnScale = 0.85
              })
              setTimeout(() => {
                this.getUIContext()?.animateTo({ curve: curves.springMotion() }, () => {
                  this.playBtnScale = 1.0
                })
              }, 100)
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
            .hoverEffect(HoverEffect.Scale)
            .onClick(() => {
              MediaControlCenter.getInstance().playNext();
              this.pageShowTime = 0;
            })
        }
        .width(StyleConstants.FULL_WIDTH)
        .justifyContent(FlexAlign.SpaceBetween)
        .padding({ left: $r('app.float.control_padding'), right: $r('app.float.control_padding') })
      }

      /** ✅ 底部功能按钮行：播放模式 → 歌单 → 静音 → 倍速 → 音量 */
      Row() {
        /** 播放模式切换（顺序/随机/单曲循环） */
        SymbolGlyph(this.playMode === MusicPlayMode.ORDER ? $r('sys.symbol.order_play') :
          this.playMode === MusicPlayMode.RANDOM ? $r('sys.symbol.shuffle') : $r('sys.symbol.repeat_1'))
          .fontSize(26)
          .renderingStrategy(SymbolRenderingStrategy.SINGLE)
          .fontColor([Color.White])
          .opacity(0.86)
          .scale({ x: this.playModeScale, y: this.playModeScale })
          .onClick(() => {
            this.getUIContext()?.animateTo({ duration: 200, curve: Curve.EaseInOut }, () => {
              this.playModeScale = 0.75;
            });
            setTimeout(() => {
              this.getUIContext()?.animateTo({ duration: 300, curve: curves.springMotion() }, () => {
                this.playModeScale = 1.0;
              });
            }, 150);
            this.switchPlayMode()
          })

        /** 歌单列表（弹出 Sheet） */
        SymbolGlyph($r('sys.symbol.music_note_list'))
          .fontSize(26)
          .renderingStrategy(SymbolRenderingStrategy.SINGLE)
          .fontColor([Color.White])
          .opacity(0.86)
          .scale({ x: this.playlistScale, y: this.playlistScale })
          .onClick(() => {
            this.getUIContext()?.animateTo({ duration: 150, curve: Curve.EaseInOut }, () => {
              this.playlistScale = 0.8;
            });
            setTimeout(() => {
              this.getUIContext()?.animateTo({ duration: 250, curve: curves.springMotion() }, () => {
                this.playlistScale = 1.0;
              });
            }, 120);
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

        /** 静音开关（铃铛图标） */
        SymbolGlyph(this.isSilentMode ? $r('sys.symbol.bell_slash') : $r('sys.symbol.bell'))
          .fontSize(26)
          .renderingStrategy(SymbolRenderingStrategy.SINGLE)
          .fontColor([Color.White])
          .opacity(0.86)
          .scale({ x: this.silentScale, y: this.silentScale })
          .onClick(() => {
            this.getUIContext()?.animateTo({ duration: 200, curve: Curve.EaseInOut }, () => {
              this.silentScale = 0.75;
            });
            setTimeout(() => {
              this.getUIContext()?.animateTo({ duration: 300, curve: curves.springMotion() }, () => {
                this.silentScale = 1.0;
              });
            }, 150);
            this.isSilentMode = !this.isSilentMode;
            if (this.isSilentMode) {
              this.volume = 0;
            } else {
              let preVolume: number = PreferencesUtil.getInstance().getValue(VOLUME_ID) as number;
              this.volume = preVolume ? preVolume : 0.1;
            }
          })

        /** 倍速设置（弹出菜单） */
        SymbolGlyph($r('sys.symbol.speed_multiple'))
          .fontSize(26)
          .renderingStrategy(SymbolRenderingStrategy.SINGLE)
          .fontColor([Color.White])
          .opacity(0.86)
          .onClick(() => { this.isShowSpeedBuild = true; })
          .bindMenu(this.speedBuilder())

        /** 音量控制（弹出 Sheet） */
        SymbolGlyph($r('sys.symbol.speaker_wave_2'))
          .fontSize(26)
          .renderingStrategy(SymbolRenderingStrategy.SINGLE)
          .fontColor([Color.White])
          .opacity(0.86)
          .onClick(() => { this.isShowVolumeBuild = true; })
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
      .padding({ top: $r('app.float.slider_margin_top'), bottom: this.isReverse ? $r('app.float.slider_margin_top') : 0 })
    }
    .reverse(this.isReverse)
  }

  /** 歌单列表 Builder */
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

  /** 音量调节 Builder（Slider 0-100%） */
  @Builder
  volumeBuilder() {
    Column() {
      Row() {
        Slider({
          value: this.volume * 100, min: 0, max: 100, step: 10, style: SliderStyle.OutSet
        })
          .showSteps(true)
          .showTips(false)
          .layoutWeight(1)
          .onChange((value: number, mode: SliderChangeMode) => {
            this.volume = value / 100;
            if (this.volume === 0) {
              this.isSilentMode = true
            } else {
              this.isSilentMode = false;
            }
          })
        Text(`${this.volume * 100}`)
      }
    }
    .padding({ bottom: 30, left: 15, right: 15 })
  }

  @Builder
  speedTitle() {
    Text($r('app.string.speed_setting'))
      .fontColor($r('app.color.text_primary'))
      .fontWeight(FontWeight.Bold)
      .fontSize((this.mainWindowInfo.widthBp === WidthBreakpoint.WIDTH_SM ||
        this.mainWindowInfo.widthBp === WidthBreakpoint.WIDTH_MD) ? 20 : 14)
  }

  /** 倍速选择菜单（0.5x / 1x / 2x / 3x） */
  @Builder
  speedBuilder() {
    Menu() {
      MenuItemGroup({ header: this.speedTitle() }) {
        ForEach(this.speedArr, (speed: number, index: number) => {
          MenuItem({
            content: `${speed}x`,
            symbolEndIcon: this.speed === speed ? new SymbolGlyphModifier($r('sys.symbol.checkmark')).fontSize('24vp') : undefined
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
      .fontColor($r('app.color.text_primary'))
      .fontWeight(FontWeight.Bold)
      .fontSize(20)
      .width('100%')
  }

  @Builder
  volumeTitle() {
    Text($r('app.string.volume_setting'))
      .maxLines(ContentConstants.PLAY_ALL_MAX_LINES)
      .fontColor($r('app.color.text_primary'))
      .fontWeight(FontWeight.Bold)
      .fontSize(20)
      .width('100%')
  }
}

/** Image 扩展：播控图标通用样式（正方形 + 半透明 + 包含模式） */
@Extend(Image)
function controlImageBuilder() {
  .aspectRatio(1)
  .opacity(0.86)
  .objectFit(ImageFit.Contain)
}

/**
 * 歌单列表项（可复用）
 * 显示：歌名 + 歌手(含角标) + 播放中等效提示图标
 */
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
            .fontColor(this.selectIndex === this.index && this.isPlay ? Color.Red : $r('app.color.text_primary'))
            .fontSize(16)
            .margin({ bottom: $r('app.float.list_item_title_margin') })
          Row() {
            Image(this.item!.mark)
              .width($r('app.float.list_item_image_size'))
              .height($r('app.float.list_item_image_size'))
              .margin({ right: $r('app.float.list_item_image_margin') })
            Text(this.item!.singer)
              .opacity($r('app.float.singer_opacity'))
              .fontColor(this.selectIndex === this.index && this.isPlay ? Color.Red : $r('app.color.text_primary'))
              .fontSize(12)
          }
        }
        .alignItems(HorizontalAlign.Start)
        /** 当前播放中的歌曲显示波形图标 */
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
    .padding({ left: $r('app.float.list_item_padding'), right: $r('app.float.list_item_padding') })
  }
}
