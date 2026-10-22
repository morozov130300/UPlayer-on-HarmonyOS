import { BusinessError } from '@kit.BasicServicesKit';
import { curves } from '@kit.ArkUI';
import { AVVolumePanel } from '@kit.AudioKit';
import { effectKit } from '@kit.ArkGraphics2D';
import { image } from '@kit.ImageKit';
import { common, ConfigurationConstant } from '@kit.AbilityKit';
import { LyricsComponent } from './LyricsComponent';
import { MusicInfoComponent } from './MusicInfoComponent';
import { StyleConstants } from '../common/constants/StyleConstants';
import { PlayerConstants } from '../common/constants/PlayerConstants';
import { SongInfo } from '../model/SongInfo';
import Logger from '../common/utils/Logger';
import { ColorConversion } from '../common/utils/ColorConversion';
import { WindowInfo } from '../common/utils/WindowUtil';
import { AppStorageKeyConstants } from '../common/constants/AppStorageKeyConstants';
import { AlbumCoverLease, AlbumCoverSize, AudioMetadataService } from '../service/AudioMetadataService';
import { DataService } from '../service/DataService';
import { GlassBackButton } from './GlassBackButton';
import { MediaTools } from '../common/utils/mediautils/MediaTools';
import { PlayerFlyingCover } from './PlayerFlyingCover';

const TAG = 'PlayerInfoComponent'

// Area 里的 Length/Position 可能是字符串或缺失，统一转成有限数值，避免 NaN 污染坐标计算
function toFiniteNumber(value: Length | undefined): number {
  const result: number = Number(value)
  return isFinite(result) ? result : 0
}

@Component
export struct PlayerInfoComponent {
  @ObjectLink @Watch('mainWindowInfoChange') mainWindowInfo: WindowInfo;
  @StorageProp(AppStorageKeyConstants.KEY_SELECT_INDEX) @Watch('getImageColor') selectIndex: number = 0;
  // 按 id 解析当前播放歌曲，避免队列下标失配导致背景与实际播放不一致
  @StorageProp('uplayer_current_song_id') @Watch('getImageColor') currentSongId: string = '';
  @StorageLink(AppStorageKeyConstants.KEY_IMAGE_COLOR) @Watch('onImageColorChange') imageColor: string = 'rgba(0, 0, 2, 1.00)';
  @StorageLink(AppStorageKeyConstants.KEY_TOP_HEIGHT) topHeight: number = 0;
  @StorageLink(AppStorageKeyConstants.KEY_BOTTOM_HEIGHT) bottomHeight: number = 0;
  @State imageLabel: PixelMap | Resource = $r('app.media.ic_public_music');
  @State imageLabelIsFallback: boolean = true;
  @State isBackgroundReady: boolean = false;
  @State isShowControl: boolean = true;
  @StorageLink(AppStorageKeyConstants.KEY_PAGE_SHOW_TIME) pageShowTime: number = 0;
  // 歌词偏移滑轨是否展开：展开期间禁用 Swiper 横滑，否则横向拖拽会被翻页手势抢走，滑块拖不动
  @StorageLink(AppStorageKeyConstants.KEY_LYRIC_OFFSET_PANEL) lyricOffsetPanelVisible: boolean = false;
  @StorageLink('uplayer_theme_mode') themeMode: string = 'system';
  @State intervalID: number = 0;
  // 手机断点一镜到底：0 = 大封面页，1 = 歌词页；由 Swiper 逐帧回调驱动浮层封面插值
  @State swipeProgress: number = 0;
  // 已停靠页：决定逐帧偏移量换算成进度的方向
  private swipeBasePage: number = 0;
  // 两端封面矩形是否测量成功；未成功时浮层不启用，两页各自正常渲染封面（降级为原样）
  @State isCoverGeometryReady: boolean = false;
  @State coverOriginX: number = 0;
  @State coverOriginY: number = 0;
  @State coverOriginWidth: number = 0;
  @State coverOriginHeight: number = 0;
  @State coverTargetX: number = 0;
  @State coverTargetY: number = 0;
  @State coverTargetWidth: number = 0;
  @State coverTargetHeight: number = 0;
  private layerWidth: number = 0;
  private layerHeight: number = 0;
  private page0GlobalX: number = 0;
  private page0GlobalY: number = 0;
  private page1GlobalX: number = 0;
  private page1GlobalY: number = 0;
  // 页容器是否已真正上报过坐标：未上报时默认 0，直接相减会把封面算到屏幕外
  private page0Measured: boolean = false;
  private page1Measured: boolean = false;
  private originWidth: number = 0;
  private originHeight: number = 0;
  private originGlobalX: number = 0;
  private originGlobalY: number = 0;
  private targetWidth: number = 0;
  private targetHeight: number = 0;
  private targetGlobalX: number = 0;
  private targetGlobalY: number = 0;
  // 系统音量写通道：底栏音量 Slider 弹层经 KEY_CURRENT_VOLUME 联动驱动 volumeLevel，
  // AVVolumePanel 常驻挂载，不做显隐切换
  @StorageProp(AppStorageKeyConstants.KEY_VOL_PANEL_MAX) volPanelMax: number = 15;
  @StorageProp(AppStorageKeyConstants.KEY_CURRENT_VOLUME) volPanelNorm: number = 0;
  @Link isShowPlay: boolean;
  @StorageLink(AppStorageKeyConstants.KEY_IS_PLAY) isPlay: boolean = false;
  // 返回按钮玻璃材质只在「Navigation 标题栏」生效区渲染；播放器页把返回键交给
  // MusicPlayer 的 Navigation 标题栏（见 MusicPlayer.playerGlassTitleBar），
  // 此处不再渲染自己的返回键，避免「内容区设材质不生效」+ 双份返回键
  showBackButton: boolean = false;
  @State prevImageLabel: PixelMap | Resource = this.imageLabel;
  @State prevImageOpacity: number = 0;
  private context: common.UIAbilityContext | undefined = AppStorage.get(AppStorageKeyConstants.KEY_UI_ABILITY_CONTEXT);
  private imageLoadRequestId: number = 0;
  private backgroundCoverLease: AlbumCoverLease | undefined = undefined;
  private previousCoverLease: AlbumCoverLease | undefined = undefined;
  @State fallbackBackgroundMap: image.PixelMap | undefined = undefined;

  onImageColorChange(): void {
    ColorConversion.setSysBarLightBackground(this.isBackgroundDark(this.imageColor));
  }

  mainWindowInfoChange() {
    Logger.info(
      `windowUtil is change,current width breakpoint is ${this.mainWindowInfo?.widthBp},height breakpoint is ${this.mainWindowInfo?.heightBp}`)
    // 断点切换后 Swiper 会重建并回到第 0 页，进度必须归零，
    // 否则残留的 1 会让浮层封面直接落在小封面位置（窗口缩放场景必现）
    this.swipeProgress = 0;
    this.swipeBasePage = 0;
    this.layerWidth = 0;
    this.layerHeight = 0;
    this.originWidth = 0;
    this.targetWidth = 0;
    // 页容器与封面都会随断点重建，旧坐标一律作废，等新的 onAreaChange 上报
    this.page0Measured = false;
    this.page1Measured = false;
    // 两端封面随断点重建，等它们的 onAreaChange 重新上报几何后再启用浮层
    this.isCoverGeometryReady = false
  }

  aboutToAppear(): void {
    ColorConversion.setSysBarLightBackground(this.isBackgroundDark(this.imageColor));
    this.getImageColor();
  }

  aboutToDisappear(): void {
    clearInterval(this.intervalID);
    this.imageLoadRequestId++;
    this.backgroundCoverLease?.release();
    this.backgroundCoverLease = undefined;
    this.previousCoverLease?.release();
    this.previousCoverLease = undefined;
    this.fallbackBackgroundMap?.release();
    this.fallbackBackgroundMap = undefined;
  }

  build() {
    Stack() {
      if (this.isBackgroundImageVisible()) {
        Image(this.prevImageLabel)
          .size(this.mainWindowInfo.heightBp !== HeightBreakpoint.HEIGHT_LG ?
            { width: PlayerConstants.BACK_IMAGE, height: '100%' } :
            { width: '100%', height: PlayerConstants.BACK_IMAGE })
          .objectFit(ImageFit.Cover)
          .blur(PlayerConstants.IMAGE_BLUR)
          .opacity(this.prevImageOpacity)

        if (this.imageLabelIsFallback && this.fallbackBackgroundMap !== undefined) {
          // 无专辑封面时：模糊音符图标作为背景，与有封面时的模糊效果一致
          Image(this.fallbackBackgroundMap)
            .size(this.mainWindowInfo.heightBp !== HeightBreakpoint.HEIGHT_LG ?
              { width: PlayerConstants.BACK_IMAGE, height: '100%' } :
              { width: '100%', height: PlayerConstants.BACK_IMAGE })
            .objectFit(ImageFit.Cover)
            .blur(PlayerConstants.IMAGE_BLUR)
            .opacity(0.5)
        } else {
          Image(this.imageLabel)
            .size(this.mainWindowInfo.heightBp !== HeightBreakpoint.HEIGHT_LG ?
              { width: PlayerConstants.BACK_IMAGE, height: '100%' } :
              { width: '100%', height: PlayerConstants.BACK_IMAGE })
            .objectFit(ImageFit.Cover)
            .fillColor(this.imageLabelIsFallback ? $r('app.color.player_icon_color') : Color.Black)
            // 兜底态（尚未生成模糊背景图）显示的是清晰着色图标，不能模糊；真封面走渲染期模糊
            .blur(this.imageLabelIsFallback ? 0 : PlayerConstants.IMAGE_BLUR)
            .opacity(0.5)
        }
      }

      Column()
        .width('100%')
        .height('100%')
        .radialGradient({
          center: ['50%', '50%'],
          radius: '80%',
          colors: [
            ['rgba(255,255,255,0.08)', 0.0],
            ['rgba(0,0,0,0.3)', 1.0],
          ]
        })

      Column()
        .width('100%')
        .height('100%')
        .linearGradient({
          direction: GradientDirection.Right,
          colors: [
            ['rgba(255,255,255,0)', 0.0],
            ['rgba(255,255,255,0.03)', 0.3],
            ['rgba(255,255,255,0.06)', 0.5],
            ['rgba(255,255,255,0.03)', 0.7],
            ['rgba(255,255,255,0)', 1.0],
          ]
        })
        .opacity(this.isPlay ? 0.6 : 0)
        .animation({ duration: StyleConstants.ANIMATION_PLAYER_LIGHT_DURATION, curve: Curve.EaseInOut })

      Column()
        .width('100%')
        .height('40%')
        .linearGradient({
          direction: GradientDirection.Bottom,
          colors: [
            ['rgba(255,255,255,0.06)', 0.0],
            ['rgba(255,255,255,0)', 1.0],
          ]
        })
        .position({ top: 0 })

      Column()
        .width('100%')
        .height('30%')
        .linearGradient({
          direction: GradientDirection.Top,
          colors: [
            ['rgba(0,0,0,0.15)', 0.0],
            ['rgba(0,0,0,0)', 1.0],
          ]
        })
        .position({ bottom: 0 })
        .opacity(0.6)

      Column() {
        if (!this.isNarrowLayout()) {
          Row() {
            Column() {
              MusicInfoComponent({ mainWindowInfo: this.mainWindowInfo })
            }
            .padding(this.mainWindowInfo.widthBp === WidthBreakpoint.WIDTH_MD ? 24 : 80)
            .layoutWeight(1)
            .height('100%')
            Column() {
              LyricsComponent({ isShowControl: this.isShowControl, mainWindowInfo: this.mainWindowInfo })
            }
            .layoutWeight(1)
            .height('100%')
            .padding(this.mainWindowInfo.widthBp === WidthBreakpoint.WIDTH_MD ? 24 : 80)
          }
          .alignItems(VerticalAlign.Top)
          .layoutWeight(1)
          .width('100%')
        } else {
          // 一镜到底容器：Swiper 内的封面被页边界裁剪且两页同时挂载，无法跨页共享，
          // 因此把封面提升到本 Stack 顶层（PlayerFlyingCover），两页内只保留透明占位
          Stack({ alignContent: Alignment.TopStart }) {
            Swiper() {
              Stack() {
                Column() {
                  MusicInfoComponent({
                    mainWindowInfo: this.mainWindowInfo,
                    isCoverFloating: this.isCoverGeometryReady,
                    onCoverAreaChange: (area: Area) => {
                      this.onOriginAreaChange(area)
                    }
                  })
                }
                .padding({
                  top: $r('app.float.music_component_top'),
                  bottom: $r('app.float.music_component_bottom'),
                  left: $r('app.float.common_padding'),
                  right: $r('app.float.common_padding')
                })
                .width('100%')
                .height('100%')
                .onAreaChange((_oldArea: Area, newArea: Area) => {
                  this.onPageAreaChange(0, newArea)
                })
              }

              Stack() {
                Column() {
                  LyricsComponent({
                    isShowControl: this.isShowControl,
                    mainWindowInfo: this.mainWindowInfo,
                    isCoverFloating: this.isCoverGeometryReady,
                    onCoverAreaChange: (area: Area) => {
                      this.onTargetAreaChange(area)
                    }
                  })
                }
                .padding({
                  top: $r('app.float.music_component_top'),
                  left: $r('app.float.common_padding'),
                  right: $r('app.float.common_padding'),
                  bottom: $r('app.float.music_component_bottom'),
                })
                .width('100%')
                .height('100%')
                .onAreaChange((_oldArea: Area, newArea: Area) => {
                  this.onPageAreaChange(1, newArea)
                })
              }
            }
            .width('100%')
            .height('100%')
            .loop(false)
            // 歌词偏移滑轨展开时禁掉横滑翻页：Swiper 的横向手势优先级高于滑块拖拽，
            // 不禁用的话手指一横拖就被判成翻页，滑块纹丝不动
            .disableSwipe(this.lyricOffsetPanelVisible)
            .curve(curves.springMotion(0.5, 0.8))
            .indicator(
              // 未选中圆点 6×6，当前页拉成 22×6 椭圆长条（高度 6 → 端部圆角半径 3）
              new DotIndicator()
                .top(8)
                .color('rgba(255, 255, 255, 0.32)')
                .selectedColor('rgba(255, 255, 255, 0.95)')
                .itemWidth(6)
                .itemHeight(6)
                .selectedItemWidth(18)
                .selectedItemHeight(6)
            )
            // 跟手阶段唯一进度源：onGestureSwipe 在手势期间每帧回调，currentOffset 即实时滑动位移
            .onGestureSwipe((_index: number, extraInfo: SwiperAnimationEvent) => {
              this.updateSwipeProgress(extraInfo.currentOffset, this.layerWidth)
            })
            // 收尾阶段：Swiper 开始回弹动画时，从「当前已显示的进度」补到目标页，
            // 不用 onContentDidScroll —— 该回调在松手瞬间会把偏移重置为 0，
            // 会把进度拉回起点再走一遍，正是之前看到的二次飞行
            .onAnimationStart((_index: number, targetIndex: number, _extraInfo: SwiperAnimationEvent) => {
              this.swipeBasePage = targetIndex
              const targetProgress: number = targetIndex === 1 ? 1 : 0
              if (Math.abs(this.swipeProgress - targetProgress) < 0.005) {
                return
              }
              // 曲线与 Swiper 的 .curve(springMotion(0.5,0.8)) 完全一致，不额外指定时长，
              // 让弹簧自由演化，封面与页面同步收尾
              this.getUIContext()?.animateTo({
                curve: curves.springMotion(0.5, 0.8)
              }, () => {
                this.swipeProgress = targetProgress
              })
            })
            .onChange((index: number) => {
              // 到位后只做数值校准，页面切换的其余逻辑保持原样
              this.swipeBasePage = index
              this.swipeProgress = index === 1 ? 1 : 0
              if (index === 1) {
                this.getUIContext()?.animateTo({ curve: curves.springMotion(0.5, 0.8) }, () => {
                  this.isShowControl = true;
                })
                this.intervalID = setInterval(() => {
                  this.pageShowTime += 1;
                  if (this.pageShowTime > 5) {
                    this.getUIContext()?.animateTo({ curve: curves.springMotion(0.5, 0.8) }, () => {
                      this.isShowControl = false;
                    })
                    clearInterval(this.intervalID);
                  }
                }, 1000);
              } else {
                this.pageShowTime = 0;
                clearInterval(this.intervalID);
              }
            })

            if (this.isCoverGeometryReady) {
              PlayerFlyingCover({
                progress: this.swipeProgress,
                originX: this.coverOriginX,
                originY: this.coverOriginY,
                originWidth: this.coverOriginWidth,
                originHeight: this.coverOriginHeight,
                targetX: this.coverTargetX,
                targetY: this.coverTargetY,
                targetWidth: this.coverTargetWidth,
                targetHeight: this.coverTargetHeight
              })
            }
          }
          .layoutWeight(1)
          .width('100%')
          .onAreaChange((_oldArea: Area, newArea: Area) => {
            this.onLayerAreaChange(newArea)
          })
        }
      }
      .width('100%')
      .height('100%')
      .padding({
        bottom: this.bottomHeight,
        top: this.topHeight
      })

      if (this.showBackButton) {
        Row() {
          GlassBackButton({
            clickSize: 56,
            iconSize: 18,
            iconColor: Color.White,
            iconOpacity: 0.8,
            onBack: () => {
              this.getUIContext()?.getRouter().back()
            }
          })
        }
        .position({ x: 8, y: this.topHeight })
        .zIndex(2)
      }

      // 系统音量面板常驻挂载：它只在音量真正变化（音量键 / volumeLevel 写入）时显示系统音量条，
      // 无法靠 visibility 主动弹出（官方 FAQ faqs-audio-37/52）。
      // position 负值 = 屏幕外 = 隐藏系统音量条，音量 UI 由底栏自定义 Slider 弹层承担；
      // volumeLevel 是应用写系统音量的唯一合法通道，单位为格（0~volPanelMax）
      AVVolumePanel({
        volumeLevel: Math.round(this.volPanelNorm * this.volPanelMax),
        volumeParameter: { position: { x: -100, y: -100 } }
      })
        // 远程视图裸挂会吞掉底栏点击（播放/暂停失灵）：限制为 1vp 占位且不参与命中测试，
        // 面板 UI 隐藏语义仍由 volumeParameter 负坐标保证
        .position({ x: 0, y: 0 })
        .width(1)
        .height(1)
        .hitTestBehavior(HitTestMode.None)
    }
    .height(StyleConstants.FULL_HEIGHT)
    .width(StyleConstants.FULL_WIDTH)
    .backgroundColor(this.imageColor)
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP])
    .animation({ duration: StyleConstants.ANIMATION_PLAYER_BACKGROUND_DURATION, curve: Curve.EaseInOut })
  }

  private isBackgroundImageVisible(): boolean {
    return !this.imageLabelIsFallback || this.isBackgroundReady;
  }

  private isBackgroundDark(colorStr: string): boolean {
    return !this.isBackgroundLight(colorStr);
  }

  private isBackgroundLight(colorStr: string): boolean {
    const match = colorStr.match(new RegExp('rgba?\\((\\d+),\\s*(\\d+),\\s*(\\d+)'));
    if (match) {
      const r = parseInt(match[1]);
      const g = parseInt(match[2]);
      const b = parseInt(match[3]);
      return 0.2126 * r + 0.7152 * g + 0.0722 * b > 140;
    }
    return false;
  }

  // 窄屏（单页滑动）判定：手机直板屏、平板分屏、PC/折叠屏窗口缩小到 XS/SM 断点，
  // 全部走同一套 Swiper + 一镜到底；只有 MD 及以上的宽窗口才用左右双栏
  private isNarrowLayout(): boolean {
    const bp: WidthBreakpoint | undefined = this.mainWindowInfo?.widthBp
    return bp === WidthBreakpoint.WIDTH_SM || bp === WidthBreakpoint.WIDTH_XS
  }

  // 逐帧滑动进度：与手指位移严格线性。position 是当前滑动偏移（可能归一化 -1~1，
  // 也可能以 vp 给出，用主轴长度自适应），方向未知，取绝对值；
  // 再按「已停靠页」决定是正向还是反向，避免到位后 position 归零导致封面弹回
  private updateSwipeProgress(position: number, mainAxisLength: number): void {
    if (!this.isNarrowLayout()) {
      return
    }
    let delta: number = Math.abs(position)
    if (delta > 1 && mainAxisLength > 0) {
      delta = delta / mainAxisLength
    }
    if (delta > 1) {
      delta = 1
    }
    const progress: number = this.swipeBasePage === 1 ? 1 - delta : delta
    if (Math.abs(progress - this.swipeProgress) < 0.0005) {
      return
    }
    this.swipeProgress = progress
  }

  // 以下三个回调由两端封面与浮层容器各自的 onAreaChange 上报。globalPosition 是页面级坐标（vp），
  // 用它取代 getRectangleById 的 id 查询：id 查询依赖挂载时机、查不到只抛异常，实测靠不住
  private onLayerAreaChange(area: Area): void {
    this.layerWidth = toFiniteNumber(area.width)
    this.layerHeight = toFiniteNumber(area.height)
    this.applyCoverGeometry()
  }

  private onPageAreaChange(pageIndex: number, area: Area): void {
    const globalX: number = toFiniteNumber(area.globalPosition.x)
    const globalY: number = toFiniteNumber(area.globalPosition.y)
    if (pageIndex === 0) {
      this.page0GlobalX = globalX
      this.page0GlobalY = globalY
      this.page0Measured = true
    } else {
      this.page1GlobalX = globalX
      this.page1GlobalY = globalY
      this.page1Measured = true
    }
    this.applyCoverGeometry()
  }

  // 封面坐标换算成「所在页内的相对位置」：Swiper 滑动时页容器与封面同步位移，
  // 两者的 globalPosition 差值恒定，浮层因此不会跟着页面一起跑
  private onOriginAreaChange(area: Area): void {
    this.originWidth = toFiniteNumber(area.width)
    this.originHeight = toFiniteNumber(area.height)
    this.originGlobalX = toFiniteNumber(area.globalPosition.x)
    this.originGlobalY = toFiniteNumber(area.globalPosition.y)
    this.applyCoverGeometry()
  }

  private onTargetAreaChange(area: Area): void {
    this.targetWidth = toFiniteNumber(area.width)
    this.targetHeight = toFiniteNumber(area.height)
    this.targetGlobalX = toFiniteNumber(area.globalPosition.x)
    this.targetGlobalY = toFiniteNumber(area.globalPosition.y)
    this.applyCoverGeometry()
  }

  // 页内相对坐标的基准与浮层层原点一致（页 0、Swiper、浮层 Stack 三者左上角重合）。
  // 任一侧页容器没有上报过坐标时一律不启用浮层：宁可回退成两页各自显示封面，也不能把封面算到屏幕外
  private applyCoverGeometry(): void {
    // 采样一次即冻结：端点位置是静态量，一旦算准就不再随任何 onAreaChange 改动。
    // 否则「页先动、进度后更新」的那几帧会用新页坐标配旧封面坐标，算出错误端点导致封面跳一下
    if (this.isCoverGeometryReady) {
      return
    }
    if (!this.isNarrowLayout() || this.layerWidth <= 0 || this.originWidth <= 0 || this.targetWidth <= 0 ||
      !this.page0Measured || !this.page1Measured) {
      return
    }
    const originX: number = this.originGlobalX - this.page0GlobalX
    const originY: number = this.originGlobalY - this.page0GlobalY
    const targetX: number = this.targetGlobalX - this.page1GlobalX
    const targetY: number = this.targetGlobalY - this.page1GlobalY
    // 越界即这组坐标不可信，不采样、继续等下一帧上报（此时浮层仍是未启用状态，页面封面正常可见）
    const outOfLayer: boolean = originX < -1 || originX > this.layerWidth || originY < -1 ||
      originY > this.layerHeight || targetX < -1 || targetX > this.layerWidth || targetY < -1 ||
      targetY > this.layerHeight
    if (outOfLayer) {
      return
    }
    this.coverOriginX = originX
    this.coverOriginY = originY
    this.coverOriginWidth = this.originWidth
    this.coverOriginHeight = this.originHeight
    this.coverTargetX = targetX
    this.coverTargetY = targetY
    this.coverTargetWidth = this.targetWidth
    this.coverTargetHeight = this.targetHeight
    Logger.info(TAG,
      `cover fly ready: origin=(${this.coverOriginX.toFixed(1)},${this.coverOriginY.toFixed(1)}) ${this.coverOriginWidth.toFixed(1)}vp ` +
        `target=(${this.coverTargetX.toFixed(1)},${this.coverTargetY.toFixed(1)}) ${this.coverTargetWidth.toFixed(1)}vp ` +
        `layer=${this.layerWidth.toFixed(1)}x${this.layerHeight.toFixed(1)}`)
    this.isCoverGeometryReady = true
  }

  getImageColor() {
    if (!this.context) {
      return;
    }
    const song: SongInfo | undefined = DataService.getInstance().getSongById(this.currentSongId);
    if (song === undefined) {
      this.setDefaultBackground();
      return;
    }
    this.loadAlbumArt(song);
  }

  private async setDefaultBackground() {
    this.imageLoadRequestId++;
    let isDark: boolean = this.themeMode === 'dark';
    if (!isDark && this.themeMode === 'system' && this.context) {
      const config = this.context.config;
      if (config.colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK) {
        isDark = true;
      }
    }
    if (isDark) {
      this.imageColor = 'rgba(0, 0, 2, 1.00)';
    } else {
      this.imageColor = 'rgba(228, 236, 247, 1.00)';
    }
    try {
      const srcImg = await MediaTools.getPixelMapFromResource(this.context!, $r('app.media.ic_public_music'));
      if (srcImg === null) {
        this.isBackgroundReady = true;
        return;
      }
      // 保存原图，模糊交给 Image.blur 渲染期完成（GPU），不再 CPU 预生成模糊副本
      this.fallbackBackgroundMap?.release();
      this.fallbackBackgroundMap = srcImg;
      this.isBackgroundReady = true;
    } catch (_) {
      this.isBackgroundReady = true;
    }
  }

  private async loadAlbumArt(song: SongInfo): Promise<void> {
    const requestId: number = ++this.imageLoadRequestId;
    let coverLease: AlbumCoverLease | undefined = undefined;
    try {
      coverLease = await AudioMetadataService.getInstance().acquireAlbumCover(song, AlbumCoverSize.LARGE);
      if (coverLease === undefined) {
        if (requestId === this.imageLoadRequestId) {
          await this.setDefaultBackground();
        }
        return;
      }
      if (requestId !== this.imageLoadRequestId) {
        return;
      }
      const pixelMap: image.PixelMap = coverLease.pixelMap;
      await this.updateImageColor(pixelMap, requestId);
      // 换 lease：旧 lease 暂存到 previousCoverLease，淡出结束后再释放（旧图渲染期间必须保活）
      this.previousCoverLease?.release();
      this.previousCoverLease = this.backgroundCoverLease;
      this.backgroundCoverLease = coverLease;
      const hasPreviousBackground: boolean = !this.imageLabelIsFallback;
      if (hasPreviousBackground) {
        this.prevImageLabel = this.imageLabel;
      }
      this.imageLabel = pixelMap;
      this.imageLabelIsFallback = false;
      this.isBackgroundReady = true;
      if (hasPreviousBackground) {
        this.getUIContext()?.animateTo({
          duration: StyleConstants.ANIMATION_BACKGROUND_FADE_DURATION,
          curve: Curve.EaseOut
        }, () => {
          this.prevImageOpacity = 0.5;
        });
        setTimeout(() => {
          if (requestId !== this.imageLoadRequestId) {
            return;
          }
          this.getUIContext()?.animateTo({
            duration: StyleConstants.ANIMATION_PLAYER_BACKGROUND_DURATION,
            curve: Curve.EaseOut
          }, () => {
            this.prevImageOpacity = 0;
          });
          setTimeout(() => {
            if (requestId === this.imageLoadRequestId) {
              this.prevImageLabel = $r('app.media.ic_public_music');
              this.previousCoverLease?.release();
              this.previousCoverLease = undefined;
            }
          }, StyleConstants.ANIMATION_PLAYER_BACKGROUND_DURATION);
        }, StyleConstants.ANIMATION_PRESS_DELAY_SHORT);
      } else {
        this.previousCoverLease?.release();
        this.previousCoverLease = undefined;
      }
    } catch (err) {
      Logger.error(`loadAlbumArt failed: ${JSON.stringify(err)}`);
    } finally {
      // 接受路径下 lease 由 backgroundCoverLease 持有（渲染期直接引用其 pixelMap），
      // 不得置空；拒绝/异常路径归还 lease
      if (this.backgroundCoverLease !== coverLease) {
        coverLease?.release();
      }
    }
  }

  private async updateImageColor(pixelMap: image.PixelMap, requestId: number): Promise<void> {
    await new Promise<void>((resolve: () => void): void => {
      effectKit.createColorPicker(pixelMap, (error: BusinessError, colorPicker: effectKit.ColorPicker) => {
        if (requestId === this.imageLoadRequestId) {
          if (error) {
            Logger.error('Failed to create color picker.');
          } else {
            const color = colorPicker.getLargestProportionColor();
            const colorArr: number[] = ColorConversion.dealColor(color.red, color.green, color.blue);
            this.imageColor = `rgba(${colorArr[0]}, ${colorArr[1]}, ${colorArr[2]}, 1)`;
          }
        }
        resolve();
      });
    });
  }
}
