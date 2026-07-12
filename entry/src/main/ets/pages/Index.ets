@Entry
@Component
struct MainPage {
  @State currentIndex: number = 0

  build() {
    Tabs({ barPosition: BarPosition.End, index: this.currentIndex }){
      TabContent(){
        HomePage()
      }
    }
  }
}

// 主页内容
@Component
struct HomePage {
  build() {
    Column() {
      Text('这是主页')
        .fontSize(20)
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#ffffffff')
  }
}