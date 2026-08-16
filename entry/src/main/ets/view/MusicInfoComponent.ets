import { curves } from '@kit.ArkUI';
import { AppStorageKeyConstants } from '../common/constants/AppStorageKeyConstants';
import { PlayerConstants } from '../common/constants/PlayerConstants';
import { StyleConstants } from '../common/constants/StyleConstants';
import { WindowInfo } from '../common/utils/WindowUtil';
import { SongInfo } from '../model/SongInfo';
import { ControlAreaComponent } from './ControlAreaComponent';

@Component
export struct MusicInfoComponent {
  @State currentTabIndex: number = 0;
  @Prop mainWindowInfo: WindowInfo;
  @Prop isReverse: boolean = false;
  @StorageLink(AppStorageKeyConstants.KEY_SONG_LIST) songList: SongInfo[] = [];
  @StorageProp(AppStorageKeyConstants.KEY_SELECT_INDEX) selectIndex: number = 0;
  @State isShowControl: boolean = false;
  @StorageLink(AppStorageKeyConstants.KEY_IS_FAVORITE) isFavorite: boolean = false;
  @State favoriteScale: number = 1.0;
  @StorageLink(AppStorageKeyConstants.KEY_IS_PLAY) isPlay: boolean = false;
  @State glowRotation: number = 0;
  @State glowTimer: number = -1;

  build() {
    Column() {
      this.CoverInfo()
      this.MusicInfo()
      Blank()
      ControlAreaComponent({ isReverse: this.isReverse, mainWindowInfo: this.mainWindowInfo })
    }
    .height(StyleConstants.FULL_HEIGHT)
    .width(StyleConstants.FULL_HEIGHT)
  }

  aboutToAppear() {
    if (this.isPlay) {
      this.startGlowAnimation();
    }
  }

  aboutToDisappear() {
    this.stopGlowAnimation();
  }

  startGlowAnimation() {
    this.stopGlowAnimation();
    this.glowTimer = setInterval(() => {
      this.getUIContext()?.animateTo({ duration: 3000, curve: Curve.Linear }, () => {
        this.glowRotation = (this.glowRotation + 360) % 360;
      });
    }, 3000);
  }

  stopGlowAnimation() {
    if (this.glowTimer !== -1) {
      clearInterval(this.glowTimer);
      this.glowTimer = -1;
    }
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
        Column()
          .width('101%')
          .aspectRatio(1)
          .borderRadius(9)
          .shadow({
            radius: this.isPlay ? 30 : 15,
            color: this.isPlay ? '#44007DFF' : $r('app.color.shadow_color'),
            offsetX: 0, offsetY: 0
          })
          .animation({ duration: 800, curve: Curve.EaseInOut })
        Image(this.songList && this.selectIndex >= 0 && this.selectIndex < this.songList.length &&
          this.songList[this.selectIndex].albumArtPath.length > 0 ?
          this.songList[this.selectIndex].albumArtPath : $r('app.media.ic_public_music'))
          .width('100%')
          .aspectRatio(1)
          .borderRadius(8)
          .constraintSize({ maxWidth: '100%', maxHeight: '50%' })
          .shadow({ radius: $r('app.float.shadow_radius'), color: $r('app.color.shadow_color'), offsetX: 0, offsetY: 8 })
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
            .fontSize($r('app.float.title_font_play'))
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
            .fontSize(16)
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
        .fontColor([this.isFavorite ? Color.Red : Color.White])
        .opacity(0.86)
        .scale({ x: this.favoriteScale, y: this.favoriteScale })
        .onClick(() => {
          this.isFavorite = !this.isFavorite;
          this.getUIContext()?.animateTo({ curve: curves.springMotion() }, () => {
            this.favoriteScale = 1.3;
          });
          setTimeout(() => {
            this.getUIContext()?.animateTo({ curve: curves.springMotion() }, () => {
              this.favoriteScale = 1.0;
            });
          }, 150);
        })
    }
    .width('100%')
    .justifyContent(FlexAlign.SpaceBetween)
    .alignItems(VerticalAlign.Top)
    .margin({ top: $r('app.float.music_info_margin_top') })
  }
}
