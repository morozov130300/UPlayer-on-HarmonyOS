// 碰一碰 + 隔空传送分享服务
import { harmonyShare, systemShare } from '@kit.ShareKit'
import { uniformTypeDescriptor as utd } from '@kit.ArkData'
import { fileIo as fs, fileUri } from '@kit.CoreFileKit'
import { window } from '@kit.ArkUI'
import { SongInfo } from '../model/SongInfo'
import { AppStorageKeyConstants } from '../common/constants/AppStorageKeyConstants'
import Logger from '../common/utils/Logger'

const TAG = 'ShareService'
const CAPABILITY: string = 'SystemCapability.Collaboration.HarmonyShare'

export class ShareService {
  private static instance: ShareService = new ShareService()
  private isKnockListening: boolean = false
  private isGesturesListening: boolean = false
  private capabilityRegistry: harmonyShare.SendCapabilityRegistry | undefined = undefined

  private knockCallback: (sharableTarget: harmonyShare.SharableTarget) => void =
    (sharableTarget: harmonyShare.SharableTarget): void => {
      this.handleShare('knockShare', sharableTarget)
    }

  private gesturesCallback: (sharableTarget: harmonyShare.SharableTarget) => void =
    (sharableTarget: harmonyShare.SharableTarget): void => {
      this.handleShare('gesturesShare', sharableTarget)
    }

  public static getInstance(): ShareService {
    return ShareService.instance
  }

  initialize(mainWindow: window.Window): void {
    if (!canIUse(CAPABILITY)) {
      Logger.info(TAG, 'HarmonyShare capability not supported')
      return
    }
    try {
      this.capabilityRegistry = { windowId: mainWindow.getWindowProperties().id }
      this.registerKnockShare()
      this.registerGesturesShare()
    } catch (err) {
      Logger.error(TAG, `initialize failed: ${JSON.stringify(err)}`)
    }
  }

  shutdown(): void {
    this.unregisterKnockShare()
    this.unregisterGesturesShare()
    this.capabilityRegistry = undefined
  }

  private registerKnockShare(): void {
    if (this.isKnockListening || this.capabilityRegistry === undefined) {
      return
    }
    try {
      harmonyShare.on('knockShare', this.capabilityRegistry, this.knockCallback)
      this.isKnockListening = true
      Logger.info(TAG, 'knockShare registered')
    } catch (err) {
      Logger.error(TAG, `knockShare register failed: ${JSON.stringify(err)}`)
    }
  }

  private unregisterKnockShare(): void {
    if (!this.isKnockListening || this.capabilityRegistry === undefined) {
      return
    }
    try {
      harmonyShare.off('knockShare', this.capabilityRegistry, this.knockCallback)
      this.isKnockListening = false
      Logger.info(TAG, 'knockShare unregistered')
    } catch (err) {
      Logger.error(TAG, `knockShare unregister failed: ${JSON.stringify(err)}`)
    }
  }

  private registerGesturesShare(): void {
    if (this.isGesturesListening || this.capabilityRegistry === undefined) {
      return
    }
    try {
      harmonyShare.on('gesturesShare', this.capabilityRegistry, this.gesturesCallback)
      this.isGesturesListening = true
      Logger.info(TAG, 'gesturesShare registered')
    } catch (err) {
      Logger.error(TAG, `gesturesShare register failed: ${JSON.stringify(err)}`)
    }
  }

  private unregisterGesturesShare(): void {
    if (!this.isGesturesListening || this.capabilityRegistry === undefined) {
      return
    }
    try {
      harmonyShare.off('gesturesShare', this.capabilityRegistry, this.gesturesCallback)
      this.isGesturesListening = false
      Logger.info(TAG, 'gesturesShare unregistered')
    } catch (err) {
      Logger.error(TAG, `gesturesShare unregister failed: ${JSON.stringify(err)}`)
    }
  }

  private handleShare(source: string, sharableTarget: harmonyShare.SharableTarget): void {
    Logger.info(TAG, `handleShare from ${source}`)
    this.shareCurrentSong(sharableTarget).catch((err: Error) => {
      Logger.error(TAG, `shareCurrentSong async failed: ${JSON.stringify(err)}`)
    })
  }

  private async shareCurrentSong(sharableTarget: harmonyShare.SharableTarget): Promise<void> {
    const songList: SongInfo[] | undefined = AppStorage.get(AppStorageKeyConstants.KEY_SONG_LIST)
    const currentTitle: string = AppStorage.get<string>('uplayer_current_title') ?? ''
    const currentIndex: number = AppStorage.get<number>(AppStorageKeyConstants.KEY_SELECT_INDEX) ?? -1
    if (currentTitle.length === 0 || songList === undefined || currentIndex < 0 || currentIndex >= songList.length) {
      await sharableTarget.clarifyNonShare({ message: '当前没有正在播放的歌曲' })
      return
    }

    const song: SongInfo = songList[currentIndex]
    const accessPath: string = song.uri.length > 0 ? song.uri : song.filePath
    if (accessPath.length === 0 || !song.isAvailable) {
      await sharableTarget.clarifyNonShare({ message: '当前歌曲文件不可用' })
      return
    }

    try {
      fs.accessSync(accessPath)
      const shareUri: string = accessPath.indexOf('://') >= 0 ? accessPath : fileUri.getUriFromPath(accessPath)
      const shareRecord: systemShare.SharedRecord = {
        utd: this.getAudioUtd(song.fileName),
        uri: shareUri,
        title: song.title.length > 0 ? song.title : song.name,
        description: song.artist
      }
      await sharableTarget.share(new systemShare.SharedData(shareRecord))
      Logger.info(TAG, `Shared song file: ${song.title}`)
    } catch (err) {
      Logger.error(TAG, `shareCurrentSong failed: ${JSON.stringify(err)}`)
      await this.rejectNoContent(sharableTarget)
    }
  }

  private getAudioUtd(fileName: string): string {
    const lowerName: string = fileName.toLowerCase()
    if (lowerName.endsWith('.mp3')) {
      return utd.UniformDataType.MP3
    }
    if (lowerName.endsWith('.flac')) {
      return utd.UniformDataType.FLAC
    }
    if (lowerName.endsWith('.aac')) {
      return utd.UniformDataType.AAC
    }
    if (lowerName.endsWith('.m4a') || lowerName.endsWith('.mp4')) {
      return utd.UniformDataType.MPEG_4_AUDIO
    }
    if (lowerName.endsWith('.ogg')) {
      return utd.UniformDataType.OGG
    }
    if (lowerName.endsWith('.wav')) {
      return utd.UniformDataType.WAVEFORM_AUDIO
    }
    if (lowerName.endsWith('.aiff') || lowerName.endsWith('.aif')) {
      return utd.UniformDataType.AIFF
    }
    if (lowerName.endsWith('.alac')) {
      return utd.UniformDataType.ALAC
    }
    if (lowerName.endsWith('.mp2')) {
      return utd.UniformDataType.MP2
    }
    if (lowerName.endsWith('.mka')) {
      return utd.UniformDataType.MATROSKA_AUDIO
    }
    return utd.UniformDataType.AUDIO
  }

  private async rejectNoContent(sharableTarget: harmonyShare.SharableTarget): Promise<void> {
    try {
      await sharableTarget.reject(harmonyShare.SharableErrorCode.NO_CONTENT_ERROR)
    } catch (err) {
      Logger.error(TAG, `reject failed: ${JSON.stringify(err)}`)
    }
  }
}
