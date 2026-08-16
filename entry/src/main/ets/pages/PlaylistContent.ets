import { common } from '@kit.AbilityKit'
import { FolderInfo } from '../model/FolderInfo'
import { SongInfo } from '../model/SongInfo'
import { DataService, AppSettingsData } from '../service/DataService'
import { SongScanner } from '../service/SongScanner'
import { ColorHelper } from '../common/utils/ColorHelper'
import Logger from '../common/utils/Logger'
import { AppStorageKeyConstants } from '../common/constants/AppStorageKeyConstants'

const TAG = 'PlaylistContent'
const FAVORITES_FOLDER_ID: string = '__favorites__'

@Component
export struct PlaylistContent {
  onNavigateToHome: (folder: FolderInfo) => void = (folder: FolderInfo): void => {}
  private context: common.UIAbilityContext | undefined = AppStorage.get<common.UIAbilityContext>(AppStorageKeyConstants.KEY_UI_ABILITY_CONTEXT)
  @State folders: FolderInfo[] = []
  @State songs: SongInfo[] = []
  @State settings: AppSettingsData = new AppSettingsData()
  @State isPlusVisible: boolean = true
  @State lastScrollY: number = 0
  @State isMultiSelectMode: boolean = false
  @State selectedFolderIds: Set<string> = new Set()
  @StorageLink(AppStorageKeyConstants.KEY_TOP_HEIGHT) topSafeHeight: number = 0
  @StorageLink('uplayer_primary_color') primaryColor: string = '#007DFF'
  private dataService: DataService = DataService.getInstance()
  private songScanner: SongScanner = SongScanner.getInstance()
  private scroller: Scroller = new Scroller()

  aboutToAppear(): void {
    this.loadData()
  }

  loadData(): void {
    this.songs = this.dataService.getSongs()
    this.settings = this.dataService.getSettings()
    this.buildFoldersFromSongs()
  }

  buildFoldersFromSongs(): void {
    const seen: Record<string, boolean> = {}
    const result: FolderInfo[] = []
    for (let i = 0; i < this.songs.length; i++) {
      const song: SongInfo = this.songs[i]
      const key: string = song.folderPath
      if (key.length > 0 && seen[key] === undefined) {
        seen[key] = true
        const folder: FolderInfo = FolderInfo.fromPath(key)
        let count: number = 0
        for (let j = 0; j < this.songs.length; j++) {
          if (this.songs[j].folderPath === key) {
            count++
          }
        }
        folder.songCount = count
        folder.isAvailable = true
        result.push(folder)
      }
    }
    this.sortFolders(result)
    this.folders = result
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

  onFolderClick(folder: FolderInfo): void {
    if (this.isMultiSelectMode) {
      this.toggleFolderSelection(folder.id)
      return
    }
    if (folder.id === FAVORITES_FOLDER_ID) {
      this.dataService.setActiveFolderFilter('__favorites__')
      this.dataService.setListMode('favorites')
    } else {
      this.dataService.setActiveFolderFilter(folder.path)
      this.dataService.setListMode('all')
    }
    this.onNavigateToHome(folder)
  }

  toggleFolderSelection(folderId: string): void {
    if (this.selectedFolderIds.has(folderId)) {
      this.selectedFolderIds.delete(folderId)
    } else {
      this.selectedFolderIds.add(folderId)
    }
    if (this.selectedFolderIds.size === 0) {
      this.isMultiSelectMode = false
    }
  }

  onFolderLongPress(folder: FolderInfo): void {
    if (folder.id === FAVORITES_FOLDER_ID) {
      return
    }
    this.isMultiSelectMode = true
    this.selectedFolderIds = new Set()
    this.selectedFolderIds.add(folder.id)
  }

  deleteSelectedFolders(): void {
    this.selectedFolderIds.forEach((folderId: string) => {
      for (let i = 0; i < this.folders.length; i++) {
        if (this.folders[i].id === folderId) {
          this.dataService.removeSongsByFolder(this.folders[i].path)
          break
        }
      }
    })
    this.selectedFolderIds = new Set()
    this.isMultiSelectMode = false
    this.loadData()
  }

  moveFolderUp(folderId: string): void {
    const idx: number = this.folders.findIndex((f: FolderInfo): boolean => f.id === folderId)
    if (idx > 0) {
      const temp: FolderInfo = this.folders[idx]
      this.folders[idx] = this.folders[idx - 1]
      this.folders[idx - 1] = temp
      this.folders = [...this.folders]
      this.saveFolderOrder()
    }
  }

  moveFolderDown(folderId: string): void {
    const idx: number = this.folders.findIndex((f: FolderInfo): boolean => f.id === folderId)
    if (idx >= 0 && idx < this.folders.length - 1) {
      const temp: FolderInfo = this.folders[idx]
      this.folders[idx] = this.folders[idx + 1]
      this.folders[idx + 1] = temp
      this.folders = [...this.folders]
      this.saveFolderOrder()
    }
  }

  saveFolderOrder(): void {
    for (let i = 0; i < this.folders.length; i++) {
      this.dataService.updateFolderSortOrder(this.folders[i].id, i)
    }
  }

  async onPlusClick(): Promise<void> {
    if (this.context === undefined) {
      return
    }
    const newSongs: SongInfo[] = await this.songScanner.pickAudioFiles(this.context)
    if (newSongs.length > 0) {
      this.dataService.addSongs(newSongs)
      this.loadData()
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
            .fontSize(18)
            .fontColor($r('app.color.text_primary'))
            .fontWeight(FontWeight.Bold)
          Blank()
          if (this.isMultiSelectMode) {
            Text('删除 (' + this.selectedFolderIds.size + ')')
              .fontSize(14)
              .fontColor(Color.Red)
              .onClick(() => { this.deleteSelectedFolders() })
            Text('取消')
              .fontSize(14)
              .fontColor($r('app.color.text_sixty_color'))
              .margin({ left: 12 })
              .onClick(() => {
                this.isMultiSelectMode = false
                this.selectedFolderIds = new Set()
              })
          } else {
            Text(this.sortModeLabel())
              .fontSize(12)
              .fontColor($r('app.color.text_sixty_color'))
              .onClick(() => { this.cycleSortMode() })
          }
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: this.topSafeHeight + 8, bottom: 12 })

        Scroll(this.scroller) {
          Column() {
            if (this.getFavoriteCount() > 0) {
              Row() {
                Image($r('app.media.heart_fill'))
                  .width(20).height(20)
                  .fillColor(this.primaryColor)
                  .margin({ right: 8 })
                Text('我喜欢的')
                  .fontSize(14)
                  .fontColor($r('app.color.text_primary'))
                  .fontWeight(FontWeight.Medium)
                Blank()
                Text(this.getFavoriteCount() + ' 首')
                  .fontSize(11)
                  .fontColor($r('app.color.text_sixty_color'))
              }
              .width('100%')
              .height(52)
              .padding({ left: 16, right: 16 })
              .backgroundColor('rgba(0,0,0,0.03)')
              .borderRadius(12)
              .margin({ left: 16, right: 16, bottom: 12 })
              .onClick(() => {
                const favFolder: FolderInfo = new FolderInfo()
                favFolder.id = FAVORITES_FOLDER_ID
                favFolder.name = '我喜欢的'
                favFolder.path = '__favorites__'
                favFolder.songCount = this.getFavoriteCount()
                this.onFolderClick(favFolder)
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
              .columnsTemplate('1fr 1fr')
              .columnsGap(12)
              .rowsGap(12)
              .padding({ left: 16, right: 16 })
              .width('100%')
            } else {
              Text('暂无歌单，点击添加歌曲')
                .fontSize(14)
                .fontColor($r('app.color.text_twenty_color'))
                .width('100%')
                .height(200)
                .textAlign(TextAlign.Center)
                .onClick(() => { this.onPlusClick() })
            }
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
      }
      .width('100%')
      .height('100%')

      if (this.isPlusVisible || !this.settings.plusButtonScrollHide) {
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
        .onClick(() => { this.onPlusClick() })
      }
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  folderCard(item: FolderInfo): void {
    Stack() {
      Column() {
        Image($r('app.media.ic_public_music'))
          .width(36).height(36)
          .fillColor($r('app.color.text_sixty_color'))
          .margin({ bottom: 8 })
        Text(item.name)
          .fontSize(14)
          .fontColor($r('app.color.text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(item.songCount + ' 首歌曲')
          .fontSize(11)
          .fontColor($r('app.color.text_sixty_color'))
          .margin({ top: 4 })
      }
      .width('100%')
      .height('100%')
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)

      if (this.isMultiSelectMode) {
        Checkbox()
          .select(this.selectedFolderIds.has(item.id))
          .position({ x: 4, y: 4 })
          .width(20).height(20)
          .onChange((checked: boolean) => {
            this.toggleFolderSelection(item.id)
          })
      }

      if (this.settings.folderSortMode === 'custom' && !this.isMultiSelectMode) {
        Column() {
          Text('▲')
            .fontSize(12)
            .fontColor($r('app.color.text_sixty_color'))
            .onClick(() => { this.moveFolderUp(item.id) })
          Text('▼')
            .fontSize(12)
            .fontColor($r('app.color.text_sixty_color'))
            .margin({ top: 2 })
            .onClick(() => { this.moveFolderDown(item.id) })
        }
        .position({ x: 4, y: 4 })
      }
    }
    .width('100%')
    .aspectRatio(1.2)
    .backgroundColor(this.isMultiSelectMode && this.selectedFolderIds.has(item.id) ?
      ColorHelper.hexWithAlpha(this.primaryColor, '22') : 'rgba(0,0,0,0.03)')
    .borderRadius(16)
    .border({ width: 1, color: $r('app.color.list_divider') })
    .onClick(() => { this.onFolderClick(item) })
    .gesture(LongPressGesture().onAction(() => { this.onFolderLongPress(item) }))
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
