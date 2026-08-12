import Logger from '../common/utils/Logger';
import { PlayerInfoComponent } from '../view/PlayerInfoComponent';
import { WindowUtil } from '../common/utils/WindowUtil';
import { AppStorageKeyConstants } from '../common/constants/AppStorageKeyConstants';
import { curves } from '@kit.ArkUI';
import { ColorHelper } from '../common/utils/ColorHelper';
import { deviceInfo } from '@kit.BasicServicesKit';
import { WindowControlsComponent } from '../view/WindowControlsComponent';
import { ShareService } from '../service/ShareService';

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
  private isPC: boolean = deviceInfo.deviceType === '2in1';
  private shareService: ShareService = ShareService.getInstance();
  @StorageLink(AppStorageKeyConstants.KEY_TOP_HEIGHT) topSafeHeight: number = 0;

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

  build() {
    Stack({ alignContent: Alignment.TopEnd }) {
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

      if (this.isPC) {
        Row() {
          WindowControlsComponent()
        }
        .padding({ top: this.topSafeHeight + 4, right: 8 })
      }
    }
    .height('100%')
    .width('100%')
    .expandSafeArea()
    .opacity(this.bgOpacity)
  }
}
