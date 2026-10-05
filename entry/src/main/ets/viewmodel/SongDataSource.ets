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
}
