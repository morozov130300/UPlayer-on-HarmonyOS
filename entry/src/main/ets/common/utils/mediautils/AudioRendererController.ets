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

import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { resourceManager } from '@kit.LocalizationKit';
import { audio } from '@kit.AudioKit';
import { fileIo } from '@kit.CoreFileKit';
import { MediaTools } from './MediaTools';
import { Options, SECOND_BUFFER_WALK, SILENT_ID } from '../../constants/PlayerConstants';
import Logger from '../Logger';
import { MediaControlCenterCallbackAction } from './MediaControlCenterCallbackAction';
import { AppStorageKeyConstants } from '../../constants/AppStorageKeyConstants';

const TAG = 'audioRendererController';

export class AudioRendererController {
  public audioRenderer?: audio.AudioRenderer;
  private initOffset: number = 0;
  private currentOffset: number = 0;
  private bufferRead: number = 0;
  private bufferNeedRead: number = 0;
  private songRawFileDescriptor: resourceManager.RawFileDescriptor | undefined = undefined;
  private context: common.UIAbilityContext | undefined = AppStorage.get(AppStorageKeyConstants.KEY_UI_ABILITY_CONTEXT);
  private curMs: number = 0;
  private static audioRendererController: AudioRendererController;

  public static getInstance(): AudioRendererController {
    if (!AudioRendererController.audioRendererController) {
      AudioRendererController.audioRendererController = new AudioRendererController();
    }
    return AudioRendererController.audioRendererController;
  }

  // [Start initAudioRenderer]
  public async initAudioRenderer() {
    if (this.audioRenderer) {
      await this.audioRenderer.release();
      Logger.info(TAG, 'audioRenderer release ')
    }
    let audioStreamInfo: audio.AudioStreamInfo = {
      samplingRate: audio.AudioSamplingRate.SAMPLE_RATE_48000,
      channels: audio.AudioChannel.CHANNEL_2,
      sampleFormat: audio.AudioSampleFormat.SAMPLE_FORMAT_S16LE,
      encodingType: audio.AudioEncodingType.ENCODING_TYPE_RAW
    };

    let audioRendererInfo: audio.AudioRendererInfo = {
      usage: audio.StreamUsage.STREAM_USAGE_MUSIC,
      rendererFlags: 0,
      volumeMode: audio.AudioVolumeMode.SYSTEM_GLOBAL
    };

    let audioRendererOptions: audio.AudioRendererOptions = {
      streamInfo: audioStreamInfo,
      rendererInfo: audioRendererInfo
    };
    try {
      let audioRenderer = await audio.createAudioRenderer(audioRendererOptions);
      Logger.info(TAG, 'Invoke createAudioRenderer succeeded.');
      this.audioRenderer = audioRenderer;
      this.setAudioRendererCallbacks();
    } catch (err) {
      Logger.error(TAG, `Invoke createAudioRenderer failed, message is ${err}`);
    }
  }

  // [End initAudioRenderer]

  // Set the callback function
  private setAudioRendererCallbacks() {
    this.setWriteDataCallback();
    this.setInterruptCallback();
    this.setOutputDeviceChangeCallback();
  }

  // [Start setWriteDataCallback]
  // Set the data read retrieval call function
  private setWriteDataCallback() {
    if (!this.audioRenderer) {
      Logger.error(TAG, 'writeData fail, audioRenderer is undefined');
      return;
    }
    let secondBufferWalk = SECOND_BUFFER_WALK;
    let bufferWalk = 0;
    let options: Options;
    try {
      this.audioRenderer.on('writeData', (buffer) => {
        if (!this.songRawFileDescriptor) {
          return;
        }
        options = {
          offset: this.currentOffset,
          length: buffer.byteLength
        };
        fileIo.readSync(this.songRawFileDescriptor.fd, buffer, options);
        this.currentOffset += buffer.byteLength;
        this.bufferRead = this.currentOffset - this.initOffset;
        bufferWalk += buffer.byteLength;
        if (this.bufferRead <= this.bufferNeedRead) {
          if (bufferWalk >= secondBufferWalk) { // 1s seek
            let curMs = MediaTools.getMsFromByteLength(this.bufferRead);
            this.seek(curMs);
            bufferWalk = 0;
          }
        } else {
          bufferWalk = 0;
          let curMs = MediaTools.getMsFromByteLength(this.songRawFileDescriptor.length);
          Logger.info(TAG, 'setWriteDataCallback CurMs is ' + curMs);
          this.seek(curMs);
          MediaControlCenterCallbackAction.getInstance().doPlayNextAction();
        }
      })
    } catch (err) {
      Logger.error(TAG, `setWriteDataCallback failed: ${JSON.stringify(err)}`);
    }
  }

  // [End setWriteDataCallback]

  // Set the focus interrupt callback function
  private setInterruptCallback() {
    if (!this.audioRenderer) {
      return;
    }
    try {
      this.audioRenderer.on('audioInterrupt', this.interruptCallback);
    } catch (err) {
      Logger.error(TAG, `setInterruptCallback failed: ${JSON.stringify(err)}`);
    }
  }

  private interruptCallback: (interruptEvent: audio.InterruptEvent) => void =
    (interruptEvent: audio.InterruptEvent) => {
      Logger.info(TAG, `forceType: ${interruptEvent.forceType},interruptEvent:${interruptEvent.hintType}`)
      if (interruptEvent.forceType === audio.InterruptForceType.INTERRUPT_FORCE) {
        switch (interruptEvent.hintType) {
          case audio.InterruptHint.INTERRUPT_HINT_PAUSE:
            MediaControlCenterCallbackAction.getInstance().doPauseAction();
            break;
          case audio.InterruptHint.INTERRUPT_HINT_STOP:
            MediaControlCenterCallbackAction.getInstance().doPauseAction();
            break;
          case audio.InterruptHint.INTERRUPT_HINT_DUCK:
            Logger.info(TAG, 'INTERRUPT_HINT_DUCK')
            break;
          case audio.InterruptHint.INTERRUPT_HINT_UNDUCK:
            Logger.info(TAG, 'INTERRUPT_HINT_UNDUCK')
            break;
          default:
            break;
        }
      } else if (interruptEvent.forceType === audio.InterruptForceType.INTERRUPT_SHARE) {
        switch (interruptEvent.hintType) {
          case audio.InterruptHint.INTERRUPT_HINT_RESUME:
            MediaControlCenterCallbackAction.getInstance().doPlayAction();
            break;
          default:
            break;
        }
      }
    }

  // Set the output device callback function
  private setOutputDeviceChangeCallback() {
    if (!this.audioRenderer) {
      return;
    }
    try {
      this.audioRenderer.on('outputDeviceChangeWithInfo', this.outputDeviceChangeCallback);
    } catch (err) {
      Logger.error(TAG, `setOutputDeviceChangeCallback failed: ${JSON.stringify(err)}`);
    }
  }

  private outputDeviceChangeCallback(deviceChangeInfo: audio.AudioStreamDeviceChangeInfo) {
    Logger.info(TAG, `DeviceInfo id: ${deviceChangeInfo.devices[0].id}`);
    Logger.info(TAG, `DeviceInfo name: ${deviceChangeInfo.devices[0].name}`);
    Logger.info(TAG, `DeviceInfo address: ${deviceChangeInfo.devices[0].address}`);
    Logger.info(TAG, `Device change reason: ${deviceChangeInfo.changeReason}`);
    if (deviceChangeInfo.changeReason === audio.AudioStreamDeviceChangeReason.REASON_OLD_DEVICE_UNAVAILABLE) {
      Logger.info(TAG, `Device change reason: ${deviceChangeInfo.changeReason}`);
      MediaControlCenterCallbackAction.getInstance().doPauseAction();
    }
  }

  // [Start setSilentMode]
  // Set the silent mode
  public async setSilentMode(isSupportSilent: boolean = false) {
    if (!this.audioRenderer || !this.context) {
      return;
    }
    this.audioRenderer.setSilentModeAndMixWithOthers(isSupportSilent);
    AppStorage.setOrCreate(AppStorageKeyConstants.KEY_IS_SILENT_MODE, isSupportSilent);
  }

  // [End setSilentMode]

  // [Start loadSongAssent]
  public async loadSongAssent(songRawFileDescriptor: resourceManager.RawFileDescriptor) {
    if (!songRawFileDescriptor) {
      Logger.error(TAG, `loadSongAssent faile : songRawFileDescriptor get failed`);
      return;
    }
    this.initOffset = songRawFileDescriptor.offset;
    this.currentOffset = this.initOffset;
    Logger.info(TAG, `current currentOffset is ${this.currentOffset}`)
    this.bufferNeedRead = songRawFileDescriptor.length;
    this.bufferRead = 0;
    this.songRawFileDescriptor = songRawFileDescriptor;
  }

  // [End loadSongAssent]

  // [Start setSpeed]
  // Set the playback speed
  public setSpeed(speed: number) {
    if (this.audioRenderer) {
      try {
        this.audioRenderer.setSpeed(speed);
      } catch (err) {
        Logger.error(TAG, `setSpeed fail, err:${JSON.stringify(err)}`)
      }
    }
  }

  // [End setSpeed]

  public getVolume(): number {
    if (!this.audioRenderer) {
      Logger.error(TAG, `audioRenderer is undefined`)
      return 0;
    }
    Logger.info(TAG,
      `min is ${this.audioRenderer.getMinStreamVolumeSync()},max is ${this.audioRenderer.getMaxStreamVolumeSync()}`)
    return this.audioRenderer.getVolume();
  }

  // [Start setVolume]
  public setVolume(volume: number) {
    if (!this.audioRenderer) {
      Logger.error(TAG, `audioRenderer is undefined`)
      return;
    }
    this.audioRenderer.setVolume(volume);
  }

  // [End setVolume]

  // [Start play]
  // play music.
  public async play() {
    if (!this.audioRenderer) {
      Logger.error(TAG, `audioRenderer is undefined.`);
      return;
    }
    try {
      await this.audioRenderer.start().catch((err: BusinessError) => {
        Logger.error(TAG, `start failed,code is ${err.code},message is ${err.message}`);
      })
    } catch (e) {
      Logger.error(TAG, `start failed,audioRenderer is undefined`);
    }
  }

  // [End play]

  // [Start pause]
  // Pause music.
  public async pause() {
    if (this.audioRenderer) {
      try {
        await this.audioRenderer.pause().catch((err: BusinessError) => {
          Logger.error(TAG, `pause failed,code is ${err.code},message is ${err.message}`);
        })
        Logger.info(TAG, 'pause success');
      } catch (e) {
        Logger.error(TAG, `pause failed,audioRenderer is undefined`);
      }
    }
  }

  // [End pause]

  // [Start Seek]
  // Seek play music.
  public seek(ms: number) {
    if (ms < 0) {
      Logger.error(TAG, 'Invalid seek position')
    }
    this.curMs = ms;
    this.currentOffset = this.initOffset + MediaTools.getOffsetFromTime(this.curMs);
    MediaControlCenterCallbackAction.getInstance().doUpdateProgressAction(ms);
  }

  // [End Seek]


  // [Start stop]
  // Stop music
  public async stop() {
    if (this.audioRenderer) {
      try {
        await this.audioRenderer.stop().catch((err: BusinessError) => {
          Logger.error(TAG, `stop failed,code is ${err.code},message is ${err.message}`);
        })
        this.curMs = 0;
        await this.audioRenderer.flush();
        Logger.info(TAG, 'stop success');
      } catch (e) {
        Logger.error(TAG, `stop failed,audioRenderer is undefined`);
      }
    }
  }
  // [End stop]

  // [Start release]
  // Release audioRenderer
  public async release() {
    if (this.audioRenderer && this.context) {
      try {
        await AudioRendererController.getInstance().stop();
        await this.audioRenderer.release().catch((err: BusinessError) => {
          if (this.songRawFileDescriptor) {
            fileIo.close(this.songRawFileDescriptor.fd);
          }
          Logger.error(TAG, `release failed,code is ${err.code},message is ${err.message}`);
        })
        Logger.info(TAG, 'release success');
      } catch (err) {
        Logger.error(TAG,
          `release failed,audioRenderer is undefined, code is ${JSON.stringify(err.code)},message is ${JSON.stringify(err.message)}`);
      }
    }
  }
  // [End release]
}
