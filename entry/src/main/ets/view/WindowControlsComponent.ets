import { window } from '@kit.ArkUI'
import { common } from '@kit.AbilityKit'
import { AppStorageKeyConstants } from '../common/constants/AppStorageKeyConstants'

@Component
export struct WindowControlsComponent {
  @StorageLink(AppStorageKeyConstants.KEY_WINDOW) windowClass: window.Window | undefined = undefined
  @StorageLink(AppStorageKeyConstants.KEY_UI_ABILITY_CONTEXT) abilityContext: common.UIAbilityContext | undefined = undefined

  build() {
    Row({ space: 8 }) {
      SymbolGlyph($r('sys.symbol.minus'))
        .fontSize(16)
        .fontColor([$r('app.color.text_sixty_color')])
        .onClick(() => {
          if (this.windowClass) { this.windowClass.minimize() }
        })
      SymbolGlyph($r('sys.symbol.square'))
        .fontSize(16)
        .fontColor([$r('app.color.text_sixty_color')])
        .onClick(() => {
          if (this.windowClass) {
            this.windowClass.maximize(window.MaximizePresentation.EXIT_IMMERSIVE)
          }
        })
      SymbolGlyph($r('sys.symbol.xmark'))
        .fontSize(16)
        .fontColor([$r('app.color.text_sixty_color')])
        .onClick(() => {
          if (this.abilityContext) { this.abilityContext.terminateSelf() }
        })
    }
    .height('100%')
    .padding({ right: 8 })
    .alignItems(VerticalAlign.Center)
  }
}
