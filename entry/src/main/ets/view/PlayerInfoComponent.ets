import { BusinessError } from '@kit.BasicServicesKit';
import { curves } from '@kit.ArkUI';
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

const TAG = 'PlayerInfoComponent'

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
  @State isShowControlLg: boolean = false;
  @StorageLink(AppStorageKeyConstants.KEY_PAGE_SHOW_TIME) pageShowTime: number = 0;
  @StorageLink('uplayer_theme_mode') themeMode: string = 'system';
  @State intervalID: number = 0;
  @Link isShowPlay: boolean;
  @StorageLink(AppStorageKeyConstants.KEY_IS_PLAY) isPlay: boolean = false;
  @State prevImageLabel: PixelMap | Resource = this.imageLabel;
  @State prevImageOpacity: number = 0;
  private context: common.UIAbilityContext | undefined = AppStorage.get(AppStorageKeyConstants.KEY_UI_ABILITY_CONTEXT);
  private imageLoadRequestId: number = 0;
  private backgroundCoverLease: AlbumCoverLease | undefined = undefined;
  private currentBackgroundMap: image.PixelMap | undefined = undefined;
  private previousBackgroundMap: image.PixelMap | undefined = undefined;

  onImageColorChange(): void {
    ColorConversion.setSysBarLightBackground(this.isBackgroundDark(this.imageColor));
  }

  mainWindowInfoChange() {
    Logger.info(
      `windowUtil is change,current width breakpoint is ${this.mainWindowInfo?.widthBp},height breakpoint is ${this.mainWindowInfo?.heightBp}`)
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
    this.currentBackgroundMap?.release();
    this.currentBackgroundMap = undefined;
    this.previousBackgroundMap?.release();
    this.previousBackgroundMap = undefined;
  }

  build() {
    Stack() {
      if (this.isBackgroundImageVisible()) {
        Image(this.prevImageLabel)
          .size(this.mainWindowInfo.heightBp !== HeightBreakpoint.HEIGHT_LG ?
            { width: PlayerConstants.BACK_IMAGE, height: '100%' } :
            { width: '100%', height: PlayerConstants.BACK_IMAGE })
          .objectFit(ImageFit.Cover)
          .opacity(this.prevImageOpacity)

        Image(this.imageLabel)
          .size(this.mainWindowInfo.heightBp !== HeightBreakpoint.HEIGHT_LG ?
            { width: PlayerConstants.BACK_IMAGE, height: '100%' } :
            { width: '100%', height: PlayerConstants.BACK_IMAGE })
          .objectFit(ImageFit.Cover)
          .fillColor(this.imageLabelIsFallback ? $r('app.color.player_icon_color') : Color.Black)
          .opacity(0.5)
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
            .width('50%')
            .height('100%')
            Column() {
              LyricsComponent({ isShowControl: this.isShowControlLg, mainWindowInfo: this.mainWindowInfo })
            }
            .width('50%')
            .height('100%')
            .padding(this.mainWindowInfo.widthBp === WidthBreakpoint.WIDTH_MD ? 24 : 80)
          }
          .alignItems(VerticalAlign.Top)
          .layoutWeight(1)
          .width('100%')
        } else {
          Swiper() {
            Stack() {
              Column() {
                MusicInfoComponent({ mainWindowInfo: this.mainWindowInfo })
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
                LyricsComponent({ isShowControl: this.isShowControl, mainWindowInfo: this.mainWindowInfo })
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
          .layoutWeight(1)
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
          .onChange((index: number) => {
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
        }
      }
      .padding({
        bottom: this.bottomHeight,
        top: this.topHeight
      })

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

  private setDefaultBackground() {
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
    this.isBackgroundReady = true;
  }

  private async loadAlbumArt(song: SongInfo): Promise<void> {
    const requestId: number = ++this.imageLoadRequestId;
    let coverLease: AlbumCoverLease | undefined = undefined;
    try {
      coverLease = await AudioMetadataService.getInstance().acquireAlbumCover(song, AlbumCoverSize.LARGE);
      if (coverLease === undefined) {
        if (requestId === this.imageLoadRequestId) {
          this.setDefaultBackground();
        }
        return;
      }
      if (requestId !== this.imageLoadRequestId) {
        return;
      }
      this.backgroundCoverLease?.release();
      this.backgroundCoverLease = coverLease;
      const pixelMap: image.PixelMap = coverLease.pixelMap;
      await this.updateImageColor(pixelMap, requestId);
      const headFilter = effectKit.createEffect(pixelMap);
      if (headFilter === null) {
        return;
      }
      headFilter.blur(PlayerConstants.IMAGE_BLUR);
      const value: image.PixelMap = await headFilter.getEffectPixelMap();
      if (requestId !== this.imageLoadRequestId) {
        value.release();
        return;
      }
this.previousBackgroundMap?.release();
      this.previousBackgroundMap = this.currentBackgroundMap;
      this.currentBackgroundMap = value;
      const hasPreviousBackground: boolean = !this.imageLabelIsFallback;
      if (hasPreviousBackground) {
        this.prevImageLabel = this.imageLabel;
      }
      this.imageLabel = value;
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
              this.previousBackgroundMap?.release();
              this.previousBackgroundMap = undefined;
            }
          }, StyleConstants.ANIMATION_PLAYER_BACKGROUND_DURATION);
        }, StyleConstants.ANIMATION_PRESS_DELAY_SHORT);
      }
    } catch (err) {
      Logger.error(`loadAlbumArt failed: ${JSON.stringify(err)}`);
    } finally {
      if (this.backgroundCoverLease === coverLease) {
        this.backgroundCoverLease = undefined;
      } else {
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
