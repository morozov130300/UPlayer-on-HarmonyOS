// 歌词加载器：把「候选路径解析 + 文件读取 + 按扩展名分发解析器」收敛到唯一实现。
// 播放器（LyricsComponent）与首页迷你歌词（Index）都必须走这里，
// 避免此前两份各自演进的加载逻辑再次分叉。
import { fileIo as fs } from '@kit.CoreFileKit'
import { util } from '@kit.ArkTS'
import { BusinessError } from '@kit.BasicServicesKit'
import { SongInfo } from '../model/SongInfo'
import { LrcEntry } from '../viewmodel/LrcEntry'
import { LyricFile } from '../common/constants/LyricConst'
import { PlayerConstants } from '../common/constants/PlayerConstants'
import { parseKrcLyric, parseLrcLyric } from '../common/utils/LrcUtils'
import Logger from '../common/utils/Logger'

const TAG = 'LyricLoader'

// 内存缓存上限：64 首歌的解析结果，峰值约几 MB，超出按插入序淘汰最旧条目（近似 LRU）
const LYRIC_CACHE_MAX_ENTRIES: number = 64
const lyricCache: Map<string, LrcEntry[]> = new Map<string, LrcEntry[]>()
// 在途请求去重：同一首歌的并发调用共享同一个 Promise，避免首页迷你歌词 + 播放页歌词 + 双 Watch 重复读盘
const pendingLoads: Map<string, Promise<LrcEntry[]>> = new Map<string, Promise<LrcEntry[]>>()

function lyricCacheKey(song: SongInfo): string {
  return `${song.lyricUri}|${song.lyricPath}`
}

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

// 回退说明：fs.readText 不支持 file://docs URI（真机报 13900002 No such file or directory），
// 而 fs.open 支持；两者不等价，按「单项不等价即回退」恢复原读取实现。
// fs.read 可能短读：循环读满 stat 得到的长度，并按实际读到的字节数截断，
// 避免尾部补零字节被解码成正文
async function readAll(fd: number, size: number): Promise<Uint8Array> {
  const target: Uint8Array = new Uint8Array(size)
  let total: number = 0
  while (total < size) {
    const chunk: ArrayBuffer = new ArrayBuffer(size - total)
    const readLen: number = await fs.read(fd, chunk)
    if (readLen <= 0) {
      break
    }
    target.set(new Uint8Array(chunk, 0, readLen), total)
    total += readLen
  }
  return total === size ? target : target.subarray(0, total)
}

async function loadFromPath(path: string): Promise<LrcEntry[]> {
  let file: fs.File | undefined = undefined
  try {
    file = await fs.open(path, fs.OpenMode.READ_ONLY)
    const size: number = (await fs.stat(file.fd)).size
    if (size <= 0) {
      return []
    }
    const bytes: Uint8Array = await readAll(file.fd, size)
    // 行文本在解析时会 trim，因此即使解码器保留了 BOM 也会被去掉
    const decoder = util.TextDecoder.create(PlayerConstants.ENCODING, { ignoreBOM: true })
    const text: string = decoder.decodeToString(bytes, { stream: false })
    return isKrcPath(path) ? parseKrcLyric(text) : parseLrcLyric(text)
  } catch (err) {
    Logger.warn(TAG, `load lyric failed path=${path} err=${JSON.stringify(err)}`)
    return []
  } finally {
    // 无论成功失败都必须关闭 fd，否则异常路径会泄漏文件描述符
    if (file !== undefined) {
      try {
        await fs.close(file)
      } catch (e) {
        Logger.warn(TAG, `close lyric file failed path=${path}`)
      }
    }
  }
}

/**
 * 读取并解析歌曲歌词。逐个候选尝试，返回首个解析出非空内容的结果；
 * 全部失败返回空数组，由上层显示「无歌词」占位。
 * 内存缓存 + 在途去重：切歌时首页与播放页的并发调用只产生一次文件 I/O；
 * 空结果（无歌词）同样缓存，避免每次切歌重复探测不存在的文件。
 */
export async function loadLyricEntries(song: SongInfo): Promise<LrcEntry[]> {
  const candidates: string[] = buildLyricCandidates(song)
  if (candidates.length === 0) {
    return []
  }
  const key: string = lyricCacheKey(song)
  const cached: LrcEntry[] | undefined = lyricCache.get(key)
  if (cached !== undefined) {
    // 刷新 LRU 新鲜度：Map 保持插入序，先删后插
    lyricCache.delete(key)
    lyricCache.set(key, cached)
    return cached
  }
  const pending: Promise<LrcEntry[]> | undefined = pendingLoads.get(key)
  if (pending !== undefined) {
    return pending
  }
  const loadTask: Promise<LrcEntry[]> = startLyricLoad(key, candidates)
  pendingLoads.set(key, loadTask)
  return loadTask
}

// 启动一次真实读盘：完成后按身份比对落缓存（clearLyricCache 后在途结果不落缓存）；
// 失败兜底返回空数组（与 loadFromPath 内部吞错语义一致），不落缓存，下次调用重新读盘
function startLyricLoad(key: string, candidates: string[]): Promise<LrcEntry[]> {
  const task: Promise<LrcEntry[]> = loadFromCandidates(candidates)
    .then((entries: LrcEntry[]): LrcEntry[] => {
      if (pendingLoads.get(key) === task) {
        pendingLoads.delete(key)
        lyricCache.set(key, entries)
        if (lyricCache.size > LYRIC_CACHE_MAX_ENTRIES) {
          const oldestKey: string | undefined = lyricCache.keys().next().value
          if (oldestKey !== undefined) {
            lyricCache.delete(oldestKey)
          }
        }
      }
      return entries
    })
    .catch((err: BusinessError): LrcEntry[] => {
      if (pendingLoads.get(key) === task) {
        pendingLoads.delete(key)
      }
      Logger.warn(TAG, `load lyric entries failed key=${key} err=${JSON.stringify(err)}`)
      return []
    })
  return task
}

async function loadFromCandidates(candidates: string[]): Promise<LrcEntry[]> {
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

/**
 * 清空歌词内存缓存与在途请求表。歌词引用发生集合级变化（重新导入覆盖）时调用，
 * 保证已打开页面重新读取落盘数据；在途请求的返回值仍交给当次调用方，但不落缓存。
 */
export function clearLyricCache(): void {
  lyricCache.clear()
  pendingLoads.clear()
}