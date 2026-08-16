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

import { songList } from '../../../model/SongListData';
import { SongItem } from '../../../viewmodel/SongData';
import SongItemBuilder from '../../../viewmodel/SongItemBuilder';
import { DEFAULT_VOLUME, MusicPlayMode, SILENT_ID, VOLUME_ID } from '../../constants/PlayerConstants';
import Logger from '../Logger';
import { AVSessionController } from './AVSessionController';
import { resourceManager } from '@kit.LocalizationKit';
import { MediaTools } from './MediaTools';
import { MediaControlCenterHandle } from './MediaControlCenterHandle';
import { BackgroundUtil } from '../BackgroundUtil';
import { common } from '@kit.AbilityKit';
import { PreferencesUtil } from '../PreferencesUtil';
import { audio } from '@kit.AudioKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { AppStorageKeyConstants } from '../../constants/AppStorageKeyConstants';

const TAG = 'MediaControlCenter';

export class MediaControlCenter {
  private avSessionController: AVSessionController | undefined = undefined;
  private mediaControlCenterHandle: MediaControlCenterHandle | undefined = undefined;
  private context: common.UIAbilityContext | undefined = AppStorage.get(AppStorageKeyConstants.KEY_UI_ABILITY_CONTEXT);
  private songItemBuilder: SongItemBuilder = new SongItemBuilder();
  private songRawFileDescriptor: resourceManager.RawFileDescriptor | undefined = undefined;
  private playMode: MusicPlayMode = MusicPlayMode.ORDER;
  private songList: SongItem[] = [];
  private musicIndex: number = 0;
  private audioSessionManager: audio.AudioSessionManager | undefined = undefined;
  private isInitted = false;
  private static mediaControlFunction: MediaControlCenter;

  constructor() {
    this.songList = songList;
    AppStorage.setOrCreate(AppStorageKeyConstants.KEY_SONG_LIST, songList);
    this.songItemBuilder = new SongItemBuilder();
  }

  // [Start loadSongAssent]
  private async loadSongAssent() {
    await this.songItemBuilder.build(this.songList[this.musicIndex]);
    this.songRawFileDescriptor = this.songItemBuilder.getRawFileDescriptor();
    if (!this.songRawFileDescriptor) {
      Logger.error(TAG, `loadSongAssent faile : songRawFileDescriptor get failed`);
      return;
    }
    Logger.info(TAG, `get duration is ${this.getDuration()}`);
    AppStorage.setOrCreate(AppStorageKeyConstants.KEY_TOTAL_TIME, MediaTools.msToCountdownTime(this.getDuration()));
    AppStorage.setOrCreate(AppStorageKeyConstants.KEY_TOTAL_MS_TIME, this.getDuration());
    AppStorage.setOrCreate(AppStorageKeyConstants.KEY_PROGRESS_MAX, this.getDuration());
    if (!this.mediaControlCenterHandle) {
      Logger.error(TAG, 'mediaControlCenterHandle is undefined');
      return;
    }
    this.mediaControlCenterHandle.loadSongAssent(this.songRawFileDescriptor);
  }

  // [End loadSongAssent]

  // Get the total duration of the song
  private getDuration() {
    if (this.songRawFileDescriptor) {
      AppStorage.setOrCreate(AppStorageKeyConstants.KEY_TOTAL_BYTE_LENGTH, this.songRawFileDescriptor.length);
      return MediaTools.getMsFromByteLength(this.songRawFileDescriptor.length);
    }
    return 0;
  }

  public static getInstance(): MediaControlCenter {
    if (!MediaControlCenter.mediaControlFunction) {
      MediaControlCenter.mediaControlFunction = new MediaControlCenter();
    }
    return MediaControlCenter.mediaControlFunction;
  }

  private async initAVSession() {
    this.avSessionController = AVSessionController.getInstance();
    await this.avSessionController.initAVSession();
  }

  private async initHandle() {
    this.mediaControlCenterHandle = MediaControlCenterHandle.getInstance();
    await this.mediaControlCenterHandle.init();
  }

  private async initAudioManager() {
    let audioManger = audio.getAudioManager();
    this.audioSessionManager = audioManger.getSessionManager();
    await this.activateAudioSession();
  }

  private async activateAudioSession(concurrencyMode: audio.AudioConcurrencyMode = audio.AudioConcurrencyMode.CONCURRENCY_PAUSE_OTHERS) {
    if (!this.audioSessionManager) {
      return;
    }
    let strategy: audio.AudioSessionStrategy = {
      concurrencyMode: concurrencyMode
    };
    try {
      await this.audioSessionManager.activateAudioSession(strategy);
      Logger.info(TAG, 'activateAudioSession SUCCESS');
    } catch (err) {
      Logger.error(TAG, `activateAudioSession failed: ${JSON.stringify(err)}`);
    }
  }

  private async deactivateAudioSession() {
    if (!this.audioSessionManager) {
      return;
    }
    try {
      await this.audioSessionManager.deactivateAudioSession();
      Logger.info(TAG, 'deactivateAudioSession SUCCESS');
    } catch (err) {
      Logger.error(TAG, `deactivateAudioSession failed: ${JSON.stringify(err)}`);
    }
  }

  public async init() {
    if (this.isInitted) {
      return;
    }
    await this.initHandle();
    await this.loadSongAssent();
    await this.initAVSession();
    await this.initAudioManager();
    this.setSilentModeFromPrefer();
    this.setVolumeFromPrefer();
    this.isInitted = true;
  }

  public release() {
    if (!this.mediaControlCenterHandle) {
      Logger.error(TAG, 'mediaControlCenterHandle is undefined');
      return;
    }
    if (!this.avSessionController) {
      Logger.error(TAG, 'avSessionController is undefined');
      return;
    }
    this.avSessionController.unregisterSessionListener();
    this.mediaControlCenterHandle.release();
    this.songItemBuilder.release();
    this.isInitted = false;
  }

  // [Start StartContinuousTask]
  public async play(index: number = this.musicIndex) {
    Logger.info(TAG, `index is ${index},musicIndex is ${this.musicIndex}`)
    if (!this.mediaControlCenterHandle) {
      Logger.error(TAG, 'mediaControlCenterHandle is undefined');
      return;
    }
    if (index !== this.musicIndex) {
      this.updateMusicIndex(index);
      await this.stop();
      await this.loadSongAssent();
    }
    this.updateIsPlay(true);
    this.mediaControlCenterHandle.play();
    BackgroundUtil.startContinuousTask(this.context);
  }

  public pause() {
    if (!this.mediaControlCenterHandle) {
      Logger.error(TAG, 'mediaControlCenterHandle is undefined');
      return;
    }
    this.mediaControlCenterHandle.pause();
    this.updateIsPlay(false);
    BackgroundUtil.stopContinuousTask(this.context!);
  }

  // [End StartContinuousTask]

  // Obtain a secure random number between 0 and 1
  private getSecureRandom0To1(): number {
    try {
      const rand = cryptoFramework.createRandom();
      const randData = rand.generateRandomSync(1);
      let randomMum: number = randData.data[0] * 1 / 255;
      return randomMum;
    } catch (err) {
      Logger.error(TAG, `getSecureRandom0To1 failed: ${JSON.stringify(err)}`);
      return Math.random();
    }
  }

  // Set a secure random number
  private setRandom() {
    let random0To1 = this.getSecureRandom0To1();
    let num = Math.round(random0To1 * (this.songList.length - 1));
    Logger.info(TAG, `random num is ${num},max length is ${this.songList.length - 1}`)
    if (this.musicIndex === num) {
      this.setRandom();
    }
    return num;
  }

  // [Start playNext]
  public async playNext() {
    await this.stop();
    let nextIndex = this.musicIndex;
    switch (this.playMode) {
      case MusicPlayMode.SINGLE_CYCLE:
        break;
      case MusicPlayMode.ORDER:
        if (this.musicIndex === this.songList.length - 1) {
          nextIndex = 0;
        } else {
          nextIndex += 1;
        }
        break;
      case MusicPlayMode.RANDOM:
        nextIndex = this.setRandom();
        break;
      default:
        break;
    }
    this.updateMusicIndex(nextIndex);
    await this.loadSongAssent();
    Logger.info(TAG, `nextIndex is ${nextIndex}`);
    await this.play();
  }

  // [End playNext]

  public async playPrevious() {
    await this.stop();
    let preIndex = this.musicIndex;
    switch (this.playMode) {
      case MusicPlayMode.SINGLE_CYCLE:
        break;
      case MusicPlayMode.ORDER:
        if (this.musicIndex === 0) {
          preIndex = this.songList.length - 1;
        } else {
          preIndex -= 1;
          if (preIndex < 0) {
            preIndex = this.songList.length - 1
          }
        }
        break;
      case MusicPlayMode.RANDOM:
        preIndex = this.setRandom();
        break;
      default:
        break;
    }
    this.updateMusicIndex(preIndex);
    await this.loadSongAssent();
    await this.play();
  }

  public async stop() {
    if (!this.context) {
      return;
    }
    if (!this.mediaControlCenterHandle) {
      return;
    }
    AppStorage.setOrCreate(AppStorageKeyConstants.KEY_CURRENT_TIME, '00:00');
    AppStorage.setOrCreate(AppStorageKeyConstants.KEY_PROGRESS, 0);
    await this.mediaControlCenterHandle.stop();
    Logger.info(TAG, 'stop success')
    BackgroundUtil.stopContinuousTask(this.context);
  }

  // Set play model
  public setPlayModel(playMode: MusicPlayMode) {
    if (!this.avSessionController) {
      return;
    }
    this.playMode = playMode;
    this.avSessionController.setPlayModeToAVSession(playMode);
    this.setPlayModeToControlArea(playMode);
  }

  private setPlayModeToControlArea(playMode: MusicPlayMode) {
    AppStorage.setOrCreate(AppStorageKeyConstants.KEY_PLAY_MODE, playMode);
  }

  public updateIsPlay(isPlay: boolean) {
    Logger.info(TAG, `avSessionController isPlay is ${isPlay}`)
    AppStorage.setOrCreate<boolean>(AppStorageKeyConstants.KEY_IS_PLAY, isPlay);
    if (!this.avSessionController) {
      Logger.error(TAG, `avSessionController is undefined`);
      return;
    }
    this.avSessionController.setPlayState(isPlay);
  }

  public getVolume(): number {
    if (!this.mediaControlCenterHandle) {
      return 0;
    }
    return this.mediaControlCenterHandle.getVolume();
  }

  public setVolume(volume: number) {
    if (!this.mediaControlCenterHandle) {
      Logger.error(TAG, 'mediaControlCenterHandle is undefined');
      return;
    }
    this.mediaControlCenterHandle.setVolume(volume);
  }

  public setSpeed(speed: number) {
    if (!this.mediaControlCenterHandle) {
      Logger.error(TAG, 'mediaControlCenterHandle is undefined');
      return;
    }
    this.mediaControlCenterHandle.setSpeed(speed)
  }

  // Set silent mode
  public async setSilentMode(isSilentMode: boolean = false) {
    if (!this.context) {
      return;
    }
    if (!this.mediaControlCenterHandle) {
      Logger.info(TAG, 'mediaControlCenterHandle is undefined in setSilentModeAndMixWithOthers')
      return;
    }
    PreferencesUtil.getInstance().preferencesPut(SILENT_ID, isSilentMode);
    if (isSilentMode) {
      this.activateAudioSession(audio.AudioConcurrencyMode.CONCURRENCY_MIX_WITH_OTHERS)
    } else {
      this.activateAudioSession();
    }
    this.mediaControlCenterHandle.setSilentMode(isSilentMode);
  }

  private async setSilentModeFromPrefer() {
    if (!this.context) {
      return;
    }
    let isSupportSilent: boolean | undefined = PreferencesUtil.getInstance().getValue(SILENT_ID) as boolean | undefined;
    if (isSupportSilent === undefined) {
      isSupportSilent = false;
    }
    AppStorage.setOrCreate(AppStorageKeyConstants.KEY_IS_SILENT_MODE, isSupportSilent);
    this.setSilentMode(isSupportSilent)
  }

  private async setVolumeFromPrefer() {
    if (!this.context) {
      return;
    }
    let volume: number | undefined = PreferencesUtil.getInstance().getValue(VOLUME_ID) as number | undefined;
    if (volume === undefined) {
      volume = DEFAULT_VOLUME;
    }
    Logger.info(TAG, `setVolumeFromPrefer volume is ${volume}`)
    this.setVolume(volume);
    AppStorage.setOrCreate(AppStorageKeyConstants.KEY_CURRENT_VOLUME, volume);
  }

  public seek(ms: number) {
    if (!this.mediaControlCenterHandle) {
      Logger.error(TAG, 'mediaControlCenterHandle is undefined');
      return;
    }
    this.mediaControlCenterHandle.seek(ms);
    this.updateProgress(ms);
  }

  public updateProgress(ms: number) {
    if (!this.avSessionController) {
      return;
    }
    this.avSessionController.setProgressState(ms);
    AppStorage.setOrCreate(AppStorageKeyConstants.KEY_PROGRESS, ms);
    AppStorage.setOrCreate(AppStorageKeyConstants.KEY_CURRENT_TIME, MediaTools.msToCountdownTime(ms));
  }

  private updateMusicIndex(musicIndex: number) {
    Logger.info(TAG, 'updateMusicIndex ===> ' + musicIndex);
    this.musicIndex = musicIndex;
    AppStorage.setOrCreate(AppStorageKeyConstants.KEY_SELECT_INDEX, musicIndex);
    if (!this.avSessionController) {
      return;
    }
    this.avSessionController.setAVMetadata();
    this.avSessionController.getAndUpdateFavoriteState(this.musicIndex.toString());
  }
}
