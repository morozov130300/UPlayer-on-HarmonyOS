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

// 两端封面矩形测量：布局首帧内可能拿不到第二页，有限次重试（20 × 60ms ≈ 1.2s）
const GEOMETRY_RETRY_MAX: number = 20
const GEOMETRY_RETRY_INTERVAL_MS: number = 60

interface CoverRect {
  x: number
  y: number
  width: number
  height: number
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
  @StorageLink('uplayer_theme_mode') themeMode: string = 'system';
  @State intervalID: number = 0;
  // 手机断点一镜到底：0 = 大封面页，1 = 歌词页；由 Swiper 逐帧回调驱动浮层封面插值
  @State swipeProgress: number = 0;
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
  private geometryRetryTimer: number = -1;
  private geometryRetryCount: number = 0;
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
    // 断点在手机/宽屏之间切换后，封面矩形必须重新测量（宽屏分支不使用浮层）
    this.scheduleGeometryMeasure()
  }

  aboutToAppear(): void {
    ColorConversion.setSysBarLightBackground(this.isBackgroundDark(this.imageColor));
    this.getImageColor();
    this.scheduleGeometryMeasure();
  }

  aboutToDisappear(): void {
    clearInterval(this.intervalID);
    this.clearGeometryRetry();
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
        if (this.mainWindowInfo.widthBp !== WidthBreakpoint.WIDTH_SM) {
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
                    isCoverFloating: this.isCoverGeometryReady
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
              }

              Stack() {
                Column() {
                  LyricsComponent({
                    isShowControl: this.isShowControl,
                    mainWindowInfo: this.mainWindowInfo,
                    isCoverFloating: this.isCoverGeometryReady
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
              }
            }
            .width('100%')
            .height('100%')
            .loop(false)
            .curve(curves.springMotion(0.5, 0.8))
            .indicator(
              new DotIndicator()
                .top(8)
                .color(this.getDotColor(false))
                .selectedColor(this.getDotColor(true))
                .itemWidth(6)
                .itemHeight(6)
                .selectedItemWidth(14)
                .selectedItemHeight(6)
            )
            // 逐帧滑动进度：position 为当前页相对 index 页的归一化偏移，index + position 即跨页进度
            .onContentDidScroll((index: number, position: number, _mainAxisLength: number) => {
              this.updateSwipeProgress(index, position)
            })
            .onChange((index: number) => {
              // 尾帧对齐：动画结束必须落到 0/1，避免浮层停在插值中途
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
          .id('cover_layer')
          .onAreaChange((oldArea: Area, newArea: Area) => {
            const width: number = Number(newArea.width)
            const height: number = Number(newArea.height)
            if (Math.abs(width - this.layerWidth) < 0.5 && Math.abs(height - this.layerHeight) < 0.5) {
              return
            }
            this.layerWidth = width
            this.layerHeight = height
            this.scheduleGeometryMeasure()
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

  // 逐帧滑动进度：0 = 大封面页，1 = 歌词页。position 为当前页相对 index 页的归一化偏移，
  // 两者相加即跨页进度；方向若与预期相反（真机表现为封面反向飞），改为 index - position
  private updateSwipeProgress(index: number, position: number): void {
    if (this.mainWindowInfo?.widthBp !== WidthBreakpoint.WIDTH_SM) {
      return
    }
    let progress: number = index + position
    if (progress < 0) {
      progress = 0
    }
    if (progress > 1) {
      progress = 1
    }
    if (Math.abs(progress - this.swipeProgress) < 0.001) {
      return
    }
    this.swipeProgress = progress
  }

  private scheduleGeometryMeasure(): void {
    this.geometryRetryCount = 0
    this.clearGeometryRetry()
    // 等一帧让布局完成，否则首次测量拿不到两端封面矩形
    this.geometryRetryTimer = setTimeout(() => {
      this.geometryRetryTimer = -1
      this.measureCoverGeometry()
    }, 0)
  }

  private clearGeometryRetry(): void {
    if (this.geometryRetryTimer !== -1) {
      clearTimeout(this.geometryRetryTimer)
      this.geometryRetryTimer = -1
    }
  }

  // 两端封面矩形在首次布局时可能尚未就绪（Swiper 第二页延迟挂载），按固定间隔有限次重试
  private retryGeometryMeasure(): void {
    if (this.geometryRetryCount >= GEOMETRY_RETRY_MAX) {
      return
    }
    this.geometryRetryCount++
    this.clearGeometryRetry()
    this.geometryRetryTimer = setTimeout(() => {
      this.geometryRetryTimer = -1
      this.measureCoverGeometry()
    }, GEOMETRY_RETRY_INTERVAL_MS)
  }

  private measureCoverGeometry(): void {
    if (this.mainWindowInfo?.widthBp !== WidthBreakpoint.WIDTH_SM) {
      if (this.isCoverGeometryReady) {
        this.isCoverGeometryReady = false
      }
      return
    }
    const layer: CoverRect | undefined = this.readRect('cover_layer')
    const origin: CoverRect | undefined = this.readRect('cover_origin')
    const target: CoverRect | undefined = this.readRect('cover_target')
    if (layer === undefined || origin === undefined || target === undefined || layer.width <= 0) {
      if (this.isCoverGeometryReady) {
        this.isCoverGeometryReady = false
      }
      this.retryGeometryMeasure()
      return
    }
    // 第 1 页的小封面位于 Swiper 第二屏，需按页宽回退到当前视口坐标系
    const pageWidth: number = layer.width
    this.coverOriginX = origin.x - layer.x
    this.coverOriginY = origin.y - layer.y
    this.coverOriginWidth = origin.width
    this.coverOriginHeight = origin.height
    this.coverTargetX = target.x - layer.x - pageWidth
    this.coverTargetY = target.y - layer.y
    this.coverTargetWidth = target.width
    this.coverTargetHeight = target.height
    this.isCoverGeometryReady = this.coverOriginWidth > 0 && this.coverTargetWidth > 0
  }

  private readRect(id: string): CoverRect | undefined {
    try {
      const uiContext = this.getUIContext()
      // 组件不存在时 getRectangleById 会抛异常，由 catch 兜住并返回 undefined
      const info = uiContext.getComponentUtils().getRectangleById(id)
      // getRectangleById 返回 px，统一换算成 vp 与布局单位对齐
      const rect: CoverRect = {
        x: uiContext.px2vp(info.windowOffset.x),
        y: uiContext.px2vp(info.windowOffset.y),
        width: uiContext.px2vp(info.size.width),
        height: uiContext.px2vp(info.size.height)
      }
      return rect
    } catch (_) {
      return undefined
    }
  }

  private getDotColor(isSelected: boolean): ResourceColor {
    const isLight = this.isBackgroundLight(this.imageColor);
    if (isSelected) {
      return isLight ? '#333333' : '#FFFFFF';
    }
    return isLight ? '#AAAAAA' : '#666666';
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
