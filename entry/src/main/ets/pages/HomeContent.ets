import { common } from '@kit.AbilityKit'
import { SongInfo } from '../model/SongInfo'
import { DataService, AppSettingsData } from '../service/DataService'
import { SongScanner } from '../service/SongScanner'
import Logger from '../common/utils/Logger'
import { AppStorageKeyConstants } from '../common/constants/AppStorageKeyConstants'

const TAG = 'HomeContent'

class DisplayItem {
  isHeader: boolean = false
  headerText: string = ''
  song: SongInfo | null = null
}

@Component
export struct HomeContent {
  private context: common.UIAbilityContext | undefined = AppStorage.get<common.UIAbilityContext>(AppStorageKeyConstants.KEY_UI_ABILITY_CONTEXT)
  @State songs: SongInfo[] = []
  @State displayItems: DisplayItem[] = []
  @State listMode: string = 'all'
  @State viewMode: string = 'flat'
  @State sortMode: string = 'name'
  @State isPlusVisible: boolean = true
  @State lastScrollY: number = 0
  @State settings: AppSettingsData = new AppSettingsData()
  private dataService: DataService = DataService.getInstance()
  private songScanner: SongScanner = SongScanner.getInstance()
  private scroller: Scroller = new Scroller()

  aboutToAppear(): void {
    this.loadData()
  }

  loadData(): void {
    this.songs = this.dataService.getSongs()
    this.settings = this.dataService.getSettings()
    this.listMode = this.dataService.getListMode()
    this.viewMode = this.dataService.getViewMode()
    this.sortMode = this.dataService.getSortMode()
    this.applyFilters()
  }

  applyFilters(): void {
    let result: SongInfo[] = []
    for (let i = 0; i < this.songs.length; i++) {
      result.push(this.songs[i])
    }

    // Active folder filter
    const activeFolder: string = this.dataService.getActiveFolderFilter()
    if (activeFolder.length > 0) {
      const filtered: SongInfo[] = []
      for (let i = 0; i < result.length; i++) {
        if (result[i].folderPath === activeFolder) {
          filtered.push(result[i])
        }
      }
      result = filtered
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
      // Folder mode: group by folder
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
        // Add header
        const header: DisplayItem = new DisplayItem()
        header.isHeader = true
        header.headerText = key
        items.push(header)
        // Add songs
        for (let si = 0; si < groupSongs.length; si++) {
          const di: DisplayItem = new DisplayItem()
          di.isHeader = false
          di.song = groupSongs[si]
          items.push(di)
        }
      }
    }
    this.displayItems = items
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

  toggleListMode(): void {
    if (this.listMode === 'all') {
      this.listMode = 'current'
    } else {
      this.listMode = 'all'
    }
    this.dataService.setListMode(this.listMode)
    this.applyFilters()
  }

  toggleViewMode(): void {
    if (this.viewMode === 'flat') {
      this.viewMode = 'folder'
    } else {
      this.viewMode = 'flat'
    }
    this.dataService.setViewMode(this.viewMode)
    this.buildDisplayItems(this.sortSongs(this.filterActiveSongs()))
  }

  filterActiveSongs(): SongInfo[] {
    let result: SongInfo[] = []
    for (let i = 0; i < this.songs.length; i++) {
      result.push(this.songs[i])
    }
    const activeFolder: string = this.dataService.getActiveFolderFilter()
    if (activeFolder.length > 0) {
      const filtered: SongInfo[] = []
      for (let i = 0; i < result.length; i++) {
        if (result[i].folderPath === activeFolder) {
          filtered.push(result[i])
        }
      }
      result = filtered
    }
    return result
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
      this.dataService.addSongs(newSongs)
      this.loadData()
    }
  }

  toggleFavorite(songId: string): void {
    this.dataService.toggleFavorite(songId)
    this.loadData()
  }

  removeSong(songId: string): void {
    this.dataService.removeSong(songId)
    this.loadData()
  }

  getSortLabel(): string {
    if (this.sortMode === 'name') {
      return '名称排序'
    } else if (this.sortMode === 'date') {
      return '添加时间'
    }
    return '自定义'
  }

  onScroll(xOffset: number, yOffset: number): void {
    if (yOffset > this.lastScrollY && yOffset > 10) {
      this.isPlusVisible = false
    } else if (yOffset < this.lastScrollY) {
      this.isPlusVisible = true
    }
    this.lastScrollY = yOffset
  }

  build() {
    Stack() {
      Column() {
        // Header toolbar
        Row() {
          Row() {
            Text(this.listMode === 'all' ? '全部歌曲' : '当前播放')
              .fontSize(14)
              .fontColor('#FFFFFF')
              .fontWeight(FontWeight.Bold)
          }
          .padding({ left: 12, right: 12, top: 6, bottom: 6 })
          .backgroundColor(this.listMode === 'all' ? 'rgba(0,125,255,0.3)' : 'rgba(255,255,255,0.1)')
          .borderRadius(16)
          .onClick(() => { this.toggleListMode() })

          Blank()

          Row() {
            Image($r('app.media.ic_sort_list'))
              .width(16).height(16)
              .fillColor('#FFFFFF')
            Text(this.getSortLabel())
              .fontSize(12)
              .fontColor('#FFFFFF')
              .margin({ left: 4 })
          }
          .padding({ left: 10, right: 10, top: 6, bottom: 6 })
          .backgroundColor('rgba(255,255,255,0.1)')
          .borderRadius(16)
          .onClick(() => { this.switchSortMode() })

          Row() {
            Text(this.viewMode === 'flat' ? '平铺' : '文件夹')
              .fontSize(12)
              .fontColor('#FFFFFF')
          }
          .padding({ left: 10, right: 10, top: 6, bottom: 6 })
          .backgroundColor('rgba(255,255,255,0.1)')
          .borderRadius(16)
          .onClick(() => { this.toggleViewMode() })
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 8, bottom: 8 })

        // Song list
        Scroll(this.scroller) {
          Column() {
            if (this.displayItems.length > 0) {
              List() {
                ForEach(this.displayItems, (item: DisplayItem, index: number) => {
                  ListItem() {
                    if (item.isHeader) {
                      this.folderHeaderRow(item.headerText)
                    } else if (item.song !== null) {
                      this.songItemRow(item.song)
                    }
                  }
                }, (item: DisplayItem, index: number) => {
                  if (item.isHeader) {
                    return 'h_' + item.headerText
                  }
                  if (item.song !== null) {
                    return item.song.id
                  }
                  return 'empty_' + index
                })
              }
              .width('100%')
            } else {
              Text('暂无歌曲，点击右下角 + 添加')
                .fontSize(14)
                .fontColor('rgba(255,255,255,0.4)')
                .width('100%')
                .height(200)
                .textAlign(TextAlign.Center)
            }
          }
          .width('100%')
        }
        .width('100%')
        .layoutWeight(1)
        .edgeEffect(EdgeEffect.Spring)
        .onScroll((xOffset: number, yOffset: number) => { this.onScroll(xOffset, yOffset) })
      }
      .width('100%')
      .height('100%')

      // "+" button overlay
      if (this.settings.plusButtonVisible && this.isPlusVisible) {
        Row() {
          Text('+')
            .fontSize(32)
            .fontColor('#FFFFFF')
            .fontWeight(FontWeight.Bold)
        }
        .width(40).height(40)
        .borderRadius(20)
        .backgroundColor('rgba(0,125,255,0.9)')
        .shadow({ radius: 10, color: '#44007DFF', offsetY: 4 })
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
  folderHeaderRow(title: string): void {
    Row() {
      Text(title)
        .fontSize(13)
        .fontColor('rgba(255,255,255,0.6)')
        .fontWeight(FontWeight.Medium)
        .padding({ left: 16, top: 12, bottom: 4 })
    }
    .width('100%')
    .backgroundColor('rgba(255,255,255,0.03)')
  }

  @Builder
  songItemRow(item: SongInfo): void {
    Row() {
      Column() {
        Text(item.name)
          .fontSize(15)
          .fontColor(item.isAvailable ? '#FFFFFF' : 'rgba(255,255,255,0.3)')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        Row() {
          Text(item.artist.length > 0 ? item.artist : '未知歌手')
            .fontSize(12)
            .fontColor('rgba(255,255,255,0.5)')
          if (item.folderName.length > 0) {
            Text(' · ' + item.folderName)
              .fontSize(12)
              .fontColor('rgba(255,255,255,0.3)')
          }
        }
        .width('100%')
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      // Favorite button
      Image(item.isFavorite ? $r('app.media.heart_fill') : $r('app.media.heart_gap'))
        .width(20).height(20)
        .fillColor(item.isFavorite ? '#FF3B30' : 'rgba(255,255,255,0.4)')
        .margin({ right: 12 })
        .onClick(() => { this.toggleFavorite(item.id) })

      // Delete button
      Text('✕')
        .fontSize(16)
        .fontColor('rgba(255,255,255,0.3)')
        .width(18).height(18)
        .textAlign(TextAlign.Center)
        .onClick(() => { this.removeSong(item.id) })
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 10, bottom: 10 })
    .alignItems(VerticalAlign.Center)
  }
}
