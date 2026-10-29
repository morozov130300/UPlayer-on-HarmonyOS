// ArkUI 26 Beta1: 接口定义变更（误报，本项目已是Stage模型）+ UX视觉布局变更（Text默认开启沉浸式材质，系统行为）
import { common } from '@kit.AbilityKit'
import { FolderInfo } from '../model/FolderInfo'
import { SongInfo } from '../model/SongInfo'
import { PlaylistInfo } from '../model/PlaylistInfo'
import { DataService, AppSettingsData, LibraryDeleteResult } from '../service/DataService'
import { importSongsWithToast } from '../service/SongScanner'
import { AVPlayerService } from '../service/AVPlayerService'
import { AVSessionController } from '../common/utils/mediautils/AVSessionController'
import { LiveViewService } from '../service/LiveViewService'
import { ColorHelper } from '../common/utils/ColorHelper'
import Logger from '../common/utils/Logger'
import { AppStorageKeyConstants } from '../common/constants/AppStorageKeyConstants'
import { StyleConstants } from '../common/constants/StyleConstants'
import { display, uiMaterial } from '@kit.ArkUI'
import { deviceInfo } from '@kit.BasicServicesKit'
import { AlbumCover } from '../component/AlbumCover'
import { PlaylistCreateDialog } from '../component/PlaylistCreateDialog'
import { AlbumCoverSize } from '../service/AudioMetadataService'
import { createBarGlassMaterial, createStyleGlassMaterial, DEFAULT_GLASS_STYLE } from '../common/utils/GlassUtil'
import { GlassBackButton } from '../view/GlassBackButton'
import { ScaleButton } from '../component/ScaleButton'
import { PressScaleHost } from '../component/PressScaleHost'
import { SettingsStore } from '../common/utils/SettingsStore'
import { CoachMarkOverlay, CoachStep } from '../view/CoachMarkOverlay'

const TAG = 'PlaylistContent'
const FAVORITES_FOLDER_ID: string = '__favorites__'

// 歌单卡片展示模型（P2-3）：coverSongs 为拼贴用的前 4 首（不足补占位格）
class PlaylistCardData {
  playlist: PlaylistInfo = new PlaylistInfo()
  coverSongs: SongInfo[] = []
  count: number = 0
}

@Component
export struct PlaylistContent {
  topContentPadding: number = 0
  // 顶部标题带高度（Index 传入，与主页问候语带同源）：标题在带内垂直居中，几何与主页一致
  topBandHeight: number = 72
  // 底部让位原始输入（Index 传入），页内自算 bottomOverlayInset() 以实时跟随显示大小
  bottomSafeHeight: number = 0
  smallBreakpoint: boolean = false
  private context: common.UIAbilityContext | undefined = AppStorage.get<common.UIAbilityContext>(AppStorageKeyConstants.KEY_UI_ABILITY_CONTEXT)
  @State folders: FolderInfo[] = []
  @State songs: SongInfo[] = []
  @State settings: AppSettingsData = new AppSettingsData()
  @State isPlusVisible: boolean = true
  @State selectedFolderPaths: string[] = []
  @State favoritesSelected: boolean = false
  // 选中自建歌单前的文件夹/收藏选中态快照：取消歌单选中时原样恢复（歌单与文件夹互斥）
  private savedFolderPathsBeforePlaylist: string[] = []
  private savedPrevFolderPathsBeforePlaylist: string[] = []
  private savedFavoritesBeforePlaylist: boolean = false
  @StorageLink(AppStorageKeyConstants.KEY_TITLE_BUTTON_WIDTH) titleButtonWidth: number = 140
  @StorageLink('uplayer_primary_color') primaryColor: string = '#007DFF'
  // 组件风格（玻璃/经典）必须走 AppStorage 实时键：settings 是 loadData 时的快照副本，
  // 在设置页切换风格后它不会变，会让本页弹窗材质/多选栏停在旧样式（表现为「切换不立即生效」）
  @StorageLink('uplayer_tab_style') tabStyle: string = 'classic'
  @StorageLink('uplayer_font_size_scale') fontSizeScale: number = 1.0
  @StorageLink('uplayer_display_size_scale') displaySizeScale: number = 1.0
  @StorageLink(AppStorageKeyConstants.KEY_LIBRARY_REVISION) @Watch('onLibraryChange') libraryRevision: number = 0
  @StorageLink(AppStorageKeyConstants.KEY_FILTER_REVISION) @Watch('onFilterChange') filterRevision: number = 0
  // Delete 键删除请求（Index 页面级键盘事件 +1）：编辑态下与删除按钮功能一致
  @StorageLink(AppStorageKeyConstants.KEY_PLAYLIST_DELETE_REQUEST) @Watch('onDeleteRequest')
  deleteRequest: number = 0
  // 下滑隐藏加号：设置页切换后需跨页实时生效，故走 AppStorage 键 + @Watch 重新上报加号可见性
  @StorageLink('uplayer_plus_button_scroll_hide') @Watch('onPlusScrollHideChange')
  plusButtonScrollHide: boolean = true
  private dataService: DataService = DataService.getInstance()
  private scroller: Scroller = new Scroller()
  private previousFolderPaths: string[] = []
  private isPC: boolean = deviceInfo.deviceType === '2in1'
  // ── 新手引导（聚光分步）：歌单页 2 步（点击选中歌单 / 歌单与文件夹二选一）──
  // 与首页引导同构：stepIndex = -1 不挂载，「已看过」标记存 SettingsStore
  @State coachStepIndex: number = -1
  private coachSteps: CoachStep[] = []
  private coachStartTimer: number = -1
  private coachStartRetries: number = 0

  // 歌单页引导步骤（目标组件 id 见 build() 中对应 .id()）
  private buildPlaylistCoachSteps(): CoachStep[] {
    const s1: CoachStep = new CoachStep()
    s1.targetId = 'coach_playlist_grid'
    s1.maxHighlightHeight = 220
    s1.title = '点击选中歌单'
    s1.description = '点击歌单卡即可选中，选中的歌单会展示在首页；再次点击取消选中。'
    const s2: CoachStep = new CoachStep()
    s2.targetId = 'coach_folder_grid'
    s2.maxHighlightHeight = 220
    s2.title = '歌单与文件夹二选一'
    s2.description = '选中的歌单或文件夹会展示在首页，两者互斥；全部取消选中时，首页展示所有已导入歌曲。'
    return [s1, s2]
  }

  // 首次进入歌单页自动弹引导：多选/文件夹编辑态不弹，重试几次直到空闲
  private maybeStartPlaylistGuide(): void {
    if (SettingsStore.getInstance().get(AppStorageKeyConstants.SETTING_GUIDE_PLAYLIST_DONE, '') === '1') {
      return
    }
    if (this.coachStartTimer >= 0) {
      clearTimeout(this.coachStartTimer)
      this.coachStartTimer = -1
    }
    this.coachStartTimer = setTimeout((): void => {
      this.coachStartTimer = -1
      if (this.isAnySelectMode()) {
        if (this.coachStartRetries < 6) {
          this.coachStartRetries++
          this.maybeStartPlaylistGuide()
        }
        return
      }
      this.coachSteps = this.buildPlaylistCoachSteps()
      this.coachStepIndex = 0
    }, 600)
  }

  // 引导结束（走完/跳过/中途切页）：落「已看过」标记并关浮层
  private finishPlaylistGuide(): void {
    this.coachStepIndex = -1
    SettingsStore.getInstance().set(AppStorageKeyConstants.SETTING_GUIDE_PLAYLIST_DONE, '1')
  }
  // 文件夹编辑态（多选删除歌曲）：与歌单多选同构，状态上提 AppStorage 供返回键/ESC 收回
  @StorageLink(AppStorageKeyConstants.KEY_PLAYLIST_FOLDER_EDIT) @Watch('onFolderEditModeChange')
  isEditMode: boolean = false
  @State editSelectedFolderIds: string[] = []
  @State gridColumns: number = 2
  // 自定义歌单（P2-3）：卡片数据 + 新建/编辑歌单弹层 + 长按冒泡菜单 + 歌单多选 + 删除二次确认
  @StorageLink(AppStorageKeyConstants.KEY_PLAYLIST_REVISION) @Watch('onPlaylistRevisionChange')
  playlistRevision: number = 0
  @State playlistCards: PlaylistCardData[] = []
  @State isPlaylistCreateVisible: boolean = false
  // 编辑歌单弹层（复用新建歌单组件，编辑模式：整体替换曲目 + 改名）
  @State isPlaylistEditVisible: boolean = false
  private editingPlaylistId: string = ''
  // 长按冒泡菜单：当前目标歌单卡（bindPopup 显示条件）
  @State playlistActionCardId: string = ''
  // 歌单多选模式：批量删除。状态挂在 AppStorage 上双向绑定，与首页多选完全同构：
  // 返回键/ESC 由 Index 的页面级事件写入 false，本页 @Watch 收到后顺带清空选中集合
  @StorageLink(AppStorageKeyConstants.KEY_PLAYLIST_MULTI_SELECT) @Watch('onPlaylistMultiSelectChange')
  isPlaylistEditMode: boolean = false
  @State playlistEditSelectedIds: string[] = []
  // Ctrl+A 全选请求（Index 页面级键盘事件 +1）：多选态下全选可见歌单
  @StorageLink(AppStorageKeyConstants.KEY_PLAYLIST_SELECT_ALL_REQUEST) @Watch('onSelectAllRequest')
  selectAllRequest: number = 0
  @State playlistDeleteConfirmId: string = ''

  aboutToAppear(): void {
    this.loadData()
    this.updateGridColumns()
    this.buildPlaylistCards()
    this.publishPlusVisible()
    // 与首页一致：进入页面时复位多选状态，避免上次残留把工具栏带进来
    AppStorage.setOrCreate(AppStorageKeyConstants.KEY_PLAYLIST_MULTI_SELECT, false)
    AppStorage.setOrCreate(AppStorageKeyConstants.KEY_PLAYLIST_FOLDER_EDIT, false)
    this.maybeStartPlaylistGuide()
  }

  aboutToDisappear(): void {
    // 切页/页面销毁时收起多选：否则下次进入仍是多选态且带着旧选中项
    AppStorage.setOrCreate(AppStorageKeyConstants.KEY_PLAYLIST_MULTI_SELECT, false)
    AppStorage.setOrCreate(AppStorageKeyConstants.KEY_PLAYLIST_FOLDER_EDIT, false)
    if (this.coachStartTimer >= 0) {
      clearTimeout(this.coachStartTimer)
      this.coachStartTimer = -1
    }
    // 引导中途切页视同看过：不再补弹
    if (this.coachStepIndex >= 0) {
      this.finishPlaylistGuide()
    }
  }

  private scaledSize(size: number): number {
    return Math.round(size * this.displaySizeScale)
  }

  // 底部让位（原由 Index 算好传入，改为页内自算跟随显示大小）：
  // 小屏 128≈56(tab)+28(margin)+40(播控)+4；大屏 88≈28+56+4
  private bottomOverlayInset(): number {
    return this.scaledSize(this.smallBreakpoint ? 128 : 88) + this.bottomSafeHeight
  }

  onLibraryChange(): void {
    this.loadData()
    this.buildPlaylistCards()
  }

  onFilterChange(): void {
    this.selectedFolderPaths = this.dataService.getSelectedFolderPaths()
    this.favoritesSelected = this.dataService.isFavoritesSelected()
    this.buildPlaylistCards()
  }

  // 歌单集合/曲目变化（KEY_PLAYLIST_REVISION +1）：重建卡片数据
  onPlaylistRevisionChange(): void {
    this.buildPlaylistCards()
  }

  private updateGridColumns(): void {
    if (deviceInfo.deviceType === '2in1') {
      this.gridColumns = 3
      return
    }
    try {
      const displayInfo = display.getDefaultDisplaySync()
      const vpWidth = this.getUIContext().px2vp(displayInfo.width)
      if (vpWidth >= 600) {
        this.gridColumns = 3
      } else {
        this.gridColumns = 2
      }
    } catch (e) {
      this.gridColumns = 2
    }
  }

  loadData(): void {
    this.songs = this.dataService.getSongs()
    this.settings = this.dataService.getSettings()
    this.selectedFolderPaths = this.dataService.getSelectedFolderPaths()
    this.favoritesSelected = this.dataService.isFavoritesSelected()
    this.buildFoldersFromSongs()
  }

  buildFoldersFromSongs(): void {
    // 恢复持久化的文件夹自定义排序序号，避免每次重建都丢失
    const persisted: FolderInfo[] = this.dataService.getFolders()
    const sortOrderMap: Map<string, number> = new Map<string, number>()
    for (let i = 0; i < persisted.length; i++) {
      sortOrderMap.set(persisted[i].id, persisted[i].sortOrder)
    }
    let nextOrder: number = 1
    const countMap: Record<string, number> = {}
    for (let i = 0; i < this.songs.length; i++) {
      const key: string = this.songs[i].folderPath
      if (key.length > 0) {
        if (countMap[key] === undefined) {
          countMap[key] = 1
        } else {
          countMap[key] = countMap[key] + 1
        }
      }
    }
    const result: FolderInfo[] = []
    const keys: string[] = Object.keys(countMap)
    for (let i = 0; i < keys.length; i++) {
      const folder: FolderInfo = FolderInfo.fromPath(keys[i])
      folder.id = keys[i]
      folder.songCount = countMap[keys[i]] as number
      folder.isAvailable = true
      const persistedOrder: number | undefined = sortOrderMap.get(folder.id)
      if (persistedOrder !== undefined) {
        folder.sortOrder = persistedOrder
      } else {
        // 新出现的文件夹按首次构建顺序依次编号
        folder.sortOrder = nextOrder
        nextOrder++
      }
      result.push(folder)
    }
    this.sortFolders(result)
    // 「我的收藏」虚拟卡片强制置顶，仅用于展示，不写入持久化文件夹列表
    const favoriteCount: number = this.getFavoriteCount()
    const display: FolderInfo[] = []
    if (favoriteCount > 0) {
      const favCard: FolderInfo = new FolderInfo()
      favCard.id = FAVORITES_FOLDER_ID
      favCard.name = '我的收藏'
      favCard.path = '__favorites__'
      favCard.songCount = favoriteCount
      favCard.isAvailable = true
      display.push(favCard)
    }
    for (let i = 0; i < result.length; i++) {
      display.push(result[i])
    }
    this.folders = display
    // 只在文件夹集合（id/名称/序号/歌曲数）真的变了时才回写 preferences：
    // 曲库每次变更都会走到这里，无脑 saveFolders 会造成一次无意义的磁盘写入
    if (this.foldersChanged(persisted, result)) {
      this.dataService.saveFolders(result)
    }
  }

  // 对比重建结果与已持久化的文件夹列表：任一字段不同即视为需要落盘
  private foldersChanged(persisted: FolderInfo[], rebuilt: FolderInfo[]): boolean {
    if (persisted.length !== rebuilt.length) {
      return true
    }
    const persistedMap: Map<string, FolderInfo> = new Map<string, FolderInfo>()
    for (let i = 0; i < persisted.length; i++) {
      persistedMap.set(persisted[i].id, persisted[i])
    }
    for (let i = 0; i < rebuilt.length; i++) {
      const old: FolderInfo | undefined = persistedMap.get(rebuilt[i].id)
      if (old === undefined || old.sortOrder !== rebuilt[i].sortOrder
        || old.songCount !== rebuilt[i].songCount || old.name !== rebuilt[i].name) {
        return true
      }
    }
    return false
  }

  sortFolders(folders: FolderInfo[]): void {
    const mode: string = this.settings.folderSortMode
    if (mode === 'name') {
      folders.sort((a: FolderInfo, b: FolderInfo): number => a.name.localeCompare(b.name))
    } else if (mode === 'count') {
      folders.sort((a: FolderInfo, b: FolderInfo): number => b.songCount - a.songCount)
    } else if (mode === 'time') {
      folders.sort((a: FolderInfo, b: FolderInfo): number => b.addedTime - a.addedTime)
    } else if (mode === 'custom') {
      folders.sort((a: FolderInfo, b: FolderInfo): number => a.sortOrder - b.sortOrder)
    }
  }

  onFolderToggle(folder: FolderInfo): void {
    // 与自建歌单互斥：一旦操作文件夹/收藏，就取消歌单筛选并丢弃恢复快照
    // （否则之后再去点歌单会把过期快照又恢复回来）
    this.savedFolderPathsBeforePlaylist = []
    this.savedPrevFolderPathsBeforePlaylist = []
    this.savedFavoritesBeforePlaylist = false
    if (folder.id === FAVORITES_FOLDER_ID) {
      if (this.favoritesSelected) {
        this.favoritesSelected = false
        this.selectedFolderPaths = [...this.previousFolderPaths]
      } else {
        this.previousFolderPaths = [...this.selectedFolderPaths]
        this.favoritesSelected = true
        this.selectedFolderPaths = []
      }
    } else {
      if (this.favoritesSelected) {
        this.favoritesSelected = false
        this.previousFolderPaths = []
      }
      const idx: number = this.selectedFolderPaths.indexOf(folder.path)
      if (idx >= 0) {
        this.selectedFolderPaths.splice(idx, 1)
        this.selectedFolderPaths = [...this.selectedFolderPaths]
      } else {
        const newPaths: string[] = []
        for (let i = 0; i < this.selectedFolderPaths.length; i++) {
          newPaths.push(this.selectedFolderPaths[i])
        }
        newPaths.push(folder.path)
        this.selectedFolderPaths = newPaths
      }
    }
    this.dataService.setFilterState(this.selectedFolderPaths, this.favoritesSelected,
      this.dataService.dimsWithPlaylistId(''))
    // 歌单卡高亮要跟着刷新（歌单筛选已被清掉）
    this.buildPlaylistCards()
  }

  isFolderSelected(folder: FolderInfo): boolean {
    if (folder.id === FAVORITES_FOLDER_ID) {
      return this.favoritesSelected
    }
    return this.selectedFolderPaths.indexOf(folder.path) >= 0
  }

  enterEditMode(folderId: string): void {
    if (this.isPlaylistEditMode) {
      this.exitPlaylistEditMode()
    }
    this.isEditMode = true
    this.editSelectedFolderIds = [folderId]
    this.publishPlusVisible()
  }

  toggleEditSelect(folderId: string): void {
    const idx: number = this.editSelectedFolderIds.indexOf(folderId)
    if (idx >= 0) {
      this.editSelectedFolderIds.splice(idx, 1)
      this.editSelectedFolderIds = [...this.editSelectedFolderIds]
    } else {
      this.editSelectedFolderIds.push(folderId)
      this.editSelectedFolderIds = [...this.editSelectedFolderIds]
    }
  }

  exitEditMode(): void {
    this.isEditMode = false
    this.editSelectedFolderIds = []
    this.publishPlusVisible()
  }

  async deleteEditSelected(): Promise<void> {
    const folderPaths: string[] = []
    for (let i = 0; i < this.editSelectedFolderIds.length; i++) {
      const fid: string = this.editSelectedFolderIds[i]
      if (fid === FAVORITES_FOLDER_ID) {
        const allSongs: SongInfo[] = this.dataService.getSongs()
        for (let j = 0; j < allSongs.length; j++) {
          if (allSongs[j].isFavorite) {
            this.dataService.toggleFavorite(allSongs[j].id)
          }
        }
      } else {
        for (let j = 0; j < this.folders.length; j++) {
          if (this.folders[j].id === fid) {
            folderPaths.push(this.folders[j].path)
            break
          }
        }
      }
    }
    if (folderPaths.length > 0) {
      const deleteResult: LibraryDeleteResult = this.dataService.removeSongsByFolders(folderPaths)
      if (deleteResult.currentSongRemoved) {
        await AVPlayerService.getInstance().stop()
        AVSessionController.getInstance().clearCurrentMedia()
        await LiveViewService.getInstance().stopLiveView()
      }
      await AVSessionController.getInstance().setAVQueueItems()
    }
    this.exitEditMode()
    this.loadData()
  }

  isEditSelected(folderId: string): boolean {
    return this.editSelectedFolderIds.indexOf(folderId) >= 0
  }

  // Delete 键：歌单多选/文件夹编辑态且有选中时执行与删除按钮相同的逻辑；空选/非编辑态忽略
  onDeleteRequest(): void {
    if (this.isPlaylistEditMode) {
      if (this.playlistEditSelectedIds.length === 0) {
        return
      }
      this.deletePlaylistEditSelected().catch((err: Error) => {
        Logger.error(TAG, `delete selected playlists failed: ${JSON.stringify(err)}`)
      })
      return
    }
    if (!this.isEditMode || this.editSelectedFolderIds.length === 0) {
      return
    }
    this.deleteEditSelected().catch((err: Error) => {
      Logger.error(TAG, `delete selected failed: ${JSON.stringify(err)}`)
    })
  }

  // 全局悬浮加号已上提到 Index：本页只上报「加号是否应显示」
  // （编辑态隐藏 + 滚动隐藏设置 + 滚动方向），由 Index 读取渲染
  private publishPlusVisible(): void {
    AppStorage.setOrCreate(AppStorageKeyConstants.KEY_PLAYLIST_PLUS_VISIBLE,
      !this.isEditMode && !this.isPlaylistEditMode &&
      (this.isPlusVisible || !this.plusButtonScrollHide))
  }

  // 设置页「向下滑动时隐藏加号按钮」变更：立即按新值重算并上报加号可见性
  onPlusScrollHideChange(): void {
    this.publishPlusVisible()
  }

  async onPlusClick(): Promise<void> {
    if (this.context === undefined) {
      return
    }
    await importSongsWithToast(this.context, this.getUIContext()?.getPromptAction())
  }

  getFavoriteCount(): number {
    let count: number = 0
    for (let i = 0; i < this.songs.length; i++) {
      if (this.songs[i].isFavorite) {
        count++
      }
    }
    return count
  }

  // ═══════════ 自定义歌单（P2-3）═══════════

  // 重建歌单卡片数据：封面拼贴取歌单前 4 首歌（按加入顺序）
  buildPlaylistCards(): void {
    const playlists: PlaylistInfo[] = this.dataService.getPlaylists()
    const songMap: Map<string, SongInfo> = new Map<string, SongInfo>()
    for (let i = 0; i < this.songs.length; i++) {
      songMap.set(this.songs[i].id, this.songs[i])
    }
    const cards: PlaylistCardData[] = []
    for (let i = 0; i < playlists.length; i++) {
      const card: PlaylistCardData = new PlaylistCardData()
      card.playlist = playlists[i]
      const songIds: string[] = this.dataService.getPlaylistItemSongIds(playlists[i].id)
      card.count = songIds.length
      for (let j = 0; j < songIds.length && card.coverSongs.length < 4; j++) {
        const song: SongInfo | undefined = songMap.get(songIds[j])
        if (song !== undefined) {
          card.coverSongs.push(song)
        }
      }
      cards.push(card)
    }
    this.playlistCards = cards
  }

  // 该歌单是否为当前筛选态激活的歌单（卡片高亮）
  isPlaylistCardActive(card: PlaylistCardData): boolean {
    return this.dataService.getFilterPlaylistId() === card.playlist.id
  }

  // 点击歌单卡：设/取消歌单筛选，与文件夹/收藏互斥。
  // 选中歌单 → 先快照当前文件夹/收藏选中态再清空（界面上文件夹卡立即取消选中）；
  // 取消歌单 → 原样恢复快照，回到选歌单之前的选中状态
  onPlaylistToggle(card: PlaylistCardData): void {
    const activeId: string = this.dataService.getFilterPlaylistId()
    if (activeId === card.playlist.id) {
      // 取消选中：恢复快照
      this.selectedFolderPaths = [...this.savedFolderPathsBeforePlaylist]
      this.favoritesSelected = this.savedFavoritesBeforePlaylist
      this.previousFolderPaths = [...this.savedPrevFolderPathsBeforePlaylist]
      this.dataService.setFilterState(this.selectedFolderPaths, this.favoritesSelected,
        this.dataService.dimsWithPlaylistId(''))
    } else {
      // 选中新歌单：仅在「此前没有激活歌单」时快照，切换歌单之间不覆盖快照
      if (activeId.length === 0) {
        this.savedFolderPathsBeforePlaylist = [...this.selectedFolderPaths]
        this.savedPrevFolderPathsBeforePlaylist = [...this.previousFolderPaths]
        this.savedFavoritesBeforePlaylist = this.favoritesSelected
      }
      this.selectedFolderPaths = []
      this.favoritesSelected = false
      // 收藏态的临时还原栈随之清空，避免收藏卡复选时把旧路径带回来
      this.previousFolderPaths = []
      this.dataService.setFilterState([], false, this.dataService.dimsWithPlaylistId(card.playlist.id))
    }
    this.buildPlaylistCards()
  }

  openPlaylistCreateDialog(): void {
    this.isPlaylistCreateVisible = true
  }

  // 组件风格（tabStyle）驱动的弹窗材质（bindSheet options 的 systemMaterial 字段）：
  // 玻璃风格 → 液态玻璃；经典风格 → Material.empty 显式关闭；设备不支持 → undefined
  private styleGlassMaterial(): uiMaterial.Material | undefined {
    return createStyleGlassMaterial(this.tabStyle, DEFAULT_GLASS_STYLE)
  }

  // 新建歌单半模态弹层标题（bindSheet 官方标题栏）
  @Builder
  playlistCreateSheetTitle(): void {
    Text('新建歌单')
      .fontSize(Math.round(20 * this.fontSizeScale))
      .fontColor($r('app.color.text_primary'))
      .fontWeight(FontWeight.Bold)
      .maxLines(1)
      .width('100%')
  }

  // 新建歌单半模态弹层内容：与首页共用的统一组件（官方 bindSheet 配置由本页宿主挂载）；
  // 每次打开弹层 builder 重新执行，组件 aboutToAppear 重跑预选
  @Builder
  playlistCreateSheetBuilder(): void {
    PlaylistCreateDialog({
      songs: this.songs,
      preselectedIds: [],
      primaryColor: this.primaryColor,
      fontSizeScale: this.fontSizeScale,
      displaySizeScale: this.displaySizeScale,
      onDone: (_addedCount: number) => {
        this.isPlaylistCreateVisible = false
        this.buildPlaylistCards()
      }
    })
  }

  // 编辑歌单弹层标题（bindSheet 官方标题栏）
  @Builder
  playlistEditSheetTitle(): void {
    Text('编辑歌单')
      .fontSize(Math.round(20 * this.fontSizeScale))
      .fontColor($r('app.color.text_primary'))
      .fontWeight(FontWeight.Bold)
      .maxLines(1)
      .width('100%')
  }

  // 编辑歌单半模态弹层内容：与新建共用的统一组件（编辑模式：预选歌单现有曲目 + 可改名）
  @Builder
  playlistEditSheetBuilder(): void {
    PlaylistCreateDialog({
      songs: this.songs,
      preselectedIds: this.dataService.getPlaylistItemSongIds(this.editingPlaylistId),
      editingPlaylistId: this.editingPlaylistId,
      initialName: this.editingPlaylistName(),
      primaryColor: this.primaryColor,
      fontSizeScale: this.fontSizeScale,
      displaySizeScale: this.displaySizeScale,
      onDone: (_savedCount: number) => {
        this.isPlaylistEditVisible = false
        this.buildPlaylistCards()
      }
    })
  }

  // 当前编辑目标的歌单名（弹层预填）
  private editingPlaylistName(): string {
    const card: PlaylistCardData | undefined = this.findPlaylistCard(this.editingPlaylistId)
    return card !== undefined ? card.playlist.name : ''
  }

  // 长按冒泡菜单 → 编辑：打开编辑歌单弹层
  openPlaylistEdit(playlistId: string): void {
    this.editingPlaylistId = playlistId
    this.isPlaylistEditVisible = true
  }

  // ═══════════ 歌单多选模式（批量删除，逻辑与首页歌曲多选一致）═══════════

  // 多选状态变化统一收口在这里（与 HomeContent.onMultiSelectModeChange 同构）：
  // 退出多选时必须一并清空选中集合——返回键/ESC 触发的退出不经过 exitPlaylistEditMode()，
  // 若不清空，下次进入多选会带着上次残留的选中项
  onPlaylistMultiSelectChange(): void {
    if (!this.isPlaylistEditMode) {
      this.playlistEditSelectedIds = []
      this.playlistActionCardId = ''
    }
    this.publishPlusVisible()
  }

  // Ctrl+A：只做全选，不做取消全选；非多选态一律忽略（与首页一致）
  onSelectAllRequest(): void {
    if (!this.isAnySelectMode()) {
      return
    }
    this.setCurrentSelectedIds(this.currentVisibleIds())
  }

  // 进入多选：与首页长按一致——进入的同时把当前长按的歌单卡选中
  enterPlaylistEditMode(playlistId: string): void {
    if (this.isEditMode) {
      this.exitEditMode()
    }
    this.playlistEditSelectedIds = []
    if (playlistId.length > 0) {
      this.playlistEditSelectedIds.push(playlistId)
    }
    this.isPlaylistEditMode = true
    this.publishPlusVisible()
  }

  exitPlaylistEditMode(): void {
    this.isPlaylistEditMode = false
    this.playlistEditSelectedIds = []
    this.publishPlusVisible()
  }

  togglePlaylistEditSelect(playlistId: string): void {
    const idx: number = this.playlistEditSelectedIds.indexOf(playlistId)
    if (idx >= 0) {
      this.playlistEditSelectedIds.splice(idx, 1)
    } else {
      this.playlistEditSelectedIds.push(playlistId)
    }
    this.playlistEditSelectedIds = this.playlistEditSelectedIds.slice()
  }

  isPlaylistEditSelected(playlistId: string): boolean {
    return this.playlistEditSelectedIds.indexOf(playlistId) >= 0
  }

  // 当前全部歌单卡 id（歌单页无隐藏项，等价于首页的「可见歌曲」集合）
  getVisiblePlaylistIds(): string[] {
    const ids: string[] = []
    for (let i = 0; i < this.playlistCards.length; i++) {
      ids.push(this.playlistCards[i].playlist.id)
    }
    return ids
  }

  // 批量删除选中歌单：只删歌单与关联关系，歌曲文件与曲库不受影响
  async deletePlaylistEditSelected(): Promise<void> {
    const ids: string[] = this.playlistEditSelectedIds.slice()
    if (ids.length === 0) {
      return
    }
    for (let i = 0; i < ids.length; i++) {
      await this.dataService.deletePlaylist(ids[i])
    }
    this.exitPlaylistEditMode()
    this.buildPlaylistCards()
  }

  // 删除二次确认：只删歌单与关联关系，歌曲文件与曲库不受影响
  async confirmPlaylistDelete(): Promise<void> {
    const playlistId: string = this.playlistDeleteConfirmId
    this.playlistDeleteConfirmId = ''
    if (playlistId.length === 0) {
      return
    }
    await this.dataService.deletePlaylist(playlistId)
    this.buildPlaylistCards()
  }

  build() {
    Stack() {
      Column() {
        // 顶部标题带：任一多选/编辑态由多选菜单栏原地替换标题（与首页替换问候语同构）
        if (this.isAnySelectMode()) {
          this.playlistMultiSelectBar()
        } else {
          Row() {
            Text('歌单')
              .fontSize(Math.round(18 * this.fontSizeScale))
              .fontColor($r('app.color.text_primary'))
              .fontWeight(FontWeight.Bold)
            ScaleButton({
              pressScale: StyleConstants.PRESS_SCALE,
              hoverScale: StyleConstants.HOVER_SCALE,
              onButtonTap: () => {
                this.cycleSortMode()
              }
            }) {
              Text(this.sortModeLabel())
                .fontSize(Math.round(12 * this.fontSizeScale))
                .fontColor($r('app.color.text_sixty_color'))
                .margin({ left: 10 })
            }
          }
          .width('100%')
          .height(this.topContentPadding + this.topBandHeight)
          .padding({
            left: 20,
            right: this.isPC ? Math.max(this.titleButtonWidth, 140) + 12 : 8,
            top: this.topContentPadding
          })
          .alignItems(VerticalAlign.Center)
          // 标题带上滑淡出（与首页问候语退出同一手感），让菜单栏接手同一位置
          .transition(TransitionEffect.asymmetric(
            TransitionEffect.OPACITY
              .animation({ duration: StyleConstants.ANIMATION_MULTI_BAR_ENTER_DURATION, curve: Curve.EaseOut }),
            TransitionEffect.OPACITY
              .combine(TransitionEffect.translate({ y: -this.scaledSize(24) }))
              .animation({ duration: StyleConstants.ANIMATION_MULTI_BAR_EXIT_DURATION, curve: Curve.EaseIn })
          ))
        }

        Scroll(this.scroller) {
          Column() {
            // 我的歌单（P2-3）：歌单卡片 + 新建入口，位于文件夹区上方
            this.playlistSection()
            if (this.folders.length > 0) {
              Grid() {
                ForEach(this.folders, (item: FolderInfo) => {
                  GridItem() {
                    PressScaleHost({ pressScale: StyleConstants.PRESS_SCALE, hoverScale: StyleConstants.HOVER_SCALE }) {
                      this.folderCard(item)
                    }
                  }
                }, (item: FolderInfo) => item.id)
              }
              .columnsTemplate('1fr '.repeat(this.gridColumns).trim())
              .columnsGap(10)
              .rowsGap(10)
              .padding({ left: 16, right: 16, top: 12 })
              .width('100%')
              // 新手引导步骤 2 的高亮锚点：文件夹卡片区
              .id('coach_folder_grid')
            } else {
              ScaleButton({
                pressScale: StyleConstants.PRESS_SCALE,
                hoverScale: StyleConstants.HOVER_SCALE,
                onButtonTap: () => {
                  this.onPlusClick()
                }
              }) {
                Text('暂无歌单，点击添加歌曲')
                  .fontSize(Math.round(14 * this.fontSizeScale))
                  .fontColor($r('app.color.text_twenty_color'))
                  .width('100%')
                  .height(200)
                  .textAlign(TextAlign.Center)
              }
            }
            Blank()
              .width('100%')
              .height(this.bottomOverlayInset())
          }
          .width('100%')
        }
        .width('100%')
        .layoutWeight(1)
        .align(Alignment.Top)
        .edgeEffect(EdgeEffect.Spring)
        .nestedScroll({
          scrollForward: NestedScrollMode.SELF_FIRST,
          scrollBackward: NestedScrollMode.SELF_FIRST
        })
        .onDidScroll((scrollOffset: number) => {
          // scrollOffset 为本帧带符号偏移：向下滚动为正、向上为负
          if (scrollOffset > 10) {
            if (this.isPlusVisible) {
              this.isPlusVisible = false
              this.publishPlusVisible()
            }
          } else if (scrollOffset < 0) {
            if (!this.isPlusVisible) {
              this.isPlusVisible = true
              this.publishPlusVisible()
            }
          }
        })
      }
      .width('100%')
      .height('100%')
      // 编辑歌单弹层（长按菜单 → 编辑）：同新建弹层的半模态配置（挂在内层，避免同节点双 bindSheet）
      .bindSheet($$this.isPlaylistEditVisible, this.playlistEditSheetBuilder(), {
        detents: [SheetSize.MEDIUM],
        dragBar: false,
        title: this.playlistEditSheetTitle(),
        showClose: true,
        preferType: SheetType.CENTER,
        systemMaterial: this.styleGlassMaterial(),
        onWillDisappear: () => {
          this.isPlaylistEditVisible = false
          this.buildPlaylistCards()
        }
      })

      // 全局悬浮加号由 Index 统一渲染（首页/歌单共用，切页不位移，设置页隐藏），
      // 可见性由 publishPlusVisible 上报，本页不再挂按钮

      // 自定义歌单弹层（P2-3）：长按冒泡菜单由卡片 bindPopup 挂载 / 删除二次确认
      if (this.playlistDeleteConfirmId.length > 0) {
        this.playlistDeleteConfirm()
      }

      // 新手引导浮层（聚光分步）：首次进入歌单页自动弹出，走完/跳过后不再出现
      // （设置-关于提供「重新查看引导」入口），遮罩拦截全部点击，点任意处进入下一步
      if (this.coachStepIndex >= 0) {
        Column() {
          CoachMarkOverlay({
            steps: this.coachSteps,
            stepIndex: this.coachStepIndex,
            primaryColor: this.primaryColor,
            isHostBusy: (): boolean => {
              return this.isAnySelectMode()
            },
            onFinish: (): void => {
              this.finishPlaylistGuide()
            }
          })
        }
        .width('100%')
        .height('100%')
        .zIndex(40)
      }
    }
    .width('100%')
    .height('100%')
    // 背景使用预设纯色（明暗自适应），不应用任何玻璃/模糊/透明度效果
    .backgroundColor($r('app.color.page_background_sm'))
    // 新建歌单统一弹窗（与首页共用组件）：官方半模态配置（标题栏 + 中档高度 + 玻璃材质）
    .bindSheet($$this.isPlaylistCreateVisible, this.playlistCreateSheetBuilder(), {
      detents: [SheetSize.MEDIUM],
      dragBar: false,
      title: this.playlistCreateSheetTitle(),
      showClose: true,
      preferType: SheetType.CENTER,
      systemMaterial: this.styleGlassMaterial()
    })
  }

  // ═══════════ 多选工具栏统一入口（歌单多选 / 文件夹编辑共用一套，逻辑对齐首页）═══════════

  onFolderEditModeChange(): void {
    if (!this.isEditMode) {
      this.editSelectedFolderIds = []
    }
    this.publishPlusVisible()
  }

  // 两种模式互斥且共用同一条顶部工具栏
  private isAnySelectMode(): boolean {
    return this.isPlaylistEditMode || this.isEditMode
  }

  private selectedCount(): number {
    return this.isPlaylistEditMode ? this.playlistEditSelectedIds.length : this.editSelectedFolderIds.length
  }

  private currentVisibleIds(): string[] {
    if (this.isPlaylistEditMode) {
      return this.getVisiblePlaylistIds()
    }
    const ids: string[] = []
    for (let i = 0; i < this.folders.length; i++) {
      ids.push(this.folders[i].id)
    }
    return ids
  }

  private currentSelectedIds(): string[] {
    return this.isPlaylistEditMode ? this.playlistEditSelectedIds : this.editSelectedFolderIds
  }

  private setCurrentSelectedIds(ids: string[]): void {
    if (this.isPlaylistEditMode) {
      this.playlistEditSelectedIds = ids
    } else {
      this.editSelectedFolderIds = ids
    }
  }

  private isAllSelected(): boolean {
    const visibleIds: string[] = this.currentVisibleIds()
    const selected: string[] = this.currentSelectedIds()
    if (visibleIds.length === 0 || selected.length !== visibleIds.length) {
      return false
    }
    for (let i = 0; i < visibleIds.length; i++) {
      if (selected.indexOf(visibleIds[i]) < 0) {
        return false
      }
    }
    return true
  }

  private toggleSelectAll(): void {
    if (this.isAllSelected()) {
      this.setCurrentSelectedIds([])
      return
    }
    this.setCurrentSelectedIds(this.currentVisibleIds())
  }

  // 反选：翻转可见项选中态，结果按列表顺序重排（与首页 invertVisibleSelection 一致）
  private invertSelection(): void {
    const visibleIds: string[] = this.currentVisibleIds()
    const selectedSet: Set<string> = new Set(this.currentSelectedIds())
    const result: string[] = []
    for (let i = 0; i < visibleIds.length; i++) {
      if (!selectedSet.has(visibleIds[i])) {
        result.push(visibleIds[i])
      }
    }
    this.setCurrentSelectedIds(result)
  }

  private deleteInSelectMode(): void {
    if (this.isPlaylistEditMode) {
      this.deletePlaylistEditSelected().catch((err: Error) => {
        Logger.error(TAG, `delete selected playlists failed: ${JSON.stringify(err)}`)
      })
      return
    }
    this.deleteEditSelected().catch((err: Error) => {
      Logger.error(TAG, `delete selected failed: ${JSON.stringify(err)}`)
    })
  }

  private exitSelectMode(): void {
    if (this.isPlaylistEditMode) {
      this.exitPlaylistEditMode()
      return
    }
    this.exitEditMode()
  }

  // ═══════════ 歌单多选菜单栏（与首页多选栏同款：返回键退出 + 全选/反选/删除）═══════════

  // 经典样式下不挂任何背景效果（与首页 multiSelectBarMaterial 策略一致）
  private playlistBarMaterial(): uiMaterial.Material | undefined {
    if (this.tabStyle === 'classic') {
      return undefined
    }
    return createBarGlassMaterial(DEFAULT_GLASS_STYLE, true, this.primaryColor)
  }

  @Builder
  playlistMultiSelectBar(): void {
    Row() {
      // 返回按钮：与首页/设置页/播放页共用同一组件，圆形玻璃材质与底部 Tab 栏同源
      GlassBackButton({
        clickSize: this.scaledSize(48),
        iconSize: this.scaledSize(15),
        iconColor: $r('app.color.text_primary'),
        iconOpacity: 0.9,
        onBack: () => { this.exitSelectMode() }
      })

      Text('已选 ' + this.selectedCount() + ' 个')
        .fontSize(Math.round(14 * this.fontSizeScale))
        .fontColor($r('app.color.text_primary'))
      Blank()
      // 全选按钮 - 带图标（与首页一致：全选后变为取消全选）
      ScaleButton({
        pressScale: StyleConstants.PRESS_SCALE,
        hoverScale: StyleConstants.HOVER_SCALE,
        onButtonTap: () => {
          this.toggleSelectAll()
        }
      }) {
        Row({ space: 4 }) {
          Image(this.isAllSelected() ? $r('app.media.ic_public_deselect_all') : $r('app.media.ic_public_select_all'))
            .width(Math.round(16 * this.fontSizeScale))
            .height(Math.round(16 * this.fontSizeScale))
            .fillColor(this.primaryColor)
          Text(this.isAllSelected() ? '取消全选' : '全选')
            .fontSize(Math.round(14 * this.fontSizeScale))
            .fontColor(this.primaryColor)
        }
        .margin({ right: 16 })
      }

      // 反选 - 纯文字按钮（图标库无对应图标，置于全选后）
      ScaleButton({
        pressScale: StyleConstants.PRESS_SCALE,
        hoverScale: StyleConstants.HOVER_SCALE,
        onButtonTap: () => {
          this.invertSelection()
        }
      }) {
        Text('反选')
          .fontSize(Math.round(14 * this.fontSizeScale))
          .fontColor(this.primaryColor)
          .margin({ right: 16 })
      }

      // 删除按钮 - 带图标：歌单多选只删歌单与关联关系；文件夹编辑走原有的曲库删除确认
      ScaleButton({
        pressScale: StyleConstants.PRESS_SCALE,
        hoverScale: StyleConstants.HOVER_SCALE,
        onButtonTap: () => {
          this.deleteInSelectMode()
        }
      }) {
        Row({ space: 4 }) {
          Image($r('app.media.ic_public_delete'))
            .width(Math.round(16 * this.fontSizeScale))
            .height(Math.round(16 * this.fontSizeScale))
            .fillColor(StyleConstants.COLOR_DANGER_RED)
          Text('删除')
            .fontSize(Math.round(14 * this.fontSizeScale))
            .fontColor(StyleConstants.COLOR_DANGER_RED)
        }
      }
    }
    .width('100%')
    .height(this.topContentPadding + this.topBandHeight)
    .padding({
      left: 4,
      right: this.isPC ? Math.max(this.titleButtonWidth, 140) + 12 : 16,
      top: this.topContentPadding
    })
    .alignItems(VerticalAlign.Center)
    .backgroundColor(Color.Transparent)
    .backgroundEffect(this.tabStyle !== 'classic' ? {
      radius: 20,
      saturation: 1.0,
      brightness: 1.0
    } : undefined)
    .systemMaterial(this.playlistBarMaterial())
    // 与首页多选菜单栏完全同款：入场上浮淡入（带延迟，等标题先退），退场下沉淡出
    .transition(TransitionEffect.asymmetric(
      TransitionEffect.OPACITY
        .combine(TransitionEffect.translate({ y: this.scaledSize(28) }))
        .animation({
          duration: StyleConstants.ANIMATION_MULTI_BAR_ENTER_DURATION,
          curve: Curve.EaseOut,
          delay: StyleConstants.ANIMATION_MULTI_BAR_ENTER_DELAY
        }),
      TransitionEffect.OPACITY
        .combine(TransitionEffect.translate({ y: this.scaledSize(28) }))
        .animation({
          duration: StyleConstants.ANIMATION_MULTI_BAR_EXIT_DURATION,
          curve: Curve.EaseIn
        })
    ))
  }

  // ═══════════ 自定义歌单 UI（P2-3）═══════════

  @Builder
  playlistSection(): void {
    Column() {
      Text('我的歌单')
        .fontSize(Math.round(14 * this.fontSizeScale))
        .fontColor($r('app.color.text_primary'))
        .fontWeight(FontWeight.Bold)
        .width('100%')
        .padding({ left: 16, right: 16 })
      Grid() {
        ForEach(this.playlistCards, (card: PlaylistCardData) => {
          GridItem() {
            // 卡片带 bindPopup 与长按手势，不能包 ScaleButton；也不能在带参 @Builder 内用页面状态驱动缩放
            // （按值传参的 @Builder 不会随状态重新求值），故用只做缩放的宿主组件，逐卡独立状态
            PressScaleHost({ pressScale: StyleConstants.PRESS_SCALE, hoverScale: StyleConstants.HOVER_SCALE }) {
              this.playlistCard(card)
            }
          }
        }, (card: PlaylistCardData) =>
          card.playlist.id + '_' + card.playlist.name + '_' + card.count + '_' +
          (this.isPlaylistCardActive(card) ? '1' : '0') + '_' +
          (this.isPlaylistEditMode ? (this.isPlaylistEditSelected(card.playlist.id) ? 's' : 'e') : 'n'))
        GridItem() {
          this.newPlaylistCard()
        }
      }
      .columnsTemplate('1fr '.repeat(this.gridColumns).trim())
      .columnsGap(10)
      .rowsGap(10)
      .padding({ left: 16, right: 16, top: 12 })
      .width('100%')
      // 新手引导步骤 1 的高亮锚点：歌单卡片区
      .id('coach_playlist_grid')
    }
    .width('100%')
    .margin({ top: 4 })
  }

  @Builder
  playlistCard(card: PlaylistCardData): void {
    Row() {
      if (this.isPlaylistEditMode) {
        Image(this.isPlaylistEditSelected(card.playlist.id) ?
          $r('app.media.ic_public_todo_filled') : $r('app.media.ic_public_todo'))
          .width(20)
          .height(20)
          .fillColor(this.isPlaylistEditSelected(card.playlist.id) ?
            this.primaryColor : $r('app.color.text_sixty_color'))
          .margin({ right: 10 })
      }
      Column() {
        Row() {
          this.collageCell(card, 0)
          this.collageCell(card, 1)
        }
        .width('100%')
        .layoutWeight(1)

        Row() {
          this.collageCell(card, 2)
          this.collageCell(card, 3)
        }
        .width('100%')
        .layoutWeight(1)
      }
      .width(this.scaledSize(44))
      .height(this.scaledSize(44))
      .borderRadius(10)
      .clip(true)

      Column({ space: 2 }) {
        Text(card.playlist.name)
          .fontSize(Math.round(12 * this.fontSizeScale))
          .fontColor($r('app.color.text_primary'))
          // 手机窄卡（2 列）时名称列只有 ~60vp，单行必然截断：允许两行，卡高 80 放得下
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        Text(card.count + ' 首')
          .fontSize(10)
          .fontColor($r('app.color.text_sixty_color'))
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      .margin({ left: 12 })
    }
    .width('100%')
    .height(80)
    .padding({ left: 16, right: 16 })
    .alignItems(VerticalAlign.Center)
    .borderRadius(16)
    .backgroundColor(this.isPlaylistCardActive(card) ?
      ColorHelper.hexWithAlpha(this.primaryColor, '22') : 'rgba(0,0,0,0.03)')
    .border({ width: this.isPlaylistCardActive(card) ? 2 : 1,
      color: this.isPlaylistCardActive(card) ? this.primaryColor : $r('app.color.list_divider') })
    .onClick(() => {
      if (this.isPlaylistEditMode) {
        this.togglePlaylistEditSelect(card.playlist.id)
      } else {
        this.onPlaylistToggle(card)
      }
    })
    .gesture(
      LongPressGesture()
        .onAction(() => {
          if (!this.isAnySelectMode()) {
            this.playlistActionCardId = card.playlist.id
          }
        })
    )
    // 长按冒泡菜单（倍速弹窗同款 bindPopup 气泡）：编辑 / 多选 / 删除
    // 气泡底色必须在 PopupOptions 上设：系统弹窗容器自带一层不透明底板，
    // 只改 builder 内容区的 backgroundColor 是盖不掉那层灰底的（暗色下尤其明显）
    .bindPopup(!this.isAnySelectMode() && this.playlistActionCardId === card.playlist.id, {
      builder: this.playlistActionPopupBuilder,
      placement: Placement.Bottom,
      showInSubWindow: false,
      // 玻璃样式：容器透明 + 磨砂，让气泡自己出真玻璃（不再依赖系统默认底板）
      // 经典样式：页面同色实底卡片
      popupColor: this.tabStyle === 'immersive' ? Color.Transparent : $r('app.color.page_background_sm'),
      backgroundBlurStyle: this.tabStyle === 'immersive' ? BlurStyle.COMPONENT_THICK : BlurStyle.NONE,
      radius: this.scaledSize(14),
      systemMaterial: this.styleGlassMaterial(),
      onStateChange: (e) => {
        if (!e.isVisible) {
          this.playlistActionCardId = ''
        }
      }
    })
  }

  // 封面拼贴单格（P2-3）：前 4 首歌封面 2×2；不足的格子铺占位底色
  @Builder
  collageCell(card: PlaylistCardData, index: number): void {
    Stack() {
      if (index < card.coverSongs.length) {
        AlbumCover({ song: card.coverSongs[index], coverWidth: '100%', coverHeight: '100%',
          coverRadius: 0, decodeSize: AlbumCoverSize.SMALL })
      } else {
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor('rgba(0,0,0,0.04)')
      }
    }
    .layoutWeight(1)
    .height('100%')
  }

  @Builder
  newPlaylistCard(): void {
    ScaleButton({
      pressScale: StyleConstants.PRESS_SCALE,
      hoverScale: StyleConstants.HOVER_SCALE,
      expandWidth: true,
      onButtonTap: () => {
        this.openPlaylistCreateDialog()
      }
    }) {
      Row() {
        Image($r('app.media.ic_public_add_norm_filled'))
          .width(28)
          .height(28)
          .fillColor(this.primaryColor)
        Text('新建歌单')
          .fontSize(Math.round(12 * this.fontSizeScale))
          .fontColor($r('app.color.text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .margin({ left: 12 })
      }
      .width('100%')
      .height(80)
      .padding({ left: 16, right: 16 })
      .alignItems(VerticalAlign.Center)
      .borderRadius(16)
      .backgroundColor('rgba(0,0,0,0.03)')
      .border({ width: 1, color: $r('app.color.list_divider') })
    }
  }

  // 长按歌单卡冒泡菜单（bindPopup，倍速弹窗同款气泡）：编辑 / 多选 / 删除
  @Builder
  playlistActionPopupBuilder(): void {
    Column() {
      ScaleButton({
        pressScale: StyleConstants.PRESS_SCALE,
        hoverScale: StyleConstants.HOVER_SCALE,
        expandWidth: true,
        onButtonTap: () => {
          const playlistId: string = this.playlistActionCardId
          this.playlistActionCardId = ''
          if (playlistId.length > 0) {
            this.openPlaylistEdit(playlistId)
          }
        }
      }) {
        Text('编辑')
          .fontSize(Math.round(14 * this.fontSizeScale))
          .fontColor($r('app.color.text_primary'))
          .width('100%')
          .textAlign(TextAlign.Center)
          .padding({ top: 12, bottom: 12 })
      }
      Divider()
        .color($r('app.color.list_divider'))
      ScaleButton({
        pressScale: StyleConstants.PRESS_SCALE,
        hoverScale: StyleConstants.HOVER_SCALE,
        expandWidth: true,
        onButtonTap: () => {
          const playlistId: string = this.playlistActionCardId
          this.playlistActionCardId = ''
          // 与首页长按进入多选一致：进入即把目标卡置为选中
          this.enterPlaylistEditMode(playlistId)
        }
      }) {
        Text('多选')
          .fontSize(Math.round(14 * this.fontSizeScale))
          .fontColor($r('app.color.text_primary'))
          .width('100%')
          .textAlign(TextAlign.Center)
          .padding({ top: 12, bottom: 12 })
      }
      Divider()
        .color($r('app.color.list_divider'))
      ScaleButton({
        pressScale: StyleConstants.PRESS_SCALE,
        hoverScale: StyleConstants.HOVER_SCALE,
        expandWidth: true,
        onButtonTap: () => {
          this.playlistDeleteConfirmId = this.playlistActionCardId
          this.playlistActionCardId = ''
        }
      }) {
        Text('删除')
          .fontSize(Math.round(14 * this.fontSizeScale))
          .fontColor(StyleConstants.COLOR_DANGER_RED)
          .width('100%')
          .textAlign(TextAlign.Center)
          .padding({ top: 12, bottom: 12 })
      }
    }
    .width(112)
    .padding({ top: 4, bottom: 4 })
    // 内容区保持透明：底色/圆角由 bindPopup 的 PopupOptions 统一给（容器级），
    // 否则会在系统底板上再叠一层，玻璃样式下直接变实色块
    .backgroundColor(Color.Transparent)
    // 暗色下页面与卡片同为深色，靠一道细描边维持卡片边界（玻璃样式不需要）
    .border({
      width: this.tabStyle === 'immersive' ? 0 : 1,
      color: $r('app.color.list_divider')
    })
    .borderRadius(this.scaledSize(14))
  }

  // 删除歌单二次确认：明确告知歌曲本身不会被删除
  @Builder
  playlistDeleteConfirm(): void {
    Stack({ alignContent: Alignment.Center }) {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor('rgba(0,0,0,0.35)')
        .onClick(() => {
          this.playlistDeleteConfirmId = ''
        })

      Column({ space: 12 }) {
        Text('删除歌单')
          .fontSize(Math.round(16 * this.fontSizeScale))
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
          .width('100%')
        Text('删除后无法恢复，歌单内的歌曲不会从曲库移除。')
          .fontSize(Math.round(13 * this.fontSizeScale))
          .fontColor($r('app.color.text_sixty_color'))
          .width('100%')

        Row({ space: 10 }) {
          Row() {
            ScaleButton({
              pressScale: StyleConstants.PRESS_SCALE,
              hoverScale: StyleConstants.HOVER_SCALE,
              expandWidth: true,
              onButtonTap: () => {
                this.playlistDeleteConfirmId = ''
              }
            }) {
              Text('取消')
                .fontSize(Math.round(14 * this.fontSizeScale))
                .fontColor($r('app.color.text_sixty_color'))
                .width('100%')
                .textAlign(TextAlign.Center)
                .padding({ top: 8, bottom: 8 })
                .borderRadius(16)
                .backgroundColor('rgba(0,0,0,0.05)')
            }
          }
          .layoutWeight(1)

          Row() {
            ScaleButton({
              pressScale: StyleConstants.PRESS_SCALE,
              hoverScale: StyleConstants.HOVER_SCALE,
              expandWidth: true,
              onButtonTap: () => {
                this.confirmPlaylistDelete().catch((err: Error) => {
                  Logger.error(TAG, `confirmPlaylistDelete failed: ${JSON.stringify(err)}`)
                })
              }
            }) {
              Text('删除')
                .fontSize(Math.round(14 * this.fontSizeScale))
                .fontColor(Color.White)
                .width('100%')
                .textAlign(TextAlign.Center)
                .padding({ top: 8, bottom: 8 })
                .borderRadius(16)
                .backgroundColor(StyleConstants.COLOR_DANGER_RED)
            }
          }
          .layoutWeight(1)
        }
        .width('100%')
      }
      .width('76%')
      .padding(18)
      .borderRadius(20)
      .backgroundColor($r('app.color.page_background_sm'))
    }
    .width('100%')
    .height('100%')
    .zIndex(30)
  }

  private findPlaylistCard(playlistId: string): PlaylistCardData | undefined {
    for (let i = 0; i < this.playlistCards.length; i++) {
      if (this.playlistCards[i].playlist.id === playlistId) {
        return this.playlistCards[i]
      }
    }
    return undefined
  }

  @Builder
  folderCard(item: FolderInfo): void {
    Row() {
      if (this.isEditMode) {
        Image(this.isEditSelected(item.id) ? $r('app.media.ic_public_todo_filled') : $r('app.media.ic_public_todo'))
          .width(20).height(20)
          .fillColor(this.isEditSelected(item.id) ? this.primaryColor : $r('app.color.text_sixty_color'))
          .margin({ right: 10 })
      }
      if (item.id === FAVORITES_FOLDER_ID) {
        Image($r('app.media.ic_public_favor_filled'))
          .width(28).height(28)
          .fillColor(this.favoritesSelected ? Color.Red : this.primaryColor)
      } else {
        Image($r('app.media.ic_public_folder'))
          .width(28)
          .height(28)
          .fillColor($r('app.color.text_sixty_color'))
      }
      Column({ space: 2 }) {
        Text(item.name)
          .fontSize(Math.round(12 * this.fontSizeScale))
          .fontColor($r('app.color.text_primary'))
          // 同歌单卡：窄卡允许两行，避免文件夹名被截成「MemoSp…」
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        Text(item.songCount + ' 首歌曲')
          .fontSize(10)
          .fontColor($r('app.color.text_sixty_color'))
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      .margin({ left: 12 })
    }
    .width('100%')
    .height(80)
    .padding({ left: 16, right: 16 })
    .alignItems(VerticalAlign.Center)
    .backgroundColor(this.isFolderSelected(item) ?
      ColorHelper.hexWithAlpha(this.primaryColor, '22') : 'rgba(0,0,0,0.03)')
    .borderRadius(16)
    .border({ width: this.isFolderSelected(item) ? 2 : 1,
      color: this.isFolderSelected(item) ? this.primaryColor : $r('app.color.list_divider') })
    .gesture(
      LongPressGesture()
        .onAction(() => {
          if (!this.isEditMode) {
            this.enterEditMode(item.id)
          }
        })
    )
    .onClick(() => {
      if (this.isEditMode) {
        this.toggleEditSelect(item.id)
      } else {
        this.onFolderToggle(item)
      }
    })
  }

  sortModeLabel(): string {
    const mode: string = this.settings.folderSortMode
    if (mode === 'name') return '按名称'
    if (mode === 'count') return '按数量'
    if (mode === 'time') return '按时间'
    if (mode === 'custom') return '自定义'
    return '按名称'
  }

  cycleSortMode(): void {
    const modes: string[] = ['name', 'count', 'time', 'custom']
    const current: string = this.settings.folderSortMode
    let idx: number = -1
    for (let i = 0; i < modes.length; i++) {
      if (modes[i] === current) {
        idx = i
        break
      }
    }
    const next: string = modes[(idx + 1) % modes.length]
    this.settings.folderSortMode = next
    this.dataService.saveSettings(this.settings)
    this.buildFoldersFromSongs()
  }
}
