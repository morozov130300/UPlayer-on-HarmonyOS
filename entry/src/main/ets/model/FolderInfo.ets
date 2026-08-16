export class FolderInfo {
  id: string = '';
  name: string = '';
  path: string = '';
  songCount: number = 0;
  addedTime: number = Date.now();
  isAvailable: boolean = true;

  static createId(): string {
    return 'folder_' + Date.now() + '_' + Math.floor(Math.random() * 1000000)
  }

  static fromPath(folderPath: string): FolderInfo {
    const folder: FolderInfo = new FolderInfo();
    folder.id = FolderInfo.createId();
    folder.path = folderPath;
    const lastSlash: number = folderPath.lastIndexOf('/')
    const lastBackslash: number = folderPath.lastIndexOf('\\')
    const sepIdx: number = lastSlash > lastBackslash ? lastSlash : lastBackslash
    folder.name = sepIdx >= 0 ? folderPath.substring(sepIdx + 1) : folderPath
    folder.songCount = 0
    folder.addedTime = Date.now()
    folder.isAvailable = true
    return folder
  }
}
