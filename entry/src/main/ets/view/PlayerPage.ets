import { SongItem } from '../model/SongData'
import { AVPlayerManager } from '../common/AVPlayerManager'
import { PlayerKey, PlayMode } from '../common/PlayerConstants'

const TAG = 'PlayerPage'

@Component
export struct PlayerPage {
  @Link isShow: boolean
  @Link currentIndex: number
  @Link isPlaying: boolean
  @Link rotationAngle: number
  songList: SongItem[] = []
  private avPlayer: AVPlayerManager = AVPlayerManager.getInstance()

  @State currentTime: number = 0
  @State totalTime: number = 0
  @State progressValue: number = 0
  @State playMode: PlayMode = PlayMode.ORDER
  @State showPlayList: boolean = false

  aboutToAppear(): void {
    this.avPlayer.setOnTimeUpdate((time: number) => {
      this.currentTime = time
      this.progressValue = time
    })
    this.avPlayer.setOnStateChange((state: string) => {
      this.isPlaying = state === 'playing'
    })
  }

  build() {
    Stack() {
      // 半透明背景
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor('#F5F5F5')

      Column() {
        // 顶部栏
        Row() {
          // 返回按钮
          Image($r('app.media.ic_public_play_last'))
            .width(24)
            .height(24)
            .rotate({ angle: 90 })
            .fillColor('#333333')
            .onClick(() => {
              this.isShow = false
            })

          Blank()

          // 歌名/歌手
          Text(this.songList[this.currentIndex]?.title || '未在播放')
            .fontSize(16)
            .fontWeight(FontWeight.Bold)
            .fontColor('#333333')
            .lineHeight(22)

          Blank()

          // 更多
          Image($r('app.media.ic_public_view_list'))
            .width(24)
            .height(24)
            .fillColor('#333333')
            .onClick(() => {
              this.showPlayList = true
            })
        }
        .padding({ left: 16, right: 16, top: 8 })
        .width('100%')
        .height(56)

        // 专辑封面
        Column() {
          Image(this.songList[this.currentIndex]?.cover || $r('app.media.ic_public_music'))
            .width(280)
            .height(280)
            .borderRadius(20)
            .rotate({ angle: this.isPlaying ? this.rotationAngle : 0 })
            .objectFit(ImageFit.Cover)
            .backgroundColor('#E0E0E0')
        }
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)

        // 歌曲信息
        Column() {
          Text(this.songList[this.currentIndex]?.title || '未在播放')
            .fontSize(22)
            .fontWeight(FontWeight.Bold)
            .fontColor('#333333')

          Text(this.songList[this.currentIndex]?.singer || '未知歌手')
            .fontSize(14)
            .fontColor('#666666')
            .margin({ top: 8 })
        }
        .alignItems(HorizontalAlign.Center)
        .width('100%')
        .padding({ bottom: 16 })

        // 进度条
        Column() {
          Slider({
            value: this.progressValue,
            min: 0,
            max: this.totalTime > 0 ? this.totalTime : 100,
            step: 1,
            style: SliderStyle.NONE,
          })
            .width('100%')
            .trackThickness(4)
            .selectedColor('#007DFF')
            .trackColor('#D9D9D9')
            .blockColor('#007DFF')
            .onChange((value: number, mode: SliderChangeMode) => {
              if (mode === SliderChangeMode.Moving) {
                this.currentTime = value
              }
              if (mode === SliderChangeMode.End) {
                this.avPlayer.seek(value)
              }
            })

          Row() {
            Text(this.formatTime(this.currentTime))
              .fontSize(12)
              .fontColor('#999999')
            Text(this.formatTime(this.totalTime))
              .fontSize(12)
              .fontColor('#999999')
          }
          .width('100%')
          .justifyContent(FlexAlign.SpaceBetween)
        }
        .padding({ left: 32, right: 32, bottom: 8 })

        // 播放控制
        Row() {
          // 上一曲
          Image($r('app.media.ic_public_play_last'))
            .width(32)
            .height(32)
            .fillColor('#333333')
            .onClick(() => {
              this.playPrev()
            })

          Blank()

          // 播放/暂停
          Image(this.isPlaying ? $r('app.media.ic_public_pause') : $r('app.media.ic_public_play'))
            .width(56)
            .height(56)
            .fillColor('#007DFF')
            .onClick(() => {
              this.togglePlay()
            })

          Blank()

          // 下一曲
          Image($r('app.media.ic_public_play_next'))
            .width(32)
            .height(32)
            .fillColor('#333333')
            .onClick(() => {
              this.playNext()
            })
        }
        .width('100%')
        .padding({ left: 48, right: 48, bottom: 24 })
        .alignItems(VerticalAlign.Center)

        // 底部操作栏
        Row() {
          Text(this.playModeText())
            .fontSize(14)
            .fontColor('#666666')
            .onClick(() => {
              this.switchPlayMode()
            })
        }
        .width('100%')
        .justifyContent(FlexAlign.Center)
        .padding({ bottom: 16 })
      }
      .width('100%')
      .height('100%')
    }
    .width('100%')
    .height('100%')
  }

  togglePlay() {
    if (this.isPlaying) {
      this.avPlayer.pause()
    } else {
      if (this.avPlayer.getDuration() <= 0) {
        this.loadAndPlay(this.currentIndex)
      } else {
        this.avPlayer.play()
      }
    }
  }

  playPrev() {
    let prev = this.currentIndex - 1
    if (prev < 0) {
      prev = this.songList.length - 1
    }
    this.currentIndex = prev
    this.loadAndPlay(prev)
  }

  playNext() {
    let next = this.currentIndex + 1
    if (next >= this.songList.length) {
      next = 0
    }
    this.currentIndex = next
    this.loadAndPlay(next)
  }

  async loadAndPlay(index: number) {
    const src = this.songList[index]?.src
    if (src) {
      await this.avPlayer.load(src)
      await this.avPlayer.play()
    }
  }

  switchPlayMode() {
    if (this.playMode === PlayMode.ORDER) {
      this.playMode = PlayMode.SINGLE
    } else if (this.playMode === PlayMode.SINGLE) {
      this.playMode = PlayMode.RANDOM
    } else {
      this.playMode = PlayMode.ORDER
    }
  }

  playModeText(): string {
    switch (this.playMode) {
      case PlayMode.ORDER:
        return '顺序播放'
      case PlayMode.SINGLE:
        return '单曲循环'
      case PlayMode.RANDOM:
        return '随机播放'
      default:
        return '顺序播放'
    }
  }

  formatTime(ms: number): string {
    const totalSec = Math.floor(ms / 1000)
    const min = Math.floor(totalSec / 60)
    const sec = totalSec % 60
    return `${min.toString().padStart(2, '0')}:${sec.toString().padStart(2, '0')}`
  }
}
