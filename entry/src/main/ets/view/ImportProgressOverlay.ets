import { AppStorageKeyConstants } from '../common/constants/AppStorageKeyConstants'

// 导入进度浮层：全屏遮罩 + 玻璃质感圆角卡片 + 环形进度与百分比，
// 由 SongScanner 通过 AppStorage 进度键驱动，未导入时不拦截任何触摸。
@Component
export struct ImportProgressOverlay {
  @StorageProp(AppStorageKeyConstants.KEY_IMPORT_RUNNING) private importRunning: boolean = false
  @StorageProp(AppStorageKeyConstants.KEY_IMPORT_TOTAL) private importTotal: number = 0
  @StorageProp(AppStorageKeyConstants.KEY_IMPORT_DONE) private importDone: number = 0
  @StorageProp('uplayer_primary_color') private primaryColor: string = '#007DFF'

  private percent(): number {
    if (this.importTotal <= 0) {
      return 0
    }
    return Math.min(100, Math.floor(this.importDone * 100 / this.importTotal))
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      if (this.importRunning) {
        // 半透明暗色遮罩：弱化背景、聚焦进度
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor('rgba(0, 0, 0, 0.32)')
          .transition({ type: TransitionType.All, opacity: 0 })

        Column({ space: 18 }) {
          Stack({ alignContent: Alignment.Center }) {
            Progress({
              value: this.importDone,
              total: Math.max(this.importTotal, 1),
              type: ProgressType.Ring
            })
              .style({ strokeWidth: 7, scaleCount: 0, scaleWidth: 0 })
              .width(76)
              .height(76)
              .color(this.primaryColor)
              .backgroundColor('rgba(255, 255, 255, 0.12)')
            Text(`${this.percent()}%`)
              .fontSize(17)
              .fontWeight(FontWeight.Bold)
              .fontColor('#FFFFFF')
          }

          Text(`正在导入 ${this.importDone} / ${this.importTotal} 首`)
            .fontSize(14)
            .fontColor('rgba(255, 255, 255, 0.75)')
        }
        .alignItems(HorizontalAlign.Center)
        .justifyContent(FlexAlign.Center)
        .padding(30)
        .borderRadius(26)
        .backgroundColor('rgba(30, 30, 32, 0.9)')
        .shadow({
          radius: 36,
          color: 'rgba(0, 0, 0, 0.28)',
          offsetX: 0,
          offsetY: 12
        })
        .transition({ type: TransitionType.All, opacity: 0, scale: { x: 0.92, y: 0.92 } })
      }
    }
    .width('100%')
    .height('100%')
    .hitTestBehavior(this.importRunning ? HitTestMode.Default : HitTestMode.None)
  }
}
