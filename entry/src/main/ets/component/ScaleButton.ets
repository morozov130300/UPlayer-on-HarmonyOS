// 通用按压/悬停缩放按钮容器：按下立即缩小、松开/取消立即弹簧回弹（跟随按压时长，无固定延时），
// 鼠标悬停放大、离开还原，点击行为通过 onButtonTap 回调。
// 受设置「按压动效」开关（AppStorage: uplayer_press_animation）统一控制：关闭时恒为 1.0，
// 不缩放、不悬停、不拦截事件；运行中关闭会立即弹簧复位。
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
  // 小按钮档位默认 0.8/1.1；大块元素（列表行、卡片）调用方传 0.9/1.02
  pressScale: number = 0.8;
  hoverScale: number = 1.1;
  // 大块元素悬停放大观感突兀，可单独关掉悬停只保留按压
  enableHover: boolean = true;
  // 整行/卡片场景：容器撑满父宽度，避免被 Column 包裹后宽度塌陷
  expandWidth: boolean = false;
  // 行内图标按钮场景：拦截命中测试，避免点击同时触发外层行的手势（原 hitTestBehavior(Block)）
  blockHitTest: boolean = false;
  onButtonTap: () => void = () => {
  };
  // 全局「按压动效」开关
  @StorageLink('uplayer_press_animation') @Watch('onPressAnimSwitchChange') pressAnimOn: boolean = false;

  // 按压优先于悬停：按压中返回 pressScale，否则悬停返回 hoverScale，都不满足回 1.0
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
    .width(this.expandWidth ? '100%' : 'auto')
    .hitTestBehavior(this.blockHitTest ? HitTestMode.Block : HitTestMode.Default)
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
    .onClick(() => {
      this.onButtonTap();
    })
  }
}
