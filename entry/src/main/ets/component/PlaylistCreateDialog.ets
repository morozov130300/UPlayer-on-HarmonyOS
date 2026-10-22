// ArkUI 26 Beta1: 接口定义变更（误报，本项目已是Stage模型）+ UX视觉布局变更（Text默认开启沉浸式材质，系统行为）
import { SongInfo } from '../model/SongInfo'
import { PlaylistInfo } from '../model/PlaylistInfo'
import { DataService } from '../service/DataService'
import Logger from '../common/utils/Logger'
import { AlbumCover } from './AlbumCover'
import { AlbumCoverSize } from '../service/AudioMetadataService'

const TAG = 'PlaylistCreateDialog'

// 新建/编辑歌单统一弹窗（歌单页/首页共用，官方 bindSheet 半模态内容）：
// 歌单名输入 + 全曲库多选 + 列表上下全选/反选操作行；
// 选中顺序即歌单内顺序，首曲自动成为封面（沿用 addSongsToPlaylist 逻辑）；
// editingPlaylistId 非空时为编辑模式：整体替换歌单曲目 + 可选改名
@Component
export struct PlaylistCreateDialog {
  songs: SongInfo[] = []
  // 打开时预选中的歌曲 id（首页多选「加入歌单」传当前选中歌曲；编辑模式传歌单现有曲目）
  preselectedIds: string[] = []
  // 编辑模式：目标歌单 id（空 = 新建模式）
  editingPlaylistId: string = ''
  // 编辑模式：预填歌单名（同时作为改名输入框初值）
  initialName: string = ''
  primaryColor: string = '#007DFF'
  fontSizeScale: number = 1.0
  displaySizeScale: number = 1.0
  // addedCount 为本次选入新歌单的歌曲数（0 表示创建了空歌单）
  onDone: (addedCount: number) => void = (_addedCount: number) => {
  }
  private dataService: DataService = DataService.getInstance()
  @State nameText: string = ''
  @State searchText: string = ''
  @State selectedIds: string[] = []

  aboutToAppear(): void {
    this.selectedIds = this.preselectedIds.slice()
    this.nameText = this.initialName
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

  // 过滤结果是否已全部选中
  private isAllFilteredSelected(): boolean {
    const filtered: SongInfo[] = this.filteredSongs()
    if (filtered.length === 0 || this.selectedIds.length < filtered.length) {
      return false
    }
    for (let i = 0; i < filtered.length; i++) {
      if (this.selectedIds.indexOf(filtered[i].id) < 0) {
        return false
      }
    }
    return true
  }

  // 全选/取消全选（与首页多选同语义）：已全选 → 清空；否则按过滤结果顺序整体替换
  private toggleSelectAllFiltered(): void {
    if (this.isAllFilteredSelected()) {
      this.selectedIds = []
      return
    }
    const filtered: SongInfo[] = this.filteredSongs()
    const ids: string[] = []
    for (let i = 0; i < filtered.length; i++) {
      ids.push(filtered[i].id)
    }
    this.selectedIds = ids
  }

  // 反选：保留过滤视图之外的已选项（原顺序），翻转过滤列表内每首歌的选中态，新选中按列表顺序追加
  private invertFilteredSelection(): void {
    const filtered: SongInfo[] = this.filteredSongs()
    const filteredSet: Set<string> = new Set()
    for (let i = 0; i < filtered.length; i++) {
      filteredSet.add(filtered[i].id)
    }
    const selectedSet: Set<string> = new Set(this.selectedIds)
    const result: string[] = []
    for (let i = 0; i < this.selectedIds.length; i++) {
      if (!filteredSet.has(this.selectedIds[i])) {
        result.push(this.selectedIds[i])
      }
    }
    for (let i = 0; i < filtered.length; i++) {
      if (!selectedSet.has(filtered[i].id)) {
        result.push(filtered[i].id)
      }
    }
    this.selectedIds = result
  }

  // 空名自动命名：未命名歌单 + 最小可用序号（避开现有歌单名，从 1 起）
  private generateUnnamedPlaylistName(): string {
    const existing: Set<string> = new Set()
    const playlists: PlaylistInfo[] = this.dataService.getPlaylists()
    for (let i = 0; i < playlists.length; i++) {
      existing.add(playlists[i].name)
    }
    let index: number = 1
    while (existing.has(`未命名歌单${index}`)) {
      index++
    }
    return `未命名歌单${index}`
  }

  // 当前编辑歌单的名称（编辑模式改名去重判断用）
  private currentEditingName(): string {
    const playlists: PlaylistInfo[] = this.dataService.getPlaylists()
    for (let i = 0; i < playlists.length; i++) {
      if (playlists[i].id === this.editingPlaylistId) {
        return playlists[i].name
      }
    }
    return ''
  }

  // 确认提交：新建模式 → 创建歌单（空名自动命名）；
  // 编辑模式 → 整体替换歌单曲目（顺序=勾选顺序）+ 名称变化时改名；超长（>30 字符）不落库
  private async confirmCommit(): Promise<void> {
    const name: string = this.nameText.trim()
    if (name.length > 30) {
      return
    }
    try {
      if (this.editingPlaylistId.length > 0) {
        const currentIds: string[] = this.dataService.getPlaylistItemSongIds(this.editingPlaylistId)
        if (currentIds.length > 0) {
          await this.dataService.removeSongsFromPlaylist(this.editingPlaylistId, currentIds)
        }
        if (this.selectedIds.length > 0) {
          await this.dataService.addSongsToPlaylist(this.editingPlaylistId, this.selectedIds.slice())
        }
        if (name.length > 0 && name !== this.currentEditingName()) {
          await this.dataService.renamePlaylist(this.editingPlaylistId, name)
        }
        this.onDone(this.selectedIds.length)
        return
      }
      const finalName: string = name.length > 0 ? name : this.generateUnnamedPlaylistName()
      const created: PlaylistInfo | undefined = await this.dataService.createPlaylist(finalName)
      if (created !== undefined) {
        const addedCount: number = this.selectedIds.length
        await this.dataService.addSongsToPlaylist(created.id, this.selectedIds.slice())
        this.onDone(addedCount)
      }
    } catch (err) {
      Logger.error(TAG, `confirmCommit failed: ${JSON.stringify(err)}`)
    }
  }

  // 全选按钮（列表上下操作行共用）：图标 + 文字
  @Builder
  selectAllButton(): void {
    Row({ space: 4 }) {
      Image(this.isAllFilteredSelected() ?
        $r('app.media.ic_public_deselect_all') : $r('app.media.ic_public_select_all'))
        .width(16)
        .height(16)
        .fillColor(this.primaryColor)
      Text(this.isAllFilteredSelected() ? '取消全选' : '全选')
        .fontSize(Math.round(14 * this.fontSizeScale))
        .fontColor(this.primaryColor)
    }
    .onClick(() => {
      this.toggleSelectAllFiltered()
    })
  }

  build() {
    Column({ space: 14 }) {
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

        // 顶部操作行：已选计数 + 全选 + 反选
        Row() {
          Text(`已选 ${this.selectedIds.length} 首`)
            .fontSize(Math.round(13 * this.fontSizeScale))
            .fontColor($r('app.color.text_sixty_color'))
          Blank()
          this.selectAllButton()
          Text('反选')
            .fontSize(Math.round(14 * this.fontSizeScale))
            .fontColor(this.primaryColor)
            .margin({ left: 16 })
            .onClick(() => {
              this.invertFilteredSelection()
            })
        }
        .width('100%')

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
              // 右侧留出滚动条宽度：否则列表滚动条会压在行尾的选中图标上
              .padding({ top: 7, bottom: 7, right: this.scaledSize(10) })
              .onClick(() => {
                this.toggleSong(song.id)
              })
            }
          }, (song: SongInfo) => song.id + (this.isSelected(song.id) ? '_1' : '_0'))
        }
        .layoutWeight(1)
        .width('100%')
        .scrollBar(BarState.Auto)
        .divider({ strokeWidth: 1, color: $r('app.color.list_divider'), startMargin: 56, endMargin: 0 })

        // 底部操作行：仅保留主操作按钮（全选/反选/已选计数已由顶部操作行承担，不重复放）
        Row() {
          Blank()
          Text(this.editingPlaylistId.length > 0 ? '保存' : '创建')
            .fontSize(Math.round(14 * this.fontSizeScale))
            .fontColor(Color.White)
            .textAlign(TextAlign.Center)
            .padding({ top: 8, bottom: 8, left: 16, right: 16 })
            .borderRadius(16)
            .backgroundColor(this.primaryColor)
            .maxLines(1)
            .onClick(() => {
              this.confirmCommit().catch((err: Error) => {
                Logger.error(TAG, `confirmCommit failed: ${JSON.stringify(err)}`)
              })
            })
        }
        .width('100%')
      }
    }
    .width('100%')
    .height('100%')
    .padding(18)
  }
}
