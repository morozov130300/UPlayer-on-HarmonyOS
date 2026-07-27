export class RgbColor {
  r: number = 0
  g: number = 0
  b: number = 0
}

export class ColorHelper {
  static hexToRgb(hex: string): RgbColor {
    let clean: string = hex.replace('#', '')
    if (clean.length === 8) {
      clean = clean.substring(2)
    }
    const result: RgbColor = new RgbColor()
    result.r = parseInt(clean.substring(0, 2), 16)
    result.g = parseInt(clean.substring(2, 4), 16)
    result.b = parseInt(clean.substring(4, 6), 16)
    return result
  }

  static hexToRgba(hex: string, alpha: number): string {
    const rgb: RgbColor = ColorHelper.hexToRgb(hex)
    return `rgba(${rgb.r}, ${rgb.g}, ${rgb.b}, ${alpha})`
  }

  static hexWithAlpha(hex: string, alphaHex: string): string {
    let clean: string = hex.replace('#', '')
    if (clean.length === 8) {
      clean = clean.substring(2)
    }
    return '#' + alphaHex + clean
  }

  static lighten(hex: string, factor: number): string {
    const rgb: RgbColor = ColorHelper.hexToRgb(hex)
    const r: number = Math.min(255, Math.floor(rgb.r + (255 - rgb.r) * factor))
    const g: number = Math.min(255, Math.floor(rgb.g + (255 - rgb.g) * factor))
    const b: number = Math.min(255, Math.floor(rgb.b + (255 - rgb.b) * factor))
    return '#' + ColorHelper.toHex(r) + ColorHelper.toHex(g) + ColorHelper.toHex(b)
  }

  static darken(hex: string, factor: number): string {
    const rgb: RgbColor = ColorHelper.hexToRgb(hex)
    const r: number = Math.max(0, Math.floor(rgb.r * (1 - factor)))
    const g: number = Math.max(0, Math.floor(rgb.g * (1 - factor)))
    const b: number = Math.max(0, Math.floor(rgb.b * (1 - factor)))
    return '#' + ColorHelper.toHex(r) + ColorHelper.toHex(g) + ColorHelper.toHex(b)
  }

  private static toHex(n: number): string {
    const s: string = n.toString(16)
    return s.length < 2 ? '0' + s : s
  }
}
