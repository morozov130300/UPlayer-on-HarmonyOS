/*
 * 自定义歌单（P2-3）：歌单元数据行，对应 playlists 表。
 * 曲目清单存 playlist_items 表（playlistId + songId），由 DataService 组装缓存。
 */
export class PlaylistInfo {
  id: string = ''
  name: string = ''
  createdTime: number = 0
  sortOrder: number = 0
  coverSongId: string = ''
}
