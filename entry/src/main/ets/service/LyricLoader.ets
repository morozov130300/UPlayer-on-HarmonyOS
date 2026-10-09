// 歌词加载器：把「候选路径解析 + 文件读取 + 按扩展名分发解析器」收敛到唯一实现。
// 播放器（LyricsComponent）与首页迷你歌词（Index）都必须走这里，
// 避免此前两份各自演进的加载逻辑再次分叉。
import { fileIo as fs } from '@kit.CoreFileKit'
import { SongInfo } from '../model/SongInfo'
import { LrcEntry } from '../viewmodel/LrcEntry'
import { LyricFile } from '../common/constants/LyricConst'
import { PlayerConstants } from '../common/constants/PlayerConstants'
import { parseKrcLyric, parseLrcLyric } from '../common/utils/LrcUtils'
import Logger from '../common/utils/Logger'

const TAG = 'LyricLoader'

function addCandidate(list: string[], value: string): void {
  if (value.length === 0 || list.indexOf(value) >= 0) {
    return
  }
  list.push(value)
}

/**
 * 构建歌词候选访问路径：只使用数据库中已存的两个字段，不做任何路径推导或探测。
 *
 * 刻意不在这里「猜」同名兄弟文件：歌词引用一旦失效，其原因（文件被删/改名/换盘/授权失效）
 * 在运行期是不可知的，任何自动推导都只是猜测，结果是「看起来修好了但其实是错的」，
 * 比明确显示「无歌词」更糟。引用是否有效只应该由导入这个源头决定。
 *
 * lyricUri 优先（picker 授权可持久化的 URI 形式），失败再退回 lyricPath（percent 解码形式）。
 */
export function buildLyricCandidates(song: SongInfo): string[] {
  const candidates: string[] = []
  addCandidate(candidates, song.lyricUri)
  addCandidate(candidates, song.lyricPath)
  return candidates
}

function isKrcPath(path: string): boolean {
  return path.toLowerCase().endsWith(LyricFile.KRC)
}

async function loadFromPath(path: string): Promise<LrcEntry[]> {
  try {
    // readText 内部完成打开/读取/UTF-8 解码/关闭，短读与 fd 泄漏由系统处理；
    // 行文本在解析时会 trim，即使保留了 BOM 也会被去掉
    const text: string = await fs.readText(path, { encoding: PlayerConstants.ENCODING })
    return isKrcPath(path) ? parseKrcLyric(text) : parseLrcLyric(text)
  } catch (err) {
    Logger.warn(TAG, `load lyric failed path=${path} err=${JSON.stringify(err)}`)
    return []
  }
}

/**
 * 读取并解析歌曲歌词。逐个候选尝试，返回首个解析出非空内容的结果；
 * 全部失败返回空数组，由上层显示「无歌词」占位。
 * 不缓存结果：调用方（播放器 / 首页）各自按需重新读取。
 */
export async function loadLyricEntries(song: SongInfo): Promise<LrcEntry[]> {
  const candidates: string[] = buildLyricCandidates(song)
  for (let i = 0; i < candidates.length; i++) {
    const entries: LrcEntry[] = await loadFromPath(candidates[i])
    if (entries.length > 0) {
      if (i > 0) {
        Logger.info(TAG, 'lyric resolved via fallback candidate')
      }
      return entries
    }
  }
  return []
}