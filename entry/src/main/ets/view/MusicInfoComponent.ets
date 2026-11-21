// ArkUI 26 Beta1: 接口定义变更（误报，本项目已是Stage模型）+ UX视觉布局变更（Text默认开启沉浸式材质，系统行为）
import { BusinessError } from '@kit.BasicServicesKit';
import { AppStorageKeyConstants } from '../common/constants/AppStorageKeyConstants';
import { PlayerConstants } from '../common/constants/PlayerConstants';
import { StyleConstants } from '../common/constants/StyleConstants';
import Logger from '../common/utils/Logger';
import { WindowInfo } from '../common/utils/WindowUtil';
import { SongInfo } from '../model/SongInfo';
import { DataService } from '../service/DataService';
import { extractSongMetadata } from '../service/MetadataTask';
import { loadLyricEntries } from '../service/LyricLoader';
import { LrcEntry } from '../viewmodel/LrcEntry';
import { ControlAreaComponent } from './ControlAreaComponent';

import { AlbumCover } from '../component/AlbumCover';
import { ScaleButton } from '../component/ScaleButton';
import { AudioQualityBadge } from '../component/AudioQualityBadge';

const TAG = 'MusicInfoComponent';

@Component
export struct MusicInfoComponent {
  @Prop mainWindowInfo: WindowInfo;
  // 手机断点下一镜到底启用时，封面由 PlayerFlyingCover 浮层渲染，本页只保留同尺寸透明占位
  @Prop isCoverFloating: boolean = false;
  // 封面区域几何上报（页面级坐标），父组件据此驱动一镜到底插值
  onCoverAreaChange: (area: Area) => void = () => {};
  @StorageLink(AppStorageKeyConstants.KEY_SONG_LIST) songList: SongInfo[] = [];
  @StorageProp(AppStorageKeyConstants.KEY_SELECT_INDEX) @Watch('onSongChange') selectIndex: number = 0;
  // 当前播放歌曲 id：显示信息一律按 id 从全量曲库解析，不依赖队列下标，
  // 避免队列被全量列表覆盖/过滤后下标指向另一首歌导致与播控条不一致
  @StorageProp('uplayer_current_song_id') @Watch('onSongChange') currentSongId: string = '';
  @State isFavorite: boolean = false;
  @StorageLink('uplayer_font_size_scale') fontSizeScale: number = 1.0;
  // 窄屏行内歌词开关（AppStorage 由 DataService.initToAppStorage 预置默认值 true）
  @StorageProp(AppStorageKeyConstants.KEY_NARROW_INLINE_LYRIC) @Watch('onInlineLyricSwitch')
  narrowInlineLyric: boolean = true;
  // 播放进度（毫秒）：行内歌词随进度推进高亮当前行
  @StorageProp(AppStorageKeyConstants.KEY_PROGRESS) @Watch('updateInlineLyricLine') progressMs: number = 0;
  // 每歌歌词偏移：拖动滑条时行内歌词同步跟随
  @StorageLink(AppStorageKeyConstants.KEY_LYRIC_OFFSET_MS) @Watch('updateInlineLyricLine') lyricOffsetMs: number = 0;
  // 歌词引用集合级变化（重新导入覆盖）时重读行内歌词
  @StorageProp(AppStorageKeyConstants.KEY_LYRIC_REVISION) @Watch('loadInlineLyric') lyricRevision: number = 0;
  // 行内歌词当前行文本与加载态：切歌/进度推进时按「进度+每歌偏移」二分定位刷新
  @State inlineLyricText: string = '';
  @State inlineLyricLoading: boolean = false;
  // 行内歌词数据缓存（当前歌曲的完整歌词行），供逐帧进度定位
  private inlineLrcEntries: LrcEntry[] = [];
  private inlineLyricRequestId: number = 0;
  private dataService: DataService = DataService.getInstance()

  aboutToAppear() {
    this.updateFavoriteState()
    this.backfillTrackMetadataIfNeeded()
    this.loadInlineLyric()
  }

  onSongChange(): void {
    this.updateFavoriteState()
    this.backfillTrackMetadataIfNeeded()
    this.loadInlineLyric()
  }

  // 行内歌词开关切换：关闭即清空显示，开启时重新加载当前歌歌词
  onInlineLyricSwitch(): void {
    this.loadInlineLyric()
  }

  // 播放/切歌时实时补齐轨道级元数据（旧库歌曲缺采样率/位深等字段时立即解析）：
  // 只回填技术参数（采样率/位深/编码/码率/文件大小），不触碰可编辑的展示字段；
  // 解析完回写数据库并刷新列表，音质标签随之补全
  private backfillTrackMetadataIfNeeded(): void {
    const song: SongInfo = this.currentSong()
    if (song.id.length === 0) {
      return
    }
    if (song.sampleRate > 0 && song.bitDepth.length > 0 && song.codec.length > 0 && song.effectiveBitrate() > 0) {
      return
    }
    const sourceUri: string = song.uri.length > 0 ? song.uri : song.filePath
    extractSongMetadata(sourceUri).then((record: Record<string, string> | undefined) => {
      if (record === undefined) {
        return
      }
      const target: SongInfo = this.currentSong()
      if (target.id !== song.id) {
        return
      }
      const rateVal: string | undefined = record['sampleRate']
      if (rateVal !== undefined && rateVal.length > 0) {
        const rateNum: number = parseInt(rateVal)
        if (!isNaN(rateNum)) {
          target.sampleRate = rateNum
        }
      }
      const depthVal: string | undefined = record['bitDepth']
      if (depthVal !== undefined && depthVal.length > 0) {
        target.bitDepth = depthVal
      }
      const codecVal: string | undefined = record['codec']
      if (codecVal !== undefined && codecVal.length > 0) {
        target.codec = codecVal
      }
      const bitrateVal: string | undefined = record['bitrate']
      if (bitrateVal !== undefined) {
        const bitrateNum: number = Number(bitrateVal)
        if (bitrateNum > 0) {
          target.bitrate = bitrateNum
        }
      }
      const fileSizeVal: string | undefined = record['fileSize']
      if (fileSizeVal !== undefined) {
        const sizeNum: number = Number(fileSizeVal)
        if (sizeNum > 0) {
          target.fileSize = sizeNum
        }
      }
      this.dataService.updateSongFields(target.id, this.dataService.getSongs())
    }).catch((err: BusinessError) => {
      Logger.warn(TAG, `backfill track metadata failed: ${JSON.stringify(err)}`)
    })
  }

  private currentSong(): SongInfo {
    // 保持对 songList 的渲染依赖（曲库整体刷新时同步重渲染），队列中被过滤掉时回退全量曲库
    return DataService.currentSongFromList(this.songList, this.currentSongId)
  }

  updateFavoriteState() {
    const song: SongInfo = this.currentSong()
    this.isFavorite = song.id.length > 0 && song.isFavorite
  }

  // 窄屏（XS/SM）判定，与 PlayerInfoComponent.isNarrowLayout 同判据
  private isNarrowWidth(): boolean {
    const bp: WidthBreakpoint | undefined = this.mainWindowInfo?.widthBp
    return bp === WidthBreakpoint.WIDTH_SM || bp === WidthBreakpoint.WIDTH_XS
  }

  // ═══ 窄屏行内歌词 ═══
  // 歌词加载：切歌/歌词引用变化时重读（LyricLoader 内存缓存命中时同步返回前次结果，
  // 加载态只在真实读盘期间出现）。开关关闭时不加载也不清数据，重新开启即恢复。
  aboutToDisappear() {
    this.inlineLyricRequestId++
    this.inlineLrcEntries = []
    this.inlineLyricText = ''
  }

  private loadInlineLyric(): void {
    const requestId: number = ++this.inlineLyricRequestId
    const song: SongInfo = this.currentSong()
    if (!this.narrowInlineLyric || !this.isNarrowWidth() || song.id.length === 0) {
      this.inlineLrcEntries = []
      this.inlineLyricText = ''
      this.inlineLyricLoading = false
      return
    }
    loadLyricEntries(song).then((entries: LrcEntry[]) => {
      if (requestId !== this.inlineLyricRequestId) {
        return
      }
      this.inlineLrcEntries = entries
      this.inlineLyricLoading = false
      this.updateInlineLyricLine()
    }).catch(() => {
      if (requestId !== this.inlineLyricRequestId) {
        return
      }
      this.inlineLrcEntries = []
      this.inlineLyricLoading = false
      this.inlineLyricText = ''
    })
  }

  // 进度推进：按「进度 + 每歌偏移」二分定位当前行（与 LrcListView.findShowLine 同算法），
  // 行文本不变时不写 @State，避免逐帧重渲染
  private updateInlineLyricLine(): void {
    if (this.inlineLrcEntries.length === 0) {
      if (this.inlineLyricText.length > 0) {
        this.inlineLyricText = ''
      }
      return
    }
    const offsetMs: number = AppStorage.get<number>(AppStorageKeyConstants.KEY_LYRIC_OFFSET_MS) ?? 0
    const target: number = this.progressMs + offsetMs
    let low: number = 0
    let high: number = this.inlineLrcEntries.length - 1
    let candidate: number = -1
    while (low <= high) {
      const middle: number = Math.floor((low + high) / 2)
      if (this.inlineLrcEntries[middle].lineStartTime <= target) {
        candidate = middle
        low = middle + 1
      } else {
        high = middle - 1
      }
    }
    const text: string = candidate >= 0 ? this.inlineLrcEntries[candidate].lineWords : ''
    if (text !== this.inlineLyricText) {
      this.inlineLyricText = text
    }
  }

  toggleFavorite() {
    const song: SongInfo = this.currentSong()
    if (song.id.length === 0) {
      return
    }
    this.dataService.toggleFavorite(song.id)
    this.isFavorite = !this.isFavorite
    AppStorage.setOrCreate(AppStorageKeyConstants.KEY_IS_FAVORITE, this.isFavorite)
  }

  build() {
    Column() {
      this.CoverInfo()
      this.MusicInfo()
      if (this.isNarrowWidth() && this.narrowInlineLyric) {
        this.InlineLyric()
      }
      Blank()
      ControlAreaComponent({ isNarrow: this.isNarrowWidth() })
    }
    .height(StyleConstants.FULL_HEIGHT)
    .width(StyleConstants.FULL_HEIGHT)
  }

  // 窄屏行内歌词（「更多」面板开关，默认开）：单行歌词紧贴歌名下方，
  // 占据歌名与控制区之间空挡的上沿，其余空间仍由 Blank 吸收、控制区贴底不位移
  @Builder
  InlineLyric() {
    Row() {
      if (this.inlineLyricLoading) {
        Blank()
      } else if (this.inlineLyricText.length > 0) {
        Text(this.inlineLyricText)
          .fontSize(Math.round(14 * this.fontSizeScale))
          .fontColor(Color.White).opacity(0.86)
          .fontWeight(FontWeight.Bold)
          .fontFamily(PlayerConstants.FONT_FAMILY_BOLD)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      } else {
        // 无歌词：与空挡同构，不显示占位文案
        Blank()
      }
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .height(28)
    .margin({ bottom: 8 })
  }

  @Builder
  CoverInfo() {
    Row() {
      Stack() {
        // 封面尺寸与定位容器：左下角音质标签通过与封面同盒的 BottomStart 对齐，只关联封面本身
        Stack({ alignContent: Alignment.BottomStart }) {
          AlbumCover({ song: this.currentSong(), coverWidth: '100%', coverHeight: '100%', coverRadius: 8,
            decodeSize: 640 })
            .width('100%')
            .aspectRatio(1)
            .opacity(this.isCoverFloating ? 0 : 1)

          // 封面左下角音质标签（黑金配色）：无徽章数据时组件自渲染为空；
          // 浮层模式下标签随封面一起搬到 PlayerFlyingCover，本页不再渲染，避免被浮层遮挡或双份
          if (!this.isCoverFloating) {
            AudioQualityBadge({
              song: this.currentSong(),
              fontSizeScale: this.fontSizeScale
            })
              .hitTestBehavior(HitTestMode.None)
          }
        }
        .width('100%')
        .aspectRatio(1)
        .constraintSize({ maxWidth: '100%', maxHeight: '50%' })
        .shadow({ radius: 12, color: 'rgba(0,0,0,0.15)', offsetX: 0, offsetY: 4 })
        .animation({ duration: StyleConstants.ANIMATION_COVER_CROSS_FADE_DURATION, curve: Curve.EaseInOut })
        // 一镜到底起点：把大封面的页面级几何上报给 PlayerInfoComponent
        .onAreaChange((_oldArea: Area, newArea: Area) => {
          this.onCoverAreaChange(newArea)
        })
      }
      .width('100%')
      .constraintSize({ maxWidth: '100%', maxHeight: '50%' })
    }
    .justifyContent(FlexAlign.Center)
    .width('100%')
    // 顶部留白：让「专辑封面 + 歌曲信息」避开左上玻璃返回键（返回键 56vp 高）。
    // 窄屏页容器顶部已有 music_component_top=64vp 内边距：行内歌词开（默认）时下移 16，
    // 为歌名下方的歌词行腾出空间；关闭时下移 32 维持原布局。宽态无页顶内边距，保持 48
    .margin({ top: this.isNarrowWidth() ? (this.narrowInlineLyric ? 16 : 32) : 48 })
  }

  @Builder
  MusicInfo() {
    Row() {
      Column() {
        Row() {
          Text(this.currentSong().title)
            .fontSize(Math.round(24 * this.fontSizeScale))
            .fontColor(Color.White).opacity(0.86)
            .fontWeight(FontWeight.Bold)
            .fontFamily(PlayerConstants.FONT_FAMILY_BOLD)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }

        Row() {
          Text(this.currentSong().artist)
            .textAlign(TextAlign.Start)
            .fontSize(Math.round(16 * this.fontSizeScale))
            .fontColor($r('app.color.play_text_color'))
            .fontFamily(PlayerConstants.FONT_FAMILY_BLACK)
            .fontWeight(FontWeight.Regular)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .padding({ top: 2, bottom: 2 })
      }
      .alignItems(HorizontalAlign.Start)
      .padding({ bottom: 10 })

      ScaleButton({
        pressScale: StyleConstants.PRESS_SCALE,
        hoverScale: StyleConstants.HOVER_SCALE,
        onButtonTap: () => { this.toggleFavorite() }
      }) {
        Image(this.isFavorite ? $r('app.media.ic_public_favor_filled') : $r('app.media.ic_public_favor'))
          .width(26)
          .height(26)
          .fillColor(this.isFavorite ? Color.Red : $r('app.color.play_text_color'))
          .opacity(0.86)
      }
    }
    .width('100%')
    .justifyContent(FlexAlign.SpaceBetween)
    .alignItems(VerticalAlign.Top)
    .margin({ top: $r('app.float.music_info_margin_top') })
  }
}
