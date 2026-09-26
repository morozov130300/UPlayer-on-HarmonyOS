// ArkUI 26 Beta1: 接口定义变更（误报，本项目已是Stage模型）+ UX视觉布局变更（Text默认开启沉浸式材质，系统行为）
import { common, ConfigurationConstant } from '@kit.AbilityKit'
import { deviceInfo } from '@kit.BasicServicesKit'
import { SongInfo } from '../model/SongInfo'
import { DataService, AppSettingsData, ImportResult } from '../service/DataService'
import { SongScanner } from '../service/SongScanner'
import { AVPlayerService } from '../service/AVPlayerService'
import { ColorHelper } from '../common/utils/ColorHelper'
import { DisplayItemDataSource } from '../viewmodel/DisplayItemDataSource'
import Logger from '../common/utils/Logger'
import { AppStorageKeyConstants } from '../common/constants/AppStorageKeyConstants'
import { AlbumCover } from '../component/AlbumCover'
import { AlbumCoverSize, AudioMetadataService, CoverPriority } from '../service/AudioMetadataService'
import { curves, uiMaterial } from '@kit.ArkUI'
import { createBarGlassMaterial, topBlurRadiusFromStrength } from '../common/utils/GlassUtil'
import { KEY_HOLDING_HAND_LEFT } from '../service/HoldingHandService'
import { GlassBackButton } from '../view/GlassBackButton'
import { StyleConstants } from '../common/constants/StyleConstants'

const TAG = 'HomeContent'
const PREFETCH_COUNT: number = 64
const PREFETCH_THROTTLE_MS: number = 50
const APPROX_ITEM_HEIGHT: number = 72
// 手柄拖拽：拖拽位移超过该距离（约一行高）时与相邻项交换位置
const DRAG_SWAP_DISTANCE: number = 60

class DisplayItem {
  isHeader: boolean = false
  headerText: string = ''
  song: SongInfo = new SongInfo()
  key: string = ''
}

@Component
export struct HomeContent {
  topContentPadding: number = 0
  bottomContentPadding: number = 0
  // 问候语内容带（由 Index 传入）：多选菜单栏进入多选时落在该带内，替换问候语的位置
  greetingBandTop: number = 0
  greetingBandHeight: number = 0
  private isPC: boolean = deviceInfo.deviceType === '2in1'
  private context: common.UIAbilityContext | undefined = AppStorage.get<common.UIAbilityContext>(AppStorageKeyConstants.KEY_UI_ABILITY_CONTEXT)
  @State songs: SongInfo[] = []
  @State displayItems: DisplayItem[] = []
  private displayDataSource: DisplayItemDataSource = new DisplayItemDataSource([])
  @State viewMode: string = 'flat'
  @State sortMode: string = 'name'
  @State isPlusVisible: boolean = true
  @State settings: AppSettingsData = new AppSettingsData()
  // 筛选胶囊与歌单页卡片选中状态实时同步：歌单页每次勾选都调用 setFilterState（同时 bump KEY_FILTER_REVISION），
  // 这里用 @Watch 跟随刷新，保证首页胶囊文字/底色即时反映当前选中的文件夹或收藏
  // 多选状态挂在 AppStorage 上并双向绑定：@Entry 页面需要在返回键/ESC 里把它置 false 来退出多选。
  // 之前是私有 @State，外部（页面级 onBackPress）无法把多选状态收回去，导致返回键只能退出应用。
  @StorageLink(AppStorageKeyConstants.KEY_HOME_MULTI_SELECT) @Watch('onMultiSelectModeChange')
  isMultiSelectMode: boolean = false
  // Ctrl+A 全选请求（由 Index 的页面级键盘事件写入并 +1）：多选态下全选可见歌曲
  @StorageLink(AppStorageKeyConstants.KEY_HOME_SELECT_ALL_REQUEST) @Watch('onSelectAllRequest')
  selectAllRequest: number = 0
  @StorageLink(AppStorageKeyConstants.KEY_TITLE_BUTTON_WIDTH) titleButtonWidth: number = 0
  @StorageLink('uplayer_font_size_scale') fontSizeScale: number = 1.0
  @StorageLink('uplayer_display_size_scale') displaySizeScale: number = 1.0
  @StorageLink(AppStorageKeyConstants.KEY_LIBRARY_REVISION) @Watch('onLibraryChange') libraryRevision: number = 0
  @StorageLink(AppStorageKeyConstants.KEY_FILTER_REVISION) @Watch('onFilterChange') filterRevision: number = 0
  // 胶囊文字用 @State 缓存：KEY_FILTER_REVISION 变化时由 @Watch 赋值，保证 UI 响应式刷新
  @State filterLabel: string = '全部歌曲'
  @State selectedIds: string[] = []
  @State failedArtIds: Set<string> = new Set<string>()
  // 手动拖拽排序状态：dragSongId 为被拖拽歌曲 id，空串表示未拖拽。
  // 必须用 id 定位（而非 index）：LazyForEach 数据移动/节点复用后 index 不可靠
  @State dragSongId: string = ''
  @State dragOffsetY: number = 0
  private dragLastY: number = 0
  @StorageLink('uplayer_primary_color') primaryColor: string = '#007DFF'
  @StorageLink('uplayer_theme_mode') themeMode: string = 'system'
  // 底部栏样式：经典样式下多选菜单栏不挂任何背景效果（磨砂/液态玻璃）
  @StorageLink('uplayer_tab_style') tabStyle: string = 'classic'
  @StorageLink('uplayer_home_top_blur_strength') homeTopBlurStrength: number = 25
  @StorageLink('uplayer_glass_thickness') glassThickness: number = 50
  @StorageLink('uplayer_interactive') interactive: boolean = true
  // 智感握姿：左手握持 → 加号靠左；其余（右手/双手/无握持/未知即默认）→ 靠右。
  // 滤波与订阅由 HoldingHandService 统一持有，本组件只订阅它的广播结果
  @StorageLink(KEY_HOLDING_HAND_LEFT) @Watch('onHoldingHandLeftChange') holdingHandLeft: boolean = false
  // 真正参与布局的贴边状态：只在 animateTo 闭包里跟随 holdingHandLeft 变化，
  // 握姿切换时加号才会「滑」到另一侧（position 支持属性动画），而不是瞬移
  @State plusOnLeft: boolean = false
  // 握姿切换的滑动曲线：弹簧跟手，与设置页主题切换等动效保持一致的手感
  private readonly PLUS_SIDE_SPRING_RESPONSE: number = 0.4
  private readonly PLUS_SIDE_SPRING_DAMPING: number = 0.8
  private dataService: DataService = DataService.getInstance()
  private songScanner: SongScanner = SongScanner.getInstance()
  private avPlayerService: AVPlayerService = AVPlayerService.getInstance()
  private scroller: Scroller = new Scroller()

  private scaledSize(size: number): number {
    return Math.round(size * this.displaySizeScale)
  }

  // 首页上端模糊半径：统一走 GlassUtil 的分段函数（先正比例、到 60 后恒定，临界处无缝相接）。
  // 只允许调用工厂，不允许在本文件重写公式——否则会与设置页顶部带产生断口
  private glassBlurRadius(): number {
    return topBlurRadiusFromStrength(this.homeTopBlurStrength)
  }

  // 多选底栏液态玻璃材质（API 26+）：能力不足/玻璃关断/低算力返回 undefined，
  // 调用处保留 backgroundEffect 兜底，保证老设备仍有磨砂。
  // 经典底部栏样式下整条不应用任何背景效果（避免压出一层灰突突的色块）
  private multiSelectBarMaterial(): uiMaterial.Material | undefined {
    if (this.tabStyle === 'classic') {
      return undefined
    }
    return createBarGlassMaterial(this.glassThickness, this.interactive)
  }

  // 经典样式下同样不挂磨砂层（与材质一起关断）
  private multiSelectBarBlurEnabled(): boolean {
    return this.tabStyle !== 'classic'
  }

  @State headerRowHeight: number = 0

  private headerOverlayHeight(): number {
    return this.headerRowHeight > 0 ? this.headerRowHeight : this.scaledSize(40)
  }

  private onHeaderRowAreaChange(area: Area): void {
    const h: Length = area.height
    if (typeof h === 'number' && h > 0 && Math.abs(h - this.headerRowHeight) > 0.5) {
      this.headerRowHeight = h
    }
  }

  // 多选菜单栏几何：高度保持原样，垂直居中于问候语内容带
  private multiSelectBarHeight(): number {
    return 56
  }

  private multiSelectBarTop(): number {
    const band: number = this.greetingBandHeight > 0 ? this.greetingBandHeight : 72
    const top: number = this.greetingBandTop + (band - this.multiSelectBarHeight()) / 2
    return top > 0 ? top : 0
  }

  // 右侧内边距与问候语保持一致：PC 上预留窗口按钮区域
  private multiSelectBarRightPadding(): number {
    return this.isPC ? Math.max(this.titleButtonWidth, 140) + 12 : 16
  }

  private listTopPadding(): number {
    return this.topContentPadding + this.headerOverlayHeight()
  }

  private scrollBarHeight(): string {
    return 'calc(100% - ' + this.listTopPadding() + 'vp)'
  }

  // 智感握姿切换：把贴边状态放进动画闭包，让加号从一侧滑到另一侧
  onHoldingHandLeftChange(): void {
    const isLeft: boolean = this.holdingHandLeft
    if (isLeft === this.plusOnLeft) {
      return
    }
    this.getUIContext()?.animateTo({
      curve: curves.springMotion(this.PLUS_SIDE_SPRING_RESPONSE, this.PLUS_SIDE_SPRING_DAMPING)
    }, () => {
      this.plusOnLeft = isLeft
    })
  }

  aboutToAppear(): void {
    this.loadData()
    this.refreshFilterLabel()
    // 首次进入按当前握姿直接落位，不做动画（避免首帧从默认侧滑过来）
    this.plusOnLeft = this.holdingHandLeft
    AppStorage.setOrCreate(AppStorageKeyConstants.KEY_HOME_MULTI_SELECT, false)
  }

  aboutToDisappear(): void {
    AppStorage.setOrCreate(AppStorageKeyConstants.KEY_HOME_MULTI_SELECT, false)
  }

  // 多选状态变化统一收口在这里。isMultiSelectMode 已改为 @StorageLink，
// 写入 AppStorage 由框架自动完成，这里不能再手动 setOrCreate（会重复通知一次）。
  // 退出多选时必须一并清空选中集合：返回键/ESC 触发的退出不经过 exitMultiSelect()，
  // 若不清空，下次进入多选会带着上次残留的选中项。
  onMultiSelectModeChange(): void {
    if (!this.isMultiSelectMode) {
      this.selectedIds = []
    }
  }

  // Ctrl+A：只做全选，不做取消全选；非多选态一律忽略（普通浏览时不响应，避免误触）
  onSelectAllRequest(): void {
    if (!this.isMultiSelectMode) {
      return
    }
    this.selectedIds = this.getVisibleSongIds()
  }

  onLibraryChange(): void {
    this.loadData()
  }

  onFilterChange(): void {
    this.applyFilters()
    this.refreshFilterLabel()
  }

  // 把 DataService 当前筛选状态写入 @State，驱动胶囊 UI 刷新
  private refreshFilterLabel(): void {
    if (this.dataService.isFavoritesSelected()) {
      this.filterLabel = '我的收藏'
    } else {
      const paths: string[] = this.dataService.getSelectedFolderPaths()
      if (paths.length === 1) {
        const lastSlash: number = paths[0].lastIndexOf('/')
        const lastBackslash: number = paths[0].lastIndexOf('\\')
        const sepIdx: number = lastSlash > lastBackslash ? lastSlash : lastBackslash
        this.filterLabel = sepIdx >= 0 ? paths[0].substring(sepIdx + 1) : paths[0]
      } else if (paths.length > 1) {
        this.filterLabel = paths.length + ' 个文件夹'
      } else {
        this.filterLabel = '全部歌曲'
      }
    }
  }

  loadData(): void {
    this.failedArtIds = new Set<string>()
    this.songs = this.dataService.getSongs()
    this.settings = this.dataService.getSettings()
    this.viewMode = this.dataService.getViewMode()
    this.sortMode = this.dataService.getSortMode()
    this.applyFilters()
  }

  applyFilters(): void {
    const isFavFilter: boolean = this.dataService.isFavoritesSelected()
    const selectedPaths: string[] = this.dataService.getSelectedFolderPaths()
    const hasFolderFilter: boolean = !isFavFilter && selectedPaths.length > 0
    const result: SongInfo[] = []
    for (let i = 0; i < this.songs.length; i++) {
      const song: SongInfo = this.songs[i]
      if (isFavFilter) {
        if (song.isFavorite) {
          result.push(song)
        }
      } else if (hasFolderFilter) {
        if (selectedPaths.indexOf(song.folderPath) >= 0) {
          result.push(song)
        }
      } else {
        result.push(song)
      }
    }
    const sorted: SongInfo[] = this.sortSongs(result)
    this.buildDisplayItems(sorted)
  }

  buildDisplayItems(sorted: SongInfo[]): void {
    const items: DisplayItem[] = []
    if (this.viewMode === 'flat') {
      for (let i = 0; i < sorted.length; i++) {
        const di: DisplayItem = new DisplayItem()
        di.isHeader = false
        di.song = sorted[i]
        items.push(di)
      }
    } else {
      const groupMap: Record<string, SongInfo[]> = {}
      for (let i = 0; i < sorted.length; i++) {
        const song: SongInfo = sorted[i]
        const key: string = song.folderName.length > 0 ? song.folderName : '其他'
        if (groupMap[key] === undefined) {
          groupMap[key] = []
        }
        groupMap[key].push(song)
      }
      const keys: string[] = Object.keys(groupMap)
      for (let gi = 0; gi < keys.length; gi++) {
        const key: string = keys[gi]
        const groupSongs: SongInfo[] = groupMap[key]
        const header: DisplayItem = new DisplayItem()
        header.isHeader = true
        header.headerText = key
        items.push(header)
        for (let si = 0; si < groupSongs.length; si++) {
          const di: DisplayItem = new DisplayItem()
          di.isHeader = false
          di.song = groupSongs[si]
          items.push(di)
        }
      }
    }
    this.displayItems = items
    this.displayDataSource.reloadData(items)
    this.syncPlayQueue()
    const visible: SongInfo[] = []
    for (let i = 0; i < items.length && visible.length < PREFETCH_COUNT; i++) {
      if (!items[i].isHeader && items[i].song.isAvailable) {
        visible.push(items[i].song)
      }
    }
    AudioMetadataService.getInstance().prefetchAlbumCovers(
      visible, AlbumCoverSize.SMALL, CoverPriority.HIGH)
  }

  // 播放队列与首页显示顺序保持一致：把当前可见顺序（跳过分组标题）同步为播放队列
  // （KEY_SONG_LIST），播放器歌单、上一首/下一首、点击播放都基于该队列索引；
  // 队列变化后按当前播放歌曲 id 重映射 selectIndex，保证高亮与切歌定位正确。
  syncPlayQueue(): void {
    const queue: SongInfo[] = []
    for (let i = 0; i < this.displayItems.length; i++) {
      const item: DisplayItem = this.displayItems[i]
      if (!item.isHeader) {
        queue.push(item.song)
      }
    }
    AppStorage.setOrCreate(AppStorageKeyConstants.KEY_SONG_LIST, queue)
    const currentId: string = AppStorage.get<string>('uplayer_current_song_id') ?? ''
    if (currentId.length > 0) {
      let idx: number = -1
      for (let i = 0; i < queue.length; i++) {
        if (queue[i].id === currentId) {
          idx = i
          break
        }
      }
      AppStorage.setOrCreate(AppStorageKeyConstants.KEY_SELECT_INDEX, idx)
    }
  }

  sortSongs(songs: SongInfo[]): SongInfo[] {
    const sorted: SongInfo[] = []
    for (let i = 0; i < songs.length; i++) {
      sorted.push(songs[i])
    }
    if (this.sortMode === 'name') {
      sorted.sort((a: SongInfo, b: SongInfo): number => {
        return a.name.localeCompare(b.name)
      })
    } else if (this.sortMode === 'date') {
      sorted.sort((a: SongInfo, b: SongInfo): number => {
        return b.addedTime - a.addedTime
      })
    } else {
      sorted.sort((a: SongInfo, b: SongInfo): number => {
        return a.sortOrder - b.sortOrder
      })
    }
    return sorted
  }

  clearFilters(): void {
    this.dataService.setFilterState([], false)
  }

  toggleViewMode(): void {
    if (this.viewMode === 'flat') {
      this.viewMode = 'folder'
    } else {
      this.viewMode = 'flat'
    }
    this.dataService.setViewMode(this.viewMode)
    this.applyFilters()
  }

  switchSortMode(): void {
    if (this.sortMode === 'name') {
      this.sortMode = 'date'
    } else if (this.sortMode === 'date') {
      this.sortMode = 'custom'
    } else {
      this.sortMode = 'name'
    }
    this.dataService.setSortMode(this.sortMode)
    this.applyFilters()
  }

  async onPlusClick(): Promise<void> {
    if (this.context === undefined) {
      return
    }
    const newSongs: SongInfo[] = await this.songScanner.pickAudioFiles(this.context)
    if (newSongs.length > 0) {
      const result: ImportResult = this.dataService.addSongs(newSongs)
      this.failedArtIds = new Set<string>()
      this.loadData()
      try {
        this.getUIContext()?.getPromptAction().showToast({
          message: `新增 ${result.newCount} 首` + (result.dupCount > 0 ? `，${result.dupCount} 首已存在` : ''),
        })
      } catch (e) {
        Logger.error(TAG, 'toast failed')
      }
    }
  }

  toggleFavorite(songId: string): void {
    const newFav: boolean = this.dataService.toggleFavorite(songId)
    AppStorage.setOrCreate(AppStorageKeyConstants.KEY_IS_FAVORITE, newFav)
    for (let i = 0; i < this.displayItems.length; i++) {
      const item: DisplayItem = this.displayItems[i]
      if (!item.isHeader && item.song && item.song.id === songId) {
        item.song.isFavorite = newFav
        this.displayDataSource.notifyDataChange(i)
        break
      }
    }
  }

  // 只有自定义排序模式才允许通过手柄拖拽重排
  canDragSort(): boolean {
    return this.sortMode === 'custom'
  }

  indexOfSong(songId: string): number {
    for (let i = 0; i < this.displayItems.length; i++) {
      const item: DisplayItem = this.displayItems[i]
      if (!item.isHeader && item.song.id === songId) {
        return i
      }
    }
    return -1
  }

  isDraggingSong(item: DisplayItem): boolean {
    return this.dragSongId.length > 0 && !item.isHeader && item.song.id === this.dragSongId
  }

  // 手柄拖拽位移更新：累计跟手偏移；每跨越约一行高度即与相邻项交换一次。
  // 拖拽行始终用 song id 定位；交换时 layout 前移与 translate 回退相互抵消，保持跟手。
  onHandleDragUpdate(offsetY: number): void {
    if (this.dragSongId.length === 0) {
      return
    }
    const cur: number = this.indexOfSong(this.dragSongId)
    if (cur < 0) {
      return
    }
    const dy: number = offsetY - this.dragLastY
    this.dragLastY = offsetY
    this.dragOffsetY = this.dragOffsetY + dy
    const step: number = this.scaledSize(DRAG_SWAP_DISTANCE)
    if (this.dragOffsetY >= step && cur < this.displayItems.length - 1) {
      this.getUIContext()?.animateTo({ curve: curves.springMotion(0.3, 0.9) }, () => {
        this.onMoveListItem(cur, cur + 1)
        this.dragOffsetY = this.dragOffsetY - step
      })
    } else if (this.dragOffsetY <= -step && cur > 0) {
      this.getUIContext()?.animateTo({ curve: curves.springMotion(0.3, 0.9) }, () => {
        this.onMoveListItem(cur, cur - 1)
        this.dragOffsetY = this.dragOffsetY + step
      })
    }
  }

  // 拖拽结束：被拖拽行以弹簧动画落位到当前槽位，并立即落盘排序结果
  finishDrag(): void {
    if (this.dragSongId.length === 0) {
      return
    }
    this.getUIContext()?.animateTo({ curve: curves.springMotion(0.3, 0.9) }, () => {
      this.dragSongId = ''
      this.dragOffsetY = 0
    })
    this.dataService.flushPendingSongWrites()
  }

  // 重排公共入口：由拖拽手柄的 PanGesture 在跨越相邻项时调用（from/to 为相邻索引）。
  // 同步重排 displayDataSource 与 displayItems，并同步底层 songs 的 sortOrder：
  // flat 视图下 displayItems 的顺序即 sortOrder 升序；
  // 持久化走 saveSongsNoReload（不 bump KEY_LIBRARY_REVISION），
  // 避免拖拽过程中触发 @Watch(onLibraryChange) → 整体 reloadData 造成闪烁。
  onMoveListItem(from: number, to: number): void {
    if (from === to || from < 0 || to < 0) {
      return
    }
    if (from >= this.displayItems.length || to >= this.displayItems.length) {
      return
    }
    this.displayDataSource.moveItem(from, to)
    // 同步本组件持有的 displayItems 数组顺序，保证后续索引类逻辑一致
    const movedItem: DisplayItem = this.displayItems.splice(from, 1)[0]
    this.displayItems.splice(to, 0, movedItem)
    // 同步重排底层 songs 数组：flat 视图下 displayItems 的顺序即 sortOrder 升序
    const songs: SongInfo[] = this.dataService.getSongs()
    const movedId: string = this.displayItems[to].song.id
    const sortable: SongInfo[] = []
    for (let i = 0; i < songs.length; i++) {
      sortable.push(songs[i])
    }
    sortable.sort((a: SongInfo, b: SongInfo): number => {
      return a.sortOrder - b.sortOrder
    })
    let fromIdx: number = -1
    for (let i = 0; i < sortable.length; i++) {
      if (sortable[i].id === movedId) {
        fromIdx = i
        break
      }
    }
    if (fromIdx < 0) {
      return
    }
    const moved: SongInfo = sortable.splice(fromIdx, 1)[0]
    sortable.splice(to, 0, moved)
    const lo: number = Math.min(fromIdx, to)
    const hi: number = Math.max(fromIdx, to)
    const orderMap: Map<string, number> = new Map<string, number>()
    for (let i = 0; i < sortable.length; i++) {
      if (i >= lo && i <= hi) {
        orderMap.set(sortable[i].id, i + 1)
      }
    }
    for (let i = 0; i < songs.length; i++) {
      const o: number | undefined = orderMap.get(songs[i].id)
      if (o !== undefined) {
        songs[i].sortOrder = o
      }
    }
    this.dataService.saveSongsNoReload(songs)
    this.syncPlayQueue()
  }

  onSongTap(item: SongInfo): void {
    if (this.isMultiSelectMode) {
      this.toggleSelectItem(item.id)
      return
    }
    // 点击播放按播放队列（与首页可见顺序一致）定位索引
    const queue: SongInfo[] | undefined = AppStorage.get<SongInfo[]>(AppStorageKeyConstants.KEY_SONG_LIST)
    if (queue === undefined) {
      return
    }
    for (let i = 0; i < queue.length; i++) {
      if (queue[i].id === item.id) {
        this.avPlayerService.playSongAt(i)
        break
      }
    }
  }

  onSongLongPress(item: SongInfo): void {
    if (!this.isMultiSelectMode) {
      this.isMultiSelectMode = true
      this.selectedIds = []
    }
    this.toggleSelectItem(item.id)
  }

  toggleSelectItem(id: string): void {
    const idx: number = this.selectedIds.indexOf(id)
    if (idx >= 0) {
      this.selectedIds.splice(idx, 1)
    } else {
      this.selectedIds.push(id)
    }
    this.selectedIds = this.selectedIds.slice()
  }

  getVisibleSongIds(): string[] {
    const ids: string[] = []
    for (let i = 0; i < this.displayItems.length; i++) {
      const item: DisplayItem = this.displayItems[i]
      if (!item.isHeader) {
        ids.push(item.song.id)
      }
    }
    return ids
  }

  isAllSelected(): boolean {
    const visibleIds: string[] = this.getVisibleSongIds()
    if (visibleIds.length === 0 || this.selectedIds.length !== visibleIds.length) {
      return false
    }
    for (let i = 0; i < visibleIds.length; i++) {
      if (this.selectedIds.indexOf(visibleIds[i]) < 0) {
        return false
      }
    }
    return true
  }

  toggleSelectAll(): boolean {
    if (this.isAllSelected()) {
      this.selectedIds = []
      return false
    }
    this.selectedIds = this.getVisibleSongIds()
    return true
  }

  exitMultiSelect(): void {
    this.isMultiSelectMode = false
    this.selectedIds = []
  }

  deleteSelected(): void {
    for (let i = 0; i < this.selectedIds.length; i++) {
      this.dataService.removeSong(this.selectedIds[i])
    }
    this.isMultiSelectMode = false
    this.selectedIds = []
    this.loadData()
  }

  isSelected(id: string): boolean {
    return this.selectedIds.indexOf(id) >= 0
  }

  getSortLabel(): string {
    if (this.sortMode === 'name') {
      return '名称排序'
    } else if (this.sortMode === 'date') {
      return '添加时间'
    }
    return '自定义'
  }

  prefetchInScrollDirection(yOffset: number, scrollingDown: boolean): void {
    const now: number = new Date().getTime()
    if (now - this.lastPrefetchTime < PREFETCH_THROTTLE_MS) {
      return
    }
    this.lastPrefetchTime = now
    const adjustedY: number = Math.max(0, yOffset - this.listTopPadding())
    const approxItemHeight: number = this.scaledSize(APPROX_ITEM_HEIGHT)
    const estStartIndex: number = Math.floor(adjustedY / approxItemHeight)
    const songs: SongInfo[] = []
    if (scrollingDown) {
      const start: number = estStartIndex + PREFETCH_COUNT
      let count: number = 0
      for (let i = start; i < this.displayItems.length && count < PREFETCH_COUNT; i++) {
        if (!this.displayItems[i].isHeader && this.displayItems[i].song.isAvailable) {
          songs.push(this.displayItems[i].song)
          count++
        }
      }
    } else {
      const end: number = Math.max(0, estStartIndex)
      const start: number = Math.max(0, end - PREFETCH_COUNT)
      let count: number = 0
      for (let i = start; i < end && count < PREFETCH_COUNT; i++) {
        if (!this.displayItems[i].isHeader && this.displayItems[i].song.isAvailable) {
          songs.push(this.displayItems[i].song)
          count++
        }
      }
    }
    if (songs.length > 0) {
      AudioMetadataService.getInstance().prefetchAlbumCovers(
        songs, AlbumCoverSize.SMALL, CoverPriority.MEDIUM)
    }
  }

  @State lastScrollY: number = 0
  private lastPrefetchTime: number = 0

  build() {
    Stack({ alignContent: Alignment.Top }) {
      Column() {
        Stack() {
          List({ space: 0, scroller: this.scroller }) {
            ListItem() {
              Row()
                .width('100%')
                .height(this.listTopPadding())
            }

            // 不注册 LazyForEach.onMove（List 内置的整行长按拖拽）：
            // 1) 内置手势触发区域是整行，无法限定在手柄上，且名称/时间排序下会误触；
            // 2) 条件注册 onMove 会在进入多选时整树重挂，长按后立刻拖拽会失效回弹。
            // 排序改为仅在拖拽手柄上通过 PanGesture 手动驱动（见 songItemRow）。
            //TODO 手柄部分不需要长按就可以排序，歌曲项部分要长按才能拖动
            LazyForEach(this.displayDataSource, (item: DisplayItem, index: number) => {
              ListItem() {
                if (item.isHeader) {
                  this.folderHeaderRow(item.headerText)
                } else if (!item.isHeader) {
                  this.songItemRow(item.song)
                }
              }
              .reuseId(item.isHeader ? 'header' : 'song')
              .translate({ y: this.isDraggingSong(item) ? this.dragOffsetY : 0 })
              .scale(this.isDraggingSong(item) ? { x: 1.03, y: 1.03 } : { x: 1, y: 1 })
              .zIndex(this.isDraggingSong(item) ? 100 : 0)
            }, (item: DisplayItem, index: number) => {
              if (item.isHeader) {
                return 'h_' + item.headerText
              }
              if (!item.isHeader) {
                return item.song.id + '_' + (item.song.isFavorite ? '1' : '0')
              }
              return 'empty_' + index
            })

            ListItem() {
              Row()
                .width('100%')
                .height(this.bottomContentPadding)
            }
          }
          .width('100%')
          .height('100%')
          .scrollBar(BarState.Off)
          .edgeEffect(EdgeEffect.Spring)
          .cachedCount(8)
          .nestedScroll({
            scrollForward: NestedScrollMode.SELF_FIRST,
            scrollBackward: NestedScrollMode.SELF_FIRST
          })
          .onDidScroll(() => {
            const offset = this.scroller.currentOffset()
            const yOffset: number = offset.yOffset
            if (yOffset > this.lastScrollY && (yOffset - this.lastScrollY) > 10) {
              this.isPlusVisible = false
              this.prefetchInScrollDirection(yOffset, true)
            } else if (yOffset < this.lastScrollY) {
              this.isPlusVisible = true
              this.prefetchInScrollDirection(yOffset, false)
            }
            this.lastScrollY = yOffset
          })

          if (this.displayItems.length === 0) {
            Text('暂无歌曲，点击添加')
              .fontSize(Math.round(14 * this.fontSizeScale))
              .fontColor($r('app.color.text_twenty_color'))
              .textAlign(TextAlign.Center)
              .onClick(() => { this.onPlusClick() })
          }

          ScrollBar({
            scroller: this.scroller,
            direction: ScrollBarDirection.Vertical,
            state: BarState.Auto
          })
          .width(this.scaledSize(4))
          .height(this.scrollBarHeight())
          .position({ top: this.listTopPadding(), right: 0 })
        }
        .width('100%')
        .layoutWeight(1)
      }
      .width('100%')
      .height('100%')

      Stack({ alignContent: Alignment.Top }) {
        Row()
          .width('100%')
          .height('100%')
          .backgroundColor(Color.Transparent)
          .linearGradientBlur(this.glassBlurRadius(), {
            fractionStops: [[1, 0], [1, 0.5], [0, 1]],
            direction: GradientDirection.Bottom
          })

        Row()
          .width('100%')
          .height('100%')
          .linearGradient({
            angle: 180,
            colors: [
              [ColorHelper.hexToRgba(this.primaryColor, 0.04), 0],
              [ColorHelper.hexToRgba(this.primaryColor, 0.02), 0.5],
              ['rgba(0,0,0,0)', 1]
            ]
          })

        Row() {
          Row() {
            Text(this.filterLabel)
              .fontSize(Math.round(14 * this.fontSizeScale))
              .fontColor($r('app.color.text_primary'))
              .fontWeight(FontWeight.Bold)
          }
          .padding({ left: 12, right: 12, top: 6, bottom: 6 })
          .backgroundColor(this.filterLabel === '全部歌曲' ? 'rgba(0,0,0,0.05)' : ColorHelper.hexToRgba(this.primaryColor, 0.12))
          .borderRadius(16)
          .onClick(() => { this.clearFilters() })

          Blank()

          Row() {
            Image($r('app.media.ic_sort_list'))
              .width(16).height(16)
              .fillColor($r('app.color.text_primary'))
            Text(this.getSortLabel())
              .fontSize(Math.round(12 * this.fontSizeScale))
              .fontColor($r('app.color.text_primary'))
              .margin({ left: 4 })
          }
          .padding({ left: 10, right: 10, top: 6, bottom: 6 })
          .backgroundColor(ColorHelper.hexToRgba(this.primaryColor, 0.12))
          .borderRadius(16)
          .onClick(() => { this.switchSortMode() })

          Row() {
            Text(this.viewMode === 'flat' ? '平铺' : '文件夹')
              .fontSize(Math.round(12 * this.fontSizeScale))
              .fontColor($r('app.color.text_primary'))
          }
          .padding({ left: 10, right: 10, top: 6, bottom: 6 })
          .backgroundColor(ColorHelper.hexToRgba(this.primaryColor, 0.12))
          .borderRadius(16)
          .onClick(() => { this.toggleViewMode() })
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 6 })
        .position({ top: this.topContentPadding - this.scaledSize(8) })
        .onAreaChange((oldValue: Area, newValue: Area) => {
          this.onHeaderRowAreaChange(newValue)
        })
      }
      .width('100%')
      .height(this.listTopPadding())
      .position({ top: 0 })
      .clip(true)
      .hitTestBehavior(HitTestMode.Transparent)
      .zIndex(2)

      // 多选菜单栏：落在问候语内容带内（替换问候语的位置），
      // 入场/退场由 transition 驱动，入场延迟让问候语先上滑隐藏
      if (this.isMultiSelectMode) {
        Row() {
          // 返回按钮：与设置页/播放页共用同一组件，圆形玻璃材质与底部 Tab 栏同源
          GlassBackButton({
            clickSize: this.scaledSize(48),
            iconSize: this.scaledSize(15),
            iconColor: $r('app.color.text_primary'),
            iconOpacity: 0.9,
            onBack: () => { this.exitMultiSelect() }
          })

          Text('已选 ' + this.selectedIds.length + ' 首')
            .fontSize(Math.round(14 * this.fontSizeScale))
            .fontColor($r('app.color.text_primary'))
          Blank()
          // 全选按钮 - 带图标
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
          .onClick(() => { this.toggleSelectAll() })

          // 删除按钮 - 带图标
          Row({ space: 4 }) {
            Image($r('app.media.ic_public_delete'))
              .width(Math.round(16 * this.fontSizeScale))
              .height(Math.round(16 * this.fontSizeScale))
              .fillColor('#FF3B30')
            Text('删除')
              .fontSize(Math.round(14 * this.fontSizeScale))
              .fontColor('#FF3B30')
          }
          .onClick(() => { this.deleteSelected() })
        }
        .width('100%')
        .height(this.multiSelectBarHeight())
        .padding({ left: 4, right: this.multiSelectBarRightPadding() })
        .backgroundColor(Color.Transparent)
        // 磨砂层常挂（液态玻璃启用时作为材质底层兜底，与 Tab 栏策略一致）；
        // 经典样式下不挂任何背景效果
        .backgroundEffect(this.multiSelectBarBlurEnabled() ? {
          radius: 20,
          saturation: 1.0,
          brightness: 1.0
        } : undefined)
        .systemMaterial(this.multiSelectBarMaterial())
        .position({ top: this.multiSelectBarTop(), left: 0 })
        .zIndex(2)
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

      if (!this.isMultiSelectMode && (this.isPlusVisible || !this.settings.plusButtonScrollHide)) {
        // 加号组件：ic_public_add_norm_filled 是「实心圆 + 加号镂空」，镂空处会漏背景光；
        // 下方垫一个同样大小（40vp）的玻璃盘（内容区走磨砂兜底 + 压暗），
        // 加号镂空处透出玻璃而非背景光；玻璃盘略大于图标内切蓝圆(约36.7vp)，边缘留一圈玻璃衬底
        Stack({ alignContent: Alignment.Center }) {
          Row()
            .width(this.scaledSize(40)).height(this.scaledSize(40))
            .borderRadius(this.scaledSize(20))
            // 磨砂 + 压暗：挡住加号镂空处的背景漏光（内容区沉浸式材质不渲染，磨砂即玻璃兜底）
            .backgroundEffect({ radius: 24, color: 'rgba(0,0,0,0.35)' })
          Image($r('app.media.ic_public_add_norm_filled'))
            .width(this.scaledSize(40)).height(this.scaledSize(40))
            .fillColor(this.primaryColor)
        }
        // 智感握姿：只切换贴边方向，不改变与底部的间距，避免握姿切换时按钮上下跳动。
        // 读 plusOnLeft（动画态）而不是 holdingHandLeft，切换才会走滑动动画
        .position({
          bottom: this.bottomContentPadding + this.scaledSize(12),
          left: this.plusOnLeft ? this.scaledSize(20) : undefined,
          right: this.plusOnLeft ? undefined : this.scaledSize(20)
        })
        .transition({ type: TransitionType.Insert, opacity: 0, scale: { x: 0.5, y: 0.5 } })
        .transition({ type: TransitionType.Delete, opacity: 0, scale: { x: 0.5, y: 0.5 } })
        .onClick(() => { this.onPlusClick() })
      }
    }
    .width('100%')
    .height('100%')
    // 背景使用预设纯色（明暗自适应），不应用任何玻璃/模糊/透明度效果
    .backgroundColor($r('app.color.page_background_sm'))
  }

  @Builder
  folderHeaderRow(title: string): void {
    Row() {
      Text(title)
        .fontSize(Math.round(13 * this.fontSizeScale))
        .fontColor($r('app.color.text_sixty_color'))
        .fontWeight(FontWeight.Medium)
        .padding({
          left: this.scaledSize(16), top: this.scaledSize(12), bottom: this.scaledSize(4)
        })
    }
    .width('100%')
    .backgroundColor('rgba(0,0,0,0.02)')
  }

  @Builder
  songItemRow(item: SongInfo): void {
    Row() {
      // 拖拽手柄：只有按住该手柄上下拖动才会触发排序。
      // 手柄区域 Block 阻断事件冒泡——不会误触行的长按/点击，也不影响列表其他区域的正常滚动。
      if (this.canDragSort() && this.isMultiSelectMode && this.viewMode === 'flat') {
        Row() {
          Image($r('app.media.ic_public_drag_handle'))
            .width(this.scaledSize(22))
            .height(this.scaledSize(22))
            .fillColor('#888888')
        }
        .padding({
          left: this.scaledSize(4), right: this.scaledSize(4),
          top: this.scaledSize(10), bottom: this.scaledSize(10)
        })
        .margin({ right: this.scaledSize(16) })
        .hitTestBehavior(HitTestMode.Block)
        .gesture(
          PanGesture({ fingers: 1, direction: PanDirection.Vertical, distance: 5 })
            .onActionStart((event: GestureEvent) => {
              const idx: number = this.indexOfSong(item.id)
              if (idx < 0) {
                return
              }
              // 凸起动画：抬手柄瞬间以缩放浮起被拖拽行
              this.getUIContext()?.animateTo({ duration: 150 }, () => {
                this.dragSongId = item.id
                this.dragOffsetY = 0
                this.dragLastY = event.offsetY
              })
            })
            .onActionUpdate((event: GestureEvent) => {
              this.onHandleDragUpdate(event.offsetY)
            })
            .onActionEnd(() => {
              this.finishDrag()
            })
            .onActionCancel(() => {
              this.finishDrag()
            })
        )
      }
      if (this.isMultiSelectMode) {
        Image(this.isSelected(item.id) ? $r('app.media.ic_public_todo_filled') : $r('app.media.ic_public_todo'))
          .width(this.scaledSize(22))
          .height(this.scaledSize(22))
          .fillColor(this.isSelected(item.id) ? this.primaryColor : $r('app.color.text_sixty_color'))
          .margin({ right: this.scaledSize(16) })
      }

      AlbumCover({ song: item, coverWidth: this.scaledSize(36), coverHeight: this.scaledSize(36),
        coverRadius: this.scaledSize(6), decodeSize: AlbumCoverSize.SMALL })
        .margin({ right: this.scaledSize(10) })

      Column() {
        Text(item.title.length > 0 ? item.title : item.name)
          .fontSize(Math.round(15 * this.fontSizeScale))
          .fontColor(item.isAvailable ? $r('app.color.text_primary') : $r('app.color.text_sixty_color'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        Row() {
          Text(item.artist.length > 0 ? item.artist : '未知歌手')
            .fontSize(Math.round(12 * this.fontSizeScale))
            .fontColor($r('app.color.text_sixty_color'))
          if (item.folderName.length > 0 && item.isAvailable) {
            Text(' · ' + item.folderName)
              .fontSize(Math.round(12 * this.fontSizeScale))
              .fontColor($r('app.color.text_twenty_color'))
          }
        }
        .width('100%')
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      if (item.isAvailable) {
        Row() {
          SymbolGlyph($r('sys.symbol.list_bullet'))
            .fontSize(Math.round(22 * this.fontSizeScale))
            .renderingStrategy(SymbolRenderingStrategy.SINGLE)
            .fontColor([$r('app.color.text_sixty_color')])
            .hitTestBehavior(HitTestMode.Block)
            .onClick(() => {
              this.dataService.addToPlayNext(item.id)
              try {
                this.getUIContext()?.getPromptAction().showToast({
                  message: '已添加到下一首播放',
                })
              } catch (e) {
                Logger.error(TAG, 'toast failed')
              }
            })
        }
        .margin({ right: this.scaledSize(16) })
      }

      Image(item.isFavorite ? $r('app.media.ic_public_favor_filled') : $r('app.media.ic_public_favor'))
        .width(this.scaledSize(22)).height(this.scaledSize(22))
        .fillColor(item.isFavorite ? '#FF3B30' : $r('app.color.text_sixty_color'))
        .hitTestBehavior(HitTestMode.Block)
        .onClick(() => {
          this.toggleFavorite(item.id)
        })
    }
    .width('100%')
    .padding({
      left: this.scaledSize(20), right: this.scaledSize(20),
      top: this.scaledSize(10), bottom: this.scaledSize(10)
    })
    .constraintSize({ minHeight: this.scaledSize(52), maxHeight: this.scaledSize(96) })
    .alignItems(VerticalAlign.Center)
    .parallelGesture(
      // 单击与长按必须先组成互斥手势组，再整体作为并行手势挂到行上。
      // 若直接给行挂 .onClick 再并行挂 LongPressGesture，二者会被合成并行组：
      // 长按成功后松手仍会补发一次单击，把刚长按选中的项又取消掉。
      GestureGroup(GestureMode.Exclusive,
        TapGesture({ count: 1, fingers: 1 })
          .onAction(() => {
            if (!item.isAvailable && !this.isMultiSelectMode) {
              try {
                this.getUIContext()?.getPromptAction().showToast({
                  message: '歌曲可能已被删除或移动'
                })
              } catch (e) {
                Logger.error(TAG, 'unavailable toast failed')
              }
              return
            }
            this.onSongTap(item)
          }),
        LongPressGesture({ repeat: false })
          .onAction(() => {
            this.onSongLongPress(item)
          })
      )
    )
  }
}
