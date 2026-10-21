import { formBindingData, formInfo, formProvider } from '@kit.FormKit'
import { BusinessError } from '@kit.BasicServicesKit'
import { common } from '@kit.AbilityKit'
import { preferences } from '@kit.ArkData'
import { image } from '@kit.ImageKit'
import { fileIo } from '@kit.CoreFileKit'
import Logger from '../common/utils/Logger'
import { AppStorageKeyConstants } from '../common/constants/AppStorageKeyConstants'
import { SongInfo } from '../model/SongInfo'
import { DataService } from './DataService'
import { AVPlayerService } from './AVPlayerService'
import { AlbumCoverSize, AudioMetadataService, CoverPriority } from './AudioMetadataService'

const TAG = 'FormUpdateService'
// 卡片快照跨进程共享偏好名（PlayerFormAbility 进程同名单读）
export const FORM_STORE_NAME: string = 'uplayer_form_store'
export const FORM_COVER_FILE_NAME: string = 'form_cover.jpg'
export const KEY_SNAP_SONG_ID: string = 'snap_song_id'
export const KEY_SNAP_TITLE: string = 'snap_title'
export const KEY_SNAP_ARTIST: string = 'snap_artist'
export const KEY_SNAP_IS_PLAYING: string = 'snap_is_playing'
export const KEY_SNAP_PERCENT: string = 'snap_percent'
export const KEY_SNAP_HAS_COVER: string = 'snap_has_cover'
const DISCOVERY_INTERVAL_MS: number = 15000
const UPDATE_INTERVAL_MS: number = 1000
const REDISCOVER_TICKS: number = 15

// 桌面播放卡片（F1）应用进程侧更新器：
// - 通过 formProvider.getPublishedRunningFormInfos 发现已加桌卡片（无需跨进程持久化 formId）
// - 1s 节流 tick 从 AppStorage / 原生引擎取播放态，快照去重后 updateForm 推送
// - 封面：切歌时从封面缓存取 PixelMap 打包 JPEG 落沙箱缓存，formImages fd 随数据下发
// - 标题/歌手/播放态等快照写入共享偏好（flushSync），供 PlayerFormAbility 进程 onAddForm 取初值
export class FormUpdateService {
  private static instance: FormUpdateService = new FormUpdateService()
  private context: common.UIAbilityContext | undefined = undefined
  private store: preferences.Preferences | undefined = undefined
  private storeReady: boolean = false
  private discoveryTimer: number = -1
  private updateTimer: number = -1
  private tickCount: number = 0
  private formIds: string[] = []
  private lastSnapshot: string = ''
  private lastPersistedCore: string = ''
  private lastCoverSongId: string = ''
  private coverReady: boolean = false
  private coverFd: number = -1
  private coverPath: string = ''
  private coverPreparing: boolean = false

  public static getInstance(): FormUpdateService {
    return FormUpdateService.instance
  }

  init(context: common.UIAbilityContext): void {
    if (this.context !== undefined) {
      return
    }
    this.context = context
    this.coverPath = context.cacheDir + '/' + FORM_COVER_FILE_NAME
    preferences.getPreferences(context, FORM_STORE_NAME).then((store: preferences.Preferences): void => {
      this.store = store
      this.storeReady = true
    }).catch((err: BusinessError): void => {
      Logger.error(TAG, `open form store failed: ${err.code} ${err.message}`)
    })
    this.startDiscovery()
  }

  shutdown(): void {
    if (this.discoveryTimer !== -1) {
      clearInterval(this.discoveryTimer)
      this.discoveryTimer = -1
    }
    this.stopUpdateTimer()
    this.closeCoverFd()
  }

  private startDiscovery(): void {
    if (this.discoveryTimer !== -1) {
      return
    }
    this.discoveryTimer = setInterval((): void => {
      this.refreshFormIds(false)
    }, DISCOVERY_INTERVAL_MS)
    this.refreshFormIds(true)
  }

  private stopUpdateTimer(): void {
    if (this.updateTimer !== -1) {
      clearInterval(this.updateTimer)
      this.updateTimer = -1
    }
  }

  private ensureUpdateTimer(): void {
    if (this.updateTimer !== -1) {
      return
    }
    this.tickCount = 0
    this.updateTimer = setInterval((): void => {
      this.tickCount++
      if (this.tickCount % REDISCOVER_TICKS === 0) {
        this.refreshFormIds(true)
      }
      this.pushUpdates(false)
    }, UPDATE_INTERVAL_MS)
  }

  // 发现已加桌卡片：有卡则启 1s tick，无卡停 tick；列表变化立即强推一次
  private refreshFormIds(forcePush: boolean): void {
    formProvider.getPublishedRunningFormInfos().then((infos: formInfo.RunningFormInfo[]): void => {
      const ids: string[] = []
      for (let i = 0; i < infos.length; i++) {
        const id: string = infos[i].formId
        if (id.length > 0) {
          ids.push(id)
        }
      }
      const changed: boolean = ids.length !== this.formIds.length || ids.join(',') !== this.formIds.join(',')
      this.formIds = ids
      if (ids.length > 0) {
        this.ensureUpdateTimer()
        if (changed || forcePush) {
          this.pushUpdates(true)
        }
      } else {
        this.stopUpdateTimer()
      }
    }).catch((err: BusinessError): void => {
      // 无卡片加桌时返回 16500100，视为空列表
      this.formIds = []
      this.stopUpdateTimer()
      Logger.debug(TAG, `getPublishedRunningFormInfos: ${err.code} ${err.message}`)
    })
  }

  // 1s 节流推送：快照（歌名|歌手|播放态|百分比）无变化时跳过，避免空转 IPC
  private pushUpdates(force: boolean): void {
    if (this.formIds.length === 0 || this.context === undefined) {
      return
    }
    const songId: string = AppStorage.get<string>('uplayer_current_song_id') ?? ''
    const title: string = AppStorage.get<string>('uplayer_current_title') ?? '未播放'
    const artist: string = AppStorage.get<string>('uplayer_current_artist') ?? ''
    const isPlaying: boolean = AppStorage.get<boolean>(AppStorageKeyConstants.KEY_IS_PLAY) ?? false
    const durationMs: number = AppStorage.get<number>(AppStorageKeyConstants.KEY_PROGRESS_MAX) ?? 0
    const positionMs: number = AVPlayerService.getInstance().getCurrentPositionMs()
    let percent: number = 0
    if (durationMs > 0 && positionMs >= 0) {
      percent = Math.floor(positionMs * 100 / durationMs)
    }
    if (percent < 0) {
      percent = 0
    }
    if (percent > 100) {
      percent = 100
    }
    const snapshot: string = `${songId}\n${title}\n${artist}\n${isPlaying}\n${percent}`
    if (!force && snapshot === this.lastSnapshot) {
      return
    }
    this.lastSnapshot = snapshot
    this.persistSnapshot(songId, title, artist, isPlaying, percent)
    if (songId !== this.lastCoverSongId) {
      this.refreshCoverForSong(songId)
    }
    const data: Record<string, Object> = {}
    data['title'] = title
    data['artist'] = artist
    data['isPlaying'] = isPlaying
    data['progressPercent'] = percent
    data['hasCover'] = this.coverReady
    if (this.coverReady) {
      const fd: number = this.ensureCoverFd()
      if (fd !== -1) {
        const imgs: Record<string, number> = {}
        imgs['form_cover'] = fd
        data['formImages'] = imgs
      }
    }
    const binding: formBindingData.FormBindingData = formBindingData.createFormBindingData(data)
    for (let i = 0; i < this.formIds.length; i++) {
      const formId: string = this.formIds[i]
      formProvider.updateForm(formId, binding).then((): void => {
      }).catch((err: BusinessError): void => {
        if (err.code === 16501001 || err.code === 16501003) {
          this.removeFormId(formId)
        } else {
          Logger.error(TAG, `updateForm failed: ${err.code} ${err.message}`)
        }
      })
    }
  }

  private removeFormId(formId: string): void {
    const next: string[] = []
    for (let i = 0; i < this.formIds.length; i++) {
      if (this.formIds[i] !== formId) {
        next.push(this.formIds[i])
      }
    }
    this.formIds = next
    if (next.length === 0) {
      this.stopUpdateTimer()
    }
  }

  // 播放态快照落共享偏好（仅核心键变化时写，flushSync 保证卡片进程可读）：
  // 供 PlayerFormAbility 进程在应用未运行时给出卡片初值
  private persistSnapshot(songId: string, title: string, artist: string, isPlaying: boolean, percent: number): void {
    if (!this.storeReady || this.store === undefined) {
      return
    }
    const core: string = `${songId}|${title}|${artist}|${isPlaying}|${this.coverReady}`
    if (core === this.lastPersistedCore) {
      return
    }
    this.lastPersistedCore = core
    try {
      this.store.putSync(KEY_SNAP_SONG_ID, songId)
      this.store.putSync(KEY_SNAP_TITLE, title)
      this.store.putSync(KEY_SNAP_ARTIST, artist)
      this.store.putSync(KEY_SNAP_IS_PLAYING, isPlaying)
      this.store.putSync(KEY_SNAP_PERCENT, percent)
      this.store.putSync(KEY_SNAP_HAS_COVER, this.coverReady)
      this.store.flush()
    } catch (err) {
      Logger.error(TAG, `persistSnapshot failed: ${JSON.stringify(err)}`)
    }
  }

  // 切歌时重建卡片封面：封面缓存取 PixelMap → JPEG → 沙箱缓存文件；
  // 成功后清空快照缓存强制下一 tick 携带新封面推送
  private async refreshCoverForSong(songId: string): Promise<void> {
    this.lastCoverSongId = songId
    this.closeCoverFd()
    this.coverReady = false
    if (songId.length === 0 || this.context === undefined || this.coverPreparing) {
      return
    }
    this.coverPreparing = true
    try {
      const song: SongInfo | undefined = DataService.getInstance().getSongById(songId)
      if (song === undefined) {
        return
      }
      const lease = await AudioMetadataService.getInstance()
        .acquireAlbumCover(song, AlbumCoverSize.SMALL, CoverPriority.LOW)
      if (lease === undefined) {
        return
      }
      try {
        const packer: image.ImagePacker = image.createImagePacker()
        try {
          const options: image.PackingOption = { format: 'image/jpeg', quality: 85 }
          const data: ArrayBuffer = await packer.packToData(lease.pixelMap, options)
          const file: fileIo.File =
            fileIo.openSync(this.coverPath, fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC)
          try {
            fileIo.writeSync(file.fd, data)
          } finally {
            fileIo.closeSync(file)
          }
          if (songId === this.lastCoverSongId) {
            this.coverReady = true
            this.lastSnapshot = ''
            this.pushUpdates(true)
          }
        } finally {
          packer.release()
        }
      } finally {
        lease.release()
      }
    } catch (err) {
      Logger.error(TAG, `refreshCoverForSong failed: ${JSON.stringify(err)}`)
    } finally {
      this.coverPreparing = false
    }
  }

  private ensureCoverFd(): number {
    if (this.coverFd !== -1) {
      return this.coverFd
    }
    try {
      const file: fileIo.File = fileIo.openSync(this.coverPath, fileIo.OpenMode.READ_ONLY)
      this.coverFd = file.fd
    } catch (err) {
      this.coverFd = -1
      Logger.error(TAG, `open cover fd failed: ${JSON.stringify(err)}`)
    }
    return this.coverFd
  }

  private closeCoverFd(): void {
    if (this.coverFd !== -1) {
      try {
        fileIo.closeSync(this.coverFd)
      } catch (err) {
      }
      this.coverFd = -1
    }
  }
}
