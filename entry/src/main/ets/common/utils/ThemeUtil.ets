import { uiAppearance } from '@kit.ArkUI'

// 统一的有效深色模式判定：themeMode 显式指定时直接返回，
// 跟随系统时实时查询系统深色模式（uiAppearance.getDarkMode）。
// 全工程深色判定必须走本函数，禁止各组件自行实现。
export function isDarkThemeEffective(themeMode: string): boolean {
  if (themeMode === 'dark') {
    return true
  }
  if (themeMode === 'light') {
    return false
  }
  try {
    return uiAppearance.getDarkMode() === uiAppearance.DarkMode.ALWAYS_DARK
  } catch (e) {
    return false
  }
}
