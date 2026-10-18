// 通用按压/悬停缩放按钮容器：按下立即缩小、松开/取消立即弹簧回弹（跟随按压时长，无固定延时），
// 鼠标悬停放大、离开还原，点击行为通过 onButtonTap 回调
import { curves } from '@kit.ArkUI';

@Component
export struct ScaleButton {
  @Builder
  emptyContent() {
  }

  @BuilderParam content: () => void = this.emptyContent;
  @State btnScale: number = 1.0;
  private isPressed: boolean = false;
  private isHovered: boolean = false;
  pressScale: number = 0.8;
  hoverScale: number = 1.1;
  onButtonTap: () => void = () => {
  };

  private targetScale(): number {
    if (this.isPressed) {
      return this.pressScale;
    }
    return this.isHovered ? this.hoverScale : 1.0;
  }

  build() {
    Column() {
      this.content()
    }
    .scale({ x: this.btnScale, y: this.btnScale })
    .onTouch((event: TouchEvent) => {
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
    .onClick(() => {
      this.onButtonTap();
    })
  }
}
