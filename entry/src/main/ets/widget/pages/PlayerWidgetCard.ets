let storage = new LocalStorage()

// 桌面播放卡片（F1）2*4：封面+歌名/歌手+进度条+播停/下一首
// 数据来源：PlayerFormAbility 初值 + 应用进程 FormUpdateService 主动 updateForm
// 交互：控制键 postCardAction call（后台控制不跳前台）、封面区 router（打开应用）
@Entry(storage)
@Component
struct PlayerWidgetCard {
  @LocalStorageProp('title') title: string = '未播放'
  @LocalStorageProp('artist') artist: string = ''
  @LocalStorageProp('isPlaying') isPlaying: boolean = false
  @LocalStorageProp('progressPercent') progressPercent: number = 0
  @LocalStorageProp('hasCover') hasCover: boolean = false

  private postCardCall(action: string): void {
    const params: Record<string, string> = {}
    params['uplayer_card_action'] = action
    const cardAction: Record<string, Object> = {}
    cardAction['action'] = 'call'
    cardAction['bundleName'] = 'cn.edu.whut.uplayer'
    cardAction['abilityName'] = 'EntryAbility'
    cardAction['params'] = params
    postCardAction(this, cardAction)
  }

  private postCardOpen(): void {
    const params: Record<string, string> = {}
    params['uplayer_card_action'] = 'open'
    const cardAction: Record<string, Object> = {}
    cardAction['action'] = 'router'
    cardAction['bundleName'] = 'cn.edu.whut.uplayer'
    cardAction['abilityName'] = 'EntryAbility'
    cardAction['params'] = params
    postCardAction(this, cardAction)
  }

  build() {
    Row({ space: 12 }) {
      Stack() {
        if (this.hasCover) {
          Image('memory://form_cover')
            .width(48)
            .height(48)
            .borderRadius(10)
            .objectFit(ImageFit.Cover)
        } else {
          Image($r('app.media.ic_public_music'))
            .width(26)
            .height(26)
            .fillColor($r('app.color.player_icon_inactive_color'))
        }
      }
      .width(48)
      .height(48)
      .borderRadius(10)
      .onClick(() => {
        this.postCardOpen()
      })

      Column({ space: 4 }) {
        Text(this.title)
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .maxLines(1)
          .width('100%')
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(this.artist.length > 0 ? this.artist : '未知歌手')
          .fontSize(11)
          .maxLines(1)
          .width('100%')
          .opacity(0.6)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Row() {
          Row()
            .width(`${this.progressPercent}%`)
            .height('100%')
            .backgroundColor($r('app.color.player_icon_color'))
        }
        .width('100%')
        .height(3)
        .borderRadius(1.5)
        .backgroundColor('#33808080')
        .clip(true)
      }
      .layoutWeight(1)
      .height('100%')
      .justifyContent(FlexAlign.Center)

      Row({ space: 14 }) {
        Image(this.isPlaying ? $r('app.media.ic_public_pause') : $r('app.media.ic_public_play'))
          .width(26)
          .height(26)
          .fillColor($r('app.color.player_icon_color'))
          .onClick(() => {
            this.postCardCall('toggle')
          })
        Image($r('app.media.ic_public_play_next'))
          .width(20)
          .height(20)
          .fillColor($r('app.color.player_icon_color'))
          .onClick(() => {
            this.postCardCall('next')
          })
      }
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .height('100%')
    .padding(14)
    .alignItems(VerticalAlign.Center)
  }
}
