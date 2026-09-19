import { uiMaterial } from '@kit.ArkUI'
import { deviceInfo } from '@kit.BasicServicesKit'

// 玻璃风格强度：连续数值滑轨 0-100。
// 0=完全关闭玻璃，1-100 均匀映射官方 ImmersiveStyle 五档：
// 1-20=ULTRA_THIN，21-40=THIN，41-60=REGULAR，61-80=THICK，81-100=ULTRA_THICK。
export const DEFAULT_GLASS_STYLE: number = 50

// 0=完全关闭玻璃（不挂 systemMaterial，无兜底模糊）
export function isGlassOff(value: number): boolean {
  return value <= 0
}

// backgroundBlurStyle 用的 BlurStyle 枚举（API 7+，所有设备可用）
export function glassBlurStyleFromStrength(value: number): BlurStyle {
  if (value < 15) {
    return BlurStyle.NONE
  }
  if (value < 35) {
    return BlurStyle.Thin
  }
  if (value < 65) {
    return BlurStyle.Regular
  }
  return BlurStyle.Thick
}

// uiMaterial 沉浸式系统材质对应的档位（API 26+）：
// 1-100 五等分映射官方 ImmersiveStyle 全部五档；0 由 isGlassOff 单独处理
export function glassImmersiveStyleFromStrength(value: number): uiMaterial.ImmersiveStyle {
  if (value <= 20) {
    return uiMaterial.ImmersiveStyle.ULTRA_THIN
  }
  if (value <= 40) {
    return uiMaterial.ImmersiveStyle.THIN
  }
  if (value <= 60) {
    return uiMaterial.ImmersiveStyle.REGULAR
  }
  if (value <= 80) {
    return uiMaterial.ImmersiveStyle.THICK
  }
  return uiMaterial.ImmersiveStyle.ULTRA_THICK
}

// API 26+ 才能用 systemMaterial / uiMaterial.ImmersiveMaterial；老设备自动降级
export function isLiquidGlassAvailable(): boolean {
  return deviceInfo.apiAvailable('26.0.0')
}

// 页面级背景只用档位，不开启 interactive 与 lightEffect：
// - interactive 会让所有页面在按下/拖动时产生 Q 弹形变（页面级不需要）
// - lightEffect 会让普通滚动也出现跟手光效（用户未同意，仅 Tab 栏保留）
// 能力不足或用户关闭玻璃时返回 undefined，配合 .systemMaterial(undefined) 关闭该效果。
export function createPageGlassMaterial(strength: number): uiMaterial.Material | undefined {
  if (!isLiquidGlassAvailable() || isGlassOff(strength)) {
    return undefined
  }
  return new uiMaterial.ImmersiveMaterial({
    style: glassImmersiveStyleFromStrength(strength)
  })
}

// Tab 栏液态玻璃材质的统一构造工厂：Index 真实 Tab 栏与设置页预览器必须共用此函数，
// 保证预览效果与真实渲染一致（style/interactive/lightEffect/colorInvert/applyShadow 全参数）。
// lightColor 为 undefined 时关闭 lightEffect；能力不足或玻璃关闭返回 undefined。
export function createTabGlassMaterial(strength: number, interactive: boolean,
  lightColor: string | undefined, colorInvert: boolean, applyShadow: boolean): uiMaterial.Material | undefined {
  if (!isLiquidGlassAvailable() || isGlassOff(strength)) {
    return undefined
  }
  return new uiMaterial.ImmersiveMaterial({
    style: glassImmersiveStyleFromStrength(strength),
    interactive: interactive,
    lightEffect: lightColor !== undefined ? { color: lightColor } : undefined,
    colorInvert: colorInvert,
    applyShadow: applyShadow
  })
}
