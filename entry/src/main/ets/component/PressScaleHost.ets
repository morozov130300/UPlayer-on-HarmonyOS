// 纯缩放缓动宿主：只提供按下缩小 / 松手弹簧回弹 / 可选悬停放大，不接管点击。
// 与 ScaleButton 的区别：不注册 onClick，用于「内部已有 onClick/长按手势/bindPopup」的卡片，
// 只在外层包一层缩放，避免改变内部手势与弹窗的挂载节点。
// 受设置「按压动效」开关（AppStorage: uplayer_press_animation）统一控制。
import { curves } from '@kit.ArkUI';

@Component
export struct PressScaleHost {
  @Builder
  emptyContent() {
  }

  @BuilderParam content: () => void = this.emptyContent;
  @State btnScale: number = 1.0;
  private isPressed: boolean = false;
  private isHovered: boolean = false;
  // 大块元素默认 0.9/1.02；小按钮可传 0.8/1.1
  pressScale: number = 0.9;
  hoverScale: number = 1.02;
  enableHover: boolean = true;
  @StorageLink('uplayer_press_animation') @Watch('onPressAnimSwitchChange') pressAnimOn: boolean = false;

  private targetScale(): number {
    if (!this.pressAnimOn) {
      return 1.0;
    }
    if (this.isPressed) {
      return this.pressScale;
    }
    return (this.enableHover && this.isHovered) ? this.hoverScale : 1.0;
  }

  // 运行中关闭开关：丢弃按压/悬停态并弹簧复位，避免卡在缩放中间值
  onPressAnimSwitchChange(): void {
    if (this.pressAnimOn) {
      return;
    }
    this.isPressed = false;
    this.isHovered = false;
    if (this.btnScale === 1.0) {
      return;
    }
    this.getUIContext()?.animateTo({ curve: curves.springMotion() }, () => {
      this.btnScale = 1.0;
    });
  }

  build() {
    Column() {
      this.content()
    }
    .width('100%')
    .scale({ x: this.btnScale, y: this.btnScale })
    .onTouch((event: TouchEvent) => {
      if (!this.pressAnimOn) {
        return;
      }
      if (event.type === TouchType.Down) {
        this.isPressed = true;
        this.getUIContext()?.animateTo({ duration: 100, curve: Curve.EaseOut }, () => {
          this.btnScale = this.pressScale;
        });
      } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
        this.isPressed = false;
        this.getUIContext()?.animateTo({ curve: curves.springMotion() }, () => {
          this.btnScale = this.targetScale();
        });
      }
    })
    .onHover((isHover: boolean) => {
      if (!this.pressAnimOn || !this.enableHover) {
        return;
      }
      if (this.isHovered === isHover) {
        return;
      }
      this.isHovered = isHover;
      if (!this.isPressed) {
        this.getUIContext()?.animateTo({ curve: curves.springMotion() }, () => {
          this.btnScale = this.targetScale();
        });
      }
    })
  }
}
