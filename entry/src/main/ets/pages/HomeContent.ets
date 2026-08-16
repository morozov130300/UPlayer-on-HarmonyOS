import { common } from '@kit.AbilityKit'
import { SongInfo } from '../model/SongInfo'
import { DataService, AppSettingsData, ImportResult } from '../service/DataService'
import { SongScanner } from '../service/SongScanner'
import { AVPlayerService } from '../service/AVPlayerService'
import { ColorHelper } from '../common/utils/ColorHelper'
import { DisplayItemDataSource } from '../viewmodel/DisplayItemDataSource'
import Logger from '../common/utils/Logger'
import { AppStorageKeyConstants } from '../common/constants/AppStorageKeyConstants'

const TAG = 'HomeContent'

class DisplayItem {
  isHeader: boolean = false
  headerText: string = ''
  song: SongInfo = new SongInfo()
  key: string = ''
}

@Component
export struct HomeContent {
  private context: common.UIAbilityContext | undefined = AppStorage.get<common.UIAbilityContext>(AppStorageKeyConstants.KEY_UI_ABILITY_CONTEXT)
  @State songs: SongInfo[] = []
  @State displayItems: DisplayItem[] = []
  private displayDataSource: DisplayItemDataSource = new DisplayItemDataSource([])
  @State viewMode: string = 'flat'
  @State sortMode: string = 'name'
  @State isPlusVisible: boolean = true
  @State settings: AppSettingsData = new AppSettingsData()
  @State isMultiSelectMode: boolean = false
  @State selectedIds: string[] = []
  @State failedArtIds: Set<string> = new Set<string>()
  @StorageLink('uplayer_primary_color') primaryColor: string = '#007DFF'
  private dataService: DataService = DataService.getInstance()
  private songScanner: SongScanner = SongScanner.getInstance()
  private avPlayerService: AVPlayerService = AVPlayerService.getInstance()
  private scroller: Scroller = new Scroller()

  aboutToAppear(): void {
    this.loadData()
  }

  loadData(): void {
    this.songs = this.dataService.getSongs()
    this.settings = this.dataService.getSettings()
    this.viewMode = this.dataService.getViewMode()
    this.sortMode = this.dataService.getSortMode()
    this.applyFilters()
  }

  applyFilters(): void {
    let result: SongInfo[] = []
    for (let i = 0; i < this.songs.length; i++) {
      result.push(this.songs[i])
    }
    if (this.dataService.isFavoritesSelected()) {
      const filtered: SongInfo[] = []
      for (let i = 0; i < result.length; i++) {
        if (result[i].isFavorite) {
          filtered.push(result[i])
        }
      }
      result = filtered
    } else {
      const selectedPaths: string[] = this.dataService.getSelectedFolderPaths()
      if (selectedPaths.length > 0) {
        const filtered: SongInfo[] = []
        for (let i = 0; i < result.length; i++) {
          if (selectedPaths.indexOf(result[i].folderPath) >= 0) {
            filtered.push(result[i])
          }
        }
        result = filtered
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
        return a.addedTime - b.addedTime
      })
    }
    return sorted
  }

  clearFilters(): void {
    this.dataService.setSelectedFolderPaths([])
    this.dataService.setFavoritesSelected(false)
    this.applyFilters()
  }

  hasActiveFilter(): boolean {
    return this.dataService.isFavoritesSelected() || this.dataService.getSelectedFolderPaths().length > 0
  }

  getFilterLabel(): string {
    if (this.dataService.isFavoritesSelected()) {
      return '我喜欢的'
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

  toggleFavorite(songId: string): void {
    const newFav: boolean = this.dataService.toggleFavorite(songId)
    AppStorage.setOrCreate(AppStorageKeyConstants.KEY_IS_FAVORITE, newFav)
    // Update the display item directly without reloading all data
    for (let i = 0; i < this.displayItems.length; i++) {
      const item: DisplayItem = this.displayItems[i]
      if (!item.isHeader && item.song && item.song.id === songId) {
        item.song.isFavorite = newFav
        break
      }
    }
    // Notify data source of change
    this.displayDataSource.notifyDataReload()
  }

  onSongTap(item: SongInfo): void {
    if (this.isMultiSelectMode) {
      this.toggleSelectItem(item.id)
      return
    }
    AppStorage.setOrCreate('uplayer_current_title', item.title.length > 0 ? item.title : item.name)
    AppStorage.setOrCreate('uplayer_current_artist', item.artist)
    AppStorage.setOrCreate('uplayer_current_album_art', item.albumArtPath)
    AppStorage.setOrCreate('uplayer_current_song_path', item.filePath)
    const allSongs: SongInfo[] = this.dataService.getSongs()
    for (let i = 0; i < allSongs.length; i++) {
      if (allSongs[i].id === item.id) {
        AppStorage.setOrCreate(AppStorageKeyConstants.KEY_SELECT_INDEX, i)
        break
      }
    }
    this.avPlayerService.play(item.uri.length > 0 ? item.uri : item.filePath)
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
    if (this.selectedIds.length === 0) {
      this.isMultiSelectMode = false
    }
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

  @State lastScrollY: number = 0

  build() {
    Stack() {
      Column() {
        Row() {
          Row() {
             Text(this.getFilterLabel())
               .fontSize(14)
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
              .fontSize(12)
              .fontColor($r('app.color.text_primary'))
              .margin({ left: 4 })
          }
          .padding({ left: 10, right: 10, top: 6, bottom: 6 })
          .backgroundColor('rgba(0,0,0,0.05)')
          .borderRadius(16)
          .onClick(() => { this.switchSortMode() })

          Row() {
            Text(this.viewMode === 'flat' ? '平铺' : '文件夹')
              .fontSize(12)
              .fontColor($r('app.color.text_primary'))
          }
          .padding({ left: 10, right: 10, top: 6, bottom: 6 })
          .backgroundColor('rgba(0,0,0,0.05)')
          .borderRadius(16)
          .onClick(() => { this.toggleViewMode() })
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 8, bottom: 8 })

        List({ space: 0, scroller: this.scroller }) {
          LazyForEach(this.displayDataSource, (item: DisplayItem, index: number) => {
            ListItem() {
              if (item.isHeader) {
                this.folderHeaderRow(item.headerText)
              } else if (!item.isHeader) {
                this.songItemRow(item.song)
              }
            }
            .reuseId(item.isHeader ? 'header' : 'song')
          }, (item: DisplayItem, index: number) => {
            if (item.isHeader) {
              return 'h_' + item.headerText
            }
            if (!item.isHeader) {
              return item.song.id
            }
            return 'empty_' + index
          })
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

        if (this.displayItems.length === 0) {
          Text('暂无歌曲，点击添加')
            .fontSize(14)
            .fontColor($r('app.color.text_twenty_color'))
            .width('100%')
            .height(200)
            .textAlign(TextAlign.Center)
            .onClick(() => { this.onPlusClick() })
        }

        if (this.isMultiSelectMode) {
          Row() {
            Text('已选 ' + this.selectedIds.length + ' 首')
              .fontSize(14)
              .fontColor($r('app.color.text_primary'))
            Blank()
            Text('取消')
              .fontSize(14)
              .fontColor(this.primaryColor)
              .margin({ right: 16 })
              .onClick(() => { this.exitMultiSelect() })
            Text('删除')
              .fontSize(14)
              .fontColor('#FF3B30')
              .onClick(() => { this.deleteSelected() })
          }
          .width('100%')
          .height(48)
          .padding({ left: 16, right: 16 })
          .backgroundColor($r('app.color.page_background_sm'))
          .border({ width: 1, color: $r('app.color.list_divider') })
        }
      }
      .width('100%')
      .height('100%')

      if (!this.isMultiSelectMode && (this.isPlusVisible || !this.settings.plusButtonScrollHide)) {
        Row() {
          Text('+')
            .fontSize(32)
            .fontColor('#FFFFFF')
            .fontWeight(FontWeight.Bold)
        }
        .width(40).height(40)
        .borderRadius(20)
        .backgroundColor(this.primaryColor)
        .shadow({ radius: 10, color: ColorHelper.hexWithAlpha(this.primaryColor, '44'), offsetY: 4 })
        .position({ bottom: 12, right: 20 })
        .justifyContent(FlexAlign.Center)
        .alignItems(VerticalAlign.Center)
        .transition({ type: TransitionType.Insert, opacity: 0, scale: { x: 0.5, y: 0.5 } })
        .transition({ type: TransitionType.Delete, opacity: 0, scale: { x: 0.5, y: 0.5 } })
        .onClick(() => { this.onPlusClick() })
      }
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  folderHeaderRow(title: string): void {
    Row() {
      Text(title)
        .fontSize(13)
        .fontColor($r('app.color.text_sixty_color'))
        .fontWeight(FontWeight.Medium)
        .padding({ left: 16, top: 12, bottom: 4 })
    }
    .width('100%')
    .backgroundColor('rgba(0,0,0,0.02)')
  }

  @Builder
  songItemRow(item: SongInfo): void {
    Row() {
      if (this.isMultiSelectMode) {
        Row() {
          if (this.isSelected(item.id)) {
            Text('✓')
              .fontSize(14)
              .fontColor('#FFFFFF')
              .fontWeight(FontWeight.Bold)
          }
        }
        .width(22).height(22)
        .borderRadius(11)
        .backgroundColor(this.isSelected(item.id) ? this.primaryColor : 'rgba(0,0,0,0.08)')
        .border({ width: 1, color: this.isSelected(item.id) ? this.primaryColor : $r('app.color.list_divider') })
        .justifyContent(FlexAlign.Center)
        .alignItems(VerticalAlign.Center)
        .margin({ right: 10 })
      }

      if (item.albumArtPath.length > 0 && !this.failedArtIds.has(item.id)) {
        Image('file://' + item.albumArtPath)
          .width(36).height(36)
          .borderRadius(6)
          .objectFit(ImageFit.Cover)
          .margin({ right: 10 })
          .opacity(item.isAvailable ? 1 : 0.35)
          .onError(() => { this.failedArtIds.add(item.id) })
      } else {
        Image($r('app.media.ic_public_music'))
          .width(36).height(36)
          .fillColor($r('app.color.text_sixty_color'))
          .margin({ right: 10 })
          .opacity(item.isAvailable ? 1 : 0.35)
      }

      Column() {
        Text(item.title.length > 0 ? item.title : item.name)
          .fontSize(15)
          .fontColor(item.isAvailable ? $r('app.color.text_primary') : $r('app.color.text_twenty_color'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        if (!item.isAvailable) {
          Text('文件不可访问，点击重新导入')
            .fontSize(11)
            .fontColor('#FF3B30')
            .width('100%')
        } else {
          Row() {
            Text(item.artist.length > 0 ? item.artist : '未知歌手')
              .fontSize(12)
              .fontColor($r('app.color.text_sixty_color'))
            if (item.folderName.length > 0) {
              Text(' · ' + item.folderName)
                .fontSize(12)
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
            .fontSize(18)
            .renderingStrategy(SymbolRenderingStrategy.SINGLE)
            .fontColor([$r('app.color.text_sixty_color')])
            .margin({ right: 12 })
            .hitTestBehavior(HitTestMode.Block)
            .onClick(() => {
              this.dataService.addToPlayNext(item.id)
              try {
                this.getUIContext()?.getPromptAction().showToast({ message: '已添加到下一首播放' })
              } catch (e) {
                Logger.error(TAG, 'toast failed')
              }
            })
        }
      }

      Image(item.isFavorite ? $r('app.media.heart_fill') : $r('app.media.heart_gap'))
        .width(22).height(22)
        .fillColor(item.isFavorite ? '#FF3B30' : $r('app.color.text_sixty_color'))
        .margin({ right: 12 })
        .hitTestBehavior(HitTestMode.Block)
        .onClick(() => {
          this.toggleFavorite(item.id)
        })
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 10, bottom: 10 })
    .alignItems(VerticalAlign.Center)
    .gesture(
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
