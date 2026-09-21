// ArkUI 26 Beta1: 接口定义变更（误报，本项目已是Stage模型）+ UX视觉布局变更（Text默认开启沉浸式材质，系统行为）
import { curves } from '@kit.ArkUI';
import { AppStorageKeyConstants } from '../common/constants/AppStorageKeyConstants';
import { PlayerConstants } from '../common/constants/PlayerConstants';
import { StyleConstants } from '../common/constants/StyleConstants';
import { WindowInfo } from '../common/utils/WindowUtil';
import { SongInfo } from '../model/SongInfo';
import { DataService } from '../service/DataService';
import { ControlAreaComponent } from './ControlAreaComponent';

import { AlbumCover } from '../component/AlbumCover';

@Component
export struct MusicInfoComponent {
  @State currentTabIndex: number = 0;
  @Prop mainWindowInfo: WindowInfo;
  @StorageLink(AppStorageKeyConstants.KEY_SONG_LIST) songList: SongInfo[] = [];
  @StorageProp(AppStorageKeyConstants.KEY_SELECT_INDEX) @Watch('onSongChange') selectIndex: number = 0;
  // 当前播放歌曲 id：显示信息一律按 id 从全量曲库解析，不依赖队列下标，
  // 避免队列被全量列表覆盖/过滤后下标指向另一首歌导致与播控条不一致
  @StorageProp('uplayer_current_song_id') @Watch('onSongChange') currentSongId: string = '';
  @State isShowControl: boolean = false;
  @State isFavorite: boolean = false;
  @State favoriteScale: number = 1.0;
  @StorageLink(AppStorageKeyConstants.KEY_IS_PLAY) isPlay: boolean = false;
  @StorageLink('uplayer_primary_color') primaryColor: string = '#007DFF';
  @StorageLink('uplayer_font_size_scale') fontSizeScale: number = 1.0;
  @State glowRotation: number = 0;
  @State glowTimer: number = -1;
  @State coverArtFailed: boolean = false;
  private dataService: DataService = DataService.getInstance()

  aboutToAppear() {
    this.updateFavoriteState()
    if (this.isPlay) {
      this.startGlowAnimation()
    }
  }

  aboutToDisappear() {
    this.stopGlowAnimation()
  }

  onSongChange(): void {
    this.coverArtFailed = false
    this.updateFavoriteState()
  }

  private currentSong(): SongInfo {
    // 先在播放队列中按 id 查找（保持对 songList 的渲染依赖，曲库整体刷新时同步重渲染），
    // 队列中被过滤掉时回退全量曲库
    if (this.songList !== undefined) {
      for (let i = 0; i < this.songList.length; i++) {
        if (this.songList[i].id === this.currentSongId) {
          return this.songList[i]
        }
      }
    }
    const song: SongInfo | undefined = this.dataService.getSongById(this.currentSongId)
    return song !== undefined ? song : new SongInfo()
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
    this.getUIContext()?.animateTo({ curve: curves.springMotion() }, () => {
      this.favoriteScale = 1.3
    })
    setTimeout(() => {
      this.getUIContext()?.animateTo({ curve: curves.springMotion() }, () => {
        this.favoriteScale = 1.0
      })
    }, StyleConstants.ANIMATION_PRESS_DELAY_LONG)
  }

  startGlowAnimation() {
    this.stopGlowAnimation()
    this.glowTimer = setInterval(() => {
      // 窗口隐藏时跳过本帧灯光推进：角度是 360 循环累加，暂停期间无感知，回前台无缝续转
      if (AppStorage.get<boolean>(AppStorageKeyConstants.KEY_UI_ACTIVE) === false) {
        return
      }
      this.getUIContext()?.animateTo({ duration: StyleConstants.ANIMATION_AMBIENT_GLOW_DURATION, curve: Curve.Linear }, () => {
        this.glowRotation = (this.glowRotation + 360) % 360
      })
    }, StyleConstants.ANIMATION_AMBIENT_GLOW_DURATION)
  }

  stopGlowAnimation() {
    if (this.glowTimer !== -1) {
      clearInterval(this.glowTimer)
      this.glowTimer = -1
    }
  }

  build() {
    Column() {
      this.CoverInfo()
      this.MusicInfo()
      Blank()
      ControlAreaComponent({ mainWindowInfo: this.mainWindowInfo })
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
          .opacity(this.isPlay ? 0.8 : 0)
          .animation({ duration: StyleConstants.ANIMATION_COVER_CROSS_FADE_DURATION, curve: Curve.EaseInOut })
        AlbumCover({ song: this.currentSong(), coverWidth: '100%', coverHeight: '100%', coverRadius: 8,
          decodeSize: 640 })
          .width('100%')
          .aspectRatio(1)
          .constraintSize({ maxWidth: '100%', maxHeight: '50%' })
          .shadow({ radius: 12, color: 'rgba(0,0,0,0.15)', offsetX: 0, offsetY: 4 })
          .animation({ duration: StyleConstants.ANIMATION_COVER_CROSS_FADE_DURATION, curve: Curve.EaseInOut })
      }
      .width('100%')
      .constraintSize({ maxWidth: '100%', maxHeight: '50%' })
    }
    .justifyContent(FlexAlign.Center)
    .width('100%')
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

      Image(this.isFavorite ? $r('app.media.ic_public_favor_filled') : $r('app.media.ic_public_favor'))
        .width(26)
        .height(26)
        .fillColor(this.isFavorite ? Color.Red : $r('app.color.play_text_color'))
        .opacity(0.86)
        .scale({ x: this.favoriteScale, y: this.favoriteScale })
        .onClick(() => { this.toggleFavorite() })
    }
    .width('100%')
    .justifyContent(FlexAlign.SpaceBetween)
    .alignItems(VerticalAlign.Top)
    .margin({ top: $r('app.float.music_info_margin_top') })
  }
}
