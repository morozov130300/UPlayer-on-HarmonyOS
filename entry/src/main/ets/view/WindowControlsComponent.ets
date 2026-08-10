import { window } from '@kit.ArkUI'
import { common } from '@kit.AbilityKit'
import { AppStorageKeyConstants } from '../common/constants/AppStorageKeyConstants'

@Component
export struct WindowControlsComponent {
  @StorageLink(AppStorageKeyConstants.KEY_WINDOW) windowClass: window.Window | undefined = undefined
  @StorageLink(AppStorageKeyConstants.KEY_UI_ABILITY_CONTEXT) abilityContext: common.UIAbilityContext | undefined = undefined

  build() {
    Row({ space: 4 }) {
      Row() {
        SymbolGlyph($r('sys.symbol.minus'))
          .fontSize(14)
          .fontColor([$r('app.color.text_sixty_color')])
      }
      .width(36).height(28)
      .borderRadius(4)
      .justifyContent(FlexAlign.Center)
      .alignItems(VerticalAlign.Center)
      .hoverEffect(HoverEffect.Highlight)
      .onClick(() => {
        if (this.windowClass) { this.windowClass.minimize() }
      })
      Row() {
        SymbolGlyph($r('sys.symbol.square'))
          .fontSize(12)
          .fontColor([$r('app.color.text_sixty_color')])
      }
      .width(36).height(28)
      .borderRadius(4)
      .justifyContent(FlexAlign.Center)
      .alignItems(VerticalAlign.Center)
      .hoverEffect(HoverEffect.Highlight)
      .onClick(() => {
        if (this.windowClass) {
          this.windowClass.maximize(window.MaximizePresentation.EXIT_IMMERSIVE)
        }
      })
      Row() {
        SymbolGlyph($r('sys.symbol.xmark'))
          .fontSize(14)
          .fontColor([$r('app.color.text_sixty_color')])
      }
      .width(36).height(28)
      .borderRadius(4)
      .justifyContent(FlexAlign.Center)
      .alignItems(VerticalAlign.Center)
      .hoverEffect(HoverEffect.Highlight)
      .onClick(() => {
        if (this.abilityContext) { this.abilityContext.terminateSelf() }
      })
    }
  }
}
