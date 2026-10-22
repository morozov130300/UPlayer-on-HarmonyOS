// ArkUI 26 Beta1: 接口定义变更（误报，本项目已是Stage模型）+ UX视觉布局变更（Text默认开启沉浸式材质，系统行为）
import { curves } from '@kit.ArkUI';
import { ControlAreaComponent } from './ControlAreaComponent';
import { PlayerConstants } from '../common/constants/PlayerConstants';
import { StyleConstants } from '../common/constants/StyleConstants';
import { LrcEntry } from '../viewmodel/LrcEntry';
import { SongInfo } from '../model/SongInfo';
import { loadLyricEntries } from '../service/LyricLoader';
import { DataService } from '../service/DataService';
import { WindowInfo } from '../common/utils/WindowUtil';
import Logger from '../common/utils/Logger';
import LrcListView from './LrcListView';
import { AppStorageKeyConstants } from '../common/constants/AppStorageKeyConstants';
import { AlbumCover } from '../component/AlbumCover';

@Component
export struct LyricsComponent {
  @Prop mainWindowInfo: WindowInfo;
  // 手机断点下一镜到底启用时，小封面由 PlayerFlyingCover 浮层渲染，此处仅保留透明占位
  @Prop isCoverFloating: boolean = false;
  // 小封面几何上报（页面级坐标），作为一镜到底的终点
  onCoverAreaChange: (area: Area) => void = () => {};
  @StorageLink(AppStorageKeyConstants.KEY_PROGRESS) time: number = 0;
  @State mLrcEntryList: Array<LrcEntry> = [];
  // 歌词加载态：加载中显示「正在加载歌词…」，与「无歌词」区分，避免解析前误占位
  @State isLyricLoading: boolean = false;
  @StorageLink(AppStorageKeyConstants.KEY_SONG_LIST) songList: SongInfo[] = [];
  @StorageProp(AppStorageKeyConstants.KEY_SELECT_INDEX) @Watch('getLrcEntryList') selectIndex: number = 0;
  // 按 id 解析当前播放歌曲，避免队列下标失配导致歌词与实际播放不一致
  @StorageProp('uplayer_current_song_id') @Watch('getLrcEntryList') currentSongId: string = '';
  // 歌词引用发生集合级变化（重新导入覆盖）时重新加载，
  // 保证已经打开的播放页无需切歌或重启即可显示歌词
  @StorageProp(AppStorageKeyConstants.KEY_LYRIC_REVISION) @Watch('getLrcEntryList') lyricRevision: number = 0;
  @Link isShowControl: boolean;
  @StorageLink(AppStorageKeyConstants.KEY_PAGE_SHOW_TIME) pageShowTime: number = 0;
  @StorageLink('uplayer_font_size_scale') fontSizeScale: number = 1.0;
  // P0-3 每歌歌词偏移：滑条已移入播放器「更多」半模态（ControlAreaComponent），
  // 这里只消费同一个 AppStorage 键驱动高亮/点击跳转换算
  @StorageLink(AppStorageKeyConstants.KEY_LYRIC_OFFSET_MS) lyricOffsetMs: number = 0;
  private lyricLoadRequestId: number = 0;

  aboutToAppear() {
    this.getLrcEntryList();
  }

  private currentSong(): SongInfo {
    return DataService.currentSongFromList(this.songList, this.currentSongId)
  }

  // 窄屏判定与 PlayerInfoComponent 保持一致：XS/SM 断点（手机、分屏、缩小后的 PC 窗口）
  // 都是单页滑动，需要显示 48×48 小封面作为一镜到底的终点
  private isNarrowLayout(): boolean {
    const bp: WidthBreakpoint | undefined = this.mainWindowInfo?.widthBp
    return bp === WidthBreakpoint.WIDTH_SM || bp === WidthBreakpoint.WIDTH_XS
  }

  async getLrcEntryList(): Promise<void> {
    const requestId: number = ++this.lyricLoadRequestId;
    this.isLyricLoading = true;
    const song: SongInfo = this.currentSong();
    // 切歌时同步本歌的歌词偏移到滑条
    this.lyricOffsetMs = song.lyricOffsetMs;
    if (song.id.length === 0) {
      this.mLrcEntryList = [];
      this.isLyricLoading = false;
      return;
    }
    // 两个歌词字段都为空时 LyricLoader 会直接返回空数组（不做任何 I/O 或路径推导），
    // 因此这里无需额外提前返回
    const entries: LrcEntry[] = await loadLyricEntries(song);
    Logger.debug('getLrcEntryList', `song=${song.id} entries=${entries.length}`);
    // 陈旧请求守卫：读歌词期间用户可能已经切歌，此时不能再覆盖当前歌曲的歌词
    if (requestId !== this.lyricLoadRequestId || this.currentSongId !== song.id) {
      return;
    }
    // 先赋列表再关加载态（同一同步块单次重渲染），避免闪「无歌词」
    this.mLrcEntryList = entries;
    this.isLyricLoading = false;
  }

  build() {
    Column() {
      if (this.isNarrowLayout()) {
        Row() {
          // 一镜到底终点：手机断点下封面由 PlayerFlyingCover 浮层渲染，此处仅保留 48×48 透明占位。
          // 尺寸与 margin 保持与裸 AlbumCover 完全一致，确保歌名/歌手不发生位移
          Stack() {
            AlbumCover({ song: this.currentSong(), coverWidth: 48, coverHeight: 48,
              coverRadius: $r('app.float.label_border') })
              .opacity(this.isCoverFloating ? 0 : 1)
          }
          .width(48)
          .height(48)
          .margin({ right: 16 })
          .onAreaChange((_oldArea: Area, newArea: Area) => {
            this.onCoverAreaChange(newArea)
          })
          Column() {
            Text(this.currentSong().title)
              .fontSize(Math.round(20 * this.fontSizeScale)).fontColor(Color.White)
              .fontWeight(PlayerConstants.FONT_WEIGHT_700)
              .fontFamily(PlayerConstants.FONT_FAMILY_BOLD)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            Row() {
              Text(this.currentSong().artist)
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

      LrcListView({ lyricMilliSecondsTime: this.time, mLrcEntryList: this.mLrcEntryList,
        isLyricLoading: this.isLyricLoading, lyricOffsetMs: this.lyricOffsetMs })
        .layoutWeight(1)

      // P0-3 歌词偏移滑条已移入播放器「更多」半模态（位置见 ControlAreaComponent.morePanelMainBuilder）

      if (this.isNarrowLayout() && this.isShowControl) {
        ControlAreaComponent()
          .margin({ top: $r('app.float.control_lyric_margin') })
          .transition({ type: TransitionType.Insert, translate: { x: 0, y: 40 }, opacity: 0 })
          .transition({ type: TransitionType.Delete, translate: { x: 0, y: 40 }, opacity: 0 })
      }
    }
    .onClick(() => {
      this.pageShowTime = 0;
      if (!this.isNarrowLayout()) {
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
