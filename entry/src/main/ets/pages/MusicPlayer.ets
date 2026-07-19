import Logger from '../common/utils/Logger';
import { MediaControlCenter } from '../common/utils/mediautils/MediaControlCenter';
import { PlayerInfoComponent } from '../view/PlayerInfoComponent';
import { WindowUtil } from '../common/utils/WindowUtil';
import { AppStorageKeyConstants } from '../common/constants/AppStorageKeyConstants';

const TAG = '[MusicPlayer]';

@Entry
@Component
struct MusicPlayer {
  @State isShowPlay: boolean = false;
  @State bgOpacity: number = 0;
  @State isLoading: boolean = true;
  @StorageLink(AppStorageKeyConstants.KEY_WINDOW_UTIL) windowUtil: WindowUtil | undefined = undefined;

  async aboutToAppear() {
    try {
      await MediaControlCenter.getInstance().init();
      this.isLoading = false;
      // 页面淡入效果
      this.getUIContext()?.animateTo({ duration: 600, curve: Curve.EaseOut }, () => {
        this.bgOpacity = 1
      })
    } catch (error) {
      Logger.error(TAG, `MediaControlCenter init error: ${JSON.stringify(error)}`);
      this.isLoading = false;
    }
  }

  aboutToDisappear() {
    Logger.info(TAG, 'aboutToDisappear');
  }

  // 页面转场动画：从底部播控条位置散开式展开
  pageTransition() {
    PageTransitionEnter({ duration: 400, curve: Curve.EaseOut })
      .translate({ x: 0, y: 60 })
      .scale({ x: 0.4, y: 0.4 })
      .opacity(0)
    PageTransitionExit({ duration: 350, curve: Curve.EaseIn })
      .translate({ x: 0, y: 60 })
      .scale({ x: 0.4, y: 0.4 })
      .opacity(0)
  }

  build() {
    Stack() {
      if (this.isLoading) {
        // 加载中状态
        Stack() {
          Column()
            .width('100%')
            .height('100%')
            .backgroundColor('#1A1A1A')
          LoadingProgress()
            .width(48)
            .height(48)
            .color('#007DFF')
        }
        .height('100%')
        .width('100%')
      } else {
        PlayerInfoComponent({ isShowPlay: this.isShowPlay, mainWindowInfo: this.windowUtil?.mainWindowInfo })
      }
    }
    .height('100%')
    .width('100%')
    .expandSafeArea()
    .opacity(this.bgOpacity)
  }
}
