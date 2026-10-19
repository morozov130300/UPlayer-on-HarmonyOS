import { audioQualityBadgeDetail, audioQualityTier } from '../common/utils/AudioQualityUtil'

/**
 * 封面左下角音质标签（黑金配色）：
 * 深黑渐变底 + 鎏金描边 + 金色光晕，等级缩写金色加粗、详情暖白，中间竖向金色渐变分隔线。
 * tier/detail 为空时对应部分不渲染，全空时整个标签不渲染（由调用处保证）。
 */
@Component
export struct AudioQualityBadge {
  @Prop tier: string = '';
  @Prop detail: string = '';
  @Prop fontSizeScale: number = 1.0;

  build() {
    Row({ space: 5 }) {
      if (this.tier.length > 0) {
        Text(this.tier)
          .fontSize(Math.round(10 * this.fontSizeScale))
          .fontColor('#F6DE9C')
          .fontWeight(FontWeight.Bold)
          .maxLines(1)
          .textShadow({ radius: 4, color: 'rgba(244, 208, 120, 0.5)', offsetX: 0, offsetY: 0 })
      }
      if (this.tier.length > 0 && this.detail.length > 0) {
        Column()
          .width(1)
          .height(Math.round(9 * this.fontSizeScale))
          .linearGradient({
            angle: 90,
            colors: [
              ['rgba(230, 200, 130, 0.15)', 0],
              ['rgba(230, 200, 130, 0.8)', 0.5],
              ['rgba(230, 200, 130, 0.15)', 1],
            ]
          })
      }
      if (this.detail.length > 0) {
        Text(this.detail)
          .fontSize(Math.round(10 * this.fontSizeScale))
          .fontColor('rgba(238, 230, 210, 0.92)')
          .fontWeight(FontWeight.Medium)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .constraintSize({ maxWidth: '70%' })
      }
    }
    .padding({ left: 8, right: 8, top: 3, bottom: 3 })
    .borderRadius(10)
    .linearGradient({
      angle: 135,
      colors: [
        ['#3B3122', 0],
        ['#0E0C08', 0.55],
        ['#2A2418', 1],
      ]
    })
    .border({ width: 1, color: 'rgba(228, 194, 122, 0.55)' })
    .shadow({ radius: 6, color: 'rgba(212, 175, 55, 0.3)', offsetX: 0, offsetY: 1 })
    .margin({ left: 8, bottom: 8 })
    .hitTestBehavior(HitTestMode.None)
  }
}
