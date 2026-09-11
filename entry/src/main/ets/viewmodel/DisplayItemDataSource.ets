import { SongInfo } from '../model/SongInfo'

class DisplayItem {
  isHeader: boolean = false
  headerText: string = ''
  song: SongInfo = new SongInfo()
  key: string = ''
}

export class DisplayItemDataSource implements IDataSource {
  private dataArray: DisplayItem[] = []
  private listeners: DataChangeListener[] = []

  constructor(items: DisplayItem[]) {
    for (let i = 0; i < items.length; i++) {
      this.dataArray.push(items[i])
    }
  }

  totalCount(): number {
    return this.dataArray.length
  }

  getData(index: number): DisplayItem {
    return this.dataArray[index]
  }

  reloadData(items: DisplayItem[]): void {
    this.dataArray = []
    for (let i = 0; i < items.length; i++) {
      this.dataArray.push(items[i])
    }
    this.notifyDataReload()
  }

  addData(index: number, data: DisplayItem): void {
    this.dataArray.splice(index, 0, data)
    this.notifyDataAdd(index)
  }

  pushData(data: DisplayItem): void {
    this.dataArray.push(data)
    this.notifyDataAdd(this.dataArray.length - 1)
  }

  registerDataChangeListener(listener: DataChangeListener): void {
    if (this.listeners.indexOf(listener) < 0) {
      this.listeners.push(listener)
    }
  }

  unregisterDataChangeListener(listener: DataChangeListener): void {
    const pos: number = this.listeners.indexOf(listener)
    if (pos >= 0) {
      this.listeners.splice(pos, 1)
    }
  }

  notifyDataReload(): void {
    for (let i = 0; i < this.listeners.length; i++) {
      this.listeners[i].onDataReloaded()
    }
  }

  notifyDataAdd(index: number): void {
    for (let i = 0; i < this.listeners.length; i++) {
      this.listeners[i].onDataAdd(index)
    }
  }

  notifyDataChange(index: number): void {
    for (let i = 0; i < this.listeners.length; i++) {
      this.listeners[i].onDataChange(index)
    }
  }

  notifyDataDelete(index: number): void {
    for (let i = 0; i < this.listeners.length; i++) {
      this.listeners[i].onDataDelete(index)
    }
  }

  notifyDataMove(from: number, to: number): void {
    for (let i = 0; i < this.listeners.length; i++) {
      this.listeners[i].onDataMove(from, to)
    }
  }

  moveItem(from: number, to: number): void {
    if (from < 0 || from >= this.dataArray.length || to < 0 || to > this.dataArray.length || from === to) {
      return
    }
    const moved: DisplayItem = this.dataArray.splice(from, 1)[0]
    this.dataArray.splice(to, 0, moved)
    this.notifyDataMove(from, to)
  }
}
