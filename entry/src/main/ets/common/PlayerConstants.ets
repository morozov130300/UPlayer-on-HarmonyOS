export class PlayerKey {
  static readonly IS_PLAY: string = 'uplayer_is_play'
  static readonly CURRENT_TIME: string = 'uplayer_current_time'
  static readonly TOTAL_TIME: string = 'uplayer_total_time'
  static readonly PROGRESS: string = 'uplayer_progress'
  static readonly PROGRESS_MAX: string = 'uplayer_progress_max'
  static readonly SONG_LIST: string = 'uplayer_song_list'
  static readonly SELECT_INDEX: string = 'uplayer_select_index'
}

export enum PlayMode {
  ORDER = 0,
  SINGLE = 1,
  RANDOM = 2,
}
