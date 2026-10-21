// 拼音预计算（S3）：入库/回填阶段把 title/artist/album/folderName 的无调全拼与
// 首字母缩写写入 songs 表 pinyinFull/pinyinAbbr 列，供 S2 模糊搜索离线匹配，
// 不在 UI 热路径做转写。转写器：Any-Latn（汉字→带调拼音）+ Latin-ASCII（去音调），
// 官方 FAQ faqs-localization-11 / faqs-arkui-355。
import { i18n } from '@kit.LocalizationKit'
import { taskpool } from '@kit.ArkTS'
import { SongInfo } from '../model/SongInfo'
import Logger from '../common/utils/Logger'

const TAG = 'PinyinTask'
const CHINESE_REGEX: RegExp = new RegExp('[\\u4e00-\\u9fff]')

interface PinyinInputItem {
  id: string
  text: string
}

export class PinyinResultItem {
  id: string = ''
  full: string = ''
  abbr: string = ''
}

export function hasChinese(text: string): boolean {
  return CHINESE_REGEX.test(text)
}

@Concurrent
function computePinyinTask(itemsJson: string): string {
  const items: PinyinInputItem[] = JSON.parse(itemsJson) as PinyinInputItem[]
  const transAny: i18n.Transliterator = i18n.Transliterator.getInstance('Any-Latn')
  const transAscii: i18n.Transliterator = i18n.Transliterator.getInstance('Latin-ASCII')
  const chineseRegex: RegExp = new RegExp('[\\u4e00-\\u9fff]')
  const whitespaceRegex: RegExp = new RegExp('\\s+')
  const results: Record<string, string>[] = []
  for (let i = 0; i < items.length; i++) {
    // 无调全拼内联：无汉字的文本原样小写（搜索仍可直接匹配原文，不浪费转写）
    const lower: string = items[i].text.toLowerCase()
    let full: string = ''
    if (!chineseRegex.test(lower)) {
      full = lower.replace(whitespaceRegex, ' ').trim()
    } else {
      const mid: string = transAny.transform(lower)
      const plain: string = transAscii.transform(mid)
      full = plain.toLowerCase().replace(whitespaceRegex, ' ').trim()
    }
    // 首字母缩写内联：按空格分词取首字母（"zhou jie lun" → "zjl"）
    let abbr: string = ''
    const parts: string[] = full.split(' ')
    for (let p = 0; p < parts.length; p++) {
      if (parts[p].length > 0) {
        abbr += parts[p].charAt(0)
      }
    }
    const item: Record<string, string> = {
      'id': items[i].id,
      'full': full,
      'abbr': abbr
    }
    results.push(item)
  }
  return JSON.stringify(results)
}

// 为一批歌曲填充拼音列：title/artist/album/folderName 拼接后统一转写。
// 已有拼音的跳过（幂等，回填可重复调用）；纯英文/数字文本跳过（列保持 ''）；
// 失败静默记日志（列留空，下次启动回填自动重试，不阻塞导入主流程）
export async function fillPinyinForSongs(batch: SongInfo[]): Promise<void> {
  if (batch.length === 0) {
    return
  }
  const items: PinyinInputItem[] = []
  for (let i = 0; i < batch.length; i++) {
    const song: SongInfo = batch[i]
    if (song.pinyinFull.length > 0) {
      continue
    }
    const text: string = `${song.title} ${song.artist} ${song.album} ${song.folderName}`
    if (!hasChinese(text)) {
      continue
    }
    const input: PinyinInputItem = { id: song.id, text: text }
    items.push(input)
  }
  if (items.length === 0) {
    return
  }
  try {
    const raw: string = await taskpool.execute(computePinyinTask, JSON.stringify(items)) as string
    const results: PinyinResultItem[] = JSON.parse(raw) as PinyinResultItem[]
    const byId: Map<string, PinyinResultItem> = new Map<string, PinyinResultItem>()
    for (let i = 0; i < results.length; i++) {
      byId.set(results[i].id, results[i])
    }
    for (let i = 0; i < batch.length; i++) {
      const found: PinyinResultItem | undefined = byId.get(batch[i].id)
      if (found !== undefined) {
        batch[i].pinyinFull = found.full
        batch[i].pinyinAbbr = found.abbr
      }
    }
  } catch (err) {
    Logger.warn(TAG, `fillPinyinForSongs failed: ${JSON.stringify(err)}`)
  }
}
