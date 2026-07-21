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
import { SongItem } from "../viewmodel/SongData"

/** 测试用歌单：保留两个最小歌曲文件 */
const songList: SongItem[] = [
  {
    id: 2,
    title: $r('app.string.song_title_two'),
    singer: $r('app.string.singer_two'),
    mark: $r('app.media.ic_sq'),
    label: $r('app.media.ic_avatar2'),
    src: 'world.pcm',
    index: 0,
    lyric: '',
    isDarkBackground: false
  },
  {
    id: 3,
    title: $r('app.string.song_title_three'),
    singer: $r('app.string.singer_three'),
    mark: $r('app.media.ic_vip'),
    label: $r('app.media.ic_avatar16'),
    src: 'power.pcm',
    index: 1,
    lyric: '',
    isDarkBackground: true
  }
]

export { songList }
