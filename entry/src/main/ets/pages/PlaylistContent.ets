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
  @State settings: AppSettingsData = new AppSettingsData()
  @State isPlusVisible: boolean = true
  @State lastScrollY: number = 0
  private dataService: DataService = DataService.getInstance()
  private songScanner: SongScanner = SongScanner.getInstance()
  private scroller: Scroller = new Scroller()

  aboutToAppear(): void {
    this.loadData()
  }

  loadData(): void {
    this.folders = this.dataService.getFolders()
    this.settings = this.dataService.getSettings()
  }

  onFolderClick(folder: FolderInfo): void {
    this.dataService.setActiveFolderFilter(folder.path)
    this.dataService.setListMode('all')
    this.onNavigateToHome(folder)
  }

  removeFolder(folderId: string): void {
    this.dataService.removeFolder(folderId)
    this.loadData()
  }

  async onPlusClick(): Promise<void> {
    if (this.context === undefined) {
      return
    }
    const folder: FolderInfo | null = await this.songScanner.pickFolder(this.context)
    if (folder !== null) {
      this.dataService.addFolder(folder)
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
            .fontColor('#FFFFFF')
            .fontWeight(FontWeight.Bold)
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 8, bottom: 12 })

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
              Text('暂无歌单，点击右下角 + 添加文件夹')
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
  folderCard(item: FolderInfo): void {
    Stack() {
      Column() {
        Image($r('app.media.ic_public_music'))
          .width(36).height(36)
          .fillColor('rgba(255,255,255,0.6)')
          .margin({ bottom: 8 })
        Text(item.name)
          .fontSize(14)
          .fontColor(item.isAvailable ? '#FFFFFF' : 'rgba(255,255,255,0.3)')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(item.songCount + ' 首歌曲')
          .fontSize(11)
          .fontColor('rgba(255,255,255,0.4)')
          .margin({ top: 4 })
      }
      .width('100%')
      .height('100%')
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)

      // Delete button (top-right)
      Text('✕')
        .fontSize(14)
        .fontColor('rgba(255,255,255,0.3)')
        .width(16).height(16)
        .textAlign(TextAlign.Center)
        .position({ top: 8, right: 8 })
        .onClick(() => { this.removeFolder(item.id) })
    }
    .width('100%')
    .aspectRatio(1.2)
    .backgroundColor(item.isAvailable ? 'rgba(255,255,255,0.08)' : 'rgba(255,255,255,0.03)')
    .borderRadius(16)
    .border({ width: 1, color: 'rgba(255,255,255,0.1)' })
    .onClick(() => { this.onFolderClick(item) })
  }
}
