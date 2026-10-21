import { FormExtensionAbility, formBindingData } from '@kit.FormKit'
import { Want } from '@kit.AbilityKit'
import { preferences } from '@kit.ArkData'
import { fileIo } from '@kit.CoreFileKit'
import Logger from '../common/utils/Logger'
import {
  FORM_COVER_FILE_NAME,
  FORM_STORE_NAME,
  KEY_SNAP_ARTIST,
  KEY_SNAP_HAS_COVER,
  KEY_SNAP_IS_PLAYING,
  KEY_SNAP_PERCENT,
  KEY_SNAP_TITLE
} from '../service/FormUpdateService'

const TAG = 'PlayerFormAbility'

// 桌面播放卡片（F1）生命周期：运行在卡片扩展进程。
// 应用进程的 FormUpdateService 持续把播放态快照写入共享偏好并主动 updateForm，
// 本类仅在卡片新增/定点刷新时从共享偏好取快照组装初值；封面取应用进程落盘的沙箱缓存文件。
export default class PlayerFormAbility extends FormExtensionAbility {
  onAddForm(want: Want): formBindingData.FormBindingData {
    const raw: Object | undefined = want.parameters !== undefined ?
      want.parameters['ohos.extra.param.key.form_identity'] : undefined
    const formId: string = typeof raw === 'string' ? raw : ''
    Logger.info(TAG, `onAddForm formId=${formId}`)
    return this.buildInitialData()
  }

  onRemoveForm(formId: string): void {
    Logger.info(TAG, `onRemoveForm formId=${formId}`)
  }

  onUpdateForm(formId: string): void {
    Logger.info(TAG, `onUpdateForm formId=${formId}`)
  }

  // 初值数据：共享偏好快照 + 沙箱封面缓存（应用进程 FormUpdateService 写入）
  private buildInitialData(): formBindingData.FormBindingData {
    const data: Record<string, Object> = {}
    data['title'] = '未播放'
    data['artist'] = ''
    data['isPlaying'] = false
    data['progressPercent'] = 0
    data['hasCover'] = false
    try {
      const options: preferences.Options = { name: FORM_STORE_NAME }
      const store: preferences.Preferences = preferences.getPreferencesSync(this.context, options)
      const titleRaw: preferences.ValueType = store.getSync(KEY_SNAP_TITLE, '未播放')
      if (typeof titleRaw === 'string') {
        data['title'] = titleRaw
      }
      const artistRaw: preferences.ValueType = store.getSync(KEY_SNAP_ARTIST, '')
      if (typeof artistRaw === 'string') {
        data['artist'] = artistRaw
      }
      const isPlayingRaw: preferences.ValueType = store.getSync(KEY_SNAP_IS_PLAYING, false)
      if (typeof isPlayingRaw === 'boolean') {
        data['isPlaying'] = isPlayingRaw
      }
      const percentRaw: preferences.ValueType = store.getSync(KEY_SNAP_PERCENT, 0)
      if (typeof percentRaw === 'number') {
        data['progressPercent'] = percentRaw
      }
      const hasCoverRaw: preferences.ValueType = store.getSync(KEY_SNAP_HAS_COVER, false)
      const hasCover: boolean = typeof hasCoverRaw === 'boolean' ? hasCoverRaw : false
      if (hasCover) {
        const coverPath: string = this.context.cacheDir + '/' + FORM_COVER_FILE_NAME
        const file: fileIo.File = fileIo.openSync(coverPath, fileIo.OpenMode.READ_ONLY)
        const imgs: Record<string, number> = {}
        imgs['form_cover'] = file.fd
        data['formImages'] = imgs
        data['hasCover'] = true
        // fd 保持打开：框架在 IPC 阶段读取，卡片扩展进程随回调结束回收，不额外 close
      }
    } catch (err) {
      Logger.error(TAG, `buildInitialData failed: ${JSON.stringify(err)}`)
    }
    return formBindingData.createFormBindingData(data)
  }
}
