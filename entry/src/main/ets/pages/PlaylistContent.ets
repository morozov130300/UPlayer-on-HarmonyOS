import { common } from '@kit.AbilityKit'
import { FolderInfo } from '../model/FolderInfo'
import { SongInfo } from '../model/SongInfo'
import { DataService, AppSettingsData } from '../service/DataService'
import { SongScanner } from '../service/SongScanner'
import Logger from '../common/utils/Logger'
import { AppStorageKeyConstants } from '../common/constants/AppStorageKeyConstants'

const TAG = 'PlaylistContent'

@Component
export struct PlaylistContent {
  onNavigateToHome: (folder: FolderInfo) => void = (folder: FolderInfo): void => {}
  private context: common.UIAbilityContext | undefined = AppStorage.get<common.UIAbilityContext>(AppStorageKeyConstants.KEY_UI_ABILITY_CONTEXT)
  @State folders: FolderInfo[] = []
  @State songs: SongInfo[] = []
  @State settings: AppSettingsData = new AppSettingsData()
  @State isPlusVisible: boolean = true
  @State lastScrollY: number = 0
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

  /** 从所有歌曲的 folderPath 自动构建文件夹列表 */
  buildFoldersFromSongs(): void {
    const seen: Record<string, boolean> = {}
    const result: FolderInfo[] = []
    for (let i = 0; i < this.songs.length; i++) {
      const song: SongInfo = this.songs[i]
      const key: string = song.folderPath
      if (key.length > 0 && seen[key] === undefined) {
        seen[key] = true
        const folder: FolderInfo = FolderInfo.fromPath(key)
        // 统计该文件夹内的歌曲数量
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
    this.folders = result
  }

  onFolderClick(folder: FolderInfo): void {
    this.dataService.setActiveFolderFilter(folder.path)
    this.dataService.setListMode('all')
    this.onNavigateToHome(folder)
  }

  async onPlusClick(): Promise<void> {
    if (this.context === undefined) {
      return
    }
    // 从歌曲所在文件夹导入歌曲文件
    const newSongs: SongInfo[] = await this.songScanner.pickAudioFiles(this.context)
    if (newSongs.length > 0) {
      this.dataService.addSongs(newSongs)
      this.loadData()
    }
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
        // Header
        Row() {
          Text('我的歌单')
            .fontSize(18)
            .fontColor($r('app.color.text_primary'))
            .fontWeight(FontWeight.Bold)
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: this.topSafeHeight + 8, bottom: 12 })

        // Folder grid
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
              .columnsTemplate('1fr 1fr')
              .columnsGap(12)
              .rowsGap(12)
              .padding({ left: 16, right: 16 })
              .width('100%')
            } else {
              Text('暂无歌单，点击右下角 + 导入歌曲')
                .fontSize(14)
                .fontColor($r('app.color.text_twenty_color'))
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

      // "+" button
      if (this.settings.plusButtonVisible && this.isPlusVisible) {
        Row() {
          Text('+')
            .fontSize(32)
            .fontColor('#FFFFFF')
            .fontWeight(FontWeight.Bold)
        }
        .width(40).height(40)
        .borderRadius(20)
        .backgroundColor(this.primaryColor)
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
    }
    .width('100%')
    .aspectRatio(1.2)
    .backgroundColor('rgba(0,0,0,0.03)')
    .borderRadius(16)
    .border({ width: 1, color: $r('app.color.list_divider') })
    .onClick(() => { this.onFolderClick(item) })
  }
}
