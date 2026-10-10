// ArkUI 26 Beta1: 接口定义变更（误报，本项目已是Stage模型）+ UX视觉布局变更（Text默认开启沉浸式材质，系统行为）
import { common } from '@kit.AbilityKit'
import { FolderInfo } from '../model/FolderInfo'
import { SongInfo } from '../model/SongInfo'
import { DataService, AppSettingsData, ImportResult, LibraryDeleteResult } from '../service/DataService'
import { SongScanner } from '../service/SongScanner'
import { AVPlayerService } from '../service/AVPlayerService'
import { AVSessionController } from '../common/utils/mediautils/AVSessionController'
import { LiveViewService } from '../service/LiveViewService'
import { ColorHelper } from '../common/utils/ColorHelper'
import { showToastGlassMaterial } from '../common/utils/GlassUtil'
import Logger from '../common/utils/Logger'
import { AppStorageKeyConstants } from '../common/constants/AppStorageKeyConstants'
import { display } from '@kit.ArkUI'
import { deviceInfo } from '@kit.BasicServicesKit'

const TAG = 'PlaylistContent'
const FAVORITES_FOLDER_ID: string = '__favorites__'

@Component
export struct PlaylistContent {
  topContentPadding: number = 0
  // 顶部标题带高度（Index 传入，与主页问候语带同源）：标题在带内垂直居中，几何与主页一致
  topBandHeight: number = 72
  bottomContentPadding: number = 0
  onNavigateToHome: () => void = (): void => {}
  private context: common.UIAbilityContext | undefined = AppStorage.get<common.UIAbilityContext>(AppStorageKeyConstants.KEY_UI_ABILITY_CONTEXT)
  @State folders: FolderInfo[] = []
  @State songs: SongInfo[] = []
  @State settings: AppSettingsData = new AppSettingsData()
  @State isPlusVisible: boolean = true
  @State selectedFolderPaths: string[] = []
  @State favoritesSelected: boolean = false
  @StorageLink(AppStorageKeyConstants.KEY_TITLE_BUTTON_WIDTH) titleButtonWidth: number = 140
  @StorageLink('uplayer_primary_color') primaryColor: string = '#007DFF'
  @StorageLink('uplayer_font_size_scale') fontSizeScale: number = 1.0
  @StorageLink('uplayer_display_size_scale') displaySizeScale: number = 1.0
  @StorageLink(AppStorageKeyConstants.KEY_LIBRARY_REVISION) @Watch('onLibraryChange') libraryRevision: number = 0
  @StorageLink(AppStorageKeyConstants.KEY_FILTER_REVISION) @Watch('onFilterChange') filterRevision: number = 0
  // Delete 键删除请求（Index 页面级键盘事件 +1）：编辑态下与删除按钮功能一致
  @StorageLink(AppStorageKeyConstants.KEY_PLAYLIST_DELETE_REQUEST) @Watch('onDeleteRequest')
  deleteRequest: number = 0
  private dataService: DataService = DataService.getInstance()
  private songScanner: SongScanner = SongScanner.getInstance()
  private scroller: Scroller = new Scroller()
  private previousFolderPaths: string[] = []
  private isPC: boolean = deviceInfo.deviceType === '2in1'
  @State isEditMode: boolean = false
  @State editSelectedFolderIds: string[] = []
  @State gridColumns: number = 2

  aboutToAppear(): void {
    this.loadData()
    this.updateGridColumns()
    this.publishPlusVisible()
  }

  private scaledSize(size: number): number {
    return Math.round(size * this.displaySizeScale)
  }

  onLibraryChange(): void {
    this.loadData()
  }

  onFilterChange(): void {
    this.selectedFolderPaths = this.dataService.getSelectedFolderPaths()
    this.favoritesSelected = this.dataService.isFavoritesSelected()
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
    this.dataService.setFilterState(this.selectedFolderPaths, this.favoritesSelected)
  }

  isFolderSelected(folder: FolderInfo): boolean {
    if (folder.id === FAVORITES_FOLDER_ID) {
      return this.favoritesSelected
    }
    return this.selectedFolderPaths.indexOf(folder.path) >= 0
  }

  enterEditMode(folderId: string): void {
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

  // Delete 键：编辑态且有选中时执行与删除按钮相同的逻辑；空选/非编辑态忽略
  onDeleteRequest(): void {
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
      !this.isEditMode && (this.isPlusVisible || !this.settings.plusButtonScrollHide))
  }

  async onPlusClick(): Promise<void> {
    if (this.context === undefined) {
      return
    }
    // 增量流式导入：每提取完一批即入库，本页列表经 KEY_LIBRARY_REVISION 的 @Watch 自动逐批刷新
    const result: ImportResult = await this.songScanner.importSongs(this.context, this.dataService)
    if (result.newCount + result.dupCount > 0) {
      try {
        showToastGlassMaterial(this.getUIContext()?.getPromptAction(),
          `新增 ${result.newCount} 首` + (result.dupCount > 0 ? `，${result.dupCount} 首已存在` : ''))
      } catch (e) {
        Logger.error(TAG, 'toast failed')
      }
    }
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

  build() {
    Stack() {
      Column() {
        Row() {
          Text('歌单')
            .fontSize(Math.round(18 * this.fontSizeScale))
            .fontColor($r('app.color.text_primary'))
            .fontWeight(FontWeight.Bold)
          Text(this.sortModeLabel())
            .fontSize(Math.round(12 * this.fontSizeScale))
            .fontColor($r('app.color.text_sixty_color'))
            .margin({ left: 10 })
            .onClick(() => { this.cycleSortMode() })
        }
        .width('100%')
        .height(this.topContentPadding + this.topBandHeight)
        .padding({
          left: 20,
          right: this.isPC ? Math.max(this.titleButtonWidth, 140) + 12 : 8,
          top: this.topContentPadding
        })
        .alignItems(VerticalAlign.Center)

        Scroll(this.scroller) {
          Column() {
            if (this.folders.length > 0) {
              Grid() {
                ForEach(this.folders, (item: FolderInfo) => {
                  GridItem() {
                    this.folderCard(item)
                  }
                }, (item: FolderInfo) => item.id)
              }
              .columnsTemplate('1fr '.repeat(this.gridColumns).trim())
              .columnsGap(10)
              .rowsGap(10)
              .padding({ left: 16, right: 16, top: 12 })
              .width('100%')
            } else {
              Text('暂无歌单，点击添加歌曲')
                .fontSize(Math.round(14 * this.fontSizeScale))
                .fontColor($r('app.color.text_twenty_color'))
                .width('100%')
                .height(200)
                .textAlign(TextAlign.Center)
                .onClick(() => { this.onPlusClick() })
            }
            Blank()
              .width('100%')
              .height(this.bottomContentPadding)
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
            this.isPlusVisible = false
            this.publishPlusVisible()
          } else if (scrollOffset < 0) {
            this.isPlusVisible = true
            this.publishPlusVisible()
          }
        })

        if (this.isEditMode) {
          Row() {
            Text('已选 ' + this.editSelectedFolderIds.length + ' 个')
              .fontSize(Math.round(14 * this.fontSizeScale))
              .fontColor($r('app.color.text_primary'))
            Blank()
            Text('取消')
              .fontSize(Math.round(14 * this.fontSizeScale))
              .fontColor(this.primaryColor)
              .margin({ right: 16 })
              .onClick(() => { this.exitEditMode() })
            Text('删除')
              .fontSize(Math.round(14 * this.fontSizeScale))
              .fontColor('#FF3B30')
              .onClick(() => {
                this.deleteEditSelected().catch((err: Error) => {
                  Logger.error(TAG, `delete selected failed: ${JSON.stringify(err)}`)
                })
              })
          }
          .width('100%')
          .height(48)
          .padding({ left: 16, right: 16 })
          .backgroundColor($r('app.color.page_background_sm'))
          .border({ width: 1, color: $r('app.color.list_divider') })
          .margin({ bottom: this.bottomContentPadding })
        }
      }
      .width('100%')
      .height('100%')

      // 全局悬浮加号由 Index 统一渲染（首页/歌单共用，切页不位移，设置页隐藏），
      // 可见性由 publishPlusVisible 上报，本页不再挂按钮
    }
    .width('100%')
    .height('100%')
    // 背景使用预设纯色（明暗自适应），不应用任何玻璃/模糊/透明度效果
    .backgroundColor($r('app.color.page_background_sm'))
  }

  @Builder
  folderCard(item: FolderInfo): void {
    Column() {
      if (this.isEditMode) {
        Image(this.isEditSelected(item.id) ? $r('app.media.ic_public_todo_filled') : $r('app.media.ic_public_todo'))
          .width(20).height(20)
          .fillColor(this.isEditSelected(item.id) ? this.primaryColor : $r('app.color.text_sixty_color'))
          .position({ x: 6, y: 6 })
      }
      if (item.id === FAVORITES_FOLDER_ID) {
        Image($r('app.media.ic_public_favor_filled'))
          .width(28).height(28)
          .fillColor(this.favoritesSelected ? Color.Red : this.primaryColor)
          .margin({ bottom: 6 })
      } else {
        Image($r('app.media.ic_public_folder'))
          .width(28)
          .height(28)
          .fillColor($r('app.color.text_sixty_color'))
          .margin({ bottom: 6 })
      }
      Text(item.name)
        .fontSize(Math.round(12 * this.fontSizeScale))
        .fontColor($r('app.color.text_primary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      Text(item.songCount + ' 首歌曲')
        .fontSize(10)
        .fontColor($r('app.color.text_sixty_color'))
        .margin({ top: 2 })
    }
    .width('100%')
    .height(80)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
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
