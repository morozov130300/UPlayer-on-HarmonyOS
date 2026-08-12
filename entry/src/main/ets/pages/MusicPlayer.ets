import Logger from '../common/utils/Logger';
import { PlayerInfoComponent } from '../view/PlayerInfoComponent';
import { WindowUtil } from '../common/utils/WindowUtil';
import { AppStorageKeyConstants } from '../common/constants/AppStorageKeyConstants';
import { curves } from '@kit.ArkUI';
import { ColorHelper } from '../common/utils/ColorHelper';
import { ShareService } from '../service/ShareService';
import { AVPlayerService } from '../service/AVPlayerService';
import { SongInfo } from '../model/SongInfo';
import { KeyCode } from '@kit.InputKit';

const TAG = '[MusicPlayer]';

@Entry
@Component
struct MusicPlayer {
  @State isShowPlay: boolean = false;
  @State bgOpacity: number = 0;
  @State isLoading: boolean = true;
  @StorageLink(AppStorageKeyConstants.KEY_WINDOW_UTIL) windowUtil: WindowUtil | undefined = undefined;
  @StorageLink('uplayer_primary_color') primaryColor: string = '#007DFF';
  @StorageLink('uplayer_display_size_scale') displaySizeScale: number = 1.0;
  @StorageLink(AppStorageKeyConstants.KEY_IS_PLAY) isPlaying: boolean = false;
  private shareService: ShareService = ShareService.getInstance();
  private avPlayerService: AVPlayerService = AVPlayerService.getInstance();

  async aboutToAppear() {
    this.isLoading = false;
    this.shareService.registerListeners('player');
    this.getUIContext()?.animateTo({ duration: 600, curve: Curve.EaseOut }, () => {
      this.bgOpacity = 1
    })
  }

  aboutToDisappear() {
    Logger.info(TAG, 'aboutToDisappear');
    this.shareService.unregisterListeners();
  }

  onPageHide(): void {
    this.shareService.unregisterListeners();
  }

  pageTransition() {
    PageTransitionEnter({ duration: 500, curve: curves.springMotion(0.6, 0.8) })
      .slide(SlideEffect.Bottom)
      .opacity(0)
    PageTransitionExit({ duration: 400, curve: curves.springMotion(0.7, 0.9) })
      .slide(SlideEffect.Bottom)
      .opacity(0)
  }

  private handleKeyEvent(event: KeyEvent): boolean {
    if (event.type !== KeyType.Down) {
      return false;
    }
    if (event.keyCode === KeyCode.KEYCODE_SPACE) {
      if (this.isPlaying) {
        this.avPlayerService.pause();
      } else {
        this.avPlayerService.resume();
      }
      return true;
    }
    if (event.keyCode === KeyCode.KEYCODE_DPAD_LEFT) {
      this.playAdjacentSong(false);
      return true;
    }
    if (event.keyCode === KeyCode.KEYCODE_DPAD_RIGHT) {
      this.playAdjacentSong(true);
      return true;
    }
    return false;
  }

  private playAdjacentSong(isNext: boolean): void {
    const songList: SongInfo[] | undefined = AppStorage.get(AppStorageKeyConstants.KEY_SONG_LIST);
    if (songList === undefined || songList.length === 0) {
      return;
    }
    const currentIndex: number = AppStorage.get<number>(AppStorageKeyConstants.KEY_SELECT_INDEX) ?? 0;
    let targetIndex: number = isNext ? currentIndex + 1 : currentIndex - 1;
    if (targetIndex >= songList.length) {
      targetIndex = 0;
    } else if (targetIndex < 0) {
      targetIndex = songList.length - 1;
    }
    const song: SongInfo = songList[targetIndex];
    AppStorage.setOrCreate(AppStorageKeyConstants.KEY_SELECT_INDEX, targetIndex);
    AppStorage.setOrCreate('uplayer_current_title', song.title.length > 0 ? song.title : song.name);
    AppStorage.setOrCreate('uplayer_current_artist', song.artist);
    AppStorage.setOrCreate('uplayer_current_album_art', song.albumArtPath);
    this.avPlayerService.play(song.uri.length > 0 ? song.uri : song.filePath);
  }

  build() {
    Stack() {
      if (this.isLoading) {
        Stack() {
          Column()
            .width('100%')
            .height('100%')
            .backgroundColor('#1A1A1A')
          LoadingProgress()
            .width(48)
            .height(48)
            .color(this.primaryColor)
        }
        .height('100%')
        .width('100%')
      } else {
        PlayerInfoComponent({ isShowPlay: this.isShowPlay, mainWindowInfo: this.windowUtil?.mainWindowInfo, sizeScale: this.displaySizeScale })
      }
    }
    .height('100%')
    .width('100%')
    .expandSafeArea()
    .opacity(this.bgOpacity)
    .focusable(true)
    .defaultFocus(true)
    .onKeyEvent((event: KeyEvent): boolean => this.handleKeyEvent(event))
  }
}
