import { curves } from '@kit.ArkUI';
import { AppStorageKeyConstants } from '../common/constants/AppStorageKeyConstants';
import { PlayerConstants } from '../common/constants/PlayerConstants';
import { StyleConstants } from '../common/constants/StyleConstants';
import { WindowInfo } from '../common/utils/WindowUtil';
import { SongInfo } from '../model/SongInfo';
import { DataService } from '../service/DataService';
import { ControlAreaComponent } from './ControlAreaComponent';
import { ColorHelper } from '../common/utils/ColorHelper';
import { AlbumCover } from '../component/AlbumCover';

@Component
export struct MusicInfoComponent {
  @State currentTabIndex: number = 0;
  @Prop mainWindowInfo: WindowInfo;
  @StorageLink(AppStorageKeyConstants.KEY_SONG_LIST) songList: SongInfo[] = [];
  @StorageProp(AppStorageKeyConstants.KEY_SELECT_INDEX) @Watch('onSongChange') selectIndex: number = 0;
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

  updateFavoriteState() {
    if (this.songList && this.selectIndex >= 0 && this.selectIndex < this.songList.length) {
      this.isFavorite = this.songList[this.selectIndex].isFavorite
    } else {
      this.isFavorite = false
    }
  }

  toggleFavorite() {
    if (!this.songList || this.selectIndex < 0 || this.selectIndex >= this.songList.length) {
      return
    }
    const song: SongInfo = this.songList[this.selectIndex]
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
    }, 150)
  }

  startGlowAnimation() {
    this.stopGlowAnimation()
    this.glowTimer = setInterval(() => {
      this.getUIContext()?.animateTo({ duration: 3000, curve: Curve.Linear }, () => {
        this.glowRotation = (this.glowRotation + 360) % 360
      })
    }, 3000)
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
          .animation({ duration: 500, curve: Curve.EaseInOut })
        AlbumCover({ song: this.songList && this.selectIndex >= 0 && this.selectIndex < this.songList.length ?
          this.songList[this.selectIndex] : new SongInfo(), coverWidth: '100%', coverHeight: '100%', coverRadius: 8 })
          .width('100%')
          .aspectRatio(1)
          .constraintSize({ maxWidth: '100%', maxHeight: '50%' })
          .shadow({ radius: 12, color: 'rgba(0,0,0,0.15)', offsetX: 0, offsetY: 4 })
          .animation({ duration: 500, curve: Curve.EaseInOut })
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
          Text(this.songList && this.selectIndex >= 0 && this.selectIndex < this.songList.length ?
            this.songList[this.selectIndex].title : '')
            .fontSize(Math.round(24 * this.fontSizeScale))
            .fontColor(Color.White).opacity(0.86)
            .fontWeight(FontWeight.Bold)
            .fontFamily(PlayerConstants.FONT_FAMILY_BOLD)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }

        Row() {
          Text(this.songList && this.selectIndex >= 0 && this.selectIndex < this.songList.length ?
            this.songList[this.selectIndex].artist : '')
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

      SymbolGlyph(this.isFavorite ? $r('sys.symbol.heart_fill') : $r('sys.symbol.heart'))
        .fontSize(26)
        .renderingStrategy(SymbolRenderingStrategy.SINGLE)
        .fontColor([this.isFavorite ? Color.Red : $r('app.color.play_text_color')])
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
