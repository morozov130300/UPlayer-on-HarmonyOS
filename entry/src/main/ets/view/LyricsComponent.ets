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
  // 偏移滑轨显隐：由「更多」面板里的条目触发（条目点了只关面板，不在这里调值）
  @StorageLink(AppStorageKeyConstants.KEY_LYRIC_OFFSET_PANEL) @Watch('onOffsetPanelVisibleChange')
  offsetPanelVisible: boolean = false;
  // 无操作自动收起计时器
  private offsetPanelTimerId: number = -1;
  private lyricLoadRequestId: number = 0;

  aboutToAppear() {
    this.getLrcEntryList();
  }

  aboutToDisappear() {
    if (this.offsetPanelTimerId >= 0) {
      clearTimeout(this.offsetPanelTimerId);
      this.offsetPanelTimerId = -1;
    }
    // 离开播放页时把滑轨状态收回，下次进来不残留
    this.offsetPanelVisible = false;
  }

  // 显隐变化即重置「无操作 5 秒」计时；每次拖动也会重置（见 onLyricOffsetChange）
  onOffsetPanelVisibleChange(): void {
    if (this.offsetPanelTimerId >= 0) {
      clearTimeout(this.offsetPanelTimerId);
      this.offsetPanelTimerId = -1;
    }
    if (!this.offsetPanelVisible) {
      return;
    }
    this.offsetPanelTimerId = setTimeout(() => {
      this.offsetPanelTimerId = -1;
      this.offsetPanelVisible = false;
    }, 5000);
  }

  // 偏移值格式化：+0.5s / -1.2s / 0.0s
  private formatLyricOffset(offsetMs: number): string {
    const seconds: number = offsetMs / 1000;
    return (seconds > 0 ? '+' : '') + seconds.toFixed(1) + 's';
  }

  // 拖动：内存即时生效（歌词高亮实时跟随）；松手/点击才单曲落库，避免拖动刷大量 DB 写
  private onLyricOffsetChange(value: number, mode: SliderChangeMode): void {
    const clamped: number = Math.round(value / 100) * 100;
    this.lyricOffsetMs = clamped;
    if (this.currentSongId.length > 0) {
      DataService.getInstance().setLyricOffset(this.currentSongId, clamped,
        mode === SliderChangeMode.End || mode === SliderChangeMode.Click);
    }
    // 有操作即续命 5 秒
    this.onOffsetPanelVisibleChange();
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

      // 歌词偏移滑轨：由「更多」面板条目触发，在原位置滑出；无操作 5 秒自动收起。
      // Block 阻断触摸冒泡，避免拖滑条触发根容器的 onClick（窄屏下会切换控制区显隐）
      if (this.offsetPanelVisible && !this.isLyricLoading && this.mLrcEntryList.length > 0) {
        Row({ space: 10 }) {
          Text('歌词偏移')
            .fontSize(Math.round(12 * this.fontSizeScale))
            .fontColor('#B3ffffff')
          Slider({ value: this.lyricOffsetMs, min: -5000, max: 5000, step: 100 })
            .layoutWeight(1)
            .selectedColor('#FFFFFF')
            .trackColor('#33FFFFFF')
            .blockColor('#FFFFFF')
            .onChange((value: number, mode: SliderChangeMode) => {
              this.onLyricOffsetChange(value, mode)
            })
          Text(this.formatLyricOffset(this.lyricOffsetMs))
            .fontSize(Math.round(12 * this.fontSizeScale))
            .fontColor('#FFFFFF')
            .width(48)
            .textAlign(TextAlign.End)
        }
        .width(StyleConstants.FULL_WIDTH)
        .padding({ left: 8, right: 8, top: 8 })
        // 不能用 HitTestMode.Block：Block 是「自身响应、子节点不响应」，会把滑块的拖拽一起吞掉。
        // 改成空 onClick 吃掉行内点击，避免冒泡到根容器切换控制区显隐，滑块照常可拖
        .onClick(() => {})
        // 自下而上滑入 + 淡入，收起时原路退回（不依赖 animateTo，隐式动画随 transition 走）
        .transition(TransitionEffect.asymmetric(
          TransitionEffect.OPACITY
            .combine(TransitionEffect.translate({ y: 16 }))
            .animation({ duration: 220, curve: Curve.EaseOut }),
          TransitionEffect.OPACITY
            .combine(TransitionEffect.translate({ y: 16 }))
            .animation({ duration: 160, curve: Curve.EaseIn })
        ))
      }

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
