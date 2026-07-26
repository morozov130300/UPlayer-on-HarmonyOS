import { BusinessError } from '@kit.BasicServicesKit';
import { curves } from '@kit.ArkUI';
import { effectKit } from '@kit.ArkGraphics2D';
import { image } from '@kit.ImageKit';
import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { LyricsComponent } from './LyricsComponent';
import { MusicInfoComponent } from './MusicInfoComponent';
import { StyleConstants } from '../common/constants/StyleConstants';
import { PlayerConstants } from '../common/constants/PlayerConstants';
import { SongInfo } from '../model/SongInfo';
import Logger from '../common/utils/Logger';
import { ColorConversion } from '../common/utils/ColorConversion';
import { WindowInfo } from '../common/utils/WindowUtil';
import { PromptActionClassNew } from '../viewmodel/PromptActionClassNew';
import { AppStorageKeyConstants } from '../common/constants/AppStorageKeyConstants';

const TAG = 'PlayerInfoComponent'

@Component
export struct PlayerInfoComponent {
  @ObjectLink @Watch('mainWindowInfoChange') mainWindowInfo: WindowInfo;
  @StorageLink(AppStorageKeyConstants.KEY_SONG_LIST) songList: SongInfo[] = [];
  @StorageProp(AppStorageKeyConstants.KEY_SELECT_INDEX) @Watch('getImageColor') selectIndex: number = 0;
  @StorageLink(AppStorageKeyConstants.KEY_IMAGE_COLOR) imageColor: string = 'rgba(0, 0, 2, 1.00)';
  @StorageLink(AppStorageKeyConstants.KEY_TOP_HEIGHT) topHeight: number = 0;
  @StorageLink(AppStorageKeyConstants.KEY_BOTTOM_HEIGHT) @Watch('bottomHeightChange') bottomHeight: number = 0;
  @State imageLabel: PixelMap | Resource = $r('app.media.ic_public_music');
  @State isShowControl: boolean = true;
  @State isShowControlLg: boolean = false;
  @State isTablet: boolean = true;
  @State isTabletFalse: boolean = false;
  @StorageLink(AppStorageKeyConstants.KEY_PAGE_SHOW_TIME) pageShowTime: number = 0;
  @State intervalID: number = 0;
  @Link isShowPlay: boolean;
  @State message: Resource = $r('app.string.no_operate');
  @StorageLink(AppStorageKeyConstants.KEY_IS_PLAY) isPlay: boolean = false;
  @State particleOpacity: number = 0;
  @State prevImageLabel: PixelMap | Resource = this.imageLabel;
  @State prevImageOpacity: number = 0;
  @State currentSwiperIndex: number = 0;
  private context: common.UIAbilityContext | undefined = AppStorage.get(AppStorageKeyConstants.KEY_UI_ABILITY_CONTEXT);

  bottomHeightChange() {
  }

  mainWindowInfoChange() {
    Logger.info(
      `windowUtil is change,current width breakpoint is ${this.mainWindowInfo?.widthBp},height breakpoint is ${this.mainWindowInfo?.heightBp}`)
    if (this.mainWindowInfo.heightBp === HeightBreakpoint.HEIGHT_MD &&
      this.mainWindowInfo.widthBp === WidthBreakpoint.WIDTH_SM) {
      PromptActionClassNew.openDialog();
    } else {
      PromptActionClassNew.closeDialog();
    }
  }

  aboutToAppear(): void {
    this.getImageColor();
  }

  aboutToDisappear(): void {
    clearInterval(this.intervalID);
  }

  build() {
    Stack() {
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
        .opacity(0.5)

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
        .animation({ duration: 1500, curve: Curve.EaseInOut })

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
            Row() {
              SymbolGlyph($r('sys.symbol.chevron_left'))
                .fontSize(32)
                .fontColor([Color.White])
                .opacity(0.8)
            }
            .width(56)
            .height(56)
            .justifyContent(FlexAlign.Center)
            .borderRadius(28)
            .hoverEffect(HoverEffect.Scale)
            .onClick(() => {
              this.getUIContext()?.getRouter().back()
            })

            Blank()
          }
          .width('100%')
          .height(56)

          Row() {
            Column() {
              MusicInfoComponent({ mainWindowInfo: this.mainWindowInfo })
            }
            .padding(this.mainWindowInfo.widthBp === WidthBreakpoint.WIDTH_MD ? 24 : 80)
            .width('50%')
            Column() {
              LyricsComponent({ isShowControl: this.isShowControlLg, mainWindowInfo: this.mainWindowInfo })
            }
            .width('50%')
            .padding(this.mainWindowInfo.widthBp === WidthBreakpoint.WIDTH_MD ? 24 : 80)
          }
          .layoutWeight(1)
          .width('100%')
        } else {
          Swiper() {
            Stack() {
              Column() {
                MusicInfoComponent({ mainWindowInfo: this.mainWindowInfo, isReverse: true })
              }
              .padding({
                top: $r('app.float.music_component_top'),
                bottom: $r('app.float.music_component_bottom'),
                left: $r('app.float.common_padding'),
                right: $r('app.float.common_padding')
              })
              .width('100%')
              .height('100%')

              Row() {
                SymbolGlyph($r('sys.symbol.chevron_left'))
                  .fontSize(32)
                  .fontColor([Color.White])
                  .opacity(0.8)
              }
              .width(56)
              .height(56)
              .justifyContent(FlexAlign.Center)
              .borderRadius(28)
              .hoverEffect(HoverEffect.Scale)
              .onClick(() => {
                this.getUIContext()?.getRouter().back()
              })
              .position({ x: 8, y: 0 })
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

              Row() {
                SymbolGlyph($r('sys.symbol.chevron_left'))
                  .fontSize(32)
                  .fontColor([Color.White])
                  .opacity(0.8)
              }
              .width(40)
              .height(56)
              .justifyContent(FlexAlign.Center)
              .borderRadius(28)
              .hoverEffect(HoverEffect.Scale)
              .onClick(() => {
                this.getUIContext()?.getRouter().back()
              })
              .position({ x: 8, y: 0 })
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
            this.currentSwiperIndex = index;
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
    }
    .height(StyleConstants.FULL_HEIGHT)
    .width(StyleConstants.FULL_WIDTH)
    .backgroundColor(this.imageColor)
    .animation({ duration: 800, curve: Curve.EaseInOut })
  }

  private isBackgroundLight(colorStr: string): boolean {
    const match = colorStr.match(new RegExp('rgba\\((\\d+),\\s*(\\d+),\\s*(\\d+)'));
    if (match) {
      const r = parseInt(match[1]);
      const g = parseInt(match[2]);
      const b = parseInt(match[3]);
      return 0.299 * r + 0.587 * g + 0.114 * b > 128;
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
    if (!this.songList || this.selectIndex < 0 || this.selectIndex >= this.songList.length) {
      Logger.error('getImageColor: selectIndex out of bounds');
      return;
    }
    const song: SongInfo = this.songList[this.selectIndex];
    if (song.albumArtPath && song.albumArtPath.length > 0) {
      this.loadAlbumArtFromFile(song.albumArtPath);
    }
  }

  private loadAlbumArtFromFile(artPath: string) {
    try {
      const file: fs.File = fs.openSync(artPath, fs.OpenMode.READ_ONLY);
      const stat = fs.statSync(artPath);
      const buffer: ArrayBuffer = new ArrayBuffer(stat.size);
      fs.readSync(file.fd, buffer);
      fs.closeSync(file);
      image.createImageSource(buffer).createPixelMap().then((pixelMap: image.PixelMap) => {
        effectKit.createColorPicker(pixelMap, (error: BusinessError, colorPicker: effectKit.ColorPicker) => {
          if (error) {
            Logger.error('Failed to create color picker.');
          } else {
            const color = colorPicker.getLargestProportionColor();
            const colorArr: number[] = ColorConversion.dealColor(color.red, color.green, color.blue);
            this.imageColor = `rgba(${colorArr[0]}, ${colorArr[1]}, ${colorArr[2]}, 1)`;
          }
        });
        const headFilter = effectKit.createEffect(pixelMap);
        if (headFilter !== null) {
          headFilter.blur(PlayerConstants.IMAGE_BLUR);
          headFilter.getEffectPixelMap().then((value: image.PixelMap) => {
            this.prevImageLabel = this.imageLabel;
            this.getUIContext()?.animateTo({ duration: 600, curve: Curve.EaseOut }, () => {
              this.prevImageOpacity = 0.5;
            });
            this.imageLabel = value;
            setTimeout(() => {
              this.getUIContext()?.animateTo({ duration: 800, curve: Curve.EaseOut }, () => {
                this.prevImageOpacity = 0;
              });
            }, 100);
          });
        }
      }).catch((error: BusinessError) => {
        Logger.error(`${error.code} + ${error.message}`);
      });
    } catch (err) {
      Logger.error(`loadAlbumArtFromFile failed: ${JSON.stringify(err)}`);
    }
  }
}
