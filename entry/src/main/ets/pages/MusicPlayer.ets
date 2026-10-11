import Logger from '../common/utils/Logger';
import { PlayerInfoComponent } from '../view/PlayerInfoComponent';
import { GlassBackButton } from '../view/GlassBackButton';
import { WindowUtil } from '../common/utils/WindowUtil';
import { AppStorageKeyConstants } from '../common/constants/AppStorageKeyConstants';
import { curves } from '@kit.ArkUI';

import { AVPlayerService } from '../service/AVPlayerService';
import { KeyCode } from '@kit.InputKit';
import { StyleConstants } from '../common/constants/StyleConstants';

const TAG = '[MusicPlayer]';

@Entry
@Component
struct MusicPlayer {
  @State isShowPlay: boolean = false;
  @State bgOpacity: number = 1;
  @State isLoading: boolean = true;
  @StorageLink(AppStorageKeyConstants.KEY_WINDOW_UTIL) windowUtil: WindowUtil | undefined = undefined;
  @StorageLink('uplayer_primary_color') primaryColor: string = '#007DFF';
  @StorageLink(AppStorageKeyConstants.KEY_IS_PLAY) isPlaying: boolean = false;
  @StorageLink(AppStorageKeyConstants.KEY_TOP_HEIGHT) topHeight: number = 0;
  private avPlayerService: AVPlayerService = AVPlayerService.getInstance();
  // 返回按钮玻璃材质只在「Navigation 标题栏」生效区渲染；用空路由栈把本页套进
  // Navigation 仅为取得玻璃生效区，实际返回仍走 router（playerGlassTitleBar.onBack）
  private navStack: NavPathStack = new NavPathStack();

  async aboutToAppear() {
    this.isLoading = false;
  }

  aboutToDisappear() {
    Logger.info(TAG, 'aboutToDisappear');
  }

  pageTransition() {
    PageTransitionEnter({ duration: StyleConstants.ANIMATION_PAGE_ENTER_DURATION, curve: curves.springMotion(0.6, 0.8) })
      .slide(SlideEffect.Bottom)
    PageTransitionExit({ duration: StyleConstants.ANIMATION_PAGE_EXIT_DURATION, curve: curves.springMotion(0.7, 0.9) })
      .slide(SlideEffect.Bottom)
  }

  private handleKeyEvent(event: KeyEvent): boolean {
    if (event.type !== KeyType.Down) {
      return false;
    }
    if (event.keyCode === KeyCode.KEYCODE_ESCAPE) {
      this.getUIContext()?.getRouter().back();
      return true;
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
    if (isNext) {
      this.avPlayerService.playNextSong();
    } else {
      this.avPlayerService.playPreviousSong();
    }
  }

  // 玻璃标题栏：把返回键（GlassBackButton 自带 systemMaterial）放进 Navigation 标题栏生效区 → 出真玻璃。
  // 标题栏自身不设材质（背景透明），玻璃区域限定在返回键圆形上（功耗友好，避免与背景图大面积材质嵌套）。
  // 返回键定位沿用原 PlayerInfoComponent：左 8vp、顶部 topHeight（状态栏高度）。
  @Builder
  playerGlassTitleBar() {
    Row() {
      GlassBackButton({
        clickSize: 56,
        iconSize: 18,
        iconColor: Color.White,
        iconOpacity: 0.8,
        onBack: () => {
          this.getUIContext()?.getRouter().back()
        }
      })
      Blank()
    }
    .width('100%')
    .padding({ left: 8, top: this.topHeight })
    .alignItems(VerticalAlign.Center)
    .backgroundColor(Color.Transparent)
  }

  build() {
    Navigation(this.navStack) {
      Stack() {
        if (this.isLoading) {
          Stack() {
            Column()
              .width('100%')
              .height('100%')
              .backgroundColor('#000000')
            LoadingProgress()
              .width(48)
              .height(48)
              .color(this.primaryColor)
          }
          .height('100%')
          .width('100%')
        } else {
          PlayerInfoComponent({
            isShowPlay: this.isShowPlay,
            mainWindowInfo: this.windowUtil?.mainWindowInfo,
            showBackButton: false
          })
          .width('100%')
          .height('100%')
        }
      }
      .height('100%')
      .width('100%')
      .backgroundColor(Color.Black)
      .expandSafeArea()
      .opacity(this.bgOpacity)
    }
    .title({
      builder: this.playerGlassTitleBar,
      height: this.topHeight + 56
    }, {
      backgroundColor: Color.Transparent,
      barStyle: BarStyle.STACK
    })
    .hideBackButton(true)
    .hideTitleBar(false)
    .mode(NavigationMode.Stack)
    .width('100%')
    .height('100%')
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP])
    .onKeyEvent((event: KeyEvent): boolean => this.handleKeyEvent(event))
  }
}
