import {
  curves, LengthMetrics, PromptAction, SymbolGlyphModifier
} from '@kit.ArkUI';
import { AVVolumePanel } from '@kit.AudioKit';
import { ContentConstants } from '../common/constants/ContentConstants';
import { MusicPlayMode, PlayerConstants, PlayModeSwitchList, VOLUME_ID } from '../common/constants/PlayerConstants';
import { StyleConstants } from '../common/constants/StyleConstants';
import Logger from '../common/utils/Logger';
import { ResourceConversion } from '../common/utils/ResourceConversion';
import { SongInfo } from '../model/SongInfo';
import { SongDataSource } from '../viewmodel/SongDataSource';
import { AVPlayerService } from '../service/AVPlayerService';
import { DataService } from '../service/DataService';
import { ColorHelper } from '../common/utils/ColorHelper';
import { common } from '@kit.AbilityKit';
import { PreferencesUtil } from '../common/utils/PreferencesUtil';
import { MediaTools } from '../common/utils/mediautils/MediaTools';
import { WindowInfo } from '../common/utils/WindowUtil';
import { AppStorageKeyConstants } from '../common/constants/AppStorageKeyConstants';
import { audio } from '@kit.AudioKit';
import { AlbumCover } from '../component/AlbumCover';

const TAG = 'ControlAreaComponent';
const SKIP_MS: number = 15000;

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
  @StorageLink(AppStorageKeyConstants.KEY_SONG_LIST) @Watch('onSongListChange') songList: SongInfo[] = [];
  @State isShowPlayList: boolean = false;
  @StorageLink(AppStorageKeyConstants.KEY_PLAY_MODE) playMode: MusicPlayMode = PlayModeSwitchList[this.playModeIndex];
  @StorageLink(AppStorageKeyConstants.KEY_SELECT_INDEX) selectIndex: number = 0;
  @StorageLink(AppStorageKeyConstants.KEY_IS_SILENT_MODE) isSilentMode: boolean = false;
  @StorageLink(AppStorageKeyConstants.KEY_CURRENT_SPEED) speed: number = 1;
  @StorageLink(AppStorageKeyConstants.KEY_CURRENT_VOLUME) volume: number = 0;
  @State isShowSpeedBuild: boolean = false;
  @State isShowVolumeBuild: boolean = false;
  @State songTimeFontSize: number = 10;
  @State songTimeFontColor: ResourceColor = '#B3FFFFFF';
  @State trackThickness: number = 6;
  @State playBtnScale: number = 1.0;
  @State sliderGlow: number = 0;
  private scroller: Scroller = new Scroller();
  private resourceConversion: ResourceConversion = new ResourceConversion();
  private context: common.UIAbilityContext | undefined = AppStorage.get(AppStorageKeyConstants.KEY_UI_ABILITY_CONTEXT);
  uiContext: UIContext = this.getUIContext();
  promptAction: PromptAction = this.uiContext.getPromptAction();
  @State playlistScale: number = 1.0;
  @State playModeScale: number = 1.0;
  @State speedScale: number = 1.0;
  @State volumeScale: number = 1.0;
  private avPlayerService: AVPlayerService = AVPlayerService.getInstance();
  private songDataSource: SongDataSource = new SongDataSource([]);
  private volumeManager: audio.AudioVolumeManager | undefined = undefined;
  private isVolumeListenerRegistered: boolean = false;
  private streamVolumeChangeCallback = (streamVolumeEvent: audio.StreamVolumeEvent): void => {
    const maxVol: number = 15;
    const newVol: number = streamVolumeEvent.volume / maxVol;
    this.volume = newVol;
    AppStorage.setOrCreate(AppStorageKeyConstants.KEY_CURRENT_VOLUME, newVol);
  };
  @StorageLink('uplayer_primary_color') primaryColor: string = '#007DFF';

  aboutToAppear(): void {
    this.avPlayerService.onSongComplete = (): void => {
      this.playNext();
    };
    this.songDataSource.reloadData(this.songList);
    this.syncSystemVolume();
  }

  aboutToDisappear(): void {
    if (this.volumeManager !== undefined && this.isVolumeListenerRegistered) {
      this.volumeManager.off('streamVolumeChange', this.streamVolumeChangeCallback);
      this.isVolumeListenerRegistered = false;
    }
  }

  onSongListChange(): void {
    this.songDataSource.reloadData(this.songList);
  }

  private async syncSystemVolume(): Promise<void> {
    try {
      const audioManager: audio.AudioManager = audio.getAudioManager();
      this.volumeManager = audioManager.getVolumeManager();
      if (!this.isVolumeListenerRegistered) {
        this.volumeManager.on('streamVolumeChange', audio.StreamUsage.STREAM_USAGE_MUSIC,
          this.streamVolumeChangeCallback);
        this.isVolumeListenerRegistered = true;
      }
      const groupManager: audio.AudioVolumeGroupManager =
        await this.volumeManager.getVolumeGroupManager(audio.DEFAULT_VOLUME_GROUP_ID);
      const currentVol: number = groupManager.getVolumeSync(audio.AudioVolumeType.MEDIA);
      this.volume = currentVol / 15;
    } catch (err) {
      Logger.error(TAG, `syncSystemVolume failed: ${JSON.stringify(err)}`);
    }
  }

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
  }

  private getSecureRandom0To1(): number {
    return Math.random();
  }

  private setRandom(retryCount: number = 0): number {
    let random0To1 = this.getSecureRandom0To1();
    let num = Math.round(random0To1 * (this.songList.length - 1));
    if (this.selectIndex === num && this.songList.length > 1 && retryCount < 5) {
      return this.setRandom(retryCount + 1);
    }
    return num;
  }

  private async playSongAt(index: number): Promise<void> {
    if (index < 0 || index >= this.songList.length) {
      return;
    }
    const song: SongInfo = this.songList[index];
    await this.avPlayerService.playSong(song, index);
  }

  private async playNext(): Promise<void> {
    const playNextId: string | undefined = DataService.getInstance().shiftPlayNext();
    if (playNextId !== undefined) {
      for (let i = 0; i < this.songList.length; i++) {
        if (this.songList[i].id === playNextId) {
          await this.playSongAt(i);
          return;
        }
      }
    }
    let nextIndex: number = this.selectIndex;
    switch (this.playMode) {
      case MusicPlayMode.SINGLE_CYCLE:
        break;
      case MusicPlayMode.ORDER:
        if (this.selectIndex >= this.songList.length - 1) {
          nextIndex = 0;
        } else {
          nextIndex = this.selectIndex + 1;
        }
        break;
      case MusicPlayMode.RANDOM:
        nextIndex = this.setRandom();
        break;
      default:
        break;
    }
    await this.playSongAt(nextIndex);
  }

  private async playPrevious(): Promise<void> {
    let prevIndex: number = this.selectIndex;
    switch (this.playMode) {
      case MusicPlayMode.SINGLE_CYCLE:
        break;
      case MusicPlayMode.ORDER:
        if (this.selectIndex <= 0) {
          prevIndex = this.songList.length - 1;
        } else {
          prevIndex = this.selectIndex - 1;
        }
        break;
      case MusicPlayMode.RANDOM:
        prevIndex = this.setRandom();
        break;
      default:
        break;
    }
    await this.playSongAt(prevIndex);
  }

  private skipForward(): void {
    const newPos: number = Math.min(this.value + SKIP_MS, this.max);
    this.avPlayerService.seek(newPos);
    this.pageShowTime = 0;
  }

  private skipBackward(): void {
    const newPos: number = Math.max(this.value - SKIP_MS, 0);
    this.avPlayerService.seek(newPos);
    this.pageShowTime = 0;
  }

  build() {
    Column() {
      Column() {
        Slider({
          min: 0, max: this.max, step: 1, style: SliderStyle.NONE, value: this.value
        })
          .trackThickness(this.trackThickness)
          .selectedColor('#FFFFFF')
          .trackColor('#B3FFFFFF')
          .enabled(this.max > 0)
          .shadow({ radius: this.sliderGlow, color: '#B3FFFFFF' })
          .onChange((value: number, mode: SliderChangeMode) => {
            if (mode === SliderChangeMode.End) {
              this.avPlayerService.seek(value);
              this.getUIContext()?.animateTo({ curve: curves.springMotion() }, () => {
                this.trackThickness = 6;
                this.songTimeFontSize = 10;
                this.songTimeFontColor = '#B3FFFFFF';
                this.sliderGlow = 0;
              });
            }
            if (mode === SliderChangeMode.Moving) {
              this.currentTime = MediaTools.msToCountdownTime(value);
              this.getUIContext()?.animateTo({ curve: curves.springMotion() }, () => {
                this.trackThickness = 10;
                this.songTimeFontSize = 12;
                this.songTimeFontColor = '#FFFFFF';
                this.sliderGlow = 8;
              });
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
      .margin({ bottom: 12 })

      Row() {
        Column() {
          SymbolGlyph($r('sys.symbol.gobackward_15'))
            .fontSize(28)
            .renderingStrategy(SymbolRenderingStrategy.SINGLE)
            .fontColor([Color.White])
            .opacity(0.86)
            .hoverEffect(HoverEffect.Scale)
            .onClick(() => { this.skipBackward(); })
        }
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)

        Column() {
          Image($r('app.media.ic_public_forward'))
            .controlImageBuilder()
            .width(32)
            .hoverEffect(HoverEffect.Scale)
            .onClick(() => {
              this.playPrevious();
              this.pageShowTime = 0;
            })
        }
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)

        Column() {
          Image(this.isPlay ? $r('app.media.ic_public_play') : $r('app.media.ic_public_pause'))
            .controlImageBuilder()
            .width(72)
            .scale({ x: this.playBtnScale, y: this.playBtnScale })
            .shadow({ radius: 10, color: ColorHelper.hexWithAlpha(this.primaryColor, '22') })
            .hoverEffect(HoverEffect.Scale)
            .onClick(() => {
              if (this.isPlay) {
                this.avPlayerService.pause();
              } else {
                this.avPlayerService.resume();
              }
              this.getUIContext()?.animateTo({ curve: curves.springMotion() }, () => {
                this.playBtnScale = 0.85;
              });
              setTimeout(() => {
                this.getUIContext()?.animateTo({ curve: curves.springMotion() }, () => {
                  this.playBtnScale = 1.0;
                });
              }, StyleConstants.ANIMATION_PRESS_DELAY_SHORT);
              this.pageShowTime = 0;
            })
        }
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)

        Column() {
          Image($r('app.media.ic_public_next'))
            .controlImageBuilder()
            .width(32)
            .hoverEffect(HoverEffect.Scale)
            .onClick(() => {
              this.playNext();
              this.pageShowTime = 0;
            })
        }
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)

        Column() {
          SymbolGlyph($r('sys.symbol.goforward_15'))
            .fontSize(28)
            .renderingStrategy(SymbolRenderingStrategy.SINGLE)
            .fontColor([Color.White])
            .opacity(0.86)
            .hoverEffect(HoverEffect.Scale)
            .onClick(() => { this.skipForward(); })
        }
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      }
      .width(StyleConstants.FULL_WIDTH)

      Row() {
        SymbolGlyph(this.playMode === MusicPlayMode.ORDER ? $r('sys.symbol.order_play') :
          this.playMode === MusicPlayMode.RANDOM ? $r('sys.symbol.shuffle') : $r('sys.symbol.repeat_1'))
          .fontSize(26)
          .renderingStrategy(SymbolRenderingStrategy.SINGLE)
          .fontColor([Color.White])
          .opacity(0.86)
          .scale({ x: this.playModeScale, y: this.playModeScale })
          .onClick(() => {
            this.getUIContext()?.animateTo({ duration: StyleConstants.ANIMATION_PRESS_DURATION_MEDIUM, curve: Curve.EaseInOut }, () => {
              this.playModeScale = 0.75;
            });
            setTimeout(() => {
              this.getUIContext()?.animateTo({ duration: StyleConstants.ANIMATION_RELEASE_DURATION_MEDIUM, curve: curves.springMotion() }, () => {
                this.playModeScale = 1.0;
              });
            }, StyleConstants.ANIMATION_PRESS_DELAY_LONG);
            this.switchPlayMode();
          })

        SymbolGlyph($r('sys.symbol.music_note_list'))
          .fontSize(26)
          .renderingStrategy(SymbolRenderingStrategy.SINGLE)
          .fontColor([Color.White])
          .opacity(0.86)
          .scale({ x: this.playlistScale, y: this.playlistScale })
          .onClick(() => {
            this.getUIContext()?.animateTo({ duration: StyleConstants.ANIMATION_PRESS_DURATION_SHORT, curve: Curve.EaseInOut }, () => {
              this.playlistScale = 0.8;
            });
            setTimeout(() => {
              this.getUIContext()?.animateTo({ duration: StyleConstants.ANIMATION_RELEASE_DURATION_SHORT, curve: curves.springMotion() }, () => {
                this.playlistScale = 1.0;
              });
            }, StyleConstants.ANIMATION_PRESS_DELAY_MEDIUM);
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

        SymbolGlyph($r('sys.symbol.speed_multiple'))
          .fontSize(26)
          .renderingStrategy(SymbolRenderingStrategy.SINGLE)
          .fontColor([Color.White])
          .opacity(0.86)
          .scale({ x: this.speedScale, y: this.speedScale })
          .onClick(() => {
            this.getUIContext()?.animateTo({ duration: StyleConstants.ANIMATION_PRESS_DURATION_SHORT, curve: Curve.EaseInOut }, () => {
              this.speedScale = 0.8;
            });
            setTimeout(() => {
              this.getUIContext()?.animateTo({ duration: StyleConstants.ANIMATION_RELEASE_DURATION_SHORT, curve: curves.springMotion() }, () => {
                this.speedScale = 1.0;
              });
            }, StyleConstants.ANIMATION_PRESS_DELAY_MEDIUM);
            this.isShowSpeedBuild = true;
          })
          .bindPopup(this.isShowSpeedBuild, {
            builder: this.speedPopupBuilder,
            placement: Placement.Top,
            showInSubWindow: false,
            onStateChange: (e) => {
              if (!e.isVisible) {
                this.isShowSpeedBuild = false;
              }
            }
          })

        SymbolGlyph($r('sys.symbol.speaker_wave_2'))
          .fontSize(26)
          .renderingStrategy(SymbolRenderingStrategy.SINGLE)
          .fontColor([Color.White])
          .opacity(0.86)
          .scale({ x: this.volumeScale, y: this.volumeScale })
          .onClick(() => {
            this.getUIContext()?.animateTo({ duration: StyleConstants.ANIMATION_PRESS_DURATION_SHORT, curve: Curve.EaseInOut }, () => {
              this.volumeScale = 0.8;
            });
            setTimeout(() => {
              this.getUIContext()?.animateTo({ duration: StyleConstants.ANIMATION_RELEASE_DURATION_SHORT, curve: curves.springMotion() }, () => {
                this.volumeScale = 1.0;
              });
            }, StyleConstants.ANIMATION_PRESS_DELAY_MEDIUM);
            this.isShowVolumeBuild = !this.isShowVolumeBuild
          })
      }
      .width(StyleConstants.FULL_WIDTH)
      .justifyContent(FlexAlign.SpaceEvenly)
      .margin({ top: 28 })

      AVVolumePanel({
        volumeLevel: Math.round(this.volume * 15),
        volumeParameter: {
          position: {
            x: this.isShowVolumeBuild ? 100 : -1,
            y: 200
          }
        }
      })
        .height(1)
    }
  }

  @Builder
  musicListBuilder() {
    Column() {
      List({ scroller: this.scroller }) {
        LazyForEach(this.songDataSource, (item: SongInfo, index: number) => {
          ListItem() {
            MusicListContainer({ item: item, index: index })
          }
        }, (item: SongInfo, index: number) => item.id + index.toString())
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
  speedPopupBuilder() {
    Column() {
      Row() {
        Text('倍速')
          .fontSize(14)
          .fontColor($r('app.color.text_primary'))
          .fontWeight(FontWeight.Bold)
        Text(`${this.speed.toFixed(2)}x`)
          .fontSize(14)
          .fontColor(this.primaryColor)
          .fontWeight(FontWeight.Bold)
          .margin({ left: 8 })
      }
      .width('100%')
      .margin({ bottom: 8 })

      Slider({
        min: 0.25, max: 3.0, step: 0.25, style: SliderStyle.OutSet, value: this.speed
      })
        .showSteps(true)
        .showTips(false)
        .width('100%')
        .selectedColor(this.primaryColor)
        .trackColor(ColorHelper.hexToRgba(this.primaryColor, 0.12))
        .blockColor('#FFFFFF')
        .blockSize({ width: 20, height: 20 })
        .blockBorderColor(this.primaryColor)
        .blockBorderWidth(3)
        .onChange((value: number, mode: SliderChangeMode) => {
          this.speed = Math.round(value * 4) / 4
          AppStorage.setOrCreate(AppStorageKeyConstants.KEY_CURRENT_SPEED, this.speed)
          this.avPlayerService.setSpeed(this.speed)
        })

      Row() {
        Text('0.25').fontSize(9).fontColor($r('app.color.text_sixty_color'))
        Text('0.5').fontSize(9).fontColor($r('app.color.text_sixty_color'))
        Text('1.0').fontSize(9).fontColor($r('app.color.text_sixty_color'))
        Text('1.5').fontSize(9).fontColor($r('app.color.text_sixty_color'))
        Text('2.0').fontSize(9).fontColor($r('app.color.text_sixty_color'))
        Text('2.5').fontSize(9).fontColor($r('app.color.text_sixty_color'))
        Text('3.0').fontSize(9).fontColor($r('app.color.text_sixty_color'))
      }
      .width('100%')
      .justifyContent(FlexAlign.SpaceBetween)
      .padding({ left: 4, right: 4 })
    }
    .padding(16)
    .width(260)
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
  item: SongInfo = new SongInfo();
  index: number = 0;
  @State listItemArtFailed: boolean = false;

  build() {
    Column() {
      Row() {
        Column() {
          Text(this.item.title)
            .fontColor(this.selectIndex === this.index && this.isPlay ? Color.Red : $r('app.color.text_primary'))
            .fontSize(16)
            .margin({ bottom: $r('app.float.list_item_title_margin') })
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Row() {
            AlbumCover({ song: this.item, coverWidth: $r('app.float.list_item_image_size'),
              coverHeight: $r('app.float.list_item_image_size') })
              .margin({ right: $r('app.float.list_item_image_margin') })
            Text(this.item.artist)
              .opacity($r('app.float.singer_opacity'))
              .fontColor(this.selectIndex === this.index && this.isPlay ? Color.Red : $r('app.color.text_primary'))
              .fontSize(12)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
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
        const avService: AVPlayerService = AVPlayerService.getInstance();
        avService.playSong(this.item, this.index);
      })
      .height($r('app.float.list_item_height'))
      .width(StyleConstants.FULL_WIDTH)
    }
    .padding({ left: $r('app.float.list_item_padding'), right: $r('app.float.list_item_padding') })
  }
}
