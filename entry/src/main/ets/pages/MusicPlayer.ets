import Logger from '../common/utils/Logger';
import { PlayerInfoComponent } from '../view/PlayerInfoComponent';
import { WindowUtil } from '../common/utils/WindowUtil';
import { AppStorageKeyConstants } from '../common/constants/AppStorageKeyConstants';
import { curves } from '@kit.ArkUI';
import { ColorHelper } from '../common/utils/ColorHelper';

const TAG = '[MusicPlayer]';

@Entry
@Component
struct MusicPlayer {
  /** 是否显示播放状态（传给子组件用） */
  @State isShowPlay: boolean = false;
  /** 页面背景透明度（用于进入时的淡入动画） */
  @State bgOpacity: number = 0;
  /** 是否正在初始化（显示加载中） */
  @State isLoading: boolean = true;
  /** 窗口工具（从 AppStorage 同步，含窗口大小、安全区信息） */
  @StorageLink(AppStorageKeyConstants.KEY_WINDOW_UTIL) windowUtil: WindowUtil | undefined = undefined;
  @StorageLink('uplayer_primary_color') primaryColor: string = '#007DFF';

  /** 页面初始化：初始化媒体引擎 → 取消加载态 → 背景淡入 */
  async aboutToAppear() {
    this.isLoading = false;
    this.getUIContext()?.animateTo({ duration: 600, curve: Curve.EaseOut }, () => {
      this.bgOpacity = 1
    })
  }

  aboutToDisappear() {
    Logger.info(TAG, 'aboutToDisappear');
  }

  /** 页面转场动画：从底部弹性滑入，从底部弹性滑出 */
  pageTransition() {
    PageTransitionEnter({ duration: 500, curve: curves.springMotion(0.6, 0.8) })
      .slide(SlideEffect.Bottom)
      .opacity(0)
    PageTransitionExit({ duration: 400, curve: curves.springMotion(0.7, 0.9) })
      .slide(SlideEffect.Bottom)
      .opacity(0)
  }

  build() {
    Stack() {
      /** 加载中：纯色背景 + LoadingProgress 动画 */
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
        /** 加载完成：显示播放器主内容（封面 + 歌词 + 控制区） */
        PlayerInfoComponent({ isShowPlay: this.isShowPlay, mainWindowInfo: this.windowUtil?.mainWindowInfo })
      }
    }
    .height('100%')
    .width('100%')
    .expandSafeArea()
    .opacity(this.bgOpacity)
  }
}
