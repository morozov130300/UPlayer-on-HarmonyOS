// ArkUI 26 Beta1: 接口定义变更（误报，本项目已是Stage模型）+ UX视觉布局变更（Text默认开启沉浸式材质，系统行为）
import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { curves } from '@kit.ArkUI';
import { ControlAreaComponent } from './ControlAreaComponent';
import { PlayerConstants } from '../common/constants/PlayerConstants';
import { StyleConstants } from '../common/constants/StyleConstants';
import { LyricFile, LyricScrollEffect } from '../common/constants/LyricConst';
import { LrcEntry } from '../viewmodel/LrcEntry';
import { SongInfo } from '../model/SongInfo';
import { parseKrcLyric, parseLrcLyric } from '../common/utils/LrcUtils';
import { WindowInfo } from '../common/utils/WindowUtil';
import Logger from '../common/utils/Logger';
import LrcListView from './LrcListView';
import { AppStorageKeyConstants } from '../common/constants/AppStorageKeyConstants';
import { AlbumCover } from '../component/AlbumCover';

@Component
export struct LyricsComponent {
  @Prop mainWindowInfo: WindowInfo;
  @StorageLink(AppStorageKeyConstants.KEY_PROGRESS) time: number = 0;
  @State progress: number = 0.01;
  @State progressText: string = '';
  @State lyricScrollEffect: LyricScrollEffect = LyricScrollEffect.Line;
  @State mLrcEntryList: Array<LrcEntry> = [];
  @StorageLink(AppStorageKeyConstants.KEY_SONG_LIST) songList: SongInfo[] = [];
  @StorageProp(AppStorageKeyConstants.KEY_SELECT_INDEX) @Watch('getLrcEntryList') selectIndex: number = 0;
  @StorageLink(AppStorageKeyConstants.KEY_IS_PLAY) isPlay: boolean = false;
  @Link isShowControl: boolean;
  @StorageLink(AppStorageKeyConstants.KEY_PAGE_SHOW_TIME) pageShowTime: number = 0;
  @State coverArtFailed: boolean = false;
  @StorageLink('uplayer_font_size_scale') fontSizeScale: number = 1.0;
  private context: common.UIAbilityContext | undefined = AppStorage.get(AppStorageKeyConstants.KEY_UI_ABILITY_CONTEXT);
  private lyricLoadRequestId: number = 0;

  aboutToAppear() {
    this.getLrcEntryList();
  }

  async getLrcEntryList(): Promise<void> {
    const requestId: number = ++this.lyricLoadRequestId;
    this.coverArtFailed = false;
    this.mLrcEntryList = [];
    if (!this.songList || this.selectIndex < 0 || this.selectIndex >= this.songList.length) {
      return;
    }
    const song: SongInfo = this.songList[this.selectIndex];
    if ((!song.lyricUri || song.lyricUri.length === 0) && (!song.lyricPath || song.lyricPath.length === 0)) {
      return;
    }
    try {
      const lyricAccessPath: string = song.lyricUri.length > 0 ? song.lyricUri : song.lyricPath
      const file: fs.File = await fs.open(lyricAccessPath, fs.OpenMode.READ_ONLY);
      const stat = await fs.stat(file.fd);
      const buffer: ArrayBuffer = new ArrayBuffer(stat.size);
      await fs.read(file.fd, buffer);
      await fs.close(file);
      const textDecoder = util.TextDecoder.create(PlayerConstants.ENCODING, { ignoreBOM: true });
      const stringData: string = textDecoder.decodeToString(new Uint8Array(buffer), { stream: false });
      const lyricCheckPath: string = song.lyricPath.length > 0 ? song.lyricPath : song.lyricUri
      const entries: LrcEntry[] = lyricCheckPath.endsWith(LyricFile.KRC) ?
        parseKrcLyric(stringData) : parseLrcLyric(stringData);
      if (requestId !== this.lyricLoadRequestId || this.selectIndex < 0 ||
        this.selectIndex >= this.songList.length || this.songList[this.selectIndex].id !== song.id) {
        return;
      }
      if (lyricCheckPath.endsWith(LyricFile.KRC)) {
        this.mLrcEntryList = entries;
      } else if (lyricCheckPath.endsWith(LyricFile.LRC)) {
        this.mLrcEntryList = entries;
      }
    } catch (err) {
      Logger.error('getLrcEntryList', `Failed to load lyric: ${JSON.stringify(err)}`);
    }
  }

  build() {
    Column() {
      if (this.mainWindowInfo.widthBp === WidthBreakpoint.WIDTH_SM) {
        Row() {
          AlbumCover({ song: this.songList && this.selectIndex >= 0 && this.selectIndex < this.songList.length ?
            this.songList[this.selectIndex] : new SongInfo(), coverWidth: 48, coverHeight: 48,
            coverRadius: $r('app.float.label_border') })
            .margin({ right: 16 })
          Column() {
            Text(this.songList && this.selectIndex >= 0 && this.selectIndex < this.songList.length ?
              this.songList[this.selectIndex].title : '')
              .fontSize(Math.round(20 * this.fontSizeScale)).fontColor(Color.White)
              .fontWeight(PlayerConstants.FONT_WEIGHT_700)
              .fontFamily(PlayerConstants.FONT_FAMILY_BOLD)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            Row() {
              Text(this.songList && this.selectIndex >= 0 && this.selectIndex < this.songList.length ?
                this.songList[this.selectIndex].artist : '')
                .fontSize(Math.round(16 * this.fontSizeScale))
                .fontColor($r('sys.color.ohos_id_color_text_hint_contrary'))
                .fontWeight(PlayerConstants.FONT_WEIGHT_500)
                .fontFamily(PlayerConstants.FONT_FAMILY_MEDIUM)
                .margin({ top: $r('app.float.singer_margin_top') })
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
            }
          }
          .height(48).alignItems(HorizontalAlign.Start).justifyContent(FlexAlign.SpaceBetween)
        }
        .width(StyleConstants.FULL_WIDTH).justifyContent(FlexAlign.Start)
        .margin({ bottom: $r('app.float.info_margin_bottom') })
      }

      LrcListView({ lyricMilliSecondsTime: this.time, mLrcEntryList: this.mLrcEntryList })
        .layoutWeight(1)

      if (this.mainWindowInfo.widthBp === WidthBreakpoint.WIDTH_SM && this.isShowControl) {
        ControlAreaComponent({ mainWindowInfo: this.mainWindowInfo })
          .margin({ top: $r('app.float.control_lyric_margin') })
          .transition({ type: TransitionType.Insert, translate: { x: 0, y: 40 }, opacity: 0 })
          .transition({ type: TransitionType.Delete, translate: { x: 0, y: 40 }, opacity: 0 })
      }
    }
    .onClick(() => {
      this.pageShowTime = 0;
      if (this.mainWindowInfo.widthBp !== WidthBreakpoint.WIDTH_SM) {
        return;
      }
      if (this.isShowControl) {
        this.getUIContext()?.animateTo({ curve: curves.springMotion(0.5, 0.8) }, () => {
          this.isShowControl = false;
        });
      } else {
        this.getUIContext()?.animateTo({ curve: curves.springMotion(0.5, 0.8) }, () => {
          this.isShowControl = true;
        });
      }
    })
  }
}
