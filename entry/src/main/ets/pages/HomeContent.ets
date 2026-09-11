// ArkUI 26 Beta1: 接口定义变更（误报，本项目已是Stage模型）+ UX视觉布局变更（Text默认开启沉浸式材质，系统行为）
import { common } from '@kit.AbilityKit'
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

const TAG = 'HomeContent'
const PREFETCH_COUNT: number = 32
const PREFETCH_THROTTLE_MS: number = 100
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
  private context: common.UIAbilityContext | undefined = AppStorage.get<common.UIAbilityContext>(AppStorageKeyConstants.KEY_UI_ABILITY_CONTEXT)
  @State songs: SongInfo[] = []
  @State displayItems: DisplayItem[] = []
  private displayDataSource: DisplayItemDataSource = new DisplayItemDataSource([])
  @State viewMode: string = 'flat'
  @State sortMode: string = 'name'
  @State isPlusVisible: boolean = true
  @State settings: AppSettingsData = new AppSettingsData()
  @State isMultiSelectMode: boolean = false
  @StorageLink('uplayer_font_size_scale') fontSizeScale: number = 1.0
  @StorageLink('uplayer_display_size_scale') displaySizeScale: number = 1.0
  @StorageLink(AppStorageKeyConstants.KEY_LIBRARY_REVISION) @Watch('onLibraryChange') libraryRevision: number = 0
  @StorageLink(AppStorageKeyConstants.KEY_FILTER_REVISION) @Watch('onFilterChange') filterRevision: number = 0
  @State selectedIds: string[] = []
  @State failedArtIds: Set<string> = new Set<string>()
  // 手动拖拽排序状态：dragSongId 为被拖拽歌曲 id，空串表示未拖拽。
  // 必须用 id 定位（而非 index）：LazyForEach 数据移动/节点复用后 index 不可靠
  @State dragSongId: string = ''
  @State dragOffsetY: number = 0
  private dragLastY: number = 0
  // 最近一次长按触发的时间戳，用于丢弃长按结束后的那次 click
  private longPressAtMs: number = 0
  @StorageLink('uplayer_primary_color') primaryColor: string = '#007DFF'
  @StorageLink('uplayer_home_top_blur_strength') homeTopBlurStrength: number = 25
  private dataService: DataService = DataService.getInstance()
  private songScanner: SongScanner = SongScanner.getInstance()
  private avPlayerService: AVPlayerService = AVPlayerService.getInstance()
  private scroller: Scroller = new Scroller()

  private scaledSize(size: number): number {
    return Math.round(size * this.displaySizeScale)
  }

  private glassBlurRadius(): number {
    return this.homeTopBlurStrength *
      (1.6 - this.homeTopBlurStrength * 0.004)
  }

  private headerOverlayHeight(): number {
    return this.scaledSize(48)
  }

  private listTopPadding(): number {
    return this.topContentPadding + this.headerOverlayHeight()
  }

  private scrollBarHeight(): string {
    return 'calc(100% - ' + this.listTopPadding() + 'vp)'
  }

  aboutToAppear(): void {
    this.loadData()
  }

  onLibraryChange(): void {
    this.loadData()
  }

  onFilterChange(): void {
    this.applyFilters()
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
    const visible: SongInfo[] = []
    for (let i = 0; i < items.length && visible.length < PREFETCH_COUNT; i++) {
      if (!items[i].isHeader && items[i].song.isAvailable) {
        visible.push(items[i].song)
      }
    }
    AudioMetadataService.getInstance().prefetchAlbumCovers(
      visible, AlbumCoverSize.SMALL, CoverPriority.HIGH)
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

  hasActiveFilter(): boolean {
    return this.dataService.isFavoritesSelected() || this.dataService.getSelectedFolderPaths().length > 0
  }

  getFilterLabel(): string {
    if (this.dataService.isFavoritesSelected()) {
      return '我的收藏'
    }
    const paths: string[] = this.dataService.getSelectedFolderPaths()
    if (paths.length === 1) {
      const lastSlash: number = paths[0].lastIndexOf('/')
      const lastBackslash: number = paths[0].lastIndexOf('\\')
      const sepIdx: number = lastSlash > lastBackslash ? lastSlash : lastBackslash
      return sepIdx >= 0 ? paths[0].substring(sepIdx + 1) : paths[0]
    }
    if (paths.length > 1) {
      return paths.length + ' 个文件夹'
    }
    return '全部歌曲'
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
  }

  onSongTap(item: SongInfo): void {
    // 丢弃长按后松手派发的那次点击，防止把刚长按选中的项又取消掉
    if (new Date().getTime() - this.longPressAtMs < 500) {
      return
    }
    if (this.isMultiSelectMode) {
      this.toggleSelectItem(item.id)
      return
    }
    const allSongs: SongInfo[] = this.dataService.getSongs()
    for (let i = 0; i < allSongs.length; i++) {
      if (allSongs[i].id === item.id) {
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
    // 记录长按时间：长按结束后松手仍会派发一次 onClick，
    // onSongTap 里据此丢弃这次点击，避免刚选中的项被取消、多选模式被退出
    this.longPressAtMs = new Date().getTime()
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
    if (this.selectedIds.length === 0) {
      this.isMultiSelectMode = false
    }
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

  toggleSelectAll(): void {
    if (this.isAllSelected()) {
      this.selectedIds = []
      return
    }
    this.selectedIds = this.getVisibleSongIds()
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
        songs, AlbumCoverSize.SMALL, CoverPriority.HIGH)
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
                .height(this.isMultiSelectMode ? this.bottomContentPadding + 56 : this.bottomContentPadding)
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

        if (this.isMultiSelectMode) {
          Row() {
            Text('已选 ' + this.selectedIds.length + ' 首')
              .fontSize(Math.round(14 * this.fontSizeScale))
              .fontColor($r('app.color.text_primary'))
            Blank()
            // 全选按钮 - 带图标
            Row({ space: 4 }) {
              SymbolGlyph($r('sys.symbol.checkmark_circle'))
                .fontSize(Math.round(16 * this.fontSizeScale))
                .fontColor([this.primaryColor])
              Text(this.isAllSelected() ? '取消全选' : '全选')
                .fontSize(Math.round(14 * this.fontSizeScale))
                .fontColor(this.primaryColor)
            }
            .margin({ right: 16 })
            .onClick(() => { this.toggleSelectAll() })

            // 取消按钮 - 带图标
            Row({ space: 4 }) {
              SymbolGlyph($r('sys.symbol.xmark'))
                .fontSize(Math.round(16 * this.fontSizeScale))
                .fontColor([$r('app.color.text_sixty_color')])
              Text('取消')
                .fontSize(Math.round(14 * this.fontSizeScale))
                .fontColor(this.primaryColor)
            }
            .margin({ right: 16 })
            .onClick(() => { this.exitMultiSelect() })

            // 删除按钮 - 带图标
            Row({ space: 4 }) {
              SymbolGlyph($r('sys.symbol.trash'))
                .fontSize(Math.round(16 * this.fontSizeScale))
                .fontColor(['#FF3B30'])
              Text('删除')
                .fontSize(Math.round(14 * this.fontSizeScale))
                .fontColor('#FF3B30')
            }
            .onClick(() => { this.deleteSelected() })
          }
          .width('100%')
          .height(56)
          .padding({ left: 16, right: 16 })
          .backgroundColor(Color.Transparent)
          .backgroundEffect({
            radius: 20,
            saturation: 1.0,
            brightness: 1.0
          })
          .border({
            width: { top: 1 },
            color: { top: $r('app.color.list_divider') }
          })
          .position({ bottom: this.bottomContentPadding })
          .zIndex(1)
        }
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
            Text(this.getFilterLabel())
              .fontSize(Math.round(14 * this.fontSizeScale))
              .fontColor($r('app.color.text_primary'))
              .fontWeight(FontWeight.Bold)
          }
          .padding({ left: 12, right: 12, top: 6, bottom: 6 })
          .backgroundColor(this.hasActiveFilter() ? ColorHelper.hexToRgba(this.primaryColor, 0.12) : 'rgba(0,0,0,0.05)')
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
          .backgroundColor('rgba(0,0,0,0.05)')
          .borderRadius(16)
          .onClick(() => { this.switchSortMode() })

          Row() {
            Text(this.viewMode === 'flat' ? '平铺' : '文件夹')
              .fontSize(Math.round(12 * this.fontSizeScale))
              .fontColor($r('app.color.text_primary'))
          }
          .padding({ left: 10, right: 10, top: 6, bottom: 6 })
          .backgroundColor('rgba(0,0,0,0.05)')
          .borderRadius(16)
          .onClick(() => { this.toggleViewMode() })
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 8, bottom: 8 })
        .position({ top: this.topContentPadding })
      }
      .width('100%')
      .height(this.listTopPadding())
      .position({ top: 0 })
      .clip(true)
      .hitTestBehavior(HitTestMode.Transparent)
      .zIndex(2)

      if (!this.isMultiSelectMode && (this.isPlusVisible || !this.settings.plusButtonScrollHide)) {
        Row() {
          Text('+')
            .fontSize(this.scaledSize(32))
            .fontColor('#FFFFFF')
            .fontWeight(FontWeight.Bold)
        }
        .width(this.scaledSize(40)).height(this.scaledSize(40))
        .borderRadius(this.scaledSize(20))
        .backgroundColor(this.primaryColor)
        .shadow({ radius: 10, color: ColorHelper.hexWithAlpha(this.primaryColor, '44'), offsetY: 4 })
        .position({ bottom: this.bottomContentPadding + this.scaledSize(12), right: this.scaledSize(20) })
        .justifyContent(FlexAlign.Center)
        .alignItems(VerticalAlign.Center)
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
          SymbolGlyph($r('sys.symbol.line_3_horizontal'))
            .fontSize(this.scaledSize(22))
            .fontColor(['#888888'])
            .renderingStrategy(SymbolRenderingStrategy.SINGLE)
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
        Row() {
          if (this.isSelected(item.id)) {
            Text('✓')
              .fontSize(Math.round(14 * this.fontSizeScale))
              .fontColor('#FFFFFF')
              .fontWeight(FontWeight.Bold)
          }
        }
        .width(this.scaledSize(22)).height(this.scaledSize(22))
        .borderRadius(this.scaledSize(11))
        .backgroundColor(this.isSelected(item.id) ? this.primaryColor : 'rgba(0,0,0,0.08)')
        .border({ width: 1, color: this.isSelected(item.id) ? this.primaryColor : $r('app.color.list_divider') })
        .justifyContent(FlexAlign.Center)
        .alignItems(VerticalAlign.Center)
        .margin({ right: this.scaledSize(16) })
      }

      AlbumCover({ song: item, coverWidth: this.scaledSize(36), coverHeight: this.scaledSize(36),
        coverRadius: this.scaledSize(6), decodeSize: AlbumCoverSize.SMALL })
        .margin({ right: this.scaledSize(10) })
        .opacity(item.isAvailable ? 1 : 0.35)

      Column() {
        Text(item.title.length > 0 ? item.title : item.name)
          .fontSize(Math.round(15 * this.fontSizeScale))
          .fontColor(item.isAvailable ? $r('app.color.text_primary') : $r('app.color.text_twenty_color'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        if (!item.isAvailable) {
          Text('文件不可访问，点击重新导入')
            .fontSize(Math.round(11 * this.fontSizeScale))
            .fontColor('#FF3B30')
            .width('100%')
        } else {
          Row() {
            Text(item.artist.length > 0 ? item.artist : '未知歌手')
              .fontSize(Math.round(12 * this.fontSizeScale))
              .fontColor($r('app.color.text_sixty_color'))
            if (item.folderName.length > 0) {
              Text(' · ' + item.folderName)
                .fontSize(Math.round(12 * this.fontSizeScale))
                .fontColor($r('app.color.text_twenty_color'))
            }
          }
          .width('100%')
        }
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
      LongPressGesture()
        .onAction(() => {
          this.onSongLongPress(item)
        })
    )
    .onClick(() => {
      if (!item.isAvailable) {
        this.onPlusClick()
        return
      }
      this.onSongTap(item)
    })
  }
}
