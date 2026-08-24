import { common } from '@kit.AbilityKit'
import { FolderInfo } from '../model/FolderInfo'
import { SongInfo } from '../model/SongInfo'
import { DataService, AppSettingsData, ImportResult, LibraryDeleteResult } from '../service/DataService'
import { SongScanner } from '../service/SongScanner'
import { AVPlayerService } from '../service/AVPlayerService'
import { AVSessionController } from '../common/utils/mediautils/AVSessionController'
import { LiveViewService } from '../service/LiveViewService'
import { ColorHelper } from '../common/utils/ColorHelper'
import Logger from '../common/utils/Logger'
import { AppStorageKeyConstants } from '../common/constants/AppStorageKeyConstants'
import { display } from '@kit.ArkUI'
import { deviceInfo } from '@kit.BasicServicesKit'
import { curves, uiMaterial } from '@kit.ArkUI'
import { createPageGlassMaterial, DEFAULT_GLASS_STYLE, glassBlurStyleFromStrength, isLiquidGlassAvailable } from '../common/utils/GlassUtil'

const TAG = 'PlaylistContent'
const FAVORITES_FOLDER_ID: string = '__favorites__'

@Component
export struct PlaylistContent {
  topContentPadding: number = 0
  bottomContentPadding: number = 0
  onNavigateToHome: () => void = (): void => {}
  private context: common.UIAbilityContext | undefined = AppStorage.get<common.UIAbilityContext>(AppStorageKeyConstants.KEY_UI_ABILITY_CONTEXT)
  @State folders: FolderInfo[] = []
  @State songs: SongInfo[] = []
  @State settings: AppSettingsData = new AppSettingsData()
  @State isPlusVisible: boolean = true
  @State lastScrollY: number = 0
  @State selectedFolderPaths: string[] = []
  @State favoritesSelected: boolean = false
  @StorageLink(AppStorageKeyConstants.KEY_TITLE_BUTTON_WIDTH) titleButtonWidth: number = 140
  @StorageLink('uplayer_primary_color') primaryColor: string = '#007DFF'
  @StorageLink('uplayer_font_size_scale') fontSizeScale: number = 1.0
  @StorageLink('uplayer_display_size_scale') displaySizeScale: number = 1.0
  @StorageLink(AppStorageKeyConstants.KEY_LIBRARY_REVISION) @Watch('onLibraryChange') libraryRevision: number = 0
  @StorageLink(AppStorageKeyConstants.KEY_FILTER_REVISION) @Watch('onFilterChange') filterRevision: number = 0
  @StorageLink('uplayer_tab_style') tabStyle: string = 'classic'
  @StorageLink('uplayer_glass_style') glassStyle: number = DEFAULT_GLASS_STYLE
  private dataService: DataService = DataService.getInstance()
  private songScanner: SongScanner = SongScanner.getInstance()
  private scroller: Scroller = new Scroller()
  private previousFolderPaths: string[] = []
  @State isEditMode: boolean = false
  @State editSelectedFolderIds: string[] = []
  @State gridColumns: number = 2

  aboutToAppear(): void {
    this.loadData()
    this.updateGridColumns()
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
      const vpWidth = displayInfo.width / 160
      if (vpWidth >= 600) {
        this.gridColumns = 3
      } else {
        this.gridColumns = 2
      }
    } catch (e) {
      this.gridColumns = 2
    }
  }

  // 玻璃风格是否在本页启用（玻璃样式 + API 26）
  isGlassEnabled(): boolean {
    return this.tabStyle === 'immersive' && isLiquidGlassAvailable()
  }

  pageGlassMaterial(): uiMaterial.Material | undefined {
    if (!this.isGlassEnabled()) {
      return undefined
    }
    return createPageGlassMaterial(this.glassStyle)
  }

  pageBlurStyle(): BlurStyle | undefined {
    return this.isGlassEnabled() ? glassBlurStyleFromStrength(this.glassStyle) : undefined
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
    this.folders = result
    // 同步持久化，保证新增文件夹的自定义序号被保存
    this.dataService.saveFolders(result)
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
    if (this.editSelectedFolderIds.length === 0) {
      this.isEditMode = false
    }
  }

  exitEditMode(): void {
    this.isEditMode = false
    this.editSelectedFolderIds = []
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

  async onPlusClick(): Promise<void> {
    if (this.context === undefined) {
      return
    }
    const newSongs: SongInfo[] = await this.songScanner.pickAudioFiles(this.context)
    if (newSongs.length > 0) {
      const result: ImportResult = this.dataService.addSongs(newSongs)
      this.loadData()
      try {
        this.getUIContext()?.getPromptAction().showToast({
          message: `新增 ${result.newCount} 首` + (result.dupCount > 0 ? `，${result.dupCount} 首已存在` : '')
        })
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
          Text('我的歌单')
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
        .padding({
          left: 16,
          right: Math.max(this.titleButtonWidth, 140) + 12,
          top: this.topContentPadding + this.scaledSize(20),
          bottom: 12
        })

        Scroll(this.scroller) {
          Column() {
            if (this.getFavoriteCount() > 0) {
              Row() {
                if (this.isEditMode) {
                  Row() {
                    if (this.isEditSelected(FAVORITES_FOLDER_ID)) {
                      Text('✓')
                        .fontSize(Math.round(12 * this.fontSizeScale))
                        .fontColor('#FFFFFF')
                        .fontWeight(FontWeight.Bold)
                    }
                  }
                  .width(20).height(20)
                  .borderRadius(10)
                  .backgroundColor(this.isEditSelected(FAVORITES_FOLDER_ID) ? this.primaryColor : 'rgba(0,0,0,0.08)')
                  .border({ width: 1, color: this.isEditSelected(FAVORITES_FOLDER_ID) ? this.primaryColor : $r('app.color.list_divider') })
                  .justifyContent(FlexAlign.Center)
                  .alignItems(VerticalAlign.Center)
                  .margin({ right: 8 })
                }
                Image($r('app.media.heart_fill'))
                  .width(20).height(20)
                  .fillColor(this.favoritesSelected ? Color.Red : this.primaryColor)
                  .margin({ right: 8 })
                Text('我喜欢的')
                  .fontSize(Math.round(14 * this.fontSizeScale))
                  .fontColor($r('app.color.text_primary'))
                  .fontWeight(FontWeight.Medium)
                Blank()
                Text(this.getFavoriteCount() + ' 首')
                  .fontSize(Math.round(11 * this.fontSizeScale))
                  .fontColor($r('app.color.text_sixty_color'))
              }
              .width('100%')
              .height(52)
              .padding({ left: 16, right: 16 })
              .backgroundColor(this.favoritesSelected ?
                ColorHelper.hexWithAlpha(this.primaryColor, '22') : 'rgba(0,0,0,0.03)')
              .borderRadius(12)
              .margin({ left: 16, right: 16, bottom: 12 })
              .gesture(
                LongPressGesture()
                  .onAction(() => {
                    if (!this.isEditMode) {
                      this.enterEditMode(FAVORITES_FOLDER_ID)
                    }
                  })
              )
              .onClick(() => {
                if (this.isEditMode) {
                  this.toggleEditSelect(FAVORITES_FOLDER_ID)
                } else {
                  const favFolder: FolderInfo = new FolderInfo()
                  favFolder.id = FAVORITES_FOLDER_ID
                  favFolder.name = '我喜欢的'
                  favFolder.path = '__favorites__'
                  favFolder.songCount = this.getFavoriteCount()
                  this.onFolderToggle(favFolder)
                }
              })
            }

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
              .padding({ left: 16, right: 16 })
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
        .edgeEffect(EdgeEffect.Spring)
        .onDidScroll(() => {
          const offset = this.scroller.currentOffset()
          const yOffset: number = offset.yOffset
          if (yOffset > this.lastScrollY && (yOffset - this.lastScrollY) > 10) {
            this.isPlusVisible = false
          } else if (yOffset < this.lastScrollY) {
            this.isPlusVisible = true
          }
          this.lastScrollY = yOffset
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

      if (!this.isEditMode && (this.isPlusVisible || !this.settings.plusButtonScrollHide)) {
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
    .backgroundColor(Color.Transparent)
    .backgroundBlurStyle(this.pageBlurStyle())
    .systemMaterial(this.pageGlassMaterial())
  }

  @Builder
  folderCard(item: FolderInfo): void {
    Column() {
      if (this.isEditMode) {
        Row() {
          if (this.isEditSelected(item.id)) {
            Text('✓')
              .fontSize(Math.round(12 * this.fontSizeScale))
              .fontColor('#FFFFFF')
              .fontWeight(FontWeight.Bold)
          }
        }
        .width(20).height(20)
        .borderRadius(10)
        .backgroundColor(this.isEditSelected(item.id) ? this.primaryColor : 'rgba(0,0,0,0.08)')
        .border({ width: 1, color: this.isEditSelected(item.id) ? this.primaryColor : $r('app.color.list_divider') })
        .justifyContent(FlexAlign.Center)
        .alignItems(VerticalAlign.Center)
        .position({ x: 6, y: 6 })
      }
      Image($r('app.media.ic_public_music'))
        .width(28).height(28)
        .fillColor($r('app.color.text_sixty_color'))
        .margin({ bottom: 6 })
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
