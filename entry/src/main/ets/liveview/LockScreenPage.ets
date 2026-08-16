import { AppStorageKeyConstants } from '../common/constants/AppStorageKeyConstants';
import { AVPlayerService } from '../service/AVPlayerService';

@Entry
@Component
struct LockScreenPage {
  @StorageLink('uplayer_current_title') title: string = '';
  @StorageLink('uplayer_current_artist') artist: string = '';
  @StorageLink('uplayer_current_album_art') albumArt: string = '';
  @StorageLink(AppStorageKeyConstants.KEY_IS_PLAY) isPlay: boolean = false;

  private playerService: AVPlayerService = AVPlayerService.getInstance();

  build() {
    Column() {
      Column() {
        if (this.albumArt.length > 0) {
          Image('file://' + this.albumArt)
            .width(120).height(120)
            .borderRadius(12)
            .objectFit(ImageFit.Cover)
        } else {
          Image($r('app.media.ic_public_music'))
            .width(120).height(120)
            .borderRadius(12)
            .fillColor(Color.White)
        }
        Text(this.title.length > 0 ? this.title : '未播放')
          .fontSize(22)
          .fontColor(Color.White)
          .fontWeight(FontWeight.Bold)
          .margin({ top: 16 })
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(this.artist.length > 0 ? this.artist : '未知歌手')
          .fontSize(16)
          .fontColor('#B3FFFFFF')
          .margin({ top: 4 })
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(this.isPlay ? '正在播放' : '已暂停')
          .fontSize(12)
          .fontColor('#80FFFFFF')
          .margin({ top: 8 })
        Row() {
          Button({ type: ButtonType.Circle }) {
            Image($r('app.media.ic_public_play_last'))
              .width(24).height(24)
              .fillColor(Color.White)
          }
          .width(48).height(48)
          .backgroundColor('#33FFFFFF')
          .onClick(() => {
            this.onPlayPrevious();
          })

          Button({ type: ButtonType.Circle }) {
            if (this.isPlay) {
              Image($r('app.media.ic_public_pause'))
                .width(28).height(28)
                .fillColor(Color.White)
            } else {
              Image($r('app.media.ic_public_play'))
                .width(28).height(28)
                .fillColor(Color.White)
            }
          }
          .width(56).height(56)
          .backgroundColor('#33FFFFFF')
          .margin({ left: 24, right: 24 })
          .onClick(() => {
            if (this.isPlay) {
              this.playerService.pause();
            } else {
              this.playerService.resume();
            }
          })

          Button({ type: ButtonType.Circle }) {
            Image($r('app.media.ic_public_play_next'))
              .width(24).height(24)
              .fillColor(Color.White)
          }
          .width(48).height(48)
          .backgroundColor('#33FFFFFF')
          .onClick(() => {
            this.onPlayNext();
          })
        }
        .margin({ top: 24 })
        .justifyContent(FlexAlign.Center)
        .alignItems(VerticalAlign.Center)
      }
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#1A1A1A')
    .justifyContent(FlexAlign.Center)
  }

  private onPlayPrevious(): void {
    this.playerService.playPreviousSong();
  }

  private onPlayNext(): void {
    this.playerService.playNextSong();
  }
}
