// ArkUI 26 Beta1: 接口定义变更（误报，本项目已是Stage模型）+ UX视觉布局变更（Text默认开启沉浸式材质，系统行为）
import {
  curves, LengthMetrics, PromptAction, SymbolGlyphModifier, uiMaterial
} from '@kit.ArkUI';
import { AVVolumePanel } from '@kit.AudioKit';

import { MusicPlayMode, PlayerConstants, PlayModeSwitchList } from '../common/constants/PlayerConstants';
import { StyleConstants } from '../common/constants/StyleConstants';
import Logger from '../common/utils/Logger';
import { SongInfo } from '../model/SongInfo';
import { SongDataSource } from '../viewmodel/SongDataSource';
import { AVPlayerService } from '../service/AVPlayerService';
import { ColorHelper } from '../common/utils/ColorHelper';
import { common } from '@kit.AbilityKit';
import { MediaTools } from '../common/utils/mediautils/MediaTools';
import { WindowInfo } from '../common/utils/WindowUtil';
import { AppStorageKeyConstants } from '../common/constants/AppStorageKeyConstants';
import { audio } from '@kit.AudioKit';
import { AlbumCover } from '../component/AlbumCover';
import { AVSessionController } from '../common/utils/mediautils/AVSessionController';
import { DataService } from '../service/DataService';

const TAG = 'ControlAreaComponent';
const SEEK_SETTLE_MS: number = 2000;
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
  @StorageLink(AppStorageKeyConstants.KEY_PLAY_MODE) @Watch('onPlayModeChange')
  playMode: MusicPlayMode = PlayModeSwitchList[this.playModeIndex];
  @StorageLink(AppStorageKeyConstants.KEY_SELECT_INDEX) selectIndex: number = 0;
  @StorageLink(AppStorageKeyConstants.KEY_CURRENT_SPEED) speed: number = 1;
  @StorageLink(AppStorageKeyConstants.KEY_CURRENT_VOLUME) volume: number = 0;
  @State isShowSpeedBuild: boolean = false;
  @State isShowVolumeBuild: boolean = false;
  @State songTimeFontSize: number = 10;
  @State songTimeFontColor: ResourceColor = '#B3FFFFFF';
  @State trackThickness: number = 6;
  @State playBtnScale: number = 1.0;
  @State sliderGlow: number = 0;
  @State isShowInfoPanel: boolean = false;
  @State infoTitle: string = '';
  @State infoArtist: string = '';
  @State infoAlbum: string = '';
  private scroller: Scroller = new Scroller();
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
  private isSeekingTimer: number = -1;
  private streamVolumeChangeCallback = (streamVolumeEvent: audio.StreamVolumeEvent): void => {
    const maxVol: number = 15;
    const newVol: number = streamVolumeEvent.volume / maxVol;
    this.volume = newVol;
    AppStorage.setOrCreate(AppStorageKeyConstants.KEY_CURRENT_VOLUME, newVol);
  };
  @StorageLink('uplayer_primary_color') primaryColor: string = '#007DFF';

  aboutToAppear(): void {
    this.songDataSource.reloadData(this.songList);
    this.syncPlayModeIndex();
    this.syncSystemVolume();
  }

  aboutToDisappear(): void {
    if (this.isSeekingTimer !== -1) {
      clearInterval(this.isSeekingTimer);
      this.isSeekingTimer = -1;
    }
    if (this.volumeManager !== undefined && this.isVolumeListenerRegistered) {
      this.volumeManager.off('streamVolumeChange', this.streamVolumeChangeCallback);
      this.isVolumeListenerRegistered = false;
    }
  }

  onSongListChange(): void {
    this.songDataSource.reloadData(this.songList);
  }

  onPlayModeChange(): void {
    this.syncPlayModeIndex();
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

  private syncPlayModeIndex(): void {
    const index: number = PlayModeSwitchList.indexOf(this.playMode);
    this.playModeIndex = index >= 0 ? index : 0;
    if (index < 0) {
      this.playMode = PlayModeSwitchList[0];
    }
  }

  switchPlayMode() {
    if (this.playModeIndex === PlayModeSwitchList.length - 1) {
      this.playModeIndex = 0;
    } else {
      this.playModeIndex++;
    }
    this.playMode = PlayModeSwitchList[this.playModeIndex];
    AVSessionController.getInstance().updatePlayMode(this.playMode);
    Logger.info(TAG, 'playModeIndex is' + this.playModeIndex);
    try {
      this.promptAction.openToast({
        message: `${this.playMode === MusicPlayMode.ORDER ?
          (this.context?.resourceManager?.getStringSync($r('app.string.sequential_playback').id) ?? '') :
          this.playMode === MusicPlayMode.RANDOM ?
            (this.context?.resourceManager?.getStringSync($r('app.string.random_playback').id) ?? '') :
            (this.context?.resourceManager?.getStringSync($r('app.string.single_playback').id) ?? '')}`,
      });
    } catch (err) {
      Logger.error(TAG, `openToast failed: ${JSON.stringify(err)}`);
    }
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

  private openInfoPanel(): void {
    if (this.selectIndex < 0 || !this.songList || this.selectIndex >= this.songList.length) {
      return;
    }
    const song: SongInfo = this.songList[this.selectIndex];
    this.infoTitle = song.title;
    this.infoArtist = song.artist;
    this.infoAlbum = song.album;
    this.isShowInfoPanel = true;
  }

  private saveSongInfo(): void {
    if (this.selectIndex < 0 || !this.songList || this.selectIndex >= this.songList.length) {
      return;
    }
    const song: SongInfo = this.songList[this.selectIndex];
    const originalTitle: string = song.title;
    const originalArtist: string = song.artist;
    const originalAlbum: string = song.album;
    const updatedTitle: string = this.infoTitle;
    const updatedArtist: string = this.infoArtist;
    const updatedAlbum: string = this.infoAlbum;
    if (originalTitle !== updatedTitle || originalArtist !== updatedArtist || originalAlbum !== updatedAlbum) {
      song.title = updatedTitle;
      song.artist = updatedArtist;
      song.album = updatedAlbum;
      const songs: SongInfo[] = this.songList.slice();
      DataService.getInstance().updateSongFields(song.id, songs);
    }
    this.isShowInfoPanel = false;
  }

  private closeInfoPanel(): void {
    this.isShowInfoPanel = false;
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
            if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) {
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
          Image($r('app.media.ic_public_play_last'))
            .controlImageBuilder()
            .width(28)
            .fillColor(Color.White)
            .hoverEffect(HoverEffect.Scale)
            .onClick(() => {
              this.avPlayerService.playPreviousSong();
              this.pageShowTime = 0;
            })
        }
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)

        Column() {
          Image(this.isPlay ? $r('app.media.ic_public_pause') : $r('app.media.ic_public_play'))
            .controlImageBuilder()
            .width(60)
            .fillColor(Color.White)
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
          Image($r('app.media.ic_public_play_next'))
            .controlImageBuilder()
            .width(28)
            .fillColor(Color.White)
            .hoverEffect(HoverEffect.Scale)
            .onClick(() => {
              this.avPlayerService.playNextSong();
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
          .hoverEffect(HoverEffect.Scale)
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
          .hoverEffect(HoverEffect.Scale)
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
          .hoverEffect(HoverEffect.Scale)
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

        SymbolGlyph($r('sys.symbol.info_circle'))
          .fontSize(26)
          .renderingStrategy(SymbolRenderingStrategy.SINGLE)
          .fontColor([Color.White])
          .opacity(0.86)
          .scale({ x: this.volumeScale, y: this.volumeScale })
          .hoverEffect(HoverEffect.Scale)
          .onClick(() => {
            this.getUIContext()?.animateTo({ duration: StyleConstants.ANIMATION_PRESS_DURATION_SHORT, curve: Curve.EaseInOut }, () => {
              this.volumeScale = 0.8;
            });
            setTimeout(() => {
              this.getUIContext()?.animateTo({ duration: StyleConstants.ANIMATION_RELEASE_DURATION_SHORT, curve: curves.springMotion() }, () => {
                this.volumeScale = 1.0;
              });
            }, StyleConstants.ANIMATION_PRESS_DELAY_MEDIUM);
            this.openInfoPanel();
          })
          .bindSheet($$this.isShowInfoPanel, this.infoPanelBuilder(), {
            detents: [SheetSize.MEDIUM],
            dragBar: false,
            showClose: true,
            preferType: SheetType.CENTER
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
  infoPanelTitle() {
    Text('')
      .width(0)
      .height(0)
  }

  @Builder
  infoPanelBuilder() {
    Column() {
      if (this.selectIndex >= 0 && this.songList && this.selectIndex < this.songList.length) {
        this.infoPanelHeader()
        Column() {
          this.infoRow('标题', this.infoTitle, true)
          this.infoRow('歌手', this.infoArtist, true)
          this.infoRow('专辑', this.infoAlbum, true)
          this.infoRow('时长', MediaTools.msToCountdownTime(this.songList[this.selectIndex].duration), false)
          if (this.songList[this.selectIndex].bitrate > 0) {
            this.infoRow('比特率', `${this.songList[this.selectIndex].bitrate / 1000} kbps`, false)
          }
          if (this.songList[this.selectIndex].sampleRate > 0) {
            this.infoRow('采样率', `${this.songList[this.selectIndex].sampleRate} Hz`, false)
          }
        }
        .width('100%')
        .margin({ bottom: 16 })
      }

      Row() {
        Button('取消')
          .height(36)
          .width('48%')
          .fontSize(14)
          .fontColor(Color.White)
          .backgroundColor('rgba(255,255,255,0.12)')
          .borderRadius(8)
          .onClick(() => { this.closeInfoPanel() })
        Button('保存')
          .height(36)
          .width('48%')
          .fontSize(14)
          .fontColor(Color.White)
          .backgroundColor(this.primaryColor)
          .borderRadius(8)
          .onClick(() => { this.saveSongInfo() })
      }
      .width('100%')
    }
    .width(300)
    .padding(20)
    .backgroundColor('#1A1A2E')
    .borderRadius(16)
  }

  @Builder
  infoPanelHeader() {
    Row() {
      AlbumCover({ song: this.songList[this.selectIndex], coverWidth: 64, coverHeight: 64, coverRadius: 8 })
      Column() {
        Text(this.songList[this.selectIndex].title)
          .fontSize(16)
          .fontWeight(FontWeight.Bold)
          .fontColor(Color.White)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(this.songList[this.selectIndex].artist.length > 0 ? this.songList[this.selectIndex].artist : '未知歌手')
          .fontSize(13)
          .fontColor('rgba(255,255,255,0.7)')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        if (this.songList[this.selectIndex].album.length > 0) {
          Text(this.songList[this.selectIndex].album)
            .fontSize(12)
            .fontColor('rgba(255,255,255,0.5)')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
      }
      .margin({ left: 12 })
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .margin({ bottom: 16 })
  }

  @Builder
  infoRow(label: string, value: string, editable: boolean) {
    Row() {
      Text(label)
        .fontSize(12)
        .fontColor('rgba(255,255,255,0.5)')
        .width(56)
      if (editable) {
        TextInput({ text: value })
          .fontSize(13)
          .fontColor(Color.White)
          .backgroundColor('rgba(255,255,255,0.08)')
          .borderRadius(4)
          .height(32)
          .padding({ left: 8, right: 8 })
          .layoutWeight(1)
          .onChange((newValue: string) => {
            if (label === '标题') {
              this.infoTitle = newValue;
            } else if (label === '歌手') {
              this.infoArtist = newValue;
            } else if (label === '专辑') {
              this.infoAlbum = newValue;
            }
          })
      } else {
        Text(value)
          .fontSize(13)
          .fontColor('rgba(255,255,255,0.8)')
          .layoutWeight(1)
      }
    }
    .width('100%')
    .height(38)
    .alignItems(VerticalAlign.Center)
    .margin({ bottom: 6 })
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
      .maxLines(1)
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
        avService.playSongAt(this.index);
      })
      .height($r('app.float.list_item_height'))
      .width(StyleConstants.FULL_WIDTH)
    }
    .padding({ left: $r('app.float.list_item_padding'), right: $r('app.float.list_item_padding') })
  }
}
