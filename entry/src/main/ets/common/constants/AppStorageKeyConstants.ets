/*
 * Copyright (c) 2026 Huawei Device Co., Ltd.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

import { BaseConstants } from './BaseConstants'

export class AppStorageKeyConstants {
  public static readonly KEY_WINDOW_UTIL: string = BaseConstants.KEY_PREFIX + 'WindowUtil'
  public static readonly KEY_IS_PLAY: string = BaseConstants.KEY_PREFIX + 'IsPlay'
  public static readonly KEY_CURRENT_TIME: string = BaseConstants.KEY_PREFIX + 'CurrentTime'
  public static readonly KEY_TOTAL_TIME: string = BaseConstants.KEY_PREFIX + 'TotalTime'
  public static readonly KEY_TOTAL_MS_TIME: string = BaseConstants.KEY_PREFIX + 'TotalMsTime'
  public static readonly KEY_PROGRESS_MAX: string = BaseConstants.KEY_PREFIX + 'ProgressMax'
  public static readonly KEY_PROGRESS: string = BaseConstants.KEY_PREFIX + 'Progress'
  public static readonly KEY_IMAGE_COLOR: string = BaseConstants.KEY_PREFIX + 'ImageColor'
  public static readonly KEY_PAGE_SHOW_TIME: string = BaseConstants.KEY_PREFIX + 'PageShowTime'
  public static readonly KEY_SONG_LIST: string = BaseConstants.KEY_PREFIX + 'SongList'
  public static readonly KEY_LIBRARY_REVISION: string = BaseConstants.KEY_PREFIX + 'LibraryRevision'
  public static readonly KEY_FILTER_REVISION: string = BaseConstants.KEY_PREFIX + 'FilterRevision'
  // 仅在歌词引用发生集合级变化（自愈回填 / 导入覆盖）时 +1，
  // 不能复用 KEY_LIBRARY_REVISION：后者会被收藏切换等高频操作触发，导致歌词文件被反复重读
  public static readonly KEY_LYRIC_REVISION: string = BaseConstants.KEY_PREFIX + 'LyricRevision'
  public static readonly KEY_PLAY_MODE: string = BaseConstants.KEY_PREFIX + 'PlayMode'
  public static readonly KEY_SELECT_INDEX: string = BaseConstants.KEY_PREFIX + 'SelectIndex'
  public static readonly KEY_CURRENT_SPEED: string = BaseConstants.KEY_PREFIX + 'CurrentSpeed'
  public static readonly KEY_CURRENT_VOLUME: string = BaseConstants.KEY_PREFIX + 'CurrentVolume'
  public static readonly KEY_IS_FAVORITE: string = BaseConstants.KEY_PREFIX + 'IsFavorite'
  public static readonly KEY_TOP_HEIGHT: string = BaseConstants.KEY_PREFIX + 'TopHeight'
  public static readonly KEY_BOTTOM_HEIGHT: string = BaseConstants.KEY_PREFIX + 'BottomHeight'
  public static readonly KEY_TITLE_BUTTON_WIDTH: string = BaseConstants.KEY_PREFIX + 'TitleButtonWidth'
  public static readonly KEY_TITLE_BUTTON_HEIGHT: string = BaseConstants.KEY_PREFIX + 'TitleButtonHeight'
  public static readonly KEY_UI_ABILITY_CONTEXT: string = BaseConstants.KEY_PREFIX + 'UIAbilityContext'
  public static readonly KEY_WINDOW: string = BaseConstants.KEY_PREFIX + 'Window'
  public static readonly KEY_TIMER_REMAINING: string = BaseConstants.KEY_PREFIX + 'TimerRemaining'
  // 当前运行中的定时所对应的预设分钟数（-1 表示自定义或无定时），
  // 用于把倒计时固定显示在原设定项上，避免被面板里的待确认选择抢走
  public static readonly KEY_TIMER_PRESET_MINUTES: string = BaseConstants.KEY_PREFIX + 'TimerPresetMinutes'
  public static readonly KEY_IMPORT_RUNNING: string = BaseConstants.KEY_PREFIX + 'ImportRunning'
  public static readonly KEY_IMPORT_TOTAL: string = BaseConstants.KEY_PREFIX + 'ImportTotal'
  public static readonly KEY_IMPORT_DONE: string = BaseConstants.KEY_PREFIX + 'ImportDone'
  public static readonly KEY_HOME_MULTI_SELECT: string = BaseConstants.KEY_PREFIX + 'HomeMultiSelect'
  // Ctrl+A 全选请求（计数器）：页面级键盘事件无法直接改 HomeContent 的 @State，
  // 每次按下 +1 触发 HomeContent 的 @Watch，由它在多选态下把可见歌曲全部选中
  public static readonly KEY_HOME_SELECT_ALL_REQUEST: string = BaseConstants.KEY_PREFIX + 'HomeSelectAllRequest'
  // 主窗口可见性（EntryAbility onForeground/onBackground 写入）：
  // 窗口隐藏时各周期性 UI 状态更新检查此键并暂停写入，避免隐藏窗口请求 vsync 收不到帧刷告警；
  // 键缺失时按可见处理
  public static readonly KEY_UI_ACTIVE: string = BaseConstants.KEY_PREFIX + 'UiActive'
  // 耳机/蓝牙输出设备断开时是否继续播放（设置页「播放」区开关，默认关）：
  // 关闭时 AudioRoutingService 检测到断开会暂停播放并提示
  public static readonly KEY_CONTINUE_PLAY_ON_UNPLUG: string = BaseConstants.KEY_PREFIX + 'ContinuePlayOnUnplug'
  // 输出设备列表/首选设备变化计数器：AudioRoutingService 在 availableDeviceChange 时 +1，
  // 「更多」面板的「输出设备」行 @StorageProp @Watch 到变化后刷新设备名与列表
  public static readonly KEY_OUTPUT_DEVICE_REVISION: string = BaseConstants.KEY_PREFIX + 'OutputDeviceRevision'
}
