import { PreferencesUtil } from '../common/utils/PreferencesUtil'
import Logger from '../common/utils/Logger'

const TAG = 'LegacyDataCleaner'

// ═══════════════════════════════════════════════════════════════════════════
// 【版本记录】v1.0.7 起移除全部旧版本兼容代码（不跨版本兼容）
//
// 背景：v1.0.6 及更早版本的曲库以 preferences JSON 形式持久化（歌曲列表 /
//       文件夹列表均为大 JSON 串）。旧版本用户覆盖安装到 v1.0.6+ 后，遗留
//       JSON 与旧结构数据即成为启动异常（闪退）的来源。
// 决策：自 v1.0.7 起不再做任何跨版本数据兼容与迁移——旧版本数据一律视为
//       废弃数据，应用每次启动时检测到即整体清除：不清洗、不转换、不迁移。
// 清除范围：
//   1) preferences 'myStore' 中不在 CURRENT_PREFERENCES_KEYS 内的所有遗留键
//      （含旧版歌曲/文件夹 JSON，键名未知也无所谓——按「非当前键即废弃」处理）；
//   2) 'uplayer.db' 中列结构不符合当前 schema 的旧表（整表 DROP 后重建，
//      见 SongDatabase 的 probeTable / enforceCurrentSchema）。
// 注意：
//   - 本清理为幂等操作，每次启动都执行——不落「已清理」标记键（少一个
//     preferences 键，也避免标记自身沦为遗留数据），单次开销仅为一次
//     getAllSync 加两次表结构探测，可忽略。应用无备份/恢复能力
//     （EntryBackupAbility 为空实现），不存在备份回灌路径。
//   - 设置读取的 pick* 字段兜底（数组类型 / 元素有限性等输入校验）保留，
//     那是运行期输入校验、不是版本兼容，删除它会 reintroduce 设置页崩溃。
//   - 当前版本持久化键集合以本文件为准；数据库 schema 以 SongDatabase 为准。
// ═══════════════════════════════════════════════════════════════════════════

// 当前版本（v1.0.7+）在 'myStore' 中实际持久化的键；与 DataService 中各
// KEY_* 常量一一对应。不在此集合内的键均为旧版本遗留，启动时删除。
const CURRENT_PREFERENCES_KEYS: string[] = [
  'uplayer_settings',
  'uplayer_sort_mode',
  'uplayer_view_mode',
  'uplayer_filter_state',
  'uplayer_play_next_queue',
  'uplayer_play_mode'
]

/**
 * 旧版本兼容数据清除器（v1.0.7 引入，替代此前的跨版本兼容逻辑）。
 *
 * 策略：不迁移、不兼容——检测到旧版本遗留数据即删除，保证新版本不会
 * 再读到任何旧格式数据。数据库旧表的整表重建在 SongDatabase.init 内完成
 * （schema 知识归属数据库自身），本类负责 preferences 遗留键清除。
 */
export class LegacyDataCleaner {
  // 无状态工具类：全部逻辑为静态方法，不实例化

  /**
   * 清除 'myStore' 中所有旧版本遗留键（不在 CURRENT_PREFERENCES_KEYS 内的键）。
   * 幂等，可每次启动调用；任何异常只记日志，不阻断启动流程。
   */
  public static purgeLegacyPreferences(): void {
    try {
      const pref: PreferencesUtil = PreferencesUtil.getInstance()
      const all: Record<string, Object> | undefined = pref.getAllEntries()
      if (all === undefined) {
        return
      }
      const legacyKeys: string[] = []
      const keys: string[] = Object.keys(all)
      for (let i: number = 0; i < keys.length; i++) {
        if (!CURRENT_PREFERENCES_KEYS.includes(keys[i])) {
          legacyKeys.push(keys[i])
        }
      }
      if (legacyKeys.length > 0) {
        pref.deleteKeys(legacyKeys)
        Logger.warn(TAG, `legacy preferences keys removed: [${legacyKeys.join(', ')}]`)
      }
    } catch (err) {
      Logger.error(TAG, `purgeLegacyPreferences failed: ${JSON.stringify(err)}`)
    }
  }
}
