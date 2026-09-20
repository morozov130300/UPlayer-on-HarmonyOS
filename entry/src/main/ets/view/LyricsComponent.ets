// ArkUI 26 Beta1: 接口定义变更（误报，本项目已是Stage模型）+ UX视觉布局变更（Text默认开启沉浸式材质，系统行为）
import { common } from '@kit.AbilityKit';
import { curves } from '@kit.ArkUI';
import { ControlAreaComponent } from './ControlAreaComponent';
import { PlayerConstants } from '../common/constants/PlayerConstants';
import { StyleConstants } from '../common/constants/StyleConstants';
import { LyricScrollEffect } from '../common/constants/LyricConst';
import { LrcEntry } from '../viewmodel/LrcEntry';
import { SongInfo } from '../model/SongInfo';
import { loadLyricEntries } from '../service/LyricLoader';
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
  // 歌词引用发生集合级变化（重新导入覆盖）时重新加载，
  // 保证已经打开的播放页无需切歌或重启即可显示歌词
  @StorageProp(AppStorageKeyConstants.KEY_LYRIC_REVISION) @Watch('getLrcEntryList') lyricRevision: number = 0;
  @StorageLink(AppStorageKeyConstants.KEY_IS_PLAY) isPlay: boolean = false;
  @Link isShowControl: boolean;
  @StorageLink(AppStorageKeyConstants.KEY_PAGE_SHOW_TIME) pageShowTime: number = 0;
  @StorageLink('uplayer_font_size_scale') fontSizeScale: number = 1.0;
  private context: common.UIAbilityContext | undefined = AppStorage.get(AppStorageKeyConstants.KEY_UI_ABILITY_CONTEXT);
  private lyricLoadRequestId: number = 0;

  aboutToAppear() {
    this.getLrcEntryList();
  }

  async getLrcEntryList(): Promise<void> {
    const requestId: number = ++this.lyricLoadRequestId;
    this.mLrcEntryList = [];
    if (!this.songList || this.selectIndex < 0 || this.selectIndex >= this.songList.length) {
      return;
    }
    const song: SongInfo = this.songList[this.selectIndex];
    // 两个歌词字段都为空时 LyricLoader 会直接返回空数组（不做任何 I/O 或路径推导），
    // 因此这里无需额外提前返回
    const entries: LrcEntry[] = await loadLyricEntries(song);
    Logger.debug('getLrcEntryList', `song=${song.id} entries=${entries.length}`);
    // 陈旧请求守卫：读歌词期间用户可能已经切歌，此时不能再覆盖当前歌曲的歌词
    if (requestId !== this.lyricLoadRequestId || this.selectIndex < 0 ||
      this.selectIndex >= this.songList.length || this.songList[this.selectIndex].id !== song.id) {
      return;
    }
    this.mLrcEntryList = entries;
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
