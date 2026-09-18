// 诗词服务：从诗泉 API（https://poetry.palemoky.com/）获取随机诗句，用于主页问候语小字展示
import { http } from '@kit.NetworkKit'
import Logger from '../common/utils/Logger'

const TAG = 'PoetryService'
const POETRY_RANDOM_URL: string = 'https://poetry.palemoky.com/api/poems/random?lang=zh-Hans'
const REQUEST_TIMEOUT_MS: number = 8000
// 过长的词句不适合作为问候语小字展示，优先挑选短句
const PREFERRED_LINE_MAX_LEN: number = 24
// 只保留：唐诗、宋词、元曲，以及所有五言/七言诗，其余类型重新获取
const MAX_FETCH_ATTEMPTS: number = 6
const PUNCTUATION_REGEX: RegExp = /[，。、；：？！“”‘’《》（）…—·\s]/g

export class PoetryService {
  private static instance: PoetryService = new PoetryService()

  public static getInstance(): PoetryService {
    return PoetryService.instance
  }

  public async fetchRandomLine(): Promise<string> {
    const httpRequest: http.HttpRequest = http.createHttp()
    try {
      // 随机接口无法指定类型，取到不满足“唐诗/宋词/元曲/五言/七言”的篇目时重试
      for (let attempt = 0; attempt < MAX_FETCH_ATTEMPTS; attempt++) {
        const resp: http.HttpResponse = await httpRequest.request(POETRY_RANDOM_URL, {
          method: http.RequestMethod.GET,
          expectDataType: http.HttpDataType.STRING,
          connectTimeout: REQUEST_TIMEOUT_MS,
          readTimeout: REQUEST_TIMEOUT_MS
        })
        if (resp.responseCode !== 200 || typeof resp.result !== 'string') {
          return ''
        }
        const line: string = this.pickLine(resp.result)
        if (line !== '') {
          return line
        }
      }
      return ''
    } catch (e) {
      Logger.error(TAG, `fetch random poem failed: ${JSON.stringify(e)}`)
      return ''
    } finally {
      httpRequest.destroy()
    }
  }

  // 读取嵌套对象 {"id":x,"name":"唐"} 中的 name 字段
  private readNestedName(raw: Object | undefined): string {
    if (raw === undefined) {
      return ''
    }
    const record: Record<string, Object> = raw as Record<string, Object>
    const nameRaw: Object | undefined = record['name']
    return nameRaw === undefined ? '' : String(nameRaw)
  }

  // 判断篇目是否满足展示条件：唐诗、宋词、元曲，或全部诗句为五言/七言
  private isWantedPoem(poem: Record<string, Object>, rawLines: string[]): boolean {
    // 接口返回的 dynasty/type 为对象，如 {"id":8,"name":"宋"}、{"id":20,"name":"宋词"}
    const dynasty: string = this.readNestedName(poem['dynasty'])
    const kind: string = this.readNestedName(poem['type'])
    if (dynasty === '唐') {
      return true
    }
    if (kind === '宋词' || kind === '元曲') {
      return true
    }
    // 其余篇目：仅当所有诗句都是五言或七言时保留
    if (rawLines.length === 0) {
      return false
    }
    for (let i = 0; i < rawLines.length; i++) {
      const stripped: string = rawLines[i].trim().replace(PUNCTUATION_REGEX, '')
      if (stripped.length === 0) {
        continue
      }
      if (stripped.length !== 5 && stripped.length !== 7) {
        return false
      }
    }
    return true
  }

  private pickLine(body: string): string {
    try {
      const root: Record<string, Object> = JSON.parse(body) as Record<string, Object>
      const dataOuter: Object | undefined = root['data']
      if (dataOuter === undefined) {
        return ''
      }
      // 实际接口返回 {"data":{ id,title,content,author,dynasty,type,lang }}，
      // 注意与官网示例展示的 data.data 双层嵌套不同
      const poem: Record<string, Object> = dataOuter as Record<string, Object>
      const contentRaw: Object | undefined = poem['content']
      if (contentRaw === undefined) {
        return ''
      }
      const rawLines: string[] = contentRaw as string[]
      if (rawLines.length === 0) {
        return ''
      }
      if (!this.isWantedPoem(poem, rawLines)) {
        return ''
      }
      const allLines: string[] = []
      const preferred: string[] = []
      for (let i = 0; i < rawLines.length; i++) {
        const line: string = rawLines[i].trim()
        if (line.length === 0) {
          continue
        }
        allLines.push(line)
        if (line.length <= PREFERRED_LINE_MAX_LEN) {
          preferred.push(line)
        }
      }
      const pool: string[] = preferred.length > 0 ? preferred : allLines
      if (pool.length === 0) {
        return ''
      }
      return pool[Math.floor(Math.random() * pool.length)]
    } catch (e) {
      Logger.error(TAG, `parse random poem failed: ${JSON.stringify(e)}`)
      return ''
    }
  }
}
