// 一碰传 (Knock Share) + 隔空抓取 (Gestures Share) 服务
import { harmonyShare, systemShare } from '@kit.ShareKit'
import { uniformTypeDescriptor as utd } from '@kit.ArkData'
import { fileUri } from '@kit.CoreFileKit'
import { common } from '@kit.AbilityKit'
import { window } from '@kit.ArkUI'
import { SongInfo } from '../model/SongInfo'
import { AppStorageKeyConstants } from '../common/constants/AppStorageKeyConstants'
import Logger from '../common/utils/Logger'

const TAG = 'ShareService'
const CAPABILITY: string = 'SystemCapability.Collaboration.HarmonyShare'

interface GesturesShareOptions {
  windowId: number
}

export class ShareService {
  private static instance: ShareService = new ShareService()
  private isKnockListening: boolean = false
  private isGesturesListening: boolean = false
  private context: common.UIAbilityContext | undefined = undefined
  private windowId: number = -1
  private pageContext: string = 'home'

  // 回调引用必须为实例属性，off()需传入同一引用才能注销
  private knockCallback: (sharableTarget: harmonyShare.SharableTarget) => void = (sharableTarget: harmonyShare.SharableTarget): void => {
    this.handleShare('knockShare', sharableTarget)
  }

  private gesturesCallback: (sharableTarget: harmonyShare.SharableTarget) => void = (sharableTarget: harmonyShare.SharableTarget): void => {
    this.handleShare('gesturesShare', sharableTarget)
  }

  public static getInstance(): ShareService {
    return ShareService.instance
  }

  // 注册分享监听，pageContext: 'home' 或 'player'
  registerListeners(pageContext: string): void {
    if (!canIUse(CAPABILITY)) {
      Logger.info(TAG, 'HarmonyShare capability not supported')
      return
    }
    this.pageContext = pageContext
    this.context = AppStorage.get<common.UIAbilityContext>(AppStorageKeyConstants.KEY_UI_ABILITY_CONTEXT)
    this.resolveWindowId()
    this.registerKnockShare(pageContext)
    this.registerGesturesShare(pageContext)
  }

  // 注销所有分享监听
  unregisterListeners(): void {
    this.unregisterKnockShare()
    this.unregisterGesturesShare()
  }

  private resolveWindowId(): void {
    if (this.windowId !== -1) {
      return
    }
    const win: window.Window | undefined = AppStorage.get<window.Window>(AppStorageKeyConstants.KEY_WINDOW)
    if (win !== undefined) {
      try {
        const props: window.WindowProperties = win.getWindowProperties()
        this.windowId = props.id
      } catch (err) {
        Logger.error(TAG, `getWindowProperties failed: ${JSON.stringify(err)}`)
      }
    }
  }

  // ═══════════ Knock Share (碰一碰) ═══════════

  private registerKnockShare(pageContext: string): void {
    if (this.isKnockListening) {
      return
    }
    try {
      harmonyShare.on('knockShare', this.knockCallback)
      this.isKnockListening = true
      Logger.info(TAG, `knockShare registered, context: ${pageContext}`)
    } catch (err) {
      Logger.error(TAG, `knockShare register failed: ${JSON.stringify(err)}`)
    }
  }

  private unregisterKnockShare(): void {
    if (!this.isKnockListening) {
      return
    }
    try {
      harmonyShare.off('knockShare', this.knockCallback)
      this.isKnockListening = false
      Logger.info(TAG, 'knockShare unregistered')
    } catch (err) {
      Logger.error(TAG, `knockShare unregister failed: ${JSON.stringify(err)}`)
    }
  }

  // ═══════════ Gestures Share (隔空抓取) ═══════════

  private registerGesturesShare(pageContext: string): void {
    if (this.isGesturesListening) {
      return
    }
    if (this.windowId === -1) {
      Logger.warn(TAG, 'gesturesShare: windowId not available')
      return
    }
    try {
      const options: GesturesShareOptions = { windowId: this.windowId }
      harmonyShare.on('gesturesShare', options, this.gesturesCallback)
      this.isGesturesListening = true
      Logger.info(TAG, `gesturesShare registered, context: ${pageContext}`)
    } catch (err) {
      Logger.error(TAG, `gesturesShare register failed: ${JSON.stringify(err)}`)
    }
  }

  private unregisterGesturesShare(): void {
    if (!this.isGesturesListening) {
      return
    }
    try {
      harmonyShare.off('gesturesShare', this.gesturesCallback)
      this.isGesturesListening = false
      Logger.info(TAG, 'gesturesShare unregistered')
    } catch (err) {
      Logger.error(TAG, `gesturesShare unregister failed: ${JSON.stringify(err)}`)
    }
  }

  // ═══════════ Share Handler ═══════════

  private handleShare(source: string, sharableTarget: harmonyShare.SharableTarget): void {
    Logger.info(TAG, `handleShare from ${source}`)
    try {
      // 判断当前页面上下文：player页面分享歌曲文件，home页面分享播放状态
      const currentPage: string = this.getCurrentPageContext()
      if (currentPage === 'player') {
        this.shareSongFile(sharableTarget).catch((err: Error) => {
          Logger.error(TAG, `shareSongFile async failed: ${JSON.stringify(err)}`)
        })
      } else {
        this.sharePlaybackState(sharableTarget)
      }
    } catch (err) {
      Logger.error(TAG, `handleShare error: ${JSON.stringify(err)}`)
      try {
        sharableTarget.reject(harmonyShare.SharableErrorCode.NO_CONTENT_ERROR)
      } catch (rejectErr) {
        Logger.error(TAG, `reject failed: ${JSON.stringify(rejectErr)}`)
      }
    }
  }

  // 获取当前页面上下文
  private getCurrentPageContext(): string {
    return this.pageContext
  }

  // 分享当前歌曲文件
  private async shareSongFile(sharableTarget: harmonyShare.SharableTarget): Promise<void> {
    const songList: SongInfo[] | undefined = AppStorage.get(AppStorageKeyConstants.KEY_SONG_LIST)
    const currentIndex: number = AppStorage.get<number>(AppStorageKeyConstants.KEY_SELECT_INDEX) ?? 0
    if (songList === undefined || currentIndex < 0 || currentIndex >= songList.length) {
      const opts: Record<string, string> = {}
      opts['message'] = '当前没有正在播放的歌曲'
      await sharableTarget.clarifyNonShare(opts)
      return
    }
    const song: SongInfo = songList[currentIndex]
    const accessPath: string = song.uri.length > 0 ? song.uri : song.filePath
    try {
      const shareUri: string = accessPath.indexOf('://') >= 0 ? accessPath : fileUri.getUriFromPath(accessPath)
      const shareRecord: systemShare.SharedRecord = {
        utd: utd.UniformDataType.AUDIO,
        uri: shareUri,
        title: song.title,
        description: song.artist
      }
      const shareData: systemShare.SharedData = new systemShare.SharedData(shareRecord)
      await sharableTarget.share(shareData)
      Logger.info(TAG, `Shared song file: ${song.title}`)
    } catch (err) {
      Logger.error(TAG, `shareSongFile failed: ${JSON.stringify(err)}`)
      await sharableTarget.reject(harmonyShare.SharableErrorCode.NO_CONTENT_ERROR)
    }
  }

  // 分享当前播放状态
  private sharePlaybackState(sharableTarget: harmonyShare.SharableTarget): void {
    const title: string = AppStorage.get<string>('uplayer_current_title') ?? ''
    const artist: string = AppStorage.get<string>('uplayer_current_artist') ?? ''
    const currentTime: number | undefined = AppStorage.get<number>(AppStorageKeyConstants.KEY_CURRENT_TIME)
    const progress: number = currentTime ?? 0

    if (title.length === 0) {
      const opts: Record<string, string> = {}
      opts['message'] = '当前没有正在播放的歌曲'
      sharableTarget.clarifyNonShare(opts)
      return
    }

    const stateRecord: Record<string, Object> = {}
    stateRecord['title'] = title
    stateRecord['artist'] = artist
    stateRecord['progress'] = progress as Object
    const content: string = JSON.stringify(stateRecord)

    const shareData: systemShare.SharedData = new systemShare.SharedData({
      utd: utd.UniformDataType.TEXT,
      content: content,
      title: 'UPlayer 播放状态',
      description: `${title} - ${artist}`
    })
    sharableTarget.share(shareData)
    Logger.info(TAG, `Shared playback state: ${title} - ${artist}`)
  }
}
