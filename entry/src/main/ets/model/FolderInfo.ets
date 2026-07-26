// 文件夹信息数据模型
export class FolderInfo {
  id: string = ''
  name: string = ''           // 文件夹名称
  path: string = ''           // 文件夹路径
  songCount: number = 0       // 文件夹内歌曲数量
  addedTime: number = Date.now()  // 添加时间戳
  isAvailable: boolean = true // 文件夹是否可用

  // 生成唯一ID
  static createId(): string {
    return 'folder_' + Date.now() + '_' + Math.floor(Math.random() * 1000000)
  }

  // 从文件夹路径创建FolderInfo
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
