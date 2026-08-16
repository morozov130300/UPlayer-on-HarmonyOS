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
  @StorageLink(AppStorageKeyConstants.KEY_WINDOW_UTIL) windowUtil: WindowUtil | undefined = undefined;

  async aboutToAppear() {
    try {
      await MediaControlCenter.getInstance().init();
    } catch (error) {
      Logger.error(TAG, `MediaControlCenter init error: ${JSON.stringify(error)}`);
    }
  }

  aboutToDisappear() {
    Logger.info(TAG, 'aboutToDisappear');
  }

  // 页面转场动画：从底部滑入，返回时向底部滑出
  pageTransition() {
    PageTransitionEnter({ duration: 350, curve: Curve.EaseInOut })
      .slide(SlideEffect.Bottom)
    PageTransitionExit({ duration: 350, curve: Curve.EaseInOut })
      .slide(SlideEffect.Bottom)
  }

  build() {
    Stack() {
      PlayerInfoComponent({ isShowPlay: this.isShowPlay, mainWindowInfo: this.windowUtil?.mainWindowInfo })
    }
    .height('100%')
    .width('100%')
    .expandSafeArea()
  }
}
