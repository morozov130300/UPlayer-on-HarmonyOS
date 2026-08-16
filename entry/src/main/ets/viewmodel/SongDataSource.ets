import { SongInfo } from '../model/SongInfo';

export class SongDataSource implements IDataSource {
  private dataArray: SongInfo[] = [];
  private listeners: DataChangeListener[] = [];

  constructor(element: SongInfo[]) {
    this.dataArray = element;
  }

  public reloadData(element: SongInfo[]): void {
    this.dataArray = element;
    this.notifyDataReload();
  }

  public totalCount(): number {
    return this.dataArray.length;
  }

  public getData(index: number): SongInfo {
    return this.dataArray[index];
  }

  public addData(index: number, data: SongInfo): void {
    this.dataArray.splice(index, 0, data);
    this.notifyDataAdd(index);
  }

  public pushData(data: SongInfo): void {
    this.dataArray.push(data);
    this.notifyDataAdd(this.dataArray.length - 1);
  }

  registerDataChangeListener(listener: DataChangeListener): void {
    if (this.listeners.indexOf(listener) < 0) {
      this.listeners.push(listener);
    }
  }

  unregisterDataChangeListener(listener: DataChangeListener): void {
    const pos = this.listeners.indexOf(listener);
    if (pos >= 0) {
      this.listeners.splice(pos, 1);
    }
  }

  notifyDataReload(): void {
    this.listeners.forEach((listener: DataChangeListener): void => {
      listener.onDataReloaded();
    });
  }

  notifyDataAdd(index: number): void {
    this.listeners.forEach((listener: DataChangeListener): void => {
      listener.onDataAdd(index);
    });
  }

  notifyDataChange(index: number): void {
    this.listeners.forEach((listener: DataChangeListener): void => {
      listener.onDataChange(index);
    });
  }

  notifyDataDelete(index: number): void {
    this.listeners.forEach((listener: DataChangeListener): void => {
      listener.onDataDelete(index);
    });
  }

  notifyDataMove(from: number, to: number): void {
    this.listeners.forEach((listener: DataChangeListener): void => {
      listener.onDataMove(from, to);
    });
  }
}
