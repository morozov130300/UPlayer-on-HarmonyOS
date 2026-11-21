// 日志文件服务：关于页「开启日志」开关 → WARN/ERROR 追加写盘 → 系统文件管理器导出。
// 说明：只有经 Logger 封装的 warn/error 会写盘；项目里少量直接调用 hilog.* 的代码
// 不经过 Logger，ArkTS 层无法拦截，不在落盘范围内。
import { fileIo as fs, picker } from '@kit.CoreFileKit'
import { hilog } from '@kit.PerformanceAnalysisKit'
import { BusinessError } from '@kit.BasicServicesKit'
import { common } from '@kit.AbilityKit'
import { SettingsStore } from './SettingsStore'
import { AppStorageKeyConstants } from '../constants/AppStorageKeyConstants'

const LOG_DOMAIN: number = 0x0000
const LOG_TAG: string = 'LogFileService'
const LOG_FILE_NAME: string = 'uplayer.log'

export class LogFileService {
  private static instance: LogFileService = new LogFileService()
  private initialized: boolean = false
  private enabled: boolean = false
  private verbose: boolean = false
  private logPath: string = ''

  public static getInstance(): LogFileService {
    return LogFileService.instance
  }

  // 必须在 windowStage.loadContent 之后调用：SettingsStore 依赖 PersistenceV2.connect，
  // 且 filesDir 由 UIAbilityContext 提供。由 EntryAbility.initAfterFirstFrame 触发。
  public init(context: common.UIAbilityContext): void {
    try {
      this.logPath = context.filesDir + '/' + LOG_FILE_NAME
      this.enabled = SettingsStore.getInstance()
        .get(AppStorageKeyConstants.SETTING_LOG_FILE_ENABLED, '0') === '1'
      this.verbose = SettingsStore.getInstance()
        .get(AppStorageKeyConstants.SETTING_LOG_VERBOSE_ENABLED, '0') === '1'
      this.initialized = true
    } catch (e) {
      hilog.error(LOG_DOMAIN, LOG_TAG, 'init failed: %{public}s', JSON.stringify(e))
    }
  }

  public isEnabled(): boolean {
    return this.enabled
  }

  // 详细日志开关状态：供 Logger 的 verboseGate 查询（DEBUG/INFO 是否写盘）。
  // 基础开关未开启时详细模式无意义，恒为 false。
  public isVerbose(): boolean {
    return this.enabled && this.verbose
  }

  // 开关落盘持久化；开启后只记录开启之后产生的日志，关闭期间不补录。
  // 关闭时删除本地日志残留，下次开启从空文件重新记录。
  public setEnabled(on: boolean): void {
    this.enabled = on
    if (!on) {
      // 基础开关关闭时同步关闭详细模式，避免下次开启时带着隐藏的详细态
      this.verbose = false
      try {
        SettingsStore.getInstance().set(AppStorageKeyConstants.SETTING_LOG_VERBOSE_ENABLED, '0')
      } catch (e) {
        hilog.error(LOG_DOMAIN, LOG_TAG, 'reset verbose failed: %{public}s', JSON.stringify(e))
      }
      this.clearLogFile()
    }
    try {
      SettingsStore.getInstance().set(AppStorageKeyConstants.SETTING_LOG_FILE_ENABLED, on ? '1' : '0')
    } catch (e) {
      hilog.error(LOG_DOMAIN, LOG_TAG, 'setEnabled failed: %{public}s', JSON.stringify(e))
    }
  }

  // 详细日志开关落盘持久化；仅影响 DEBUG/INFO 是否写盘，不改变基础开关。
  public setVerbose(on: boolean): void {
    this.verbose = on
    try {
      SettingsStore.getInstance().set(AppStorageKeyConstants.SETTING_LOG_VERBOSE_ENABLED, on ? '1' : '0')
    } catch (e) {
      hilog.error(LOG_DOMAIN, LOG_TAG, 'setVerbose failed: %{public}s', JSON.stringify(e))
    }
  }

  // 单文件持续追加：CREATE 保证首次写入时创建，APPEND 保证不覆盖历史
  public append(level: string, prefix: string, message: string): void {
    if (!this.initialized || !this.enabled || this.logPath.length === 0) {
      return
    }
    let file: fs.File | undefined = undefined
    try {
      const line: string = `[${LogFileService.timestamp()}] [${level}] ${prefix}: ${message}\n`
      file = fs.openSync(this.logPath, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.APPEND)
      fs.writeSync(file.fd, line)
    } catch (e) {
      hilog.error(LOG_DOMAIN, LOG_TAG, 'append failed: %{public}s', JSON.stringify(e))
    } finally {
      if (file !== undefined) {
        try {
          fs.closeSync(file)
        } catch (e) {
          hilog.error(LOG_DOMAIN, LOG_TAG, 'close failed: %{public}s', JSON.stringify(e))
        }
      }
    }
  }

  // 导出前读出全量日志；文件不存在（从未开启过 / 开启后无 warn、error）返回空串
  public readAll(): string {
    if (!this.initialized || this.logPath.length === 0) {
      return ''
    }
    try {
      if (!fs.accessSync(this.logPath, fs.AccessModeType.EXIST)) {
        return ''
      }
      return fs.readTextSync(this.logPath)
    } catch (e) {
      hilog.error(LOG_DOMAIN, LOG_TAG, 'readAll failed: %{public}s', JSON.stringify(e))
      return ''
    }
  }

  // 删除整个日志文件；导出成功后调用，后续 warn/error 由 append 的 CREATE 重新建文件继续写。
  public clearLogFile(): void {
    if (!this.initialized || this.logPath.length === 0) {
      return
    }
    try {
      if (fs.accessSync(this.logPath, fs.AccessModeType.EXIST)) {
        fs.unlinkSync(this.logPath)
      }
    } catch (e) {
      hilog.error(LOG_DOMAIN, LOG_TAG, 'clearLogFile failed: %{public}s', JSON.stringify(e))
    }
  }

  // 导出默认文件名：UPlayer_yyyyMMdd_HHmmss.log（用户仍可在系统文件管理器里改名）
  public defaultExportFileName(): string {
    const d: Date = new Date()
    const p = (n: number): string => n.toString().padStart(2, '0')
    return `UPlayer_${d.getFullYear()}${p(d.getMonth() + 1)}${p(d.getDate())}_` +
      `${p(d.getHours())}${p(d.getMinutes())}${p(d.getSeconds())}.log`
  }

  // 拉起系统文件管理器（DocumentViewPicker.save）由用户选择保存位置，直接把沙箱日志文件
  // 复制到该 URI。不预先快照：期间新产生的 warn/error 仍写入同一个 uplayer.log，
  // 写入用户文件那一刻读到什么就导出什么；导出成功后删除整个文件，后续日志由 append 重建。
  // 保存用户文件无需申请权限。返回 'ok' 成功 / 'cancel' 用户取消 / 'error' 写入失败。
  public exportToUser(context: common.UIAbilityContext, fileName: string): Promise<string> {
    return new Promise<string>((resolve: (result: string) => void): void => {
      try {
        const options: picker.DocumentSaveOptions = new picker.DocumentSaveOptions()
        options.newFileNames = [fileName]
        options.fileSuffixChoices = ['日志文件|.log']
        const docPicker: picker.DocumentViewPicker = new picker.DocumentViewPicker(context)
        docPicker.save(options).then((uris: string[]): void => {
          if (uris.length === 0) {
            resolve('cancel')
            return
          }
          let file: fs.File | undefined = undefined
          try {
            const content: string = this.readAll()
            file = fs.openSync(uris[0], fs.OpenMode.READ_WRITE)
            fs.writeSync(file.fd, content)
            // 仅成功后删除整个文件；取消/失败原文件不动，无需写回
            this.clearLogFile()
            resolve('ok')
          } catch (e) {
            hilog.error(LOG_DOMAIN, LOG_TAG, 'write export failed: %{public}s', JSON.stringify(e))
            resolve('error')
          } finally {
            if (file !== undefined) {
              try {
                fs.closeSync(file)
              } catch (e) {
                hilog.error(LOG_DOMAIN, LOG_TAG, 'close export failed: %{public}s', JSON.stringify(e))
              }
            }
          }
        }).catch((err: BusinessError): void => {
          // 用户取消通常以 reject 返回，按取消处理，不打扰用户
          hilog.info(LOG_DOMAIN, LOG_TAG, `save cancelled or failed: ${err.code} ${err.message}`)
          resolve('cancel')
        })
      } catch (e) {
        hilog.error(LOG_DOMAIN, LOG_TAG, 'exportToUser failed: %{public}s', JSON.stringify(e))
        resolve('error')
      }
    })
  }

  private static timestamp(): string {
    const d: Date = new Date()
    const p = (n: number, w: number): string => n.toString().padStart(w, '0')
    return `${d.getFullYear()}-${p(d.getMonth() + 1, 2)}-${p(d.getDate(), 2)} ` +
      `${p(d.getHours(), 2)}:${p(d.getMinutes(), 2)}:${p(d.getSeconds(), 2)}.${p(d.getMilliseconds(), 3)}`
  }
}
