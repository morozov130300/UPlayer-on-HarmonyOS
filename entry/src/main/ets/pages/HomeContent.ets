// ArkUI 26 Beta1: 接口定义变更（误报，本项目已是Stage模型）+ UX视觉布局变更（Text默认开启沉浸式材质，系统行为）
import { common } from '@kit.AbilityKit'
import { deviceInfo } from '@kit.BasicServicesKit'
import { SongInfo } from '../model/SongInfo'
import { PlaylistInfo } from '../model/PlaylistInfo'
import { DataService, AppSettingsData, LibraryDeleteResult, FilterDimensions } from '../service/DataService'
import { importSongsWithToast } from '../service/SongScanner'
import { AVPlayerService } from '../service/AVPlayerService'
import { AVSessionController } from '../common/utils/mediautils/AVSessionController'
import { LiveViewService } from '../service/LiveViewService'
import { ColorHelper } from '../common/utils/ColorHelper'
import { DisplayItem, DisplayItemDataSource } from '../viewmodel/DisplayItemDataSource'
import Logger from '../common/utils/Logger'
import { AppStorageKeyConstants } from '../common/constants/AppStorageKeyConstants'
import { AlbumCover } from '../component/AlbumCover'
import { AlbumCoverSize, AudioMetadataService, CoverPriority } from '../service/AudioMetadataService'
import { curves, uiMaterial } from '@kit.ArkUI'
import { createBarGlassMaterial, DEFAULT_GLASS_STYLE, showToastGlassMaterial, topBlurRadiusFromStrength } from '../common/utils/GlassUtil'
import { GlassBackButton } from '../view/GlassBackButton'
import { StyleConstants } from '../common/constants/StyleConstants'

const TAG = 'HomeContent'
const PREFETCH_COUNT: number = 64
const PREFETCH_THROTTLE_MS: number = 50
const APPROX_ITEM_HEIGHT: number = 72
// 手柄拖拽：拖拽位移超过该距离（约一行高）时与相邻项交换位置
const DRAG_SWAP_DISTANCE: number = 60
// 模糊搜索：输入防抖间隔与结果条数上限（命中权重排序后截断）
const SEARCH_DEBOUNCE_MS: number = 300
const SEARCH_RESULT_LIMIT: number = 200
// 筛选面板：单维度候选项上限（按歌曲数降序截断，防止超长列表拖垮面板）
const FILTER_PANEL_OPTION_LIMIT: number = 100
// 最近播放：lastPlayedAt 倒序展示条数上限（P0-4）
const RECENT_PLAY_LIMIT: number = 20

// 搜索命中封装：score 为各 token 权重之和，0 表示不命中
class ScoredSong {
  song: SongInfo = new SongInfo()
  score: number = 0
}

// 筛选面板候选项：value 为原始匹配值（可能为空串），label 为展示文案，count 为歌曲数
class FilterChipOption {
  value: string = ''
  label: string = ''
  count: number = 0
}

// 「加入歌单」弹窗行（P2-3）：id/name/count 为歌单快照，打开弹窗时重建
class PickerPlaylistRow {
  id: string = ''
  name: string = ''
  count: number = 0
}

@Component
export struct HomeContent {
  topContentPadding: number = 0
  // 底部让位原始输入（Index 传入），页内自算 bottomOverlayInset() 以实时跟随显示大小
  bottomSafeHeight: number = 0
  smallBreakpoint: boolean = false
  // 问候语内容带（由 Index 传入）：多选菜单栏进入多选时落在该带内，替换问候语的位置
  greetingBandTop: number = 0
  greetingBandHeight: number = 0
  private isPC: boolean = deviceInfo.deviceType === '2in1'
  private context: common.UIAbilityContext | undefined = AppStorage.get<common.UIAbilityContext>(AppStorageKeyConstants.KEY_UI_ABILITY_CONTEXT)
  @State songs: SongInfo[] = []
  @State displayItems: DisplayItem[] = []
  private displayDataSource: DisplayItemDataSource = new DisplayItemDataSource([])
  @State viewMode: string = 'flat'
  @State sortMode: string = 'name'
  @State isPlusVisible: boolean = true
  @State settings: AppSettingsData = new AppSettingsData()
  // 筛选胶囊与歌单页卡片选中状态实时同步：歌单页每次勾选都调用 setFilterState（同时 bump KEY_FILTER_REVISION），
  // 这里用 @Watch 跟随刷新，保证首页胶囊文字/底色即时反映当前选中的文件夹或收藏
  // 多选状态挂在 AppStorage 上并双向绑定：@Entry 页面需要在返回键/ESC 里把它置 false 来退出多选。
  // 之前是私有 @State，外部（页面级 onBackPress）无法把多选状态收回去，导致返回键只能退出应用。
  @StorageLink(AppStorageKeyConstants.KEY_HOME_MULTI_SELECT) @Watch('onMultiSelectModeChange')
  isMultiSelectMode: boolean = false
  // Ctrl+A 全选请求（由 Index 的页面级键盘事件写入并 +1）：多选态下全选可见歌曲
  @StorageLink(AppStorageKeyConstants.KEY_HOME_SELECT_ALL_REQUEST) @Watch('onSelectAllRequest')
  selectAllRequest: number = 0
  // Delete 键删除请求（Index 页面级键盘事件 +1）：多选态下与删除按钮功能一致
  @StorageLink(AppStorageKeyConstants.KEY_HOME_DELETE_REQUEST) @Watch('onDeleteRequest')
  deleteRequest: number = 0
  // 艺术家拆分分隔符（设置页「播放」区配置）：筛选下拉列表按这些符号把
  // 「midnight kiss,kappa」等多艺人串拆成独立艺术家归类；默认值须与
  // AppSettingsData.artistSeparators 一致，变化经 saveSettings 推送 @Watch 重筛
  @StorageLink(AppStorageKeyConstants.KEY_ARTIST_SEPARATORS) @Watch('onArtistSeparatorsChange')
  artistSeparators: string[] = [',', '，', '&', '＆']
  @StorageLink(AppStorageKeyConstants.KEY_TITLE_BUTTON_WIDTH) titleButtonWidth: number = 0
  @StorageLink('uplayer_font_size_scale') fontSizeScale: number = 1.0
  @StorageLink('uplayer_display_size_scale') displaySizeScale: number = 1.0
  @StorageLink(AppStorageKeyConstants.KEY_LIBRARY_REVISION) @Watch('onLibraryChange') libraryRevision: number = 0
  @StorageLink(AppStorageKeyConstants.KEY_FILTER_REVISION) @Watch('onFilterChange') filterRevision: number = 0
  // 胶囊文字用 @State 缓存：KEY_FILTER_REVISION 变化时由 @Watch 赋值，保证 UI 响应式刷新
  @State filterLabel: string = '全部歌曲'
  @State selectedIds: string[] = []
  // 手动拖拽排序状态：dragSongId 为被拖拽歌曲 id，空串表示未拖拽。
  // 必须用 id 定位（而非 index）：LazyForEach 数据移动/节点复用后 index 不可靠
  @State dragSongId: string = ''
  @State dragOffsetY: number = 0
  private dragLastY: number = 0
  // 模糊搜索（S2）：搜索行显隐、输入内容、300ms 防抖句柄；
  // Ctrl+F 由 Index 页面级键盘事件 +1 触发 @Watch，打开搜索行并聚焦输入框
  @State isSearchActive: boolean = false
  @State searchText: string = ''
  private searchDebounceId: number = -1
  @StorageLink(AppStorageKeyConstants.KEY_HOME_SEARCH_FOCUS) @Watch('onSearchFocusRequest')
  searchFocusRequest: number = 0
  // 组合筛选面板（S1）：面板显隐、各维度已选值与候选列表
  @State isFilterPanelVisible: boolean = false
  @State panelArtists: string[] = []
  @State panelAlbums: string[] = []
  @State panelGenres: string[] = []
  @State panelYears: string[] = []
  @State panelArtistOptions: FilterChipOption[] = []
  @State panelAlbumOptions: FilterChipOption[] = []
  @State panelGenreOptions: FilterChipOption[] = []
  @State panelYearOptions: FilterChipOption[] = []
  // 自定义歌单（P2-3）：筛选态激活的歌单 id 缓存（refreshFilterLabel 同步），
  // 歌单集合变化经 KEY_PLAYLIST_REVISION @Watch 刷新列表；多选「加入歌单」弹窗状态
  @State playlistFilterId: string = ''
  @StorageLink(AppStorageKeyConstants.KEY_PLAYLIST_REVISION) @Watch('onPlaylistRevisionChange')
  playlistRevision: number = 0
  @State isPlaylistPickerVisible: boolean = false
  @State pickerRows: PickerPlaylistRow[] = []
  @State pickerNewName: string = ''
  @StorageLink('uplayer_primary_color') primaryColor: string = '#007DFF'
  // 底部栏样式：经典样式下多选菜单栏不挂任何背景效果（磨砂/液态玻璃）
  @StorageLink('uplayer_tab_style') tabStyle: string = 'classic'
  @StorageLink('uplayer_tab_touch_indicator') tabTouchIndicator: string = 'light'
  @StorageLink('uplayer_tab_light_color') tabLightColor: string = 'theme'
  @StorageLink('uplayer_home_top_blur_strength') homeTopBlurStrength: number = 25
  // 下滑隐藏加号：设置页切换后需跨页实时生效，故走 AppStorage 键 + @Watch 重新上报加号可见性
  @StorageLink('uplayer_plus_button_scroll_hide') @Watch('onPlusScrollHideChange')
  plusButtonScrollHide: boolean = true
  private dataService: DataService = DataService.getInstance()
  private avPlayerService: AVPlayerService = AVPlayerService.getInstance()
  private scroller: Scroller = new Scroller()

  private scaledSize(size: number): number {
    return Math.round(size * this.displaySizeScale)
  }

  // 底部让位（原由 Index 算好传入，改为页内自算跟随显示大小）：
  // 小屏 128≈56(tab)+28(margin)+40(播控)+4；大屏 88≈28+56+4
  private bottomOverlayInset(): number {
    return this.scaledSize(this.smallBreakpoint ? 128 : 88) + this.bottomSafeHeight
  }

  // 首页上端模糊半径：统一走 GlassUtil 的分段函数（先正比例、到 60 后恒定，临界处无缝相接）。
  // 只允许调用工厂，不允许在本文件重写公式——否则会与设置页顶部带产生断口
  private glassBlurRadius(): number {
    return topBlurRadiusFromStrength(this.homeTopBlurStrength)
  }

  // 多选底栏液态玻璃材质（API 26+）：能力不足/玻璃关断/低算力返回 undefined，
  // 调用处保留 backgroundEffect 兜底，保证老设备仍有磨砂。
  // 经典底部栏样式下整条不应用任何背景效果（避免压出一层灰突突的色块）
  // 玻璃厚度/交互形变等档位设置已删除：消费点固定默认开启
  private multiSelectBarMaterial(): uiMaterial.Material | undefined {
    if (this.tabStyle === 'classic') {
      return undefined
    }
    return createBarGlassMaterial(DEFAULT_GLASS_STYLE, true,
      this.tabTouchIndicator === 'light' ?
        (this.tabLightColor === 'white' ? '#FFFFFF' : this.primaryColor) : undefined)
  }

  // 经典样式下同样不挂磨砂层（与材质一起关断）
  private multiSelectBarBlurEnabled(): boolean {
    return this.tabStyle !== 'classic'
  }

  @State headerRowHeight: number = 0

  private headerOverlayHeight(): number {
    return this.headerRowHeight > 0 ? this.headerRowHeight : this.scaledSize(40)
  }

  private onHeaderRowAreaChange(area: Area): void {
    const h: Length = area.height
    if (typeof h === 'number' && h > 0 && Math.abs(h - this.headerRowHeight) > 0.5) {
      this.headerRowHeight = h
    }
  }

  // 多选菜单栏几何：高度保持原样，垂直居中于问候语内容带
  private multiSelectBarHeight(): number {
    return 56
  }

  private multiSelectBarTop(): number {
    const band: number = this.greetingBandHeight > 0 ? this.greetingBandHeight : 72
    const top: number = this.greetingBandTop + (band - this.multiSelectBarHeight()) / 2
    return top > 0 ? top : 0
  }

  // 右侧内边距与问候语保持一致：PC 上预留窗口按钮区域
  private multiSelectBarRightPadding(): number {
    return this.isPC ? Math.max(this.titleButtonWidth, 140) + 12 : 16
  }

  private listTopPadding(): number {
    return this.topContentPadding + this.headerOverlayHeight()
  }

  private scrollBarHeight(): string {
    return 'calc(100% - ' + this.listTopPadding() + 'vp)'
  }

  aboutToAppear(): void {
    this.loadData()
    this.refreshFilterLabel()
    this.publishPlusVisible()
    AppStorage.setOrCreate(AppStorageKeyConstants.KEY_HOME_MULTI_SELECT, false)
  }

  aboutToDisappear(): void {
    AppStorage.setOrCreate(AppStorageKeyConstants.KEY_HOME_MULTI_SELECT, false)
    if (this.searchDebounceId >= 0) {
      clearTimeout(this.searchDebounceId)
      this.searchDebounceId = -1
    }
  }

  // 多选状态变化统一收口在这里。isMultiSelectMode 已改为 @StorageLink，
// 写入 AppStorage 由框架自动完成，这里不能再手动 setOrCreate（会重复通知一次）。
  // 退出多选时必须一并清空选中集合：返回键/ESC 触发的退出不经过 exitMultiSelect()，
  // 若不清空，下次进入多选会带着上次残留的选中项。
  onMultiSelectModeChange(): void {
    if (!this.isMultiSelectMode) {
      this.selectedIds = []
    }
    this.publishPlusVisible()
  }

  // Ctrl+A：只做全选，不做取消全选；非多选态一律忽略（普通浏览时不响应，避免误触）
  onSelectAllRequest(): void {
    if (!this.isMultiSelectMode) {
      return
    }
    this.selectedIds = this.getVisibleSongIds()
  }

  // Delete 键：多选态且有选中时执行与删除按钮相同的逻辑；空选/非多选态忽略
  onDeleteRequest(): void {
    if (!this.isMultiSelectMode || this.selectedIds.length === 0) {
      return
    }
    this.deleteSelected()
  }

  onLibraryChange(): void {
    this.loadData()
    // 曲库任何变更后强制刷新胶囊文案：筛选状态可能随删除被收敛（如文件夹歌曲被全删），
    // 但收敛不一定 bump KEY_FILTER_REVISION，这里兜底保证胶囊与数据一致
    this.refreshFilterLabel()
  }

  onFilterChange(): void {
    this.applyFilters()
    this.refreshFilterLabel()
  }

  // 分隔符配置变化（设置页保存触发）：面板开着则重建候选项，再按新拆分重筛
  onArtistSeparatorsChange(): void {
    if (this.isFilterPanelVisible) {
      this.buildPanelOptions()
    }
    this.applyFilters()
  }

  // 把 DataService 当前筛选状态写入 @State，驱动胶囊 UI 刷新；
  // 组合筛选维度激活时追加标注（保持「全部歌曲」判断语义：维度激活即不再视为未筛选）
  private refreshFilterLabel(): void {
    let label: string = ''
    // 歌单筛选（P2-3）：胶囊显示歌单名（与文件夹/收藏互斥，优先级最高）
    const playlistId: string = this.dataService.getFilterPlaylistId()
    this.playlistFilterId = playlistId
    if (playlistId.length > 0) {
      const playlists: PlaylistInfo[] = this.dataService.getPlaylists()
      label = '歌单'
      for (let i = 0; i < playlists.length; i++) {
        if (playlists[i].id === playlistId) {
          label = playlists[i].name
          break
        }
      }
    } else if (this.dataService.isFavoritesSelected()) {
      label = '我的收藏'
    } else {
      const paths: string[] = this.dataService.getSelectedFolderPaths()
      if (paths.length === 1) {
        const lastSlash: number = paths[0].lastIndexOf('/')
        const lastBackslash: number = paths[0].lastIndexOf('\\')
        const sepIdx: number = lastSlash > lastBackslash ? lastSlash : lastBackslash
        label = sepIdx >= 0 ? paths[0].substring(sepIdx + 1) : paths[0]
      } else if (paths.length > 1) {
        label = paths.length + ' 个文件夹'
      } else {
        label = '全部歌曲'
      }
    }
    if (this.countActiveFilterDims() > 0) {
      label = label === '全部歌曲' ? '组合筛选' : label + ' · 筛选'
    }
    this.filterLabel = label
  }

  // 歌单集合/曲目变化（P2-3）：歌单筛选态下列表随歌单内容刷新，胶囊同步歌单名
  onPlaylistRevisionChange(): void {
    this.applyFilters()
    this.refreshFilterLabel()
  }

  // 打开「加入歌单」弹窗（P2-3）：快照歌单列表（名称 + 首数）
  openPlaylistPicker(): void {
    const rows: PickerPlaylistRow[] = []
    const playlists: PlaylistInfo[] = this.dataService.getPlaylists()
    for (let i = 0; i < playlists.length; i++) {
      const row: PickerPlaylistRow = new PickerPlaylistRow()
      row.id = playlists[i].id
      row.name = playlists[i].name
      row.count = this.dataService.getPlaylistItemSongIds(playlists[i].id).length
      rows.push(row)
    }
    this.pickerRows = rows
    this.pickerNewName = ''
    this.isPlaylistPickerVisible = true
  }

  // 选中歌曲加入已有歌单：加完关弹窗、退多选并 toast 提示
  private async addSelectedToPlaylist(playlistId: string): Promise<void> {
    await this.dataService.addSongsToPlaylist(playlistId, this.selectedIds.slice())
    this.isPlaylistPickerVisible = false
    this.exitMultiSelect()
    try {
      showToastGlassMaterial(this.getUIContext()?.getPromptAction(), '已加入歌单')
    } catch (e) {
      Logger.error(TAG, 'toast failed')
    }
  }

  // 新建歌单并加入当前选中歌曲（空名/超长不创建）
  private async createPlaylistWithSelected(): Promise<void> {
    const name: string = this.pickerNewName.trim()
    if (name.length === 0 || name.length > 30) {
      return
    }
    const created: PlaylistInfo | undefined = await this.dataService.createPlaylist(name)
    if (created !== undefined) {
      await this.addSelectedToPlaylist(created.id)
    }
  }

  private countActiveFilterDims(): number {
    return this.dataService.getFilterArtists().length + this.dataService.getFilterAlbums().length +
      this.dataService.getFilterGenres().length + this.dataService.getFilterYears().length
  }

  loadData(): void {
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
    const dimArtists: string[] = this.dataService.getFilterArtists()
    const dimAlbums: string[] = this.dataService.getFilterAlbums()
    const dimGenres: string[] = this.dataService.getFilterGenres()
    const dimYears: string[] = this.dataService.getFilterYears()
    const hasDimFilter: boolean = dimArtists.length > 0 || dimAlbums.length > 0 ||
      dimGenres.length > 0 || dimYears.length > 0
    // 歌单筛选（P2-3）：激活时仅保留歌单内曲目（与文件夹/收藏互斥，顶级列表来源）
    const playlistId: string = this.dataService.getFilterPlaylistId()
    let playlistSongIds: Set<string> | undefined = undefined
    if (playlistId.length > 0) {
      playlistSongIds = new Set<string>()
      const itemIds: string[] = this.dataService.getPlaylistItemSongIds(playlistId)
      for (let i = 0; i < itemIds.length; i++) {
        playlistSongIds.add(itemIds[i])
      }
    }
    const query: string = this.searchText.trim().toLowerCase()
    const isSearching: boolean = query.length > 0
    const result: SongInfo[] = []
    for (let i = 0; i < this.songs.length; i++) {
      const song: SongInfo = this.songs[i]
      if (isFavFilter) {
        if (!song.isFavorite) {
          continue
        }
      } else if (hasFolderFilter) {
        if (selectedPaths.indexOf(song.folderPath) < 0) {
          continue
        }
      }
      if (playlistSongIds !== undefined && !playlistSongIds.has(song.id)) {
        continue
      }
      if (hasDimFilter) {
        if (dimArtists.length > 0 && !this.songMatchesArtistFilter(song, dimArtists)) {
          continue
        }
        if (dimAlbums.length > 0 && dimAlbums.indexOf(song.album) < 0) {
          continue
        }
        if (dimGenres.length > 0 && dimGenres.indexOf(song.genre) < 0) {
          continue
        }
        if (dimYears.length > 0 && dimYears.indexOf(song.year) < 0) {
          continue
        }
      }
      result.push(song)
    }
    if (isSearching) {
      // 搜索模式：按命中权重排序（标题/歌手等前缀 > 包含 > 全拼 > 首字母缩写），截断前 200 条
      const scored: ScoredSong[] = []
      for (let i = 0; i < result.length; i++) {
        const score: number = this.searchScore(result[i], query)
        if (score > 0) {
          const item: ScoredSong = new ScoredSong()
          item.song = result[i]
          item.score = score
          scored.push(item)
        }
      }
      scored.sort((a: ScoredSong, b: ScoredSong): number => {
        return b.score - a.score
      })
      const capped: SongInfo[] = []
      for (let i = 0; i < scored.length && capped.length < SEARCH_RESULT_LIMIT; i++) {
        capped.push(scored[i].song)
      }
      this.buildDisplayItems(capped)
      return
    }
    if (this.sortMode === 'recent') {
      // 最近播放排序（P0-4）：仅展示播过的歌，lastPlayedAt 倒序前 20，覆盖常规排序
      const played: SongInfo[] = []
      for (let i = 0; i < result.length; i++) {
        if (result[i].lastPlayedAt > 0) {
          played.push(result[i])
        }
      }
      played.sort((a: SongInfo, b: SongInfo): number => {
        return b.lastPlayedAt - a.lastPlayedAt
      })
      const capped: SongInfo[] = []
      for (let i = 0; i < played.length && capped.length < RECENT_PLAY_LIMIT; i++) {
        capped.push(played[i])
      }
      this.buildDisplayItems(capped)
      return
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
    } else if (this.viewMode === 'album' || this.viewMode === 'artist') {
      // 专辑/歌手分组视图（P2-4）：组序随当前排序，组内按音轨数值序重排；
      // 分组头挂组内代表歌曲渲染封面，点击整组连播（见 groupHeaderRow）
      const groupMap: Record<string, SongInfo[]> = {}
      for (let i = 0; i < sorted.length; i++) {
        const song: SongInfo = sorted[i]
        const key: string = this.groupKeyForView(song)
        if (groupMap[key] === undefined) {
          groupMap[key] = []
        }
        groupMap[key].push(song)
      }
      const keys: string[] = Object.keys(groupMap)
      for (let gi = 0; gi < keys.length; gi++) {
        const key: string = keys[gi]
        const groupSongs: SongInfo[] = groupMap[key]
        this.sortGroupSongs(groupSongs)
        const header: DisplayItem = new DisplayItem()
        header.isHeader = true
        header.headerText = key
        header.song = groupSongs[0]
        header.headerCount = groupSongs.length
        items.push(header)
        for (let si = 0; si < groupSongs.length; si++) {
          const di: DisplayItem = new DisplayItem()
          di.isHeader = false
          di.song = groupSongs[si]
          items.push(di)
        }
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
    this.syncPlayQueue()
    const visible: SongInfo[] = []
    for (let i = 0; i < items.length && visible.length < PREFETCH_COUNT; i++) {
      if (!items[i].isHeader && items[i].song.isAvailable) {
        visible.push(items[i].song)
      }
    }
    AudioMetadataService.getInstance().prefetchAlbumCovers(
      visible, AlbumCoverSize.SMALL, CoverPriority.HIGH)
  }

  // 播放队列与首页显示顺序保持一致：把当前可见顺序（跳过分组标题）同步为播放队列
  // （KEY_SONG_LIST），播放器歌单、上一首/下一首、点击播放都基于该队列索引；
  // 队列变化后按当前播放歌曲 id 重映射 selectIndex，保证高亮与切歌定位正确。
  syncPlayQueue(): void {
    const queue: SongInfo[] = []
    for (let i = 0; i < this.displayItems.length; i++) {
      const item: DisplayItem = this.displayItems[i]
      if (!item.isHeader) {
        queue.push(item.song)
      }
    }
    AppStorage.setOrCreate(AppStorageKeyConstants.KEY_SONG_LIST, queue)
    const currentId: string = AppStorage.get<string>('uplayer_current_song_id') ?? ''
    if (currentId.length > 0) {
      let idx: number = -1
      for (let i = 0; i < queue.length; i++) {
        if (queue[i].id === currentId) {
          idx = i
          break
        }
      }
      AppStorage.setOrCreate(AppStorageKeyConstants.KEY_SELECT_INDEX, idx)
    }
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
    // 点击筛选胶囊 = 整体重置：文件夹/收藏与组合筛选维度一并清空
    this.dataService.setFilterState([], false, new FilterDimensions())
  }

  // ═══════════ 模糊搜索（S2）═══════════

  // Ctrl+F：打开搜索行并聚焦输入框。
  // requestFocus 要求节点已挂树（错误码 150003），isSearchActive 渲染搜索行后再延迟请求焦点
  onSearchFocusRequest(): void {
    this.openSearch()
  }

  openSearch(): void {
    this.isSearchActive = true
    setTimeout(() => {
      this.getUIContext()?.getFocusController().requestFocus('home_search_input')
    }, 100)
  }

  closeSearch(): void {
    this.isSearchActive = false
    if (this.searchDebounceId >= 0) {
      clearTimeout(this.searchDebounceId)
      this.searchDebounceId = -1
    }
    if (this.searchText.length > 0) {
      this.searchText = ''
      this.applyFilters()
    }
  }

  private onSearchTextChanged(value: string): void {
    this.searchText = value
    if (this.searchDebounceId >= 0) {
      clearTimeout(this.searchDebounceId)
    }
    this.searchDebounceId = setTimeout(() => {
      this.searchDebounceId = -1
      this.applyFilters()
    }, SEARCH_DEBOUNCE_MS)
  }

  // 搜索打分：query 按空白切 token，各 token 须至少命中一个字段（AND 语义），
  // 权重：标题/歌名/歌手/专辑/文件名（前缀 8 / 包含 6）> 全拼（5/4）> 首字母缩写（3/2）
  private searchScore(song: SongInfo, query: string): number {
    const tokens: string[] = this.splitSearchTokens(query)
    if (tokens.length === 0) {
      return 0
    }
    let total: number = 0
    for (let i = 0; i < tokens.length; i++) {
      const tokenScore: number = this.tokenScore(song, tokens[i])
      if (tokenScore <= 0) {
        return 0
      }
      total += tokenScore
    }
    return total
  }

  private splitSearchTokens(query: string): string[] {
    const tokens: string[] = []
    const parts: string[] = query.split(' ')
    for (let i = 0; i < parts.length; i++) {
      const part: string = parts[i].trim()
      if (part.length > 0) {
        tokens.push(part)
      }
    }
    return tokens
  }

  private tokenScore(song: SongInfo, token: string): number {
    let best: number = 0
    best = Math.max(best, this.textScore(song.title, token, 8, 6))
    best = Math.max(best, this.textScore(song.name, token, 8, 6))
    best = Math.max(best, this.textScore(song.artist, token, 8, 6))
    best = Math.max(best, this.textScore(song.album, token, 8, 6))
    best = Math.max(best, this.textScore(song.fileName, token, 8, 6))
    best = Math.max(best, this.textScore(song.pinyinFull, token, 5, 4))
    best = Math.max(best, this.textScore(song.pinyinAbbr, token, 3, 2))
    return best
  }

  private textScore(text: string, token: string, prefixScore: number, containsScore: number): number {
    if (text.length === 0) {
      return 0
    }
    const lower: string = text.toLowerCase()
    if (lower.startsWith(token)) {
      return prefixScore
    }
    if (lower.indexOf(token) >= 0) {
      return containsScore
    }
    return 0
  }

  // ═══════════ 组合筛选面板（S1）═══════════

  openFilterPanel(): void {
    this.panelArtists = this.dataService.getFilterArtists().slice()
    this.panelAlbums = this.dataService.getFilterAlbums().slice()
    this.panelGenres = this.dataService.getFilterGenres().slice()
    this.panelYears = this.dataService.getFilterYears().slice()
    this.buildPanelOptions()
    this.isFilterPanelVisible = true
  }

  closeFilterPanel(): void {
    this.isFilterPanelVisible = false
  }

  // 「完成」：把面板选择组装成 FilterDimensions 提交，
  // 触发 KEY_FILTER_REVISION → onFilterChange → applyFilters + refreshFilterLabel
  applyFilterPanel(): void {
    const dims: FilterDimensions = new FilterDimensions()
    dims.artists = this.panelArtists.slice()
    dims.albums = this.panelAlbums.slice()
    dims.genres = this.panelGenres.slice()
    dims.years = this.panelYears.slice()
    // 筛选面板只管理艺术家/专辑/流派/年份：歌单筛选由歌单页卡片控制，这里原样保留
    dims.playlistId = this.dataService.getFilterPlaylistId()
    this.dataService.setFilterState(this.dataService.getSelectedFolderPaths(),
      this.dataService.isFavoritesSelected(), dims)
    this.isFilterPanelVisible = false
  }

  // 「重置」：清空面板各维度选择并立即应用（保留文件夹/收藏筛选）
  resetFilterPanel(): void {
    this.panelArtists = []
    this.panelAlbums = []
    this.panelGenres = []
    this.panelYears = []
    this.applyFilterPanel()
  }

  private togglePanelValue(list: string[], value: string): void {
    const idx: number = list.indexOf(value)
    if (idx >= 0) {
      list.splice(idx, 1)
    } else {
      list.push(value)
    }
  }

  onChipToggle(dim: string, value: string): void {
    if (dim === 'artist') {
      this.togglePanelValue(this.panelArtists, value)
      this.panelArtists = this.panelArtists.slice()
    } else if (dim === 'album') {
      this.togglePanelValue(this.panelAlbums, value)
      this.panelAlbums = this.panelAlbums.slice()
    } else if (dim === 'genre') {
      this.togglePanelValue(this.panelGenres, value)
      this.panelGenres = this.panelGenres.slice()
    } else if (dim === 'year') {
      this.togglePanelValue(this.panelYears, value)
      this.panelYears = this.panelYears.slice()
    }
  }

  private isChipSelected(selected: string[], value: string): boolean {
    return selected.indexOf(value) >= 0
  }

  // 艺术家拆分：按当前分隔符把多艺人串拆成独立艺术家（「midnight kiss,kappa」→ 两位），
  // 拆后去首尾空白、去重；空串原样返回（归入「未知」）；无分隔符或无可拆内容时回退原串
  private splitArtistNames(artist: string): string[] {
    if (artist.length === 0) {
      return [artist]
    }
    const seps: string[] = this.artistSeparators
    if (seps.length === 0) {
      return [artist]
    }
    const names: string[] = []
    let current: string = ''
    for (let i = 0; i < artist.length; i++) {
      const ch: string = artist.charAt(i)
      if (seps.indexOf(ch) >= 0) {
        const trimmed: string = current.trim()
        if (trimmed.length > 0 && names.indexOf(trimmed) < 0) {
          names.push(trimmed)
        }
        current = ''
      } else {
        current += ch
      }
    }
    const last: string = current.trim()
    if (last.length > 0 && names.indexOf(last) < 0) {
      names.push(last)
    }
    if (names.length === 0) {
      return [artist]
    }
    return names
  }

  // 艺术家筛选匹配：歌曲任一拆分后艺术家命中已选值即保留；
  // 同时回退匹配原始整串，兼容升级前按未拆分串保存的旧筛选状态
  private songMatchesArtistFilter(song: SongInfo, dimArtists: string[]): boolean {
    if (dimArtists.indexOf(song.artist) >= 0) {
      return true
    }
    const names: string[] = this.splitArtistNames(song.artist)
    for (let i = 0; i < names.length; i++) {
      if (dimArtists.indexOf(names[i]) >= 0) {
        return true
      }
    }
    return false
  }

  // 候选项构建：各维度按值聚合计数、数量降序（并列按名称），空值归入「未知」；
  // 艺术家维度先按分隔符拆分成独立艺术家再聚合（多艺人歌曲对每位艺术家各计 +1）
  private buildPanelOptions(): void {
    const artistMap: Record<string, number> = {}
    const albumMap: Record<string, number> = {}
    const genreMap: Record<string, number> = {}
    const yearMap: Record<string, number> = {}
    for (let i = 0; i < this.songs.length; i++) {
      const song: SongInfo = this.songs[i]
      const songArtists: string[] = this.splitArtistNames(song.artist)
      for (let ai = 0; ai < songArtists.length; ai++) {
        this.bumpOptionCount(artistMap, songArtists[ai])
      }
      this.bumpOptionCount(albumMap, song.album)
      this.bumpOptionCount(genreMap, song.genre)
      this.bumpOptionCount(yearMap, song.year)
    }
    this.panelArtistOptions = this.optionsFromMap(artistMap)
    this.panelAlbumOptions = this.optionsFromMap(albumMap)
    this.panelGenreOptions = this.optionsFromMap(genreMap)
    this.panelYearOptions = this.optionsFromMap(yearMap)
  }

  private bumpOptionCount(map: Record<string, number>, value: string): void {
    if (map[value] === undefined) {
      map[value] = 0
    }
    map[value] = map[value] + 1
  }

  private optionsFromMap(map: Record<string, number>): FilterChipOption[] {
    const keys: string[] = Object.keys(map)
    const options: FilterChipOption[] = []
    for (let i = 0; i < keys.length; i++) {
      const key: string = keys[i]
      const option: FilterChipOption = new FilterChipOption()
      option.value = key
      option.label = key.length > 0 ? key : '未知'
      option.count = map[key]
      options.push(option)
    }
    options.sort((a: FilterChipOption, b: FilterChipOption): number => {
      if (b.count !== a.count) {
        return b.count - a.count
      }
      return a.label.localeCompare(b.label)
    })
    const capped: FilterChipOption[] = []
    for (let i = 0; i < options.length && i < FILTER_PANEL_OPTION_LIMIT; i++) {
      capped.push(options[i])
    }
    return capped
  }

  toggleViewMode(): void {
    // 四态循环（P2-4）：平铺 → 文件夹 → 专辑 → 歌手
    if (this.viewMode === 'flat') {
      this.viewMode = 'folder'
    } else if (this.viewMode === 'folder') {
      this.viewMode = 'album'
    } else if (this.viewMode === 'album') {
      this.viewMode = 'artist'
    } else {
      this.viewMode = 'flat'
    }
    this.dataService.setViewMode(this.viewMode)
    this.applyFilters()
  }

  // 视图胶囊文案（P2-4）
  viewModeLabel(): string {
    if (this.viewMode === 'folder') {
      return '文件夹'
    }
    if (this.viewMode === 'album') {
      return '专辑'
    }
    if (this.viewMode === 'artist') {
      return '歌手'
    }
    return '平铺'
  }

  // 专辑/歌手分组的取键字段（P2-4）：空值归入「未知」组
  private groupKeyForView(song: SongInfo): string {
    if (this.viewMode === 'album') {
      return song.album.length > 0 ? song.album : '未知专辑'
    }
    return song.artist.length > 0 ? song.artist : '未知艺术家'
  }

  // 音轨数值（P2-4）：解析 "3/12" → 3；非法/缺失返回 0（由调用方兜底 addedTime）
  private trackNumber(song: SongInfo): number {
    const raw: string = song.track
    const slashIdx: number = raw.indexOf('/')
    const text: string = slashIdx >= 0 ? raw.substring(0, slashIdx) : raw
    const parsed: number = parseInt(text)
    return Number.isFinite(parsed) && parsed > 0 ? parsed : 0
  }

  // 专辑/歌手组内排序（P2-4）：歌手视图先按专辑名二级分组，再按音轨数值序，兜底加入时间
  private sortGroupSongs(groupSongs: SongInfo[]): void {
    const byAlbum: boolean = this.viewMode === 'artist'
    groupSongs.sort((a: SongInfo, b: SongInfo): number => {
      if (byAlbum) {
        const albumCmp: number = a.album.localeCompare(b.album)
        if (albumCmp !== 0) {
          return albumCmp
        }
      }
      const at: number = this.trackNumber(a)
      const bt: number = this.trackNumber(b)
      if (at !== bt) {
        return at - bt
      }
      return a.addedTime - b.addedTime
    })
  }

  // 点击专辑/歌手分组头（P2-4）：整组连播——播放队列临时收窄为组内可播歌曲后播第一首；
  // 下一次筛选/曲库变化经 syncPlayQueue 自动恢复全量可见队列
  playGroupFromHeader(headerText: string): void {
    const groupSongs: SongInfo[] = []
    let started: boolean = false
    for (let i = 0; i < this.displayItems.length; i++) {
      const it: DisplayItem = this.displayItems[i]
      if (!started) {
        if (it.isHeader && it.headerText === headerText) {
          started = true
        }
        continue
      }
      if (it.isHeader) {
        break
      }
      if (it.song.isAvailable) {
        groupSongs.push(it.song)
      }
    }
    if (groupSongs.length === 0) {
      return
    }
    AppStorage.setOrCreate(AppStorageKeyConstants.KEY_SONG_LIST, groupSongs)
    this.avPlayerService.playSongAt(0).catch((err: Error): void => {
      Logger.error(TAG, `group play failed: ${JSON.stringify(err)}`)
    })
  }

  switchSortMode(): void {
    if (this.sortMode === 'name') {
      this.sortMode = 'date'
    } else if (this.sortMode === 'date') {
      this.sortMode = 'custom'
    } else if (this.sortMode === 'custom') {
      this.sortMode = 'recent'
    } else {
      this.sortMode = 'name'
    }
    this.dataService.setSortMode(this.sortMode)
    this.applyFilters()
  }

  // 全局悬浮加号已上提到 Index：本页只上报「加号是否应显示」
  // （多选态隐藏 + 滚动隐藏设置 + 滚动方向），由 Index 读取渲染
  private publishPlusVisible(): void {
    AppStorage.setOrCreate(AppStorageKeyConstants.KEY_HOME_PLUS_VISIBLE,
      !this.isMultiSelectMode && (this.isPlusVisible || !this.plusButtonScrollHide))
  }

  // 设置页「向下滑动时隐藏加号按钮」变更：立即按新值重算并上报加号可见性
  onPlusScrollHideChange(): void {
    this.publishPlusVisible()
  }

  async onPlusClick(): Promise<void> {
    if (this.context === undefined) {
      return
    }
    await importSongsWithToast(this.context, this.getUIContext()?.getPromptAction())
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
    this.syncPlayQueue()
  }

  onSongTap(item: SongInfo): void {
    if (this.isMultiSelectMode) {
      this.toggleSelectItem(item.id)
      return
    }
    // 点击播放按播放队列（与首页可见顺序一致）定位索引
    const queue: SongInfo[] | undefined = AppStorage.get<SongInfo[]>(AppStorageKeyConstants.KEY_SONG_LIST)
    if (queue === undefined) {
      return
    }
    for (let i = 0; i < queue.length; i++) {
      if (queue[i].id === item.id) {
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

  toggleSelectAll(): boolean {
    if (this.isAllSelected()) {
      this.selectedIds = []
      return false
    }
    this.selectedIds = this.getVisibleSongIds()
    return true
  }

  exitMultiSelect(): void {
    this.isMultiSelectMode = false
    this.selectedIds = []
  }

  deleteSelected(): void {
    // 歌单筛选态（P2-3）：删除按钮语义 = 移出歌单——只删 playlist_items 关联行，不动歌曲文件；
    // 移出后 bump KEY_PLAYLIST_REVISION → onPlaylistRevisionChange 重新过滤列表
    if (this.playlistFilterId.length > 0) {
      const playlistId: string = this.playlistFilterId
      const ids: string[] = this.selectedIds.slice()
      this.isMultiSelectMode = false
      this.selectedIds = []
      this.dataService.removeSongsFromPlaylist(playlistId, ids).catch((err: Error) => {
        Logger.error(TAG, `removeSongsFromPlaylist failed: ${JSON.stringify(err)}`)
      })
      return
    }
    // 走统一删除入口：全链路清理（播放队列/筛选状态/文件夹列表/当前播放），
    // 否则删除某文件夹全部歌曲后，顶部筛选胶囊仍残留该文件夹名
    const result: LibraryDeleteResult = this.dataService.removeSongsByIds(this.selectedIds.slice())
    this.isMultiSelectMode = false
    this.selectedIds = []
    this.applyLibraryDeleteResult(result)
  }

  deleteSongById(songId: string): void {
    // 左滑删除同样走统一删除入口，与多选删除共用清理链路
    const result: LibraryDeleteResult = this.dataService.removeSongsByIds([songId])
    this.applyLibraryDeleteResult(result)
  }

  private applyLibraryDeleteResult(result: LibraryDeleteResult): void {
    if (result.currentSongRemoved) {
      AVPlayerService.getInstance().stop().catch((err: Error) => {
        Logger.error(TAG, `stop player after delete failed: ${JSON.stringify(err)}`)
      })
      AVSessionController.getInstance().clearCurrentMedia()
      LiveViewService.getInstance().stopLiveView().catch((err: Error) => {
        Logger.error(TAG, `stop live view after delete failed: ${JSON.stringify(err)}`)
      })
    }
    this.loadData()
    this.refreshFilterLabel()
  }

  isSelected(id: string): boolean {
    return this.selectedIds.indexOf(id) >= 0
  }

  getSortLabel(): string {
    if (this.sortMode === 'name') {
      return '名称排序'
    } else if (this.sortMode === 'date') {
      return '添加时间'
    } else if (this.sortMode === 'recent') {
      return '最近播放'
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
        songs, AlbumCoverSize.SMALL, CoverPriority.MEDIUM)
    }
  }

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
            //TODO 手柄部分不需要长按就可以排序，歌曲项部分要长按才能拖动
            LazyForEach(this.displayDataSource, (item: DisplayItem, index: number) => {
              ListItem() {
                if (item.isHeader) {
                  if (this.viewMode === 'album' || this.viewMode === 'artist') {
                    this.groupHeaderRow(item)
                  } else {
                    this.folderHeaderRow(item.headerText)
                  }
                } else if (!item.isHeader) {
                  this.songItemRow(item.song)
                }
              }
              .reuseId(item.isHeader ? 'header' : 'song')
              // 左滑露出删除：非多选态的歌曲行启用（多选态行内有勾选与手柄拖拽，避免手势冲突）
              .swipeAction({
                end: (!item.isHeader && !this.isMultiSelectMode) ? {
                  builder: (): void => {
                    this.songSwipeDeleteButton(item.song)
                  }
                } : undefined
              })
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
                .height(this.bottomOverlayInset())
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
          .onDidScroll((scrollOffset: number) => {
            // scrollOffset 为本帧带符号偏移：向下滚动为正、向上为负
            if (scrollOffset > 10) {
              if (this.isPlusVisible) {
                this.isPlusVisible = false
                this.publishPlusVisible()
              }
              this.prefetchInScrollDirection(this.scroller.currentOffset().yOffset, true)
            } else if (scrollOffset < 0) {
              if (!this.isPlusVisible) {
                this.isPlusVisible = true
                this.publishPlusVisible()
              }
              this.prefetchInScrollDirection(this.scroller.currentOffset().yOffset, false)
            }
          })

          if (this.displayItems.length === 0) {
            Text(this.searchText.trim().length > 0 ? '未找到匹配的歌曲' : '暂无歌曲，点击添加')
              .fontSize(Math.round(14 * this.fontSizeScale))
              .fontColor($r('app.color.text_twenty_color'))
              .textAlign(TextAlign.Center)
              .onClick(() => {
                if (this.searchText.trim().length === 0) {
                  this.onPlusClick()
                }
              })
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

        Column() {
          Row() {
            Text(this.filterLabel)
              .fontSize(Math.round(14 * this.fontSizeScale))
              .fontColor($r('app.color.text_primary'))
              .fontWeight(FontWeight.Bold)
              .padding({ left: 12, right: 12, top: 6, bottom: 6 })
              .backgroundColor(this.filterLabel === '全部歌曲' ? 'rgba(0,0,0,0.05)' : ColorHelper.hexToRgba(this.primaryColor, 0.12))
              .borderRadius(16)
              .onClick(() => { this.clearFilters() })

            // 组合筛选入口（S1）：维度激活时高亮提示
            Text('筛选')
              .fontSize(Math.round(12 * this.fontSizeScale))
              .fontColor($r('app.color.text_primary'))
              .padding({ left: 10, right: 10, top: 6, bottom: 6 })
              .margin({ left: 8 })
              .backgroundColor(this.countActiveFilterDims() > 0 ?
                ColorHelper.hexToRgba(this.primaryColor, 0.28) : 'rgba(0,0,0,0.05)')
              .borderRadius(16)
              .onClick(() => { this.openFilterPanel() })

            Blank()

            // 模糊搜索入口（S2）：展开/收起搜索行，Ctrl+F 亦可触发
            Row() {
              Image($r('app.media.ic_public_search'))
                .width(16).height(16)
                .fillColor($r('app.color.text_primary'))
            }
            .padding({ left: 10, right: 10, top: 8, bottom: 8 })
            .backgroundColor(ColorHelper.hexToRgba(this.primaryColor, 0.12))
            .borderRadius(16)
            .onClick(() => {
              if (this.isSearchActive) {
                this.closeSearch()
              } else {
                this.openSearch()
              }
            })

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
            .margin({ left: 8 })
            .backgroundColor(ColorHelper.hexToRgba(this.primaryColor, 0.12))
            .borderRadius(16)
            .onClick(() => { this.switchSortMode() })

            Row() {
              Text(this.viewModeLabel())
                .fontSize(Math.round(12 * this.fontSizeScale))
                .fontColor($r('app.color.text_primary'))
            }
            .padding({ left: 10, right: 10, top: 6, bottom: 6 })
            .margin({ left: 8 })
            .backgroundColor(ColorHelper.hexToRgba(this.primaryColor, 0.12))
            .borderRadius(16)
            .onClick(() => { this.toggleViewMode() })
          }
          .width('100%')

          if (this.isSearchActive) {
            this.searchInputRow()
          }
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 6 })
        .position({ top: this.topContentPadding - this.scaledSize(8) })
        .onAreaChange((oldValue: Area, newValue: Area) => {
          this.onHeaderRowAreaChange(newValue)
        })
      }
      .width('100%')
      .height(this.listTopPadding())
      .position({ top: 0 })
      .clip(true)
      // BLOCK_HIERARCHY：自身+子节点（筛选/排序/视图按钮）响应，同时阻止下方歌曲列表穿透响应；
      // 不能用 Block——Block 会连子节点的触摸测试一起阻塞，导致这一行按钮全部点不了
      .hitTestBehavior(HitTestMode.BLOCK_HIERARCHY)
      .zIndex(2)

      // 多选菜单栏：落在问候语内容带内（替换问候语的位置），
      // 入场/退场由 transition 驱动，入场延迟让问候语先上滑隐藏
      if (this.isMultiSelectMode) {
        Row() {
          // 返回按钮：与设置页/播放页共用同一组件，圆形玻璃材质与底部 Tab 栏同源
          GlassBackButton({
            clickSize: this.scaledSize(48),
            iconSize: this.scaledSize(15),
            iconColor: $r('app.color.text_primary'),
            iconOpacity: 0.9,
            onBack: () => { this.exitMultiSelect() }
          })

          Text('已选 ' + this.selectedIds.length + ' 首')
            .fontSize(Math.round(14 * this.fontSizeScale))
            .fontColor($r('app.color.text_primary'))
          Blank()
          // 全选按钮 - 带图标
          Row({ space: 4 }) {
            Image(this.isAllSelected() ? $r('app.media.ic_public_deselect_all') : $r('app.media.ic_public_select_all'))
              .width(Math.round(16 * this.fontSizeScale))
              .height(Math.round(16 * this.fontSizeScale))
              .fillColor(this.primaryColor)
            Text(this.isAllSelected() ? '取消全选' : '全选')
              .fontSize(Math.round(14 * this.fontSizeScale))
              .fontColor(this.primaryColor)
          }
          .margin({ right: 16 })
          .onClick(() => { this.toggleSelectAll() })

          // 加入歌单（P2-3）- 带图标：弹窗选择目标歌单或新建
          Row({ space: 4 }) {
            Image($r('app.media.ic_public_add_norm_filled'))
              .width(Math.round(16 * this.fontSizeScale))
              .height(Math.round(16 * this.fontSizeScale))
              .fillColor(this.primaryColor)
            Text('加入歌单')
              .fontSize(Math.round(14 * this.fontSizeScale))
              .fontColor(this.primaryColor)
          }
          .margin({ right: 16 })
          .onClick(() => { this.openPlaylistPicker() })

          // 删除按钮 - 带图标；歌单筛选态（P2-3）语义变为「移出歌单」（不删文件）
          Row({ space: 4 }) {
            Image($r('app.media.ic_public_delete'))
              .width(Math.round(16 * this.fontSizeScale))
              .height(Math.round(16 * this.fontSizeScale))
              .fillColor(StyleConstants.COLOR_DANGER_RED)
            Text(this.playlistFilterId.length > 0 ? '移出歌单' : '删除')
              .fontSize(Math.round(14 * this.fontSizeScale))
              .fontColor(StyleConstants.COLOR_DANGER_RED)
          }
          .onClick(() => { this.deleteSelected() })
        }
        .width('100%')
        .height(this.multiSelectBarHeight())
        .padding({ left: 4, right: this.multiSelectBarRightPadding() })
        .backgroundColor(Color.Transparent)
        // 磨砂层常挂（液态玻璃启用时作为材质底层兜底，与 Tab 栏策略一致）；
        // 经典样式下不挂任何背景效果
        .backgroundEffect(this.multiSelectBarBlurEnabled() ? {
          radius: 20,
          saturation: 1.0,
          brightness: 1.0
        } : undefined)
        .systemMaterial(this.multiSelectBarMaterial())
        .position({ top: this.multiSelectBarTop(), left: 0 })
        .zIndex(2)
        .transition(TransitionEffect.asymmetric(
          TransitionEffect.OPACITY
            .combine(TransitionEffect.translate({ y: this.scaledSize(28) }))
            .animation({
              duration: StyleConstants.ANIMATION_MULTI_BAR_ENTER_DURATION,
              curve: Curve.EaseOut,
              delay: StyleConstants.ANIMATION_MULTI_BAR_ENTER_DELAY
            }),
          TransitionEffect.OPACITY
            .combine(TransitionEffect.translate({ y: this.scaledSize(28) }))
            .animation({
              duration: StyleConstants.ANIMATION_MULTI_BAR_EXIT_DURATION,
              curve: Curve.EaseIn
            })
        ))
      }

      // 组合筛选面板（S1）：半透明遮罩 + 顶部下拉卡片；遮罩点击直接关闭（不应用未提交的修改）
      if (this.isFilterPanelVisible) {
        Stack({ alignContent: Alignment.Top }) {
          Column()
            .width('100%')
            .height('100%')
            .backgroundColor('rgba(0,0,0,0.35)')
            .onClick(() => { this.closeFilterPanel() })

          Column() {
            Row() {
              Text('筛选')
                .fontSize(Math.round(16 * this.fontSizeScale))
                .fontWeight(FontWeight.Bold)
                .fontColor($r('app.color.text_primary'))
              Blank()
              Text('重置')
                .fontSize(Math.round(14 * this.fontSizeScale))
                .fontColor($r('app.color.text_sixty_color'))
                .onClick(() => { this.resetFilterPanel() })
              Text('完成')
                .fontSize(Math.round(14 * this.fontSizeScale))
                .fontColor(Color.White)
                .padding({ left: 14, right: 14, top: 6, bottom: 6 })
                .backgroundColor(this.primaryColor)
                .borderRadius(14)
                .margin({ left: 16 })
                .onClick(() => { this.applyFilterPanel() })
            }
            .width('100%')
            .alignItems(VerticalAlign.Center)

            Scroll() {
              Column() {
                this.filterChipSection('艺术家', this.panelArtistOptions, this.panelArtists, 'artist')
                this.filterChipSection('专辑', this.panelAlbumOptions, this.panelAlbums, 'album')
                this.filterChipSection('流派', this.panelGenreOptions, this.panelGenres, 'genre')
                this.filterChipSection('年份', this.panelYearOptions, this.panelYears, 'year')
              }
              .width('100%')
              .alignItems(HorizontalAlign.Start)
            }
            .layoutWeight(1)
            .width('100%')
            .align(Alignment.Start)
            .scrollBar(BarState.Auto)
          }
          .width('92%')
          .constraintSize({ maxHeight: '62%' })
          .padding(16)
          .borderRadius(20)
          .backgroundColor($r('app.color.page_background_sm'))
          .margin({ top: this.listTopPadding() })
        }
        .width('100%')
        .height('100%')
        .zIndex(20)
        .transition(TransitionEffect.OPACITY)
      }

      // 「加入歌单」弹窗（P2-3）：目标歌单列表 + 新建歌单并加入
      if (this.isPlaylistPickerVisible) {
        Stack({ alignContent: Alignment.Top }) {
          Column()
            .width('100%')
            .height('100%')
            .backgroundColor('rgba(0,0,0,0.35)')
            .onClick(() => { this.isPlaylistPickerVisible = false })

          Column() {
            Row() {
              Text('加入歌单')
                .fontSize(Math.round(16 * this.fontSizeScale))
                .fontWeight(FontWeight.Bold)
                .fontColor($r('app.color.text_primary'))
              Blank()
              Text('取消')
                .fontSize(Math.round(14 * this.fontSizeScale))
                .fontColor($r('app.color.text_sixty_color'))
                .padding({ left: 14, right: 14, top: 6, bottom: 6 })
                .onClick(() => { this.isPlaylistPickerVisible = false })
            }
            .width('100%')
            .alignItems(VerticalAlign.Center)

            // 新建歌单并加入：输入名称即建即加
            Row({ space: 10 }) {
              TextInput({ placeholder: '新建歌单名称' })
                .layoutWeight(1)
                .height(this.scaledSize(36))
                .fontSize(Math.round(14 * this.fontSizeScale))
                .backgroundColor('rgba(0,0,0,0.04)')
                .borderRadius(12)
                .onChange((value: string) => {
                  this.pickerNewName = value
                })
              Text('创建并加入')
                .fontSize(Math.round(13 * this.fontSizeScale))
                .fontColor(Color.White)
                .padding({ left: 12, right: 12, top: 8, bottom: 8 })
                .borderRadius(14)
                .backgroundColor(this.primaryColor)
                .onClick(() => {
                  this.createPlaylistWithSelected().catch((err: Error) => {
                    Logger.error(TAG, `createPlaylistWithSelected failed: ${JSON.stringify(err)}`)
                  })
                })
            }
            .width('100%')
            .margin({ top: 12 })

            if (this.pickerRows.length === 0) {
              Text('还没有歌单，输入名称创建一个吧')
                .fontSize(Math.round(13 * this.fontSizeScale))
                .fontColor($r('app.color.text_twenty_color'))
                .width('100%')
                .textAlign(TextAlign.Center)
                .margin({ top: 24 })
            } else {
              Scroll() {
                Column() {
                  ForEach(this.pickerRows, (row: PickerPlaylistRow) => {
                    Row() {
                      Image($r('app.media.ic_public_music'))
                        .width(20)
                        .height(20)
                        .fillColor($r('app.color.text_sixty_color'))
                        .margin({ right: 12 })
                      Text(row.name)
                        .fontSize(Math.round(14 * this.fontSizeScale))
                        .fontColor($r('app.color.text_primary'))
                        .maxLines(1)
                        .textOverflow({ overflow: TextOverflow.Ellipsis })
                        .layoutWeight(1)
                      Text(row.count + ' 首')
                        .fontSize(Math.round(12 * this.fontSizeScale))
                        .fontColor($r('app.color.text_sixty_color'))
                        .margin({ left: 12 })
                    }
                    .width('100%')
                    .padding({ top: 12, bottom: 12 })
                    .onClick(() => {
                      this.addSelectedToPlaylist(row.id).catch((err: Error) => {
                        Logger.error(TAG, `addSelectedToPlaylist failed: ${JSON.stringify(err)}`)
                      })
                    })
                  }, (row: PickerPlaylistRow) => row.id + '_' + row.count)
                }
                .width('100%')
              }
              .layoutWeight(1)
              .width('100%')
              .margin({ top: 4 })
              .scrollBar(BarState.Auto)
            }
          }
          .width('92%')
          .constraintSize({ maxHeight: '62%' })
          .padding(16)
          .borderRadius(20)
          .backgroundColor($r('app.color.page_background_sm'))
          .margin({ top: this.listTopPadding() })
        }
        .width('100%')
        .height('100%')
        .zIndex(20)
        .transition(TransitionEffect.OPACITY)
      }

      // 全局悬浮加号由 Index 统一渲染（首页/歌单共用，切页不位移，设置页隐藏），
      // 可见性由 publishPlusVisible 上报，本页不再挂按钮
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

  // 专辑/歌手分组头（P2-4）：代表封面 + 组名 + 曲目数，整行点击连播组内歌曲
  @Builder
  groupHeaderRow(item: DisplayItem): void {
    Row({ space: this.scaledSize(10) }) {
      AlbumCover({ song: item.song, coverWidth: this.scaledSize(40), coverHeight: this.scaledSize(40),
        coverRadius: this.scaledSize(8), decodeSize: AlbumCoverSize.SMALL })

      Column({ space: 2 }) {
        Text(item.headerText)
          .fontSize(Math.round(15 * this.fontSizeScale))
          .fontColor($r('app.color.text_primary'))
          .fontWeight(FontWeight.Medium)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        Text(`${item.headerCount} 首`)
          .fontSize(Math.round(12 * this.fontSizeScale))
          .fontColor($r('app.color.text_sixty_color'))
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      Image($r('app.media.ic_public_play'))
        .width(this.scaledSize(22)).height(this.scaledSize(22))
        .fillColor($r('app.color.text_sixty_color'))
    }
    .width('100%')
    .padding({
      left: this.scaledSize(16), right: this.scaledSize(16),
      top: this.scaledSize(8), bottom: this.scaledSize(8)
    })
    .margin({ top: this.scaledSize(4) })
    .borderRadius(10)
    .backgroundColor('rgba(0,0,0,0.02)')
    .onClick(() => {
      this.playGroupFromHeader(item.headerText)
    })
  }

  // 模糊搜索输入行（S2）：随搜索激活显示在胶囊行下方，高度并入 headerRowHeight 自动下推列表
  @Builder
  searchInputRow(): void {
    Row({ space: 8 }) {
      Image($r('app.media.ic_public_search'))
        .width(16).height(16)
        .fillColor($r('app.color.text_sixty_color'))

      TextInput({ text: this.searchText, placeholder: '搜索歌曲 / 歌手 / 专辑 / 拼音' })
        .id('home_search_input')
        .layoutWeight(1)
        .height(this.scaledSize(32))
        .fontSize(Math.round(14 * this.fontSizeScale))
        .placeholderFont({ size: Math.round(14 * this.fontSizeScale) })
        .placeholderColor($r('app.color.text_twenty_color'))
        .fontColor($r('app.color.text_primary'))
        .caretColor(this.primaryColor)
        .backgroundColor(Color.Transparent)
        .padding({ left: 0, right: 0 })
        .onChange((value: string) => {
          this.onSearchTextChanged(value)
        })

      if (this.searchText.length > 0) {
        Image($r('app.media.ic_public_close'))
          .width(16).height(16)
          .fillColor($r('app.color.text_sixty_color'))
          .onClick(() => {
            this.searchText = ''
            this.applyFilters()
          })
      }

      Text('取消')
        .fontSize(Math.round(14 * this.fontSizeScale))
        .fontColor($r('app.color.text_sixty_color'))
        .onClick(() => { this.closeSearch() })
    }
    .width('100%')
    .margin({ top: 8 })
    .padding({ left: 12, right: 12, top: 4, bottom: 4 })
    .borderRadius(18)
    .backgroundColor('rgba(0,0,0,0.05)')
    .alignItems(VerticalAlign.Center)
  }

  // 筛选面板单维度分区（S1）：标题 + 芯片流式换行，多选高亮
  @Builder
  filterChipSection(sectionTitle: string, options: FilterChipOption[], selected: string[], dim: string): void {
    if (options.length > 0) {
      Column() {
        Text(sectionTitle)
          .fontSize(Math.round(13 * this.fontSizeScale))
          .fontColor($r('app.color.text_sixty_color'))
          .margin({ bottom: 8 })
        Flex({ wrap: FlexWrap.Wrap }) {
          ForEach(options, (option: FilterChipOption) => {
            Text(option.label + ' ' + option.count)
              .fontSize(Math.round(12 * this.fontSizeScale))
              .fontColor(this.isChipSelected(selected, option.value) ?
                this.primaryColor : $r('app.color.text_primary'))
              .padding({ left: 10, right: 10, top: 5, bottom: 5 })
              .margin({ right: 8, bottom: 8 })
              .borderRadius(14)
              .backgroundColor(this.isChipSelected(selected, option.value) ?
                ColorHelper.hexToRgba(this.primaryColor, 0.18) : 'rgba(0,0,0,0.05)')
              .onClick(() => {
                this.onChipToggle(dim, option.value)
              })
          }, (option: FilterChipOption) => dim + '_' + option.value)
        }
        .width('100%')
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .margin({ bottom: 12 })
    }
  }

  @Builder
  songItemRow(item: SongInfo): void {
    Row() {
      // 拖拽手柄：只有按住该手柄上下拖动才会触发排序。
      // 手柄区域 Block 阻断事件冒泡——不会误触行的长按/点击，也不影响列表其他区域的正常滚动。
      if (this.canDragSort() && this.isMultiSelectMode && this.viewMode === 'flat') {
        Row() {
          Image($r('app.media.ic_public_drag_handle'))
            .width(this.scaledSize(22))
            .height(this.scaledSize(22))
            .fillColor('#888888')
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
        Image(this.isSelected(item.id) ? $r('app.media.ic_public_todo_filled') : $r('app.media.ic_public_todo'))
          .width(this.scaledSize(22))
          .height(this.scaledSize(22))
          .fillColor(this.isSelected(item.id) ? this.primaryColor : $r('app.color.text_sixty_color'))
          .margin({ right: this.scaledSize(16) })
      }

      AlbumCover({ song: item, coverWidth: this.scaledSize(36), coverHeight: this.scaledSize(36),
        coverRadius: this.scaledSize(6), decodeSize: AlbumCoverSize.SMALL })
        .margin({ right: this.scaledSize(10) })

      Column() {
        Text(item.title.length > 0 ? item.title : item.name)
          .fontSize(Math.round(15 * this.fontSizeScale))
          .fontColor(item.isAvailable ? $r('app.color.text_primary') : $r('app.color.text_sixty_color'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        Row() {
          Text(item.artist.length > 0 ? item.artist : '未知歌手')
            .fontSize(Math.round(12 * this.fontSizeScale))
            .fontColor($r('app.color.text_sixty_color'))
          if (item.folderName.length > 0 && item.isAvailable) {
            Text(' · ' + item.folderName)
              .fontSize(Math.round(12 * this.fontSizeScale))
              .fontColor($r('app.color.text_twenty_color'))
          }
        }
        .width('100%')
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
                showToastGlassMaterial(this.getUIContext()?.getPromptAction(), '已添加到下一首播放')
              } catch (e) {
                Logger.error(TAG, 'toast failed')
              }
            })
        }
        .margin({ right: this.scaledSize(16) })
      }

      Image(item.isFavorite ? $r('app.media.ic_public_favor_filled') : $r('app.media.ic_public_favor'))
        .width(this.scaledSize(22)).height(this.scaledSize(22))
        .fillColor(item.isFavorite ? StyleConstants.COLOR_DANGER_RED : $r('app.color.text_sixty_color'))
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
      // 单击与长按必须先组成互斥手势组，再整体作为并行手势挂到行上。
      // 若直接给行挂 .onClick 再并行挂 LongPressGesture，二者会被合成并行组：
      // 长按成功后松手仍会补发一次单击，把刚长按选中的项又取消掉。
      GestureGroup(GestureMode.Exclusive,
        TapGesture({ count: 1, fingers: 1 })
          .onAction(() => {
            if (!item.isAvailable && !this.isMultiSelectMode) {
              try {
                showToastGlassMaterial(this.getUIContext()?.getPromptAction(), '歌曲可能已被删除或移动')
              } catch (e) {
                Logger.error(TAG, 'unavailable toast failed')
              }
              return
            }
            this.onSongTap(item)
          }),
        LongPressGesture({ repeat: false })
          .onAction(() => {
            this.onSongLongPress(item)
          })
      )
    )
  }

  @Builder
  songSwipeDeleteButton(song: SongInfo): void {
    Row() {
      Row() {
        Image($r('app.media.ic_public_delete'))
          .width(this.scaledSize(16))
          .height(this.scaledSize(16))
          .fillColor(Color.White)
      }
      .height(this.scaledSize(36))
      .width(this.scaledSize(36))
      .borderRadius(this.scaledSize(18))
      .backgroundColor(StyleConstants.COLOR_DANGER_RED)
      .justifyContent(FlexAlign.Center)
      .alignItems(VerticalAlign.Center)
      .margin({ right: this.scaledSize(12) })
      .onClick(() => {
        this.deleteSongById(song.id)
      })
    }
    .width(this.scaledSize(48))
    .height('100%')
    .justifyContent(FlexAlign.End)
    .alignItems(VerticalAlign.Center)
  }
}
