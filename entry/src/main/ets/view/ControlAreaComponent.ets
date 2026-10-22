// ArkUI 26 Beta1: 接口定义变更（误报，本项目已是Stage模型）+ UX视觉布局变更（Text默认开启沉浸式材质，系统行为）
import {
  curves, PromptAction, uiMaterial, uiAppearance
} from '@kit.ArkUI';
import { DatePickerComponent, DisplayMode, TimeFormat, DatePickerComponentResult } from '@ohos.arkui.advanced.DatePickerComponent';

import { MusicPlayMode, PlayerConstants, PlayModeSwitchList } from '../common/constants/PlayerConstants';
import { StyleConstants } from '../common/constants/StyleConstants';
import Logger from '../common/utils/Logger';
import { SongInfo } from '../model/SongInfo';
import { SongDataSource } from '../viewmodel/SongDataSource';
import { AVPlayerService } from '../service/AVPlayerService';
import { ColorHelper } from '../common/utils/ColorHelper';
import { common } from '@kit.AbilityKit';
import { MediaTools } from '../common/utils/mediautils/MediaTools';
import { AppStorageKeyConstants } from '../common/constants/AppStorageKeyConstants';
import { audio } from '@kit.AudioKit';
import { AVCastPicker } from '@kit.AVSessionKit';
import { BluetoothAudioService } from '../service/BluetoothAudioService';
import { BusinessError, SuppressWarnings, SuppressWarningsType } from '@kit.BasicServicesKit';
import { AlbumCover } from '../component/AlbumCover';
import { AVSessionController } from '../common/utils/mediautils/AVSessionController';
import { DataService } from '../service/DataService';
import { createStyleGlassMaterial, createToastGlassMaterial, DEFAULT_GLASS_STYLE, showToastGlassMaterial } from '../common/utils/GlassUtil';
import { isDarkThemeEffective } from '../common/utils/ThemeUtil';
import { applyMetadataToSong, extractSongMetadata, saveSongTagsToFile, TagsWriteResult } from '../service/MetadataTask';
import { ScaleButton } from '../component/ScaleButton';

const TAG = 'ControlAreaComponent';
const SEEK_SETTLE_MS: number = 2000;
const SKIP_MS: number = 15000;
const TIMER_PRESET_MINUTES: number[] = [5, 10, 15, 20, 30, 45, 60];
const TIMER_SONG_PRESETS: number[] = [1, 3, 5, 10];

@Component
@SuppressWarnings({rules: [SuppressWarningsType.SYSCAP, SuppressWarningsType.COMPATIBILITY]})
export struct ControlAreaComponent {
  @StorageLink(AppStorageKeyConstants.KEY_IS_PLAY) isPlay: boolean = false;
  @StorageLink(AppStorageKeyConstants.KEY_CURRENT_TIME) currentTime: string = '00:00';
  @StorageLink(AppStorageKeyConstants.KEY_TOTAL_TIME) totalTime: string = '00:00';
  @StorageLink(AppStorageKeyConstants.KEY_PROGRESS) value: number = 0;
  @StorageLink(AppStorageKeyConstants.KEY_PROGRESS_MAX) max: number = 0;
  @State playModeIndex: number = 0;
  @StorageLink(AppStorageKeyConstants.KEY_PAGE_SHOW_TIME) pageShowTime: number = 0;
  @StorageLink(AppStorageKeyConstants.KEY_SONG_LIST) @Watch('onSongListChange') songList: SongInfo[] = [];
  @State isShowPlayList: boolean = false;
  @StorageLink(AppStorageKeyConstants.KEY_PLAY_MODE) @Watch('onPlayModeChange')
  playMode: MusicPlayMode = PlayModeSwitchList[this.playModeIndex];
  @StorageLink(AppStorageKeyConstants.KEY_SELECT_INDEX) selectIndex: number = 0;
  // 按 id 解析当前播放歌曲用于显示，避免队列下标失配
  @StorageLink('uplayer_current_song_id') currentSongId: string = '';
  @StorageLink(AppStorageKeyConstants.KEY_CURRENT_SPEED) speed: number = 1;
  @StorageLink(AppStorageKeyConstants.KEY_CURRENT_VOLUME) volume: number = 0;
  @State isShowSpeedBuild: boolean = false;
  @State isShowVolumeBuild: boolean = false;
  @State songTimeFontSize: number = 10;
  @State songTimeFontColor: ResourceColor = '#B3FFFFFF';
  @State trackThickness: number = 6;
  @State isShowMorePanel: boolean = false;
  // 「更多」面板内部层级：0 主列表 / 1 歌曲信息 / 2 定时关闭 / 3 输出设备。
  // 二级页在同一 sheet 内原地覆盖显示，不另开弹窗
  @State morePanelLevel: number = 0;
  @State timerRemainingSeconds: number = 0;
  @State timerIntervalID: number = -1;
  @State activePresetMinutes: number = -1;
  @State customHours: number = 0;
  @State customMinutes: number = 0;
  @State customSeconds: number = 0;
  @State selectedPresetMinutes: number = -1;
  @State isShowCustomPicker: boolean = false;
  // 按歌曲数定时（P0-1）：AVPlayerService 在每首自然完曲时递减并写回，
  // 这里仅 @StorageProp 单向同步展示；写路径全部经 AppStorage.setOrCreate
  @StorageProp(AppStorageKeyConstants.KEY_TIMER_SONGS_REMAINING) timerSongsRemaining: number = 0;
  @State activePresetSongs: number = -1;
  @State isShowSongCountPicker: boolean = false;
  @State customSongCountText: string = '';
  @State edittingFieldIndex: number = -1;
  @State edittingValue: string = '';
  private scroller: Scroller = new Scroller();
  private context: common.UIAbilityContext | undefined = AppStorage.get(AppStorageKeyConstants.KEY_UI_ABILITY_CONTEXT);
  uiContext: UIContext = this.getUIContext();
  promptAction: PromptAction = this.uiContext.getPromptAction();
  private avPlayerService: AVPlayerService = AVPlayerService.getInstance();
  private songDataSource: SongDataSource = new SongDataSource([]);
  private volumeManager: audio.AudioVolumeManager | undefined = undefined;
  private isVolumeListenerRegistered: boolean = false;
  // 系统媒体音量最大格数（getMaxVolumeByStream，API 20+）：手机常见 15，PC 可能是 20/100，
  // 归一化显示与 AVVolumePanel 档位映射都必须用它，不能硬编码
  @State maxVolumeLevel: number = 15;
  // 「更多」面板：蓝牙 A2DP 音频行（P1-4）。编解码能力为系统应用接口三方不可查，
  // 仅展示 设备名/连接态/播放态；KEY_BLUETOOTH_AUDIO_REVISION 变化时刷新
  @StorageProp(AppStorageKeyConstants.KEY_BLUETOOTH_AUDIO_REVISION) @Watch('onBluetoothAudioRevision')
  private bluetoothAudioRevision: number = 0;
  @State bluetoothAudioLabel: string = '';
  private bluetoothAudioService: BluetoothAudioService = BluetoothAudioService.getInstance();

  private settingTextColor(): ResourceColor {
    const themeMode: string = AppStorage.get<string>('uplayer_theme_mode') ?? 'system'
    if (themeMode === 'dark') {
      return '#FFFFFF'
    }
    if (themeMode === 'system') {
      try {
        return uiAppearance.getDarkMode() === uiAppearance.DarkMode.ALWAYS_DARK ? '#FFFFFF' : ColorHelper.darken(this.primaryColor, 0.35)
      } catch (e) {
        return ColorHelper.darken(this.primaryColor, 0.35)
      }
    }
    return ColorHelper.darken(this.primaryColor, 0.35)
  }
  private matchPresetMinutes(totalSeconds: number): number {
    if (totalSeconds <= 0 || totalSeconds % 60 !== 0) {
      return -1
    }
    const minutes: number = totalSeconds / 60
    return TIMER_PRESET_MINUTES.indexOf(minutes) >= 0 ? minutes : -1
  }
  // 正在倒计时的预设项：倒计时只跟随它，不受面板里「待确认选择」影响
  private isTimerPresetActive(min: number): boolean {
    return this.timerRemainingSeconds > 0 && this.activePresetMinutes === min
  }
  // 用户刚点选、尚未点确认的预设项
  private isTimerPresetPending(min: number): boolean {
    return this.selectedPresetMinutes === min && this.activePresetMinutes !== min
  }
  private isEffectiveDarkMode(): boolean {
    return isDarkThemeEffective(AppStorage.get<string>('uplayer_theme_mode') ?? 'system')
  }
  private streamVolumeChangeCallback = (streamVolumeEvent: audio.StreamVolumeEvent): void => {
    const maxVol: number = this.maxVolumeLevel > 0 ? this.maxVolumeLevel : 15;
    const newVol: number = streamVolumeEvent.volume / maxVol;
    this.volume = newVol;
    AppStorage.setOrCreate(AppStorageKeyConstants.KEY_CURRENT_VOLUME, newVol);
  };
  @StorageLink('uplayer_primary_color') primaryColor: string = '#007DFF';
  @StorageLink('uplayer_font_size_scale') fontSizeScale: number = 1.0;
  // 显示大小必须用 @StorageLink 响应式读取：AppStorage.get 非响应式，调节后组件不刷新
  @StorageLink('uplayer_display_size_scale') displaySizeScale: number = 1.0;
  // 组件风格（immersive 玻璃 / classic 经典）：驱动弹窗类（Popup/Sheet）与选择类（Slider）材质
  @StorageLink('uplayer_tab_style') tabStyle: string = 'classic';

  private scaledFont(size: number): number {
    return Math.round(size * this.fontSizeScale)
  }

  private scaledSize(size: number): number {
    return Math.round(size * this.displaySizeScale)
  }

  // Toast 液态玻璃材质（API 26+ 调用级 systemMaterial）：
  // 「系统组件液态玻璃」开关已删除，设备支持时固定挂材质；能力不足返回 undefined，走系统默认样式
  private toastGlassMaterial(): uiMaterial.Material | undefined {
    return createToastGlassMaterial(DEFAULT_GLASS_STYLE)
  }

  // 组件风格驱动的弹窗与滑块材质：玻璃风格 → 液态玻璃；经典风格 → Material.empty 显式关闭；
  // 设备不支持 → undefined（低版本不得触碰 uiMaterial.Material.empty 符号）
  private styleGlassMaterial(): uiMaterial.Material | undefined {
    return createStyleGlassMaterial(this.tabStyle, DEFAULT_GLASS_STYLE)
  }

  aboutToAppear(): void {
    this.songDataSource.reloadData(this.songList);
    this.syncPlayModeIndex();
    this.syncSystemVolume();
    this.restoreTimerState();
    this.updateBluetoothAudioLabel();
  }

  aboutToDisappear(): void {
    if (this.timerIntervalID !== -1) {
      clearInterval(this.timerIntervalID);
      this.timerIntervalID = -1;
    }
    if (this.volumeManager !== undefined && this.isVolumeListenerRegistered) {
      this.volumeManager.off('streamVolumeChange', this.streamVolumeChangeCallback);
      this.isVolumeListenerRegistered = false;
    }
  }

  onSongListChange(): void {
    this.songDataSource.reloadData(this.songList);
  }

  onPlayModeChange(): void {
    this.syncPlayModeIndex();
  }

  private async syncSystemVolume(): Promise<void> {
    try {
      const audioManager: audio.AudioManager = audio.getAudioManager();
      this.volumeManager = audioManager.getVolumeManager();
      if (!this.isVolumeListenerRegistered) {
        this.volumeManager.on('streamVolumeChange', audio.StreamUsage.STREAM_USAGE_MUSIC,
          this.streamVolumeChangeCallback);
        this.isVolumeListenerRegistered = true;
      }
      const currentVol: number = this.volumeManager.getVolumeByStream(audio.StreamUsage.STREAM_USAGE_MUSIC);
      // 系统接口取真实最大格数（API 20+），失败时保持 15 的保守兜底
      try {
        const maxVol: number = this.volumeManager.getMaxVolumeByStream(audio.StreamUsage.STREAM_USAGE_MUSIC);
        if (maxVol > 0) {
          this.maxVolumeLevel = maxVol;
          AppStorage.setOrCreate<number>(AppStorageKeyConstants.KEY_VOL_PANEL_MAX, maxVol);
        }
      } catch (err) {
        Logger.warn(TAG, `getMaxVolumeByStream failed: ${JSON.stringify(err)}`);
      }
      this.volume = currentVol / (this.maxVolumeLevel > 0 ? this.maxVolumeLevel : 15);
    } catch (err) {
      Logger.error(TAG, `syncSystemVolume failed: ${JSON.stringify(err)}`);
    }
  }

  // ─── 音量弹层：AVVolumePanel 只在音量真正变化时显示系统音量条，无法被 visibility 主动弹出，
  // 官方 FAQ faqs-audio-52 做法：自定义 Slider 弹层驱动 volumeLevel 写系统音量；
  // 系统音量条已由 PlayerInfoComponent 常驻 AVVolumePanel 的负 position 隐藏，
  // 音量键变化经 streamVolumeChange 同步进 Slider
  toggleVolumePanel(): void {
    this.isShowVolumeBuild = !this.isShowVolumeBuild;
  }

  // ─── 蓝牙音频行（P1-4）：A2DP 状态展示 ───

  onBluetoothAudioRevision(): void {
    this.updateBluetoothAudioLabel();
  }

  updateBluetoothAudioLabel(): void {
    const svc: BluetoothAudioService = this.bluetoothAudioService;
    if (!svc.isPermissionGranted()) {
      this.bluetoothAudioLabel = '未授权，点击重试';
      return;
    }
    if (!svc.isSupported()) {
      this.bluetoothAudioLabel = '设备不支持蓝牙音频';
      return;
    }
    if (!svc.isBluetoothEnabled()) {
      this.bluetoothAudioLabel = '蓝牙未开启';
      return;
    }
    if (!svc.isConnectedDevice()) {
      this.bluetoothAudioLabel = '未连接蓝牙音频设备';
      return;
    }
    const playState: string = svc.isPlaying() ? '正在播放' : '已连接';
    this.bluetoothAudioLabel = `${svc.getDeviceName()} · ${playState}`;
  }

  // 整行灰显判据：设备不支持 / 已授权但蓝牙关闭；未授权可点击重试，不灰显
  private isBluetoothRowDisabled(): boolean {
    const svc: BluetoothAudioService = this.bluetoothAudioService;
    if (!svc.isPermissionGranted()) {
      return false;
    }
    if (!svc.isSupported()) {
      return true;
    }
    return !svc.isBluetoothEnabled();
  }

  // 打开「更多」面板时调用：allowPrompt=false 只静默查询已授权状态，绝不弹权限框
  //（首次安装时弹框与半模态抢焦点会让面板打不开且吞掉所有输入）
  // 点击「蓝牙音频」行时调用：allowPrompt=true，由用户主动触发授权
  private initBluetoothAudio(allowPrompt: boolean): void {
    this.bluetoothAudioService.ensurePermissionAndInit(this.context, allowPrompt)
      .then((): void => {
        this.updateBluetoothAudioLabel();
      })
      .catch((err: BusinessError): void => {
        Logger.warn(TAG, `bluetooth ensurePermissionAndInit failed: ${JSON.stringify(err)}`);
      });
  }

  private syncPlayModeIndex(): void {
    const index: number = PlayModeSwitchList.indexOf(this.playMode);
    this.playModeIndex = index >= 0 ? index : 0;
    if (index < 0) {
      this.playMode = PlayModeSwitchList[0];
    }
  }

  switchPlayMode() {
    if (this.playModeIndex === PlayModeSwitchList.length - 1) {
      this.playModeIndex = 0;
    } else {
      this.playModeIndex++;
    }
    this.playMode = PlayModeSwitchList[this.playModeIndex];
    AVSessionController.getInstance().updatePlayMode(this.playMode);
    Logger.info(TAG, 'playModeIndex is' + this.playModeIndex);
    try {
      // openToast 返回 Promise，失败走异步 reject：必须用 .catch 兜底，try/catch 只能拦同步抛出
      this.promptAction.openToast({
        message: `${this.playMode === MusicPlayMode.ORDER ?
          (this.context?.resourceManager?.getStringSync($r('app.string.sequential_playback').id) ?? '') :
          this.playMode === MusicPlayMode.RANDOM ?
            (this.context?.resourceManager?.getStringSync($r('app.string.random_playback').id) ?? '') :
            (this.context?.resourceManager?.getStringSync($r('app.string.single_playback').id) ?? '')}`,
        systemMaterial: this.toastGlassMaterial(),
      }).catch((err: BusinessError) => {
        Logger.error(TAG, `openToast rejected: code=${err.code}, message=${err.message}`);
      });
    } catch (err) {
      Logger.error(TAG, `openToast failed: ${JSON.stringify(err)}`);
    }
  }

  private skipForward(): void {
    const newPos: number = Math.min(this.value + SKIP_MS, this.max);
    this.avPlayerService.seek(newPos);
    this.pageShowTime = 0;
  }

  private skipBackward(): void {
    const newPos: number = Math.max(this.value - SKIP_MS, 0);
    this.avPlayerService.seek(newPos);
    this.pageShowTime = 0;
  }

  // ═══════════ 定时关闭 ═══════════

  private restoreTimerState(): void {
    const stored: number = AppStorage.get<number>(AppStorageKeyConstants.KEY_TIMER_REMAINING) ?? 0
    if (stored > 0) {
      const remaining: number = stored <= 90 ? stored * 60 : stored
      this.timerRemainingSeconds = remaining
      const storedPreset: number = AppStorage.get<number>(AppStorageKeyConstants.KEY_TIMER_PRESET_MINUTES) ?? -1
      this.activePresetMinutes = TIMER_PRESET_MINUTES.indexOf(storedPreset) >= 0 ? storedPreset : -1
      this.startTimer()
    }
    // 按歌曲数定时恢复（P0-1）：计数经 @StorageProp 自动同步，这里只恢复预设高亮
    this.activePresetSongs = AppStorage.get<number>(AppStorageKeyConstants.KEY_TIMER_PRESET_SONGS) ?? -1
  }

  private startTimer(): void {
    this.stopTimer()
    if (this.timerRemainingSeconds <= 0) {
      return
    }
    this.timerIntervalID = setInterval(() => {
      if (this.timerRemainingSeconds <= 1) {
        this.clearTimer()
        try {
          // 时间模式到期：按设置的淡出时长平滑降至静音后停止（P0-1）
          this.avPlayerService.fadeOutAndStop()
        } catch (e) {
          Logger.error(TAG, `timer stop failed: ${JSON.stringify(e)}`)
        }
        return
      }
      this.timerRemainingSeconds--
      AppStorage.setOrCreate(AppStorageKeyConstants.KEY_TIMER_REMAINING, this.timerRemainingSeconds)
    }, 1000)
  }

  // 仅清时间定时（切换到按歌曲数模式时的互斥清理）
  private clearTimeTimer(): void {
    this.stopTimer()
    this.timerRemainingSeconds = 0
    this.activePresetMinutes = -1
    AppStorage.setOrCreate(AppStorageKeyConstants.KEY_TIMER_REMAINING, 0)
    AppStorage.setOrCreate(AppStorageKeyConstants.KEY_TIMER_PRESET_MINUTES, -1)
  }

  private clearTimer(): void {
    this.clearTimeTimer()
    // 同步清按歌曲数定时（P0-1）
    this.activePresetSongs = -1
    AppStorage.setOrCreate(AppStorageKeyConstants.KEY_TIMER_SONGS_REMAINING, 0)
    AppStorage.setOrCreate(AppStorageKeyConstants.KEY_TIMER_PRESET_SONGS, -1)
  }

  private stopTimer(): void {
    if (this.timerIntervalID !== -1) {
      clearInterval(this.timerIntervalID)
      this.timerIntervalID = -1
    }
  }

  private setTimerSeconds(totalSeconds: number): void {
    if (totalSeconds <= 0) {
      return
    }
    // 时间模式与按歌曲数模式互斥：启动时间定时即取消歌曲数定时（P0-1）
    this.activePresetSongs = -1
    AppStorage.setOrCreate(AppStorageKeyConstants.KEY_TIMER_SONGS_REMAINING, 0)
    AppStorage.setOrCreate(AppStorageKeyConstants.KEY_TIMER_PRESET_SONGS, -1)
    this.timerRemainingSeconds = totalSeconds
    this.activePresetMinutes = this.matchPresetMinutes(totalSeconds)
    this.startTimer()
    AppStorage.setOrCreate(AppStorageKeyConstants.KEY_TIMER_REMAINING, totalSeconds)
    AppStorage.setOrCreate(AppStorageKeyConstants.KEY_TIMER_PRESET_MINUTES, this.activePresetMinutes)
  }

  // ═══════════ 按歌曲数定时（P0-1）═══════════

  // 启动歌曲数定时：与时间模式互斥；AVPlayerService 每首自然完曲递减，
  // 最后一首曲尾按淡出时长设置平滑淡出后停止
  private setTimerSongs(count: number): void {
    if (count <= 0 || count > 99) {
      return
    }
    this.clearTimeTimer()
    this.activePresetSongs = TIMER_SONG_PRESETS.indexOf(count) >= 0 ? count : -1
    this.isShowSongCountPicker = false
    AppStorage.setOrCreate(AppStorageKeyConstants.KEY_TIMER_SONGS_REMAINING, count)
    AppStorage.setOrCreate(AppStorageKeyConstants.KEY_TIMER_PRESET_SONGS, this.activePresetSongs)
  }

  private isTimerSongsPresetActive(count: number): boolean {
    return this.timerSongsRemaining > 0 && this.activePresetSongs === count
  }

  // 歌曲数模式自定义定时进行中（非预设值）：高亮「自定义」入口
  private isTimerSongsCustomActive(): boolean {
    return this.timerSongsRemaining > 0 && this.activePresetSongs < 0
  }

  // 自定义歌曲数输入合法性（1-99 的整数）
  private isCustomSongCountValid(): boolean {
    const parsed: number = parseInt(this.customSongCountText)
    return Number.isFinite(parsed) && parsed >= 1 && parsed <= 99
  }

  private customSongCountValue(): number {
    return parseInt(this.customSongCountText)
  }

  private formatTimerCountdown(totalSeconds: number): string {
    const h: number = Math.floor(totalSeconds / 3600)
    const m: number = Math.floor((totalSeconds % 3600) / 60)
    const s: number = totalSeconds % 60
    const mm: string = m < 10 ? '0' + m : '' + m
    const ss: string = s < 10 ? '0' + s : '' + s
    if (h > 0) {
      return `${h}:${mm}:${ss}`
    }
    return `${mm}:${ss}`
  }

  private startEditField(index: number, currentValue: string): void {
    this.edittingFieldIndex = index;
    this.edittingValue = currentValue;
  }

  private cancelEditField(): void {
    this.edittingFieldIndex = -1;
    this.edittingValue = '';
  }

  private currentSong(): SongInfo {
    return DataService.currentSongFromList(this.songList, this.currentSongId);
  }

  // 文件大小格式化：B/KB/MB
  private formatFileSize(bytes: number): string {
    if (bytes <= 0) {
      return ''
    }
    if (bytes >= 1024 * 1024) {
      return `${(bytes / (1024 * 1024)).toFixed(2)} MB`
    }
    if (bytes >= 1024) {
      return `${(bytes / 1024).toFixed(1)} KB`
    }
    return `${bytes} B`
  }

  // 打开歌曲信息面板时对缺少轨道级元数据的歌曲（旧库导入于扩展字段之前）懒解析补齐：
  // 16 个可编辑字段允许用户编辑，解析结果不得覆盖已编辑值，应用后恢复原值
  private refreshSongMetadataIfNeeded(): void {
    const song: SongInfo = this.currentSong()
    if (song.id.length === 0) {
      return
    }
    if (song.bitrate > 0 && song.channels.length > 0 && song.fileSize > 0) {
      return
    }
    const sourceUri: string = song.uri.length > 0 ? song.uri : song.filePath
    extractSongMetadata(sourceUri).then((record: Record<string, string> | undefined) => {
      if (record === undefined) {
        return
      }
      const target: SongInfo = this.currentSong()
      if (target.id !== song.id) {
        return
      }
      const savedTitle: string = target.title
      const savedArtist: string = target.artist
      const savedAlbum: string = target.album
      const savedGenre: string = target.genre
      const savedYear: string = target.year
      const savedTrack: string = target.track
      const savedDisc: string = target.disc
      const savedComposer: string = target.composer
      const savedAlbumArtist: string = target.albumArtist
      const savedAuthor: string = target.author
      const savedLanguage: string = target.language
      const savedDateTime: string = target.dateTime
      const savedEncoder: string = target.encoder
      const savedComment: string = target.comment
      const savedDescription: string = target.description
      const savedConductor: string = target.conductor
      applyMetadataToSong(target, record)
      target.title = savedTitle
      target.artist = savedArtist
      target.album = savedAlbum
      target.genre = savedGenre
      target.year = savedYear
      target.track = savedTrack
      target.disc = savedDisc
      target.composer = savedComposer
      target.albumArtist = savedAlbumArtist
      target.author = savedAuthor
      target.language = savedLanguage
      target.dateTime = savedDateTime
      target.encoder = savedEncoder
      target.comment = savedComment
      target.description = savedDescription
      target.conductor = savedConductor
      DataService.getInstance().updateSongFields(target.id, DataService.getInstance().getSongs())
    }).catch((err: BusinessError) => {
      Logger.warn(TAG, `refresh song metadata failed: ${JSON.stringify(err)}`)
    })
  }

  // 将编辑值应用到歌曲的对应可编辑字段；有变更返回 true
  private applyEditToSong(song: SongInfo, index: number, value: string): boolean {
    switch (index) {
      case 0:
        if (song.title !== value) {
          song.title = value
          return true
        }
        return false
      case 1:
        if (song.artist !== value) {
          song.artist = value
          return true
        }
        return false
      case 2:
        if (song.album !== value) {
          song.album = value
          return true
        }
        return false
      case 3:
        if (song.genre !== value) {
          song.genre = value
          return true
        }
        return false
      case 4:
        if (song.track !== value) {
          song.track = value
          return true
        }
        return false
      case 5:
        if (song.disc !== value) {
          song.disc = value
          return true
        }
        return false
      case 6:
        if (song.composer !== value) {
          song.composer = value
          return true
        }
        return false
      case 7:
        if (song.albumArtist !== value) {
          song.albumArtist = value
          return true
        }
        return false
      case 8:
        if (song.author !== value) {
          song.author = value
          return true
        }
        return false
      case 9:
        if (song.dateTime !== value) {
          song.dateTime = value
          return true
        }
        return false
      case 10:
        if (song.encoder !== value) {
          song.encoder = value
          return true
        }
        return false
      case 11:
        if (song.description !== value) {
          song.description = value
          return true
        }
        return false
      case 18:
        if (song.year !== value) {
          song.year = value
          return true
        }
        return false
      case 24:
        if (song.language !== value) {
          song.language = value
          return true
        }
        return false
      case 25:
        if (song.comment !== value) {
          song.comment = value
          return true
        }
        return false
      default:
        return false
    }
  }

  // 编辑结果异步真实写回源 MP3 文件（DB 已先行保存，此处失败仅提示不回滚）
  private writeTagsToFileWithToast(song: SongInfo): void {
    saveSongTagsToFile(song).then((result: TagsWriteResult) => {
      if (result.ok || result.reason === 'noSource') {
        return
      }
      if (result.reason === 'noWritePermission') {
        showToastGlassMaterial(this.promptAction, '无文件写权限，修改已保存在应用内（重新导入歌曲后可写入文件）')
        return
      }
      if (result.reason === 'unsupported') {
        showToastGlassMaterial(this.promptAction, '该文件格式暂不支持写入标签，修改已保存在应用内')
        return
      }
      showToastGlassMaterial(this.promptAction, '写入文件失败，修改已保存在应用内')
    }).catch((err: BusinessError) => {
      Logger.warn(TAG, `write tags to file failed: ${JSON.stringify(err)}`)
    })
  }

  private saveEditField(): void {
    const song: SongInfo = this.currentSong();
    if (song.id.length === 0) {
      this.cancelEditField();
      return;
    }
    // songList 可能是过滤后的播放队列子集，持久化必须基于完整曲库，避免覆盖丢歌
    const allSongs: SongInfo[] = DataService.getInstance().getSongs();
    if (this.applyEditToSong(song, this.edittingFieldIndex, this.edittingValue)) {
      DataService.getInstance().updateSongFields(song.id, allSongs);
      this.writeTagsToFileWithToast(song);
    }
    this.cancelEditField();
  }

  build() {
    Column() {
      Column() {
        Column() {
          Slider({
            min: 0, max: this.max, step: 1, style: SliderStyle.NONE, value: this.value
          })
            .trackThickness(this.trackThickness)
            .selectedColor('#FFFFFF')
            .trackColor('#B3FFFFFF')
            .enabled(this.max > 0)
            .focusable(false)
            .onChange((value: number, mode: SliderChangeMode) => {
              if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) {
                this.avPlayerService.seek(value);
                this.getUIContext()?.animateTo({ curve: curves.springMotion() }, () => {
                  this.trackThickness = 6;
                  this.songTimeFontSize = 10;
                  this.songTimeFontColor = '#B3FFFFFF';
                });
              }
              if (mode === SliderChangeMode.Moving) {
                this.currentTime = MediaTools.msToCountdownTime(value);
                this.getUIContext()?.animateTo({ curve: curves.springMotion() }, () => {
                  this.trackThickness = 10;
                  this.songTimeFontSize = 12;
                  this.songTimeFontColor = '#FFFFFF';
                });
              }
              this.pageShowTime = 0;
            })
            .height($r('app.float.slider_height'))
            .width(StyleConstants.FULL_WIDTH)
        }
        .height(this.scaledSize(32))
        .width(StyleConstants.FULL_WIDTH)
        .alignItems(HorizontalAlign.Center)
        Row() {
          Text(this.currentTime)
            .fontColor(this.songTimeFontColor)
            .fontSize(this.songTimeFontSize)
            .fontFamily(PlayerConstants.FONT_FAMILY_BLACK)
            .lineHeight('14vp')
          Text(this.totalTime)
            .fontColor(this.songTimeFontColor)
            .fontSize(this.songTimeFontSize)
            .fontFamily(PlayerConstants.FONT_FAMILY_BLACK)
            .lineHeight('14vp')
        }
        .width(StyleConstants.FULL_WIDTH)
        .justifyContent(FlexAlign.SpaceBetween)
      }
      .margin({ bottom: 12 })

      Row() {
        Column() {
          ScaleButton({
            pressScale: 0.8,
            hoverScale: 1.1,
            onButtonTap: () => { this.skipBackward(); }
          }) {
            Image($r('app.media.ic_public_fast_backward'))
              .width(28)
              .height(28)
              .fillColor(Color.White)
              .opacity(0.86)
          }
        }
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)

        Column() {
          ScaleButton({
            pressScale: 0.8,
            hoverScale: 1.1,
            onButtonTap: () => {
              this.avPlayerService.playPreviousSong();
              this.pageShowTime = 0;
            }
          }) {
            Image($r('app.media.ic_public_play_last'))
              .controlImageBuilder()
              .width(28)
              .fillColor(Color.White)
          }
        }
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)

        Column() {
          ScaleButton({
            pressScale: 0.85,
            hoverScale: 1.05,
            onButtonTap: () => {
              if (this.isPlay) {
                this.avPlayerService.pause();
              } else {
                this.avPlayerService.resume();
              }
              this.pageShowTime = 0;
            }
          }) {
            Image(this.isPlay ? $r('app.media.ic_public_play') : $r('app.media.ic_public_pause'))
              .controlImageBuilder()
              .width(60)
              .fillColor(Color.White)
              .shadow({ radius: 10, color: ColorHelper.hexWithAlpha(this.primaryColor, '22') })
          }
        }
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)

        Column() {
          ScaleButton({
            pressScale: 0.8,
            hoverScale: 1.1,
            onButtonTap: () => {
              this.avPlayerService.playNextSong();
              this.pageShowTime = 0;
            }
          }) {
            Image($r('app.media.ic_public_play_next'))
              .controlImageBuilder()
              .width(28)
              .fillColor(Color.White)
          }
        }
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)

        Column() {
          ScaleButton({
            pressScale: 0.8,
            hoverScale: 1.1,
            onButtonTap: () => { this.skipForward(); }
          }) {
            Image($r('app.media.ic_public_fast_forward'))
              .width(28)
              .height(28)
              .fillColor(Color.White)
              .opacity(0.86)
          }
        }
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      }
      .width(StyleConstants.FULL_WIDTH)

      Row() {
        ScaleButton({
          pressScale: 0.75,
          hoverScale: 1.1,
          onButtonTap: () => { this.switchPlayMode(); }
        }) {
          SymbolGlyph(this.playMode === MusicPlayMode.ORDER ? $r('sys.symbol.order_play') :
            this.playMode === MusicPlayMode.RANDOM ? $r('sys.symbol.shuffle') : $r('sys.symbol.repeat_1'))
            .fontSize(26)
            .renderingStrategy(SymbolRenderingStrategy.SINGLE)
            .fontColor([Color.White])
            .opacity(0.86)
        }

        ScaleButton({
          pressScale: 0.8,
          hoverScale: 1.1,
          onButtonTap: () => { this.isShowPlayList = true; }
        }) {
          SymbolGlyph($r('sys.symbol.music_note_list'))
            .fontSize(26)
            .renderingStrategy(SymbolRenderingStrategy.SINGLE)
            .fontColor([Color.White])
            .opacity(0.86)
            .bindSheet($$this.isShowPlayList, this.musicListBuilder(), {
              detents: [SheetSize.MEDIUM],
              dragBar: false,
              title: this.playListTitle(),
              showClose: true,
              preferType: SheetType.CENTER,
              systemMaterial: this.styleGlassMaterial(),
              onWillAppear: () => {
                Logger.info(TAG, 'musicListBuilder');
                this.scroller.scrollToIndex(this.selectIndex, false, ScrollAlign.CENTER);
              }
            })
        }

        ScaleButton({
          pressScale: 0.8,
          hoverScale: 1.1,
          onButtonTap: () => { this.isShowSpeedBuild = true; }
        }) {
          SymbolGlyph($r('sys.symbol.speed_multiple'))
            .fontSize(26)
            .renderingStrategy(SymbolRenderingStrategy.SINGLE)
            .fontColor([Color.White])
            .opacity(0.86)
            .bindPopup(this.isShowSpeedBuild, {
              builder: this.speedPopupBuilder,
              placement: Placement.Top,
              showInSubWindow: false,
              systemMaterial: this.styleGlassMaterial(),
              onStateChange: (e) => {
                if (!e.isVisible) {
                  this.isShowSpeedBuild = false;
                }
              }
            })
        }

        // 音量入口：自定义 Slider 弹层（AVVolumePanel 无法被点击主动弹出，见 toggleVolumePanel 注释）
        ScaleButton({
          pressScale: 0.8,
          hoverScale: 1.1,
          onButtonTap: () => { this.toggleVolumePanel(); }
        }) {
          Image($r('app.media.ic_public_sound'))
            .width(26)
            .height(26)
            .fillColor(Color.White)
            .opacity(0.86)
            .bindPopup(this.isShowVolumeBuild, {
              builder: this.volumePopupBuilder,
              placement: Placement.Top,
              showInSubWindow: false,
              systemMaterial: this.styleGlassMaterial(),
              onStateChange: (e) => {
                if (!e.isVisible) {
                  this.isShowVolumeBuild = false;
                }
              }
            })
        }

        ScaleButton({
          pressScale: 0.8,
          hoverScale: 1.1,
          onButtonTap: () => {
            this.isShowMorePanel = true;
            this.initBluetoothAudio(false);
          }
        }) {
          Image($r('app.media.ic_public_more'))
            .width(26)
            .height(26)
            .fillColor(Color.White)
            .opacity(0.86)
            .bindSheet($$this.isShowMorePanel, this.morePanelBuilder(), {
              detents: [SheetSize.MEDIUM],
              dragBar: false,
              title: this.morePanelTitle(),
              showClose: true,
              preferType: SheetType.CENTER,
              systemMaterial: this.styleGlassMaterial(),
              onWillDisappear: () => {
                this.isShowMorePanel = false;
                // 关闭后回到主列表，下次打开不从二级页恢复
                this.cancelEditField();
                this.morePanelLevel = 0;
                this.selectedPresetMinutes = -1;
                this.isShowCustomPicker = false;
                this.isShowSongCountPicker = false;
                this.customSongCountText = '';
              }
            })
        }
      }
      .width(StyleConstants.FULL_WIDTH)
      .justifyContent(FlexAlign.SpaceEvenly)
      .margin({ top: 28 })
    }
  }

  // 投播设备行整行内容：由 AVCastPicker customPicker 自绘，整行均可点击唤起系统投播面板
  @Builder
  castPickerRowBuilder() {
    Row() {
      Column({ space: 2 }) {
        Text('投播设备')
          .fontSize(this.scaledFont(14))
          .fontWeight(FontWeight.Medium)
          .fontColor(this.settingTextColor())
          Text('投播 / 输出到其它设备')
          .fontSize(this.scaledFont(12))
          .fontColor($r('app.color.text_sixty_color'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .alignItems(HorizontalAlign.Start)
      Blank()
      Image($r('app.media.ic_public_arrow_right'))
        .width(this.scaledSize(18))
        .height(this.scaledSize(18))
        .fillColor($r('app.color.text_twenty_color'))
    }
    .width('100%')
    .height('100%')
    .padding({ left: 16, right: 16 })
  }

  // 「更多」sheet 内容入口：按层级切换，二级页在同一个 sheet 内原地覆盖，不再弹新窗口
  @Builder
  morePanelBuilder() {
    if (this.morePanelLevel === 1) {
      this.songInfoPanelBuilder()
    } else if (this.morePanelLevel === 2) {
      this.timerPanelBuilder()
    } else {
      this.morePanelMainBuilder()
    }
  }

  @Builder
  morePanelMainBuilder() {
    Column({ space: 8 }) {
      // 歌曲信息入口行（二级弹窗）
      Row() {
        Column({ space: 2 }) {
          Text('歌曲信息')
            .fontSize(this.scaledFont(14))
            .fontWeight(FontWeight.Medium)
            .fontColor(this.settingTextColor())
          if (this.currentSongId.length > 0) {
            Text(this.currentSong().title)
              .fontSize(this.scaledFont(12))
              .fontColor($r('app.color.text_sixty_color'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        Blank()
        Image($r('app.media.ic_public_arrow_right'))
          .width(this.scaledSize(18))
          .height(this.scaledSize(18))
          .fillColor($r('app.color.text_twenty_color'))
      }
      .width('100%')
      .height(52)
      .padding({ left: 16, right: 16 })
      .backgroundColor($r('app.color.player_bg_color'))
      .borderRadius(this.scaledSize(10))
      .onClick(() => {
        this.refreshSongMetadataIfNeeded()
        this.morePanelLevel = 1
      })

      // 定时关闭入口行
      Row() {
        Column({ space: 2 }) {
          Text('定时关闭')
            .fontSize(this.scaledFont(14))
            .fontWeight(FontWeight.Medium)
            .fontColor(this.settingTextColor())
          if (this.timerRemainingSeconds > 0) {
            Text(`剩余 ${this.formatTimerCountdown(this.timerRemainingSeconds)}`)
              .fontSize(this.scaledFont(12))
              .fontColor(this.primaryColor)
          } else if (this.timerSongsRemaining > 0) {
            Text(`剩余 ${this.timerSongsRemaining} 首`)
              .fontSize(this.scaledFont(12))
              .fontColor(this.primaryColor)
          }
        }
        .alignItems(HorizontalAlign.Start)
        Blank()
        Image($r('app.media.ic_public_arrow_right'))
          .width(this.scaledSize(18))
          .height(this.scaledSize(18))
          .fillColor($r('app.color.text_twenty_color'))
      }
      .width('100%')
      .height(52)
      .padding({ left: 16, right: 16 })
      .backgroundColor($r('app.color.player_bg_color'))
      .borderRadius(this.scaledSize(10))
      .onClick(() => {
        this.morePanelLevel = 2
      })

      // 投播设备行：系统 AVCastPicker 组件整行铺满（设备发现/连接/认证/切换全部系统接管）
      AVCastPicker({
        sessionType: 'audio',
        customPicker: (): void => {
          this.castPickerRowBuilder()
        }
      })
        .width('100%')
        .height(52)
        .backgroundColor($r('app.color.player_bg_color'))
        .borderRadius(this.scaledSize(10))

      // 蓝牙音频行（P1-4）：A2DP 连接状态展示；编解码能力为系统应用接口三方不可查，
      // 仅展示 设备名/连接态/播放态，点击重试授权或刷新状态
      Row() {
        Column({ space: 2 }) {
          Text('蓝牙音频')
            .fontSize(this.scaledFont(14))
            .fontWeight(FontWeight.Medium)
            .fontColor(this.isBluetoothRowDisabled() ?
              $r('app.color.text_twenty_color') : this.settingTextColor())
          Text(this.bluetoothAudioLabel)
            .fontSize(this.scaledFont(12))
            .fontColor(this.isBluetoothRowDisabled() ?
              $r('app.color.text_twenty_color') : $r('app.color.text_sixty_color'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        Blank()
      }
      .width('100%')
      .height(52)
      .padding({ left: 16, right: 16 })
      .backgroundColor($r('app.color.player_bg_color'))
      .borderRadius(this.scaledSize(10))
      .onClick(() => {
        // 用户主动点行才申请权限：允许弹系统权限框
        this.initBluetoothAudio(true);
      })
    }
    .width(StyleConstants.FULL_WIDTH)
    .padding({ left: 16, right: 16 })
    .transition(this.morePanelTransition(false))
  }

  @Builder
  songInfoPanelBuilder() {
    if (this.currentSongId.length > 0) {
      Column() {
        Scroll() {
          Column() {
            Row() {
              AlbumCover({ song: this.currentSong(), coverWidth: 72, coverHeight: 72, coverRadius: 8 })
              Column() {
                Text(this.currentSong().title)
                  .fontSize(this.scaledFont(16))
                  .fontWeight(FontWeight.Bold)
                  .fontColor($r('app.color.text_primary'))
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                Text(this.currentSong().artist.length > 0 ? this.currentSong().artist : '未知歌手')
                  .fontSize(this.scaledFont(13))
                  .fontColor($r('app.color.text_sixty_color'))
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                if (this.currentSong().album.length > 0) {
                  Text(this.currentSong().album)
                    .fontSize(this.scaledFont(12))
                    .fontColor($r('app.color.text_twenty_color'))
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                }
              }
              .margin({ left: 12 })
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)
              Blank()
            }
            .width('100%')
            .height(this.scaledFont(90))
            .alignItems(VerticalAlign.Center)
            .padding({ left: 16, right: 16 })

            // 可编辑元数据组置顶：编辑交互与原有条目一致（点行内联编辑 + 确定/取消）
            Column({ space: 0 }) {
              this.morePanelInfoRow(0, '标题', this.infoValue(0), true)
              this.morePanelInfoRow(1, '歌手', this.infoValue(1), true)
              this.morePanelInfoRow(2, '专辑', this.infoValue(2), true)
              this.morePanelInfoRow(3, '流派', this.infoValue(3), true)
              this.morePanelInfoRow(18, '年份', this.infoValue(18), true)
              this.morePanelInfoRow(4, '音轨号', this.infoValue(4), true)
              this.morePanelInfoRow(5, '碟号', this.infoValue(5), true)
              this.morePanelInfoRow(6, '作曲家', this.infoValue(6), true)
              this.morePanelInfoRow(7, '专辑艺术家', this.infoValue(7), true)
              this.morePanelInfoRow(8, '作者', this.infoValue(8), true)
              this.morePanelInfoRow(24, '语言', this.infoValue(24), true)
              this.morePanelInfoRow(9, '日期', this.infoValue(9), true)
              this.morePanelInfoRow(10, '编码器', this.infoValue(10), true)
              this.morePanelInfoRow(25, '注释', this.infoValue(25), true)
              this.morePanelInfoRow(11, '描述', this.infoValue(11), true)
            }
            .width('100%')
            .padding({ left: 16, right: 16 })

            // 只读技术信息组
            Column({ space: 0 }) {
              this.morePanelInfoRow(12, '时长', this.infoValue(12), false)
              this.morePanelInfoRow(14, '码率', this.infoValue(14), false)
              this.morePanelInfoRow(13, '采样率', this.infoValue(13), false)
              this.morePanelInfoRow(20, '位深', this.infoValue(20), false)
              this.morePanelInfoRow(19, '声道数', this.infoValue(19), false)
              this.morePanelInfoRow(21, '编码格式', this.infoValue(21), false)
              this.morePanelInfoRow(22, '音轨数量', this.infoValue(22), false)
              this.morePanelInfoRow(23, '文件大小', this.infoValue(23), false)
              this.morePanelInfoRow(15, 'MIME', this.infoValue(15), false)
              this.morePanelInfoRow(16, '文件路径', this.infoValue(16), false)
              this.morePanelInfoRow(17, '文件夹', this.infoValue(17), false)
            }
            .width('100%')
            .margin({ top: 12 })
            .padding({ left: 16, right: 16, top: 4, bottom: 16 })
          }
          .width(StyleConstants.FULL_WIDTH)
        }
        .layoutWeight(1)
        .align(Alignment.TopStart)
        .scrollBar(BarState.Off)
      }
      .width(StyleConstants.FULL_WIDTH)
      .height(StyleConstants.FULL_HEIGHT)
      .justifyContent(FlexAlign.Start)
      .alignItems(HorizontalAlign.Start)
      .transition(this.morePanelTransition(true))
    }
  }

  @Builder
  morePanelInfoRow(index: number, label: string, value: string, editable: boolean) {
    Row() {
      Text(label)
        .fontSize(this.scaledFont(12))
        .fontColor($r('app.color.text_sixty_color'))
        .width(64)
      if (index === this.edittingFieldIndex && editable) {
        TextInput({ text: this.edittingValue })
          .fontSize(this.scaledFont(13))
          .fontColor($r('app.color.text_primary'))
          .backgroundColor($r('app.color.player_bg_color'))
          .borderRadius(4)
          .height(this.scaledFont(32))
          // 编辑态文字起点必须与显示态值文字对齐（标签列 64vp 右缘）：左内边距为 0，
          // 点击行进入编辑时文字不再随输入框内边距横向位移
          .padding({ left: 0, right: 8 })
          .layoutWeight(1)
          .defaultFocus(true)
          .enterKeyType(EnterKeyType.Done)
          .onChange((newValue: string) => {
            this.edittingValue = newValue
          })
          .onSubmit(() => {
            this.saveEditField()
          })
        Button('确定')
          .height(this.scaledFont(32))
          .fontSize(this.scaledFont(12))
          .fontColor(Color.White)
          .backgroundColor(this.primaryColor)
          .borderRadius(4)
          .margin({ left: 8 })
          .padding({ left: 10, right: 10 })
          .onClick(() => { this.saveEditField() })
        Button('取消')
          .height(this.scaledFont(32))
          .fontSize(this.scaledFont(12))
          .fontColor($r('app.color.text_sixty_color'))
          .backgroundColor($r('app.color.player_bg_color'))
          .borderRadius(4)
          .margin({ left: 8 })
          .padding({ left: 10, right: 10 })
          .onClick(() => { this.cancelEditField() })
      } else {
        Text(value && value.length > 0 ? value : '-')
          .fontSize(this.scaledFont(13))
          .fontColor($r('app.color.text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
      }
    }
    .width('100%')
    .height(this.scaledFont(40))
    .alignItems(VerticalAlign.Center)
    .border({ width: { bottom: 1 }, color: $r('app.color.list_divider') })
    .onClick(() => {
      if (editable && index !== this.edittingFieldIndex) {
        this.startEditField(index, this.infoValue(index))
      }
    })
  }

  @Builder
  timerPanelBuilder() {
    Column({ space: this.scaledSize(12) }) {
      if (this.isShowCustomPicker) {
        DatePickerComponent({
          options: {
            displayMode: DisplayMode.TIME,
            timeOptions: {
              format: TimeFormat.HOUR_MINUTE_SECOND,
              useMilitaryTime: true,
              start: new Date(1970, 0, 1, 0, 0, 0),
              end: new Date(1970, 0, 1, 24, 59, 59),
              selected: new Date(1970, 0, 1, this.customHours, this.customMinutes, this.customSeconds),
              onChange: (result: DatePickerComponentResult) => {
                this.selectedPresetMinutes = -1
                this.customHours = result.hour ?? 0
                this.customMinutes = result.minute ?? 0
                this.customSeconds = result.second ?? 0
              }
            }
          }
        })
        .width('100%')

        Row({ space: this.scaledSize(8) }) {
          Button('返回')
            .layoutWeight(1)
            .height(this.scaledSize(40))
            .fontSize(this.scaledFont(14))
            .fontColor(this.settingTextColor())
            .backgroundColor(ColorHelper.hexToRgba(this.primaryColor, 0.08))
            .borderRadius(this.scaledSize(10))
            .onClick(() => {
              this.isShowCustomPicker = false
            })
          Button('确认')
            .layoutWeight(1)
            .height(this.scaledSize(40))
            .fontSize(this.scaledFont(14))
            .fontColor(this.customHours * 3600 + this.customMinutes * 60 + this.customSeconds > 0 ? Color.White : 'rgba(255,255,255,0.4)')
            .backgroundColor(this.customHours * 3600 + this.customMinutes * 60 + this.customSeconds > 0 ? this.primaryColor : '#555555')
            .borderRadius(this.scaledSize(10))
            .enabled(this.customHours * 3600 + this.customMinutes * 60 + this.customSeconds > 0)
            .onClick(() => {
              this.setTimerSeconds(this.customHours * 3600 + this.customMinutes * 60 + this.customSeconds)
              this.customHours = 0
              this.customMinutes = 0
              this.customSeconds = 0
              this.isShowCustomPicker = false
            })
        }
        .width('100%')
      } else if (this.isShowSongCountPicker) {
        // 按歌曲数自定义（1-99 首）：点确定立即生效，非法输入保持本页等待重输
        Column({ space: this.scaledSize(12) }) {
          Text('自定义歌曲数（1-99 首）')
            .fontSize(this.scaledFont(14))
            .fontColor(this.settingTextColor())
            .fontWeight(FontWeight.Medium)
            .width('100%')

          Row({ space: this.scaledSize(8) }) {
            TextInput({ text: this.customSongCountText, placeholder: '1-99' })
              .type(InputType.Number)
              .height(this.scaledSize(40))
              .fontSize(this.scaledFont(14))
              .fontColor(this.settingTextColor())
              .layoutWeight(1)
              .onChange((newValue: string) => {
                this.customSongCountText = newValue
              })
              .enterKeyType(EnterKeyType.Done)
              .onSubmit(() => {
                if (this.isCustomSongCountValid()) {
                  this.setTimerSongs(this.customSongCountValue())
                }
              })

            Button('确定')
              .height(this.scaledSize(40))
              .fontSize(this.scaledFont(14))
              .fontColor(this.isCustomSongCountValid() ? Color.White : 'rgba(255,255,255,0.4)')
              .backgroundColor(this.isCustomSongCountValid() ? this.primaryColor : '#555555')
              .borderRadius(this.scaledSize(10))
              .enabled(this.isCustomSongCountValid())
              .onClick(() => {
                this.setTimerSongs(this.customSongCountValue())
              })
          }
          .width('100%')

          Button('返回')
            .width('100%')
            .height(this.scaledSize(40))
            .fontSize(this.scaledFont(14))
            .fontColor(this.settingTextColor())
            .backgroundColor(ColorHelper.hexToRgba(this.primaryColor, 0.08))
            .borderRadius(this.scaledSize(10))
            .onClick(() => {
              this.isShowSongCountPicker = false
            })
        }
        .width('100%')
      } else {
        Column({ space: this.scaledSize(6) }) {
          ForEach(TIMER_PRESET_MINUTES, (min: number) => {
            Row() {
              Text(`${min}分钟`)
                .fontSize(this.scaledFont(13))
                .fontColor(this.isTimerPresetActive(min) ? '#FFFFFF'
                  : (this.isTimerPresetPending(min) ? this.primaryColor : this.settingTextColor()))

              Blank()

              if (this.isTimerPresetActive(min)) {
                Text(this.formatTimerCountdown(this.timerRemainingSeconds))
                  .fontSize(this.scaledFont(14))
                  .fontWeight(FontWeight.Bold)
                  .fontColor('#FFFFFF')
              }
            }
            .width('100%')
            .padding({
              left: this.scaledSize(12),
              right: this.scaledSize(12),
              top: this.scaledSize(8),
              bottom: this.scaledSize(8)
            })
            .backgroundColor(this.isTimerPresetActive(min) ? this.primaryColor
              : (this.isTimerPresetPending(min)
                ? ColorHelper.hexToRgba(this.primaryColor, this.isEffectiveDarkMode() ? 0.32 : 0.16)
                : (this.isEffectiveDarkMode() ? '#333333' : ColorHelper.hexToRgba(this.primaryColor, 0.08))))
            .borderRadius(this.scaledSize(8))
            .alignItems(VerticalAlign.Center)
            .onClick(() => {
              this.selectedPresetMinutes = this.selectedPresetMinutes === min ? -1 : min
            })
          }, (min: number) => min.toString())

          Row() {
            Text('自定义')
              .fontSize(this.scaledFont(13))
              .fontColor(this.settingTextColor())

            Blank()

            if (this.timerRemainingSeconds > 0 && this.activePresetMinutes < 0) {
              Text(this.formatTimerCountdown(this.timerRemainingSeconds))
                .fontSize(this.scaledFont(14))
                .fontWeight(FontWeight.Bold)
                .fontColor(this.isEffectiveDarkMode() ? '#FFFFFF' : this.primaryColor)
            }
          }
          .width('100%')
          .padding({
            left: this.scaledSize(12),
            right: this.scaledSize(12),
            top: this.scaledSize(8),
            bottom: this.scaledSize(8)
          })
          .backgroundColor(Color.Transparent)
          .border({ width: 1, color: this.isEffectiveDarkMode() ? 'rgba(255,255,255,0.15)' : ColorHelper.hexToRgba(this.primaryColor, 0.2), radius: this.scaledSize(8) })
          .alignItems(VerticalAlign.Center)
          .onClick(() => {
            this.isShowCustomPicker = true
          })
        }

        Button('确认')
          .width('100%')
          .height(this.scaledSize(40))
          .fontSize(this.scaledFont(14))
          .fontColor(this.selectedPresetMinutes > 0 ? Color.White : 'rgba(255,255,255,0.4)')
          .backgroundColor(this.selectedPresetMinutes > 0 ? this.primaryColor : '#555555')
          .borderRadius(this.scaledSize(10))
          .enabled(this.selectedPresetMinutes > 0)
          .onClick(() => {
            this.setTimerSeconds(this.selectedPresetMinutes * 60)
            this.selectedPresetMinutes = -1
          })

        // ─── 按歌曲数（P0-1）：点击预设立即生效，再点同一预设取消 ───
        Row() {
          Text('按歌曲数')
            .fontSize(this.scaledFont(13))
            .fontColor(this.settingTextColor())
            .fontWeight(FontWeight.Medium)

          Blank()

          if (this.timerSongsRemaining > 0) {
            Text(`剩余 ${this.timerSongsRemaining} 首`)
              .fontSize(this.scaledFont(13))
              .fontWeight(FontWeight.Bold)
              .fontColor(this.isEffectiveDarkMode() ? '#FFFFFF' : this.primaryColor)
          }
        }
        .width('100%')

        Flex({ wrap: FlexWrap.Wrap }) {
          ForEach(TIMER_SONG_PRESETS, (count: number) => {
            Text(`${count}首`)
              .fontSize(this.scaledFont(13))
              .fontColor(this.isTimerSongsPresetActive(count) ? '#FFFFFF' : this.settingTextColor())
              .textAlign(TextAlign.Center)
              .height(this.scaledSize(36))
              .constraintSize({ minWidth: this.scaledSize(64) })
              .padding({ left: this.scaledSize(14), right: this.scaledSize(14) })
              .borderRadius(this.scaledSize(8))
              .backgroundColor(this.isTimerSongsPresetActive(count) ? this.primaryColor
                : (this.isEffectiveDarkMode() ? '#333333' : ColorHelper.hexToRgba(this.primaryColor, 0.08)))
              .margin({ right: this.scaledSize(8), bottom: this.scaledSize(4) })
              .onClick(() => {
                if (this.isTimerSongsPresetActive(count)) {
                  this.clearTimer()
                } else {
                  this.setTimerSongs(count)
                }
              })
          }, (count: number) => `songs-${count}`)

          Text('自定义')
            .fontSize(this.scaledFont(13))
            .fontColor(this.isTimerSongsCustomActive() ? '#FFFFFF' : this.settingTextColor())
            .textAlign(TextAlign.Center)
            .height(this.scaledSize(36))
            .padding({ left: this.scaledSize(14), right: this.scaledSize(14) })
            .borderRadius(this.scaledSize(8))
            .backgroundColor(this.isTimerSongsCustomActive() ? this.primaryColor
              : (this.isEffectiveDarkMode() ? '#333333' : ColorHelper.hexToRgba(this.primaryColor, 0.08)))
            .margin({ right: this.scaledSize(8), bottom: this.scaledSize(4) })
            .onClick(() => {
              if (this.isTimerSongsCustomActive()) {
                this.clearTimer()
              } else {
                this.customSongCountText = ''
                this.isShowSongCountPicker = true
              }
            })
        }
        .width('100%')

        if (this.timerRemainingSeconds > 0 || this.timerSongsRemaining > 0) {
          Button('取消定时')
            .width('100%')
            .height(this.scaledSize(40))
            .fontSize(this.scaledFont(14))
            .fontColor(StyleConstants.COLOR_DANGER_RED)
            .backgroundColor(Color.Transparent)
            .border({ width: 1, color: StyleConstants.COLOR_DANGER_RED, radius: this.scaledSize(10) })
            .onClick(() => {
              this.clearTimer()
            })
        }
      }
    }
    .width(StyleConstants.FULL_WIDTH)
    .padding({ top: 16, bottom: 16, left: 16, right: 16 })
    .transition(this.morePanelTransition(true))
  }

  private infoValue(index: number): string {
    const song: SongInfo = this.currentSong();
    if (song.id.length === 0) {
      return ''
    }
    switch (index) {
      case 0: return song.title
      case 1: return song.artist
      case 2: return song.album
      case 3: return song.genre
      case 4: return song.track
      case 5: return song.disc
      case 6: return song.composer
      case 7: return song.albumArtist
      case 8: return song.author
      case 9: return song.dateTime
      case 10: return song.encoder
      case 11: return song.description
      case 12: return MediaTools.msToCountdownTime(song.duration)
      case 13: return song.sampleRate > 0 ? `${song.sampleRate} Hz` : ''
      case 14: return song.effectiveBitrate() > 0 ? `${Math.round(song.effectiveBitrate() / 1000)} kbps` : ''
      case 15: return song.mimeType
      case 16: return song.filePath
      case 17: return song.folderName
      case 18: return song.year
      case 19: return song.channels
      case 20: return song.bitDepth.length > 0 ? `${song.bitDepth} bit` : ''
      case 21: return song.codec
      case 22: return song.trackCount
      case 23: return this.formatFileSize(song.fileSize)
      case 24: return song.language
      case 25: return song.comment
      default: return ''
    }
  }

  @Builder
  musicListBuilder() {
    Column() {
      List({ scroller: this.scroller }) {
        LazyForEach(this.songDataSource, (item: SongInfo, index: number) => {
          ListItem() {
            MusicListContainer({ item: item, index: index })
          }
        }, (item: SongInfo) => item.id)
        ListItem().height(48)
      }
      .height(StyleConstants.FULL_HEIGHT)
      .width(StyleConstants.FULL_WIDTH)
      .layoutWeight(1)
      .divider({
        color: $r('app.color.list_divider'),
        strokeWidth: $r('app.float.stroke_width'),
        startMargin: $r('app.float.list_item_padding'),
        endMargin: $r('app.float.list_item_padding')
      })
    }
  }

  @Builder
  speedPopupBuilder() {
    Column() {
      Row() {
        Text('倍速')
          .fontSize(14)
          .fontColor($r('app.color.text_primary'))
          .fontWeight(FontWeight.Bold)
        Text(`${this.speed.toFixed(2)}x`)
          .fontSize(14)
          .fontColor(this.primaryColor)
          .fontWeight(FontWeight.Bold)
          .margin({ left: 8 })
      }
      .width('100%')
      .margin({ bottom: 8 })

      Slider({
        min: 0.25, max: 3.0, step: 0.25, style: SliderStyle.OutSet, value: this.speed
      })
        .showSteps(true)
        .showTips(false)
        .width('100%')
        .selectedColor(this.primaryColor)
        .trackColor(ColorHelper.hexToRgba(this.primaryColor, 0.12))
        .blockColor('#FFFFFF')
        .blockSize({ width: 20, height: 20 })
        .blockBorderColor(this.primaryColor)
        .blockBorderWidth(3)
        .systemMaterial(this.styleGlassMaterial())
        .onChange((value: number, mode: SliderChangeMode) => {
          this.speed = Math.round(value * 4) / 4
          AppStorage.setOrCreate(AppStorageKeyConstants.KEY_CURRENT_SPEED, this.speed)
          this.avPlayerService.setSpeed(this.speed)
        })

      Row() {
        Text('0.25').fontSize(9).fontColor($r('app.color.text_sixty_color'))
        Text('0.5').fontSize(9).fontColor($r('app.color.text_sixty_color'))
        Text('1.0').fontSize(9).fontColor($r('app.color.text_sixty_color'))
        Text('1.5').fontSize(9).fontColor($r('app.color.text_sixty_color'))
        Text('2.0').fontSize(9).fontColor($r('app.color.text_sixty_color'))
        Text('2.5').fontSize(9).fontColor($r('app.color.text_sixty_color'))
        Text('3.0').fontSize(9).fontColor($r('app.color.text_sixty_color'))
      }
      .width('100%')
      .justifyContent(FlexAlign.SpaceBetween)
      .padding({ left: 4, right: 4 })
    }
    .padding(16)
    .width(260)
  }

  // 音量弹层：Slider 档位（0~maxVolumeLevel）→ 归一化 volume → KEY_CURRENT_VOLUME →
  // PlayerInfoComponent 常驻 AVVolumePanel.volumeLevel 写入系统音量（应用侧唯一合法写通道）
  @Builder
  volumePopupBuilder() {
    Column() {
      Row() {
        Text('音量')
          .fontSize(14)
          .fontColor($r('app.color.text_primary'))
          .fontWeight(FontWeight.Bold)
        Text(`${Math.round(this.volume * 100)}%`)
          .fontSize(14)
          .fontColor(this.primaryColor)
          .fontWeight(FontWeight.Bold)
          .margin({ left: 8 })
      }
      .width('100%')
      .margin({ bottom: 8 })

      Slider({
        min: 0, max: this.maxVolumeLevel, step: 1, style: SliderStyle.OutSet,
        value: Math.round(this.volume * this.maxVolumeLevel)
      })
        .showSteps(false)
        .showTips(false)
        .width('100%')
        .selectedColor(this.primaryColor)
        .trackColor(ColorHelper.hexToRgba(this.primaryColor, 0.12))
        .blockColor('#FFFFFF')
        .blockSize({ width: 20, height: 20 })
        .blockBorderColor(this.primaryColor)
        .blockBorderWidth(3)
        .systemMaterial(this.styleGlassMaterial())
        .onChange((value: number, mode: SliderChangeMode) => {
          const level: number = Math.round(value);
          this.volume = this.maxVolumeLevel > 0 ? level / this.maxVolumeLevel : 0;
        })
    }
    .padding(16)
    .width(260)
  }

  @Builder
  playListTitle() {
    Text($r('app.string.play_list', this.songList.length))
      .maxLines(1)
      .fontColor($r('app.color.text_primary'))
      .fontWeight(FontWeight.Bold)
      .fontSize(20)
      .width('100%')
  }

  // 二级页不另开弹窗：标题栏左侧加返回箭头，点回主列表
  // 热区：图标 20vp，外层容器 44×44vp（不小于最小可点尺寸），点击落在容器上
  @Builder
  morePanelTitle() {
    Row() {
      if (this.morePanelLevel > 0) {
        Row() {
          Image($r('app.media.ic_public_arrow_right'))
            .width(this.scaledSize(20))
            .height(this.scaledSize(20))
            .fillColor($r('app.color.text_primary'))
            .rotate({ angle: 180 })
            .hitTestBehavior(HitTestMode.None)
        }
        .width(this.scaledSize(44))
        .height(this.scaledSize(44))
        // 负边距会让 44vp 热区被标题栏裁掉一部分，箭头看起来偏左，故热区整体落在可视区内
        .margin({ left: 0, right: this.scaledSize(6) })
        .justifyContent(FlexAlign.Center)
        .alignItems(VerticalAlign.Center)
        .borderRadius(this.scaledSize(22))
        .onClick(() => {
          this.backToMorePanelRoot()
        })
      }
      Text(this.morePanelTitleText())
        .maxLines(1)
        .fontColor($r('app.color.text_primary'))
        .fontWeight(FontWeight.Bold)
        .fontSize(this.scaledFont(20))
    }
    .width('100%')
    .height(this.scaledSize(44))
    .alignItems(VerticalAlign.Center)
  }

  private morePanelTitleText(): string {
    switch (this.morePanelLevel) {
      case 1:
        return '歌曲信息'
      case 2:
        return '定时关闭'
      default:
        return '更多'
    }
  }

  private backToMorePanelRoot(): void {
    if (this.morePanelLevel === 1) {
      this.cancelEditField()
    }
    if (this.morePanelLevel === 2) {
      this.selectedPresetMinutes = -1
      this.isShowCustomPicker = false
    }
    this.morePanelLevel = 0
  }

  // 「更多」面板一级/二级切换过渡：主列表左进左出、二级页右进右出，
  // 进出方向与「进入二级页 / 返回主列表」天然对应，避免生硬硬切
  private morePanelTransition(fromRight: boolean): TransitionEffect {
    return TransitionEffect.OPACITY
      .combine(TransitionEffect.translate({ x: fromRight ? 48 : -48 }))
      .animation({ duration: 320, curve: Curve.EaseOut })
  }
}

@Extend(Image)
function controlImageBuilder() {
  .aspectRatio(1)
  .opacity(0.86)
  .objectFit(ImageFit.Contain)
}

@Component
struct MusicListContainer {
  @StorageLink(AppStorageKeyConstants.KEY_IS_PLAY) isPlay: boolean = false;
  @StorageLink(AppStorageKeyConstants.KEY_SELECT_INDEX) selectIndex: number = 0;
  item: SongInfo = new SongInfo();
  index: number = 0;

  build() {
    Column() {
      Row() {
        Column() {
          Text(this.item.title)
            .fontColor(!this.item.isAvailable ? $r('app.color.text_sixty_color') :
              (this.selectIndex === this.index && this.isPlay ? Color.Red : $r('app.color.text_primary')))
            .fontSize(16)
            .margin({ bottom: $r('app.float.list_item_title_margin') })
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Row() {
            AlbumCover({ song: this.item, coverWidth: $r('app.float.list_item_image_size'),
              coverHeight: $r('app.float.list_item_image_size') })
              .margin({ right: $r('app.float.list_item_image_margin') })
            Text(this.item.artist)
              .opacity($r('app.float.singer_opacity'))
              .fontColor(!this.item.isAvailable ? $r('app.color.text_sixty_color') :
                (this.selectIndex === this.index && this.isPlay ? Color.Red : $r('app.color.text_primary')))
              .fontSize(12)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
        }
        .alignItems(HorizontalAlign.Start)
        if (this.selectIndex === this.index && this.isPlay) {
          Column() {
            Image($r('app.media.ic_public_sound'))
              .width(26)
              .height(26)
              .fillColor(Color.Red)
              .opacity(0.86)
          }
        }
      }
      .justifyContent(FlexAlign.SpaceBetween)
      .onClick(() => {
        const avService: AVPlayerService = AVPlayerService.getInstance();
        avService.playSongAt(this.index);
      })
      .height($r('app.float.list_item_height'))
      .width(StyleConstants.FULL_WIDTH)
    }
    .padding({ left: $r('app.float.list_item_padding'), right: $r('app.float.list_item_padding') })
  }
}
