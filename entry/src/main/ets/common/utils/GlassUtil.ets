import { uiMaterial } from '@kit.ArkUI'
import { deviceInfo } from '@kit.BasicServicesKit'

// 玻璃风格强度：固定 6 档滑轨（0=关闭玻璃 + 官方 ImmersiveStyle 五档）。
// 0=完全关闭玻璃；20/40/60/80/100 依次对应
// ULTRA_THIN / THIN / REGULAR / THICK / ULTRA_THICK。
export const DEFAULT_GLASS_STYLE: number = 50

// 玻璃厚度滑轨的全部固定档位（步长 20）
export const GLASS_THICKNESS_STEPS: number[] = [0, 20, 40, 60, 80, 100]

// 旧数据归一化：clamp 0-100 后四舍五入到最近档位（50 等距时统一取 60）
export function normalizeGlassThickness(value: number): number {
  return Math.max(0, Math.min(100, Math.round(value / 20) * 20))
}

// 档位显示名：0=关闭，其余对应官方五档
export function glassThicknessLabel(value: number): string {
  if (value <= 0) {
    return '关闭'
  }
  if (value <= 20) {
    return '极薄'
  }
  if (value <= 40) {
    return '薄'
  }
  if (value <= 60) {
    return '常规'
  }
  if (value <= 80) {
    return '厚'
  }
  return '极厚'
}

// 0=完全关闭玻璃（不挂 systemMaterial，无兜底模糊）
export function isGlassOff(value: number): boolean {
  return value <= 0
}

// 上端渐变模糊（首页上端 / 设置页顶部带 / 设置页预览方块）的「模糊强度 → 模糊半径」映射：
// 全项目唯一一份，禁止各处再抄第二份，否则首页与设置页会在临界处各说各话。
//   0 ≤ strength ≤ TOP_BLUR_CAP_STRENGTH：r = TOP_BLUR_SLOPE × strength            （正比例段）
//   strength > TOP_BLUR_CAP_STRENGTH    ：r = TOP_BLUR_SLOPE × TOP_BLUR_CAP_STRENGTH（常数段）
// 常数段必须取正比例段在临界强度处的同一取值（60 × 1.6 = 96），两段在 strength = 60 处
// 严丝合缝相接（两侧都是 96），临界处强度不变、无断口；常数段不得写死第二个数值。
// 曲线从下往上读即「先正比例升到满，再恒定不变」。
export const TOP_BLUR_SLOPE: number = 1.6
export const TOP_BLUR_CAP_STRENGTH: number = 60

export function topBlurRadiusFromStrength(strength: number): number {
  if (strength <= 0) {
    return 0
  }
  if (strength <= TOP_BLUR_CAP_STRENGTH) {
    return TOP_BLUR_SLOPE * strength
  }
  return TOP_BLUR_SLOPE * TOP_BLUR_CAP_STRENGTH
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

// API 26+ 才能用 systemMaterial / uiMaterial.ImmersiveMaterial；老设备自动降级。
// 双保险：除 API 版本外还要求设备声明支持 ImmersiveMaterial（isImmersiveMaterialSupported
// 为 false 时挂材质不生效，如部分模拟器/2in1 设备）。该 API 26 才存在，必须先过版本判断再调用。
export function isLiquidGlassAvailable(): boolean {
  if (!deviceInfo.apiAvailable('26.0.0')) {
    return false
  }
  try {
    return uiMaterial.isImmersiveMaterialSupported()
  } catch (e) {
    return false
  }
}

// 设备算力材质档位（EXQUISITE 高 / GENTLE 中 / SMOOTH 低）；API 26 以下或查询失败返回 undefined
export function getDeviceMaterialLevel(): uiMaterial.MaterialLevel | undefined {
  if (!deviceInfo.apiAvailable('26.0.0')) {
    return undefined
  }
  try {
    return uiMaterial.getGlobalMaterialLevel()
  } catch (e) {
    return undefined
  }
}

// 低算力设备（SMOOTH）：ImmersiveStyle 档位不生效，材质面退化为纯色/边框/阴影，
// 此时组件侧必须保留 backgroundEffect 兜底模糊维持可读性
export function isLowPowerGlassDevice(): boolean {
  return getDeviceMaterialLevel() === uiMaterial.MaterialLevel.SMOOTH
}

// 系统沉浸光效（ImmersiveMaterial.lightEffect，即底部栏「跟手光效」）是否真的会渲染：
// 官方明确该参数仅对「高算力/中算力」设备生效，低算力（SMOOTH）设备上会被系统直接忽略，
// 表现为：玻璃材质本身还在（低档位用背景色/边框/阴影实现），但按压/跟手的光效完全没有。
// 这类设备必须由组件侧自绘跟手光效兜底（见 Index.tabLightGlow）。
export function isSystemLightEffectAvailable(): boolean {
  return isLiquidGlassAvailable() && !isLowPowerGlassDevice()
}

// 设备材质能力诊断串：跟手光效不生效时用于真机 hilog 定位（TAG = Index/GlassUtil）
export function materialCapabilityInfo(): string {
  const level: uiMaterial.MaterialLevel | undefined = getDeviceMaterialLevel()
  let levelName: string = 'unknown'
  if (level === uiMaterial.MaterialLevel.EXQUISITE) {
    levelName = 'EXQUISITE'
  } else if (level === uiMaterial.MaterialLevel.GENTLE) {
    levelName = 'GENTLE'
  } else if (level === uiMaterial.MaterialLevel.SMOOTH) {
    levelName = 'SMOOTH'
  }
  return `api26=${deviceInfo.apiAvailable('26.0.0')}, liquidGlassAvailable=${isLiquidGlassAvailable()}, ` +
    `materialLevel=${levelName}, systemLightEffectAvailable=${isSystemLightEffectAvailable()}`
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

// 底部栏/多选操作栏等横向条状组件的液态玻璃材质工厂（API 26+）：
// - interactive 复用全局「交互形变」开关控制 Q 弹形变
// - applyShadow 固定关闭：这些组件均有手写 shadow 投影设计，避免材质阴影覆盖
// - 不开 lightEffect / colorInvert（与页面级 createPageGlassMaterial 策略一致）
// 低算力设备（SMOOTH）返回 undefined，让组件保留 backgroundEffect 兜底
export function createBarGlassMaterial(strength: number, interactive: boolean): uiMaterial.Material | undefined {
  if (!isLiquidGlassAvailable() || isGlassOff(strength) || isLowPowerGlassDevice()) {
    return undefined
  }
  return new uiMaterial.ImmersiveMaterial({
    style: glassImmersiveStyleFromStrength(strength),
    interactive: interactive,
    applyShadow: false
  })
}

// Toast 等系统组件调用级 systemMaterial 专用（API 26+）：
// 仅档位，无交互形变（Toast 是瞬时提示，形变无意义）；材质默认阴影由系统接管
export function createToastGlassMaterial(strength: number): uiMaterial.Material | undefined {
  if (!isLiquidGlassAvailable() || isGlassOff(strength) || isLowPowerGlassDevice()) {
    return undefined
  }
  return new uiMaterial.ImmersiveMaterial({
    style: glassImmersiveStyleFromStrength(strength)
  })
}
