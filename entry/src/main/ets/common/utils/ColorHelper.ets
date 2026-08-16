export class RgbColor {
  r: number = 0
  g: number = 0
  b: number = 0
}

export class HsvColor {
  h: number = 0
  s: number = 0
  v: number = 0
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

  static hexToHsv(hex: string): HsvColor {
    const rgb: RgbColor = ColorHelper.hexToRgb(hex)
    const r: number = rgb.r / 255
    const g: number = rgb.g / 255
    const b: number = rgb.b / 255
    const max: number = Math.max(r, g, b)
    const min: number = Math.min(r, g, b)
    const delta: number = max - min
    const result: HsvColor = new HsvColor()
    if (delta > 0) {
      if (max === r) {
        result.h = 60 * (((g - b) / delta) % 6)
      } else if (max === g) {
        result.h = 60 * ((b - r) / delta + 2)
      } else {
        result.h = 60 * ((r - g) / delta + 4)
      }
    }
    if (result.h < 0) {
      result.h += 360
    }
    result.s = max === 0 ? 0 : delta / max
    result.v = max
    return result
  }

  static hsvToHex(hue: number, saturation: number, value: number): string {
    const h: number = ((hue % 360) + 360) % 360
    const s: number = Math.max(0, Math.min(1, saturation))
    const v: number = Math.max(0, Math.min(1, value))
    const chroma: number = v * s
    const section: number = h / 60
    const x: number = chroma * (1 - Math.abs(section % 2 - 1))
    let r: number = 0
    let g: number = 0
    let b: number = 0
    if (section < 1) {
      r = chroma
      g = x
    } else if (section < 2) {
      r = x
      g = chroma
    } else if (section < 3) {
      g = chroma
      b = x
    } else if (section < 4) {
      g = x
      b = chroma
    } else if (section < 5) {
      r = x
      b = chroma
    } else {
      r = chroma
      b = x
    }
    const match: number = v - chroma
    return ('#' + ColorHelper.toHex(Math.round((r + match) * 255)) +
      ColorHelper.toHex(Math.round((g + match) * 255)) +
      ColorHelper.toHex(Math.round((b + match) * 255))).toUpperCase()
  }

  private static toHex(n: number): string {
    const s: string = n.toString(16)
    return s.length < 2 ? '0' + s : s
  }
}
