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
import { ControlAreaComponent } from './ControlAreaComponent';

import { AlbumCover } from '../component/AlbumCover';
import { ScaleButton } from '../component/ScaleButton';
import { audioQualityBadgeText } from '../common/utils/AudioQualityUtil';

const TAG = 'MusicInfoComponent';

@Component
export struct MusicInfoComponent {
  @Prop mainWindowInfo: WindowInfo;
  // 手机断点下一镜到底启用时，封面由 PlayerFlyingCover 浮层渲染，本页只保留同尺寸透明占位
  @Prop isCoverFloating: boolean = false;
  @StorageLink(AppStorageKeyConstants.KEY_SONG_LIST) songList: SongInfo[] = [];
  @StorageProp(AppStorageKeyConstants.KEY_SELECT_INDEX) @Watch('onSongChange') selectIndex: number = 0;
  // 当前播放歌曲 id：显示信息一律按 id 从全量曲库解析，不依赖队列下标，
  // 避免队列被全量列表覆盖/过滤后下标指向另一首歌导致与播控条不一致
  @StorageProp('uplayer_current_song_id') @Watch('onSongChange') currentSongId: string = '';
  @State isFavorite: boolean = false;
  @StorageLink(AppStorageKeyConstants.KEY_IS_PLAY) isPlay: boolean = false;
  @StorageLink('uplayer_font_size_scale') fontSizeScale: number = 1.0;
  @State glowRotation: number = 0;
  private dataService: DataService = DataService.getInstance()

  aboutToAppear() {
    this.updateFavoriteState()
    this.backfillTrackMetadataIfNeeded()
    if (this.isPlay) {
      this.startGlowAnimation()
    }
  }

  aboutToDisappear() {
    this.stopGlowAnimation()
  }

  onSongChange(): void {
    this.updateFavoriteState()
    this.backfillTrackMetadataIfNeeded()
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

  toggleFavorite() {
    const song: SongInfo = this.currentSong()
    if (song.id.length === 0) {
      return
    }
    this.dataService.toggleFavorite(song.id)
    this.isFavorite = !this.isFavorite
    AppStorage.setOrCreate(AppStorageKeyConstants.KEY_IS_FAVORITE, this.isFavorite)
  }

  startGlowAnimation() {
    this.stopGlowAnimation()
    // 官方无限循环动画：360°/ANIMATION_AMBIENT_GLOW_DURATION 匀速旋转，
    // 窗口隐藏时 vsync 停止即自动冻结，回前台无缝续转
    this.getUIContext()?.animateTo({
      duration: StyleConstants.ANIMATION_AMBIENT_GLOW_DURATION,
      curve: Curve.Linear,
      iterations: -1
    }, () => {
      this.glowRotation = this.glowRotation + 360;
    })
  }

  stopGlowAnimation() {
    // 用 0 时长动画取消无限动画；渐变光晕 360° 循环对称，回到基值视觉无缝
    this.getUIContext()?.animateTo({ duration: 0 }, () => {
      this.glowRotation = this.glowRotation % 360;
    })
  }

  build() {
    Column() {
      this.CoverInfo()
      this.MusicInfo()
      Blank()
      ControlAreaComponent()
    }
    .height(StyleConstants.FULL_HEIGHT)
    .width(StyleConstants.FULL_HEIGHT)
  }

  @Builder
  CoverInfo() {
    Row() {
      Stack() {
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
          .opacity(this.isPlay && !this.isCoverFloating ? 0.8 : 0)
          .animation({ duration: StyleConstants.ANIMATION_COVER_CROSS_FADE_DURATION, curve: Curve.EaseInOut })
        // 封面尺寸与定位容器：左下角音质标签通过与封面同盒的 BottomStart 对齐，只关联封面本身
        Stack({ alignContent: Alignment.BottomStart }) {
          AlbumCover({ song: this.currentSong(), coverWidth: '100%', coverHeight: '100%', coverRadius: 8,
            decodeSize: 640 })
            .width('100%')
            .aspectRatio(1)
            .opacity(this.isCoverFloating ? 0 : 1)

          // 封面左下角音质标签（码率/编码格式）：半透明黑底白字小胶囊，无码率数据时不渲染
          // 浮层模式下标签随封面一起搬到 PlayerFlyingCover，本页不再渲染，避免被浮层遮挡或双份
          if (!this.isCoverFloating && audioQualityBadgeText(this.currentSong()).length > 0) {
            Row() {
              Text(audioQualityBadgeText(this.currentSong()))
                .fontSize(Math.round(10 * this.fontSizeScale))
                .fontColor(Color.White)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .constraintSize({ maxWidth: '70%' })
            }
            .padding({ left: 6, right: 6, top: 3, bottom: 3 })
            .borderRadius(8)
            .backgroundColor('rgba(0, 0, 0, 0.45)')
            .margin({ left: 8, bottom: 8 })
            .hitTestBehavior(HitTestMode.None)
          }
        }
        .width('100%')
        .aspectRatio(1)
        .constraintSize({ maxWidth: '100%', maxHeight: '50%' })
        .shadow({ radius: 12, color: 'rgba(0,0,0,0.15)', offsetX: 0, offsetY: 4 })
        .animation({ duration: StyleConstants.ANIMATION_COVER_CROSS_FADE_DURATION, curve: Curve.EaseInOut })
        // 一镜到底起点：PlayerInfoComponent 通过该 id 测量大封面矩形
        .id('cover_origin')
      }
      .width('100%')
      .constraintSize({ maxWidth: '100%', maxHeight: '50%' })
    }
    .justifyContent(FlexAlign.Center)
    .width('100%')
    // 顶部留白：让「专辑封面 + 歌曲信息」整体下移，避开左上玻璃返回键（返回键 56vp 高，
    // 宽态内容上边距 24vp 时封面顶会顶进返回键区域），下移 48vp 后封面顶低于返回键底并留缝
    .margin({ top: 48 })
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
        pressScale: 0.8,
        hoverScale: 1.1,
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
