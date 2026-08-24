import { uiMaterial } from '@kit.ArkUI'
import { deviceInfo } from '@kit.BasicServicesKit'

// 玻璃风格 key 与档位映射（与 SettingsDetailPage 中的玻璃风格选择项保持一致）
// 注意：设置项的 label 是面向用户的描述，value 才是存储值；这里用 value 字符串做映射。
const STYLE_THIN: string = 'thin'
const STYLE_REGULAR: string = 'regular'
const STYLE_THICK: string = 'thick'
export const DEFAULT_GLASS_STYLE: string = STYLE_REGULAR

export const GLASS_STYLE_OPTIONS: string[] = [STYLE_THIN, STYLE_REGULAR, STYLE_THICK]

// 严格 ArkTS 不允许裸对象字面量、也不允许对类做动态索引访问；
// 用显式函数 + 字符串字面量匹配代替 GLASS_STYLE_LABELS[opt] 风格的索引。
export function glassStyleLabel(key: string): string {
  switch (key) {
    case STYLE_THIN:
      return '薄'
    case STYLE_THICK:
      return '厚'
    default:
      return '常规'
  }
}

// backgroundBlurStyle 用的 BlurStyle 枚举（API 7+，所有设备可用）
export function glassBlurStyleFromKey(key: string): BlurStyle {
  switch (key) {
    case STYLE_THIN:
      return BlurStyle.Thin
    case STYLE_THICK:
      return BlurStyle.Thick
    default:
      return BlurStyle.Regular
  }
}

// uiMaterial 沉浸式系统材质对应的档位（API 26+）
export function glassImmersiveStyleFromKey(key: string): uiMaterial.ImmersiveStyle {
  switch (key) {
    case STYLE_THIN:
      return uiMaterial.ImmersiveStyle.THIN
    case STYLE_THICK:
      return uiMaterial.ImmersiveStyle.THICK
    default:
      return uiMaterial.ImmersiveStyle.REGULAR
  }
}

// API 26+ 才能用 systemMaterial / uiMaterial.ImmersiveMaterial；老设备自动降级
export function isLiquidGlassAvailable(): boolean {
  return deviceInfo.apiAvailable('26.0.0')
}

// 构造一个用于页面级背景的液态玻璃材质（interactive + lightEffect 全开）。
// 不可用时返回 undefined，配合 .systemMaterial(undefined) 关闭该效果。
export function createPageGlassMaterial(styleKey: string): uiMaterial.Material | undefined {
  if (!isLiquidGlassAvailable()) {
    return undefined
  }
  return new uiMaterial.ImmersiveMaterial({
    style: glassImmersiveStyleFromKey(styleKey),
    interactive: true,
    lightEffect: { color: undefined }
  })
}