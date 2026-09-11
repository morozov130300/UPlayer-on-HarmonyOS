// 诗词服务：从诗泉 API（https://poetry.palemoky.com/）获取随机诗句，用于主页问候语小字展示
import { http } from '@kit.NetworkKit'
import Logger from '../common/utils/Logger'

const TAG = 'PoetryService'
const POETRY_RANDOM_URL: string = 'https://poetry.palemoky.com/api/poems/random?lang=zh-Hans'
const REQUEST_TIMEOUT_MS: number = 8000
// 过长的词句不适合作为问候语小字展示，优先挑选短句
const PREFERRED_LINE_MAX_LEN: number = 24

export class PoetryService {
  private static instance: PoetryService = new PoetryService()

  public static getInstance(): PoetryService {
    return PoetryService.instance
  }

  public async fetchRandomLine(): Promise<string> {
    const httpRequest: http.HttpRequest = http.createHttp()
    try {
      const resp: http.HttpResponse = await httpRequest.request(POETRY_RANDOM_URL, {
        method: http.RequestMethod.GET,
        expectDataType: http.HttpDataType.STRING,
        connectTimeout: REQUEST_TIMEOUT_MS,
        readTimeout: REQUEST_TIMEOUT_MS
      })
      if (resp.responseCode !== 200 || typeof resp.result !== 'string') {
        return ''
      }
      return this.pickLine(resp.result)
    } catch (e) {
      Logger.error(TAG, `fetch random poem failed: ${JSON.stringify(e)}`)
      return ''
    } finally {
      httpRequest.destroy()
    }
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
