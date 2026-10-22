// ArkUI 26 Beta1: 接口定义变更（误报，本项目已是Stage模型）+ UX视觉布局变更（Text默认开启沉浸式材质，系统行为）
import { SongInfo } from '../model/SongInfo'
import { PlaylistInfo } from '../model/PlaylistInfo'
import { DataService } from '../service/DataService'
import Logger from '../common/utils/Logger'
import { AlbumCover } from './AlbumCover'
import { AlbumCoverSize } from '../service/AudioMetadataService'

const TAG = 'PlaylistCreateDialog'

// 新建歌单统一弹窗（歌单页/首页共用）：歌单名输入 + 全曲库多选；
// 选中顺序即歌单内顺序，首曲自动成为封面（沿用 addSongsToPlaylist 逻辑）
@Component
export struct PlaylistCreateDialog {
  songs: SongInfo[] = []
  // 打开时预选中的歌曲 id（首页多选「加入歌单」场景传入当前选中歌曲）
  preselectedIds: string[] = []
  primaryColor: string = '#007DFF'
  fontSizeScale: number = 1.0
  displaySizeScale: number = 1.0
  onCancel: () => void = () => {
  }
  // addedCount 为本次选入新歌单的歌曲数（0 表示创建了空歌单）
  onDone: (addedCount: number) => void = (_addedCount: number) => {
  }
  private dataService: DataService = DataService.getInstance()
  @State nameText: string = ''
  @State searchText: string = ''
  @State selectedIds: string[] = []

  aboutToAppear(): void {
    this.selectedIds = this.preselectedIds.slice()
  }

  private scaledSize(size: number): number {
    return Math.round(size * this.displaySizeScale)
  }

  private isSelected(songId: string): boolean {
    return this.selectedIds.indexOf(songId) >= 0
  }

  // 搜索过滤：标题/歌手/专辑（含拼音）不区分大小写子串匹配
  private filteredSongs(): SongInfo[] {
    const keyword: string = this.searchText.trim().toLowerCase()
    const result: SongInfo[] = []
    for (let i = 0; i < this.songs.length; i++) {
      const song: SongInfo = this.songs[i]
      if (keyword.length === 0) {
        result.push(song)
        continue
      }
      if (song.title.toLowerCase().indexOf(keyword) >= 0 ||
        song.artist.toLowerCase().indexOf(keyword) >= 0 ||
        song.album.toLowerCase().indexOf(keyword) >= 0 ||
        song.pinyinFull.toLowerCase().indexOf(keyword) >= 0 ||
        song.pinyinAbbr.toLowerCase().indexOf(keyword) >= 0) {
        result.push(song)
      }
    }
    return result
  }

  // 勾选/取消勾选：点击顺序即歌单内曲目顺序
  private toggleSong(songId: string): void {
    const index: number = this.selectedIds.indexOf(songId)
    if (index >= 0) {
      this.selectedIds.splice(index, 1)
    } else {
      this.selectedIds.push(songId)
    }
  }

  // 确认创建：空名/超长（>30 字符）不落库
  private async confirmCreate(): Promise<void> {
    const name: string = this.nameText.trim()
    if (name.length === 0 || name.length > 30) {
      return
    }
    try {
      const created: PlaylistInfo | undefined = await this.dataService.createPlaylist(name)
      if (created !== undefined) {
        const addedCount: number = this.selectedIds.length
        await this.dataService.addSongsToPlaylist(created.id, this.selectedIds.slice())
        this.onDone(addedCount)
      }
    } catch (err) {
      Logger.error(TAG, `confirmCreate failed: ${JSON.stringify(err)}`)
    }
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor('rgba(0,0,0,0.35)')
        .onClick(() => {
          this.onCancel()
        })

      Column({ space: 14 }) {
        Text('新建歌单')
          .fontSize(Math.round(16 * this.fontSizeScale))
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
          .width('100%')

        TextInput({ text: this.nameText, placeholder: '输入歌单名称' })
          .height(this.scaledSize(38))
          .fontSize(Math.round(14 * this.fontSizeScale))
          .backgroundColor('rgba(0,0,0,0.04)')
          .borderRadius(12)
          .onChange((value: string) => {
            this.nameText = value
          })
          .enterKeyType(EnterKeyType.Next)

        if (this.songs.length === 0) {
          Text('曲库为空，先导入歌曲后即可选歌建单')
            .fontSize(Math.round(13 * this.fontSizeScale))
            .fontColor($r('app.color.text_twenty_color'))
            .width('100%')
            .textAlign(TextAlign.Center)
            .padding({ top: 24, bottom: 24 })
        } else {
          TextInput({ text: this.searchText, placeholder: '搜索歌曲、歌手、专辑' })
            .height(this.scaledSize(36))
            .fontSize(Math.round(13 * this.fontSizeScale))
            .backgroundColor('rgba(0,0,0,0.04)')
            .borderRadius(12)
            .onChange((value: string) => {
              this.searchText = value
            })

          List() {
            ForEach(this.filteredSongs(), (song: SongInfo) => {
              ListItem() {
                Row({ space: 10 }) {
                  AlbumCover({
                    song: song, coverWidth: this.scaledSize(36), coverHeight: this.scaledSize(36),
                    coverRadius: 8, decodeSize: AlbumCoverSize.SMALL
                  })
                  Column({ space: 2 }) {
                    Text(song.title)
                      .fontSize(Math.round(14 * this.fontSizeScale))
                      .fontColor($r('app.color.text_primary'))
                      .maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                    Text(song.artist)
                      .fontSize(Math.round(12 * this.fontSizeScale))
                      .fontColor($r('app.color.text_sixty_color'))
                      .maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                  }
                  .layoutWeight(1)
                  .alignItems(HorizontalAlign.Start)

                  Image(this.isSelected(song.id) ?
                    $r('app.media.ic_public_todo_filled') : $r('app.media.ic_public_todo'))
                    .width(22)
                    .height(22)
                    .fillColor(this.isSelected(song.id) ? this.primaryColor : $r('app.color.text_sixty_color'))
                }
                .width('100%')
                .padding({ top: 7, bottom: 7 })
                .onClick(() => {
                  this.toggleSong(song.id)
                })
              }
            }, (song: SongInfo) => song.id + (this.isSelected(song.id) ? '_1' : '_0'))
          }
          .constraintSize({ maxHeight: this.scaledSize(300) })
          .width('100%')
          .scrollBar(BarState.Auto)
          .divider({ strokeWidth: 1, color: $r('app.color.list_divider'), startMargin: 56, endMargin: 0 })
        }

        Row({ space: 10 }) {
          Text('取消')
            .fontSize(Math.round(14 * this.fontSizeScale))
            .fontColor($r('app.color.text_sixty_color'))
            .layoutWeight(1)
            .textAlign(TextAlign.Center)
            .padding({ top: 8, bottom: 8 })
            .borderRadius(16)
            .backgroundColor('rgba(0,0,0,0.05)')
            .onClick(() => {
              this.onCancel()
            })
          Text(this.selectedIds.length > 0 ? `创建（已选 ${this.selectedIds.length} 首）` : '创建')
            .fontSize(Math.round(14 * this.fontSizeScale))
            .fontColor(Color.White)
            .layoutWeight(1)
            .textAlign(TextAlign.Center)
            .padding({ top: 8, bottom: 8 })
            .borderRadius(16)
            .backgroundColor(this.primaryColor)
            .maxLines(1)
            .onClick(() => {
              this.confirmCreate().catch((err: Error) => {
                Logger.error(TAG, `confirmCreate failed: ${JSON.stringify(err)}`)
              })
            })
        }
        .width('100%')
      }
      .width('76%')
      .constraintSize({ maxHeight: '82%' })
      .padding(18)
      .borderRadius(20)
      .backgroundColor($r('app.color.page_background_sm'))
    }
    .width('100%')
    .height('100%')
    .zIndex(40)
  }
}
