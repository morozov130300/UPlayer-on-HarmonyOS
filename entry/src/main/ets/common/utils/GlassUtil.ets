import { uiMaterial } from '@kit.ArkUI'
import { deviceInfo } from '@kit.BasicServicesKit'

// 玻璃风格强度：连续数值滑轨 0-100。
// 0=无模糊，<25=薄，<65=常规，>=65=厚。给用户一个无级细调空间。
export const DEFAULT_GLASS_STYLE: number = 50

// 档位 key（用于辅助函数识别"用户当前大致处于哪一档"，仅做标签/语义用，不参与渲染）
const STYLE_THIN: number = 20
const STYLE_REGULAR: number = 50
const STYLE_THICK: number = 80

// 当前数值处于的档位 key
export function glassStyleBucket(value: number): number {
  if (value < 35) {
    return STYLE_THIN
  }
  if (value < 65) {
    return STYLE_REGULAR
  }
  return STYLE_THICK
}

// 把数值映射到档位 label（"薄"/"常规"/"厚"）
export function glassStyleLabel(value: number): string {
  const bucket: number = glassStyleBucket(value)
  switch (bucket) {
    case STYLE_THIN:
      return '薄'
    case STYLE_THICK:
      return '厚'
    default:
      return '常规'
  }
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

// uiMaterial 沉浸式系统材质对应的档位（API 26+）
export function glassImmersiveStyleFromStrength(value: number): uiMaterial.ImmersiveStyle {
  if (value < 35) {
    return uiMaterial.ImmersiveStyle.THIN
  }
  if (value < 65) {
    return uiMaterial.ImmersiveStyle.REGULAR
  }
  return uiMaterial.ImmersiveStyle.THICK
}

// 平滑版：用分段指数插值替代阶跃，避免滑轨经过 35/65 时产生突跳
// 输出归一化强度 [0, 1]：0=THIN，0.5=REGULAR，1=THICK
function normalizeImmersiveStrength(value: number): number {
  const clamped: number = Math.max(0, Math.min(100, value))
  if (clamped <= 35) {
    // THIN(0) -> REGULAR(0.5) 指数过渡
    const t: number = clamped / 35
    return 0.5 * (Math.exp(3 * t - 1.5) - Math.exp(-1.5)) / (Math.exp(1.5) - Math.exp(-1.5))
  }
  if (clamped <= 65) {
    // REGULAR(0.5) 稳态区间，仅做线性微调避免平台边缘不连续
    const t: number = (clamped - 35) / 30
    return 0.5 + 0.02 * Math.sin(t * Math.PI)
  }
  // REGULAR(0.5) -> THICK(1.0) 指数过渡
  const t: number = (clamped - 65) / 35
  return 0.5 + 0.5 * (Math.exp(3 * t - 1.5) - Math.exp(-1.5)) / (Math.exp(1.5) - Math.exp(-1.5))
}

// 平滑版：根据归一化强度选择 ImmersiveStyle，同时支持无断档的 systemMaterial 回退阈值
export function glassImmersiveStyleFromStrengthSmooth(value: number): uiMaterial.ImmersiveStyle {
  const norm: number = normalizeImmersiveStrength(value)
  if (norm < 0.45) {
    return uiMaterial.ImmersiveStyle.THIN
  }
  if (norm < 0.75) {
    return uiMaterial.ImmersiveStyle.REGULAR
  }
  return uiMaterial.ImmersiveStyle.THICK
}

// API 26+ 才能用 systemMaterial / uiMaterial.ImmersiveMaterial；老设备自动降级
export function isLiquidGlassAvailable(): boolean {
  return deviceInfo.apiAvailable('26.0.0')
}

// 页面级背景只用档位，不开启 interactive 与 lightEffect：
// - interactive 会让所有页面在按下/拖动时产生 Q 弹形变（页面级不需要）
// - lightEffect 会让普通滚动也出现跟手光效（用户未同意，仅 Tab 栏保留）
// 能力不足时返回 undefined，配合 .systemMaterial(undefined) 关闭该效果。
export function createPageGlassMaterial(strength: number): uiMaterial.Material | undefined {
  if (!isLiquidGlassAvailable()) {
    return undefined
  }
  return new uiMaterial.ImmersiveMaterial({
    style: glassImmersiveStyleFromStrength(strength)
  })
}

// 兼容旧数据：从 string key（thin/regular/thick）解析到连续数值
export function glassStyleKeyToStrength(key: string | number | undefined): number {
  if (typeof key === 'number' && !isNaN(key)) {
    return Math.max(0, Math.min(100, key))
  }
  switch (key) {
    case 'thin':
      return STYLE_THIN
    case 'thick':
      return STYLE_THICK
    case 'regular':
    default:
      return STYLE_REGULAR
  }
}