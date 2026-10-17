// 偏好存储：基于 PersistenceV2 的字符串键值持久化，替代旧 preferences('myStore')。
// 硬性约束：PersistenceV2.connect 必须在 windowStage.loadContent 之后才能访问，
// 本类的 get/set 均为懒连接（首次调用时 connect），严禁在 loadContent 之前调用。
import { PersistenceV2 } from '@kit.ArkUI'
import Logger from './Logger'

const TAG = 'SettingsStore'
const DEBOUNCE_SAVE_MS: number = 300

// PersistenceV2 只能持久化 object 类型，字符串设置值统一用本包装类承载。
// 属性不加 @Trace：避免每次赋值触发整对象自动落盘，改由 set() 控制立即落盘
// （PersistenceV2.save）或 300ms 防抖落盘，保持旧 preferences 的 immediate 语义。
export class PersistString {
  value: string

  constructor(value: string) {
    this.value = value
  }
}

export class SettingsStore {
  private static instance: SettingsStore = new SettingsStore()
  private items: Map<string, PersistString> = new Map()
  private saveTimer: number = -1
  private pendingSaveKeys: Set<string> = new Set()

  public static getInstance(): SettingsStore {
    return SettingsStore.instance
  }

  private connectItem(key: string, def: string): PersistString | undefined {
    const cached: PersistString | undefined = this.items.get(key)
    if (cached !== undefined) {
      return cached
    }
    try {
      const item: PersistString | undefined =
        PersistenceV2.connect(PersistString, key, (): PersistString => new PersistString(def))
      if (item === undefined) {
        Logger.error(TAG, `connect returned undefined for key ${key}`)
        return undefined
      }
      this.items.set(key, item)
      return item
    } catch (e) {
      Logger.error(TAG, `connect failed for key ${key}: ${JSON.stringify(e)}`)
      return undefined
    }
  }

  // 读取持久化字符串；空串视为「未设置」，返回 def
  get(key: string, def: string): string {
    const item: PersistString | undefined = this.connectItem(key, def)
    if (item === undefined || item.value.length === 0) {
      return def
    }
    return item.value
  }

  // immediate=true 立即落盘；false 走 300ms 防抖合并落盘（供拖动过程逐帧调用）
  set(key: string, value: string, immediate: boolean = true): void {
    const item: PersistString | undefined = this.connectItem(key, value)
    if (item === undefined) {
      return
    }
    item.value = value
    if (immediate) {
      this.saveNow(key)
    } else {
      this.scheduleSave(key)
    }
  }

  private saveNow(key: string): void {
    try {
      PersistenceV2.save(key)
    } catch (e) {
      Logger.error(TAG, `save failed for key ${key}: ${JSON.stringify(e)}`)
    }
  }

  private scheduleSave(key: string): void {
    this.pendingSaveKeys.add(key)
    if (this.saveTimer !== -1) {
      return
    }
    this.saveTimer = setTimeout(() => {
      this.saveTimer = -1
      this.flushPendingSaves()
    }, DEBOUNCE_SAVE_MS)
  }

  flushPendingSaves(): void {
    if (this.saveTimer !== -1) {
      clearTimeout(this.saveTimer)
      this.saveTimer = -1
    }
    if (this.pendingSaveKeys.size === 0) {
      return
    }
    const keys: string[] = Array.from(this.pendingSaveKeys)
    this.pendingSaveKeys.clear()
    for (let i = 0; i < keys.length; i++) {
      this.saveNow(keys[i])
    }
  }
}
