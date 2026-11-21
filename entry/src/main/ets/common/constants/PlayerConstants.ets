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

/**
 * Constants for player area.
 */
export class PlayerConstants {
  static readonly ENCODING: string = 'utf-8';
  // ═══ 播放倍速统一档位表（播放器倍速弹窗与设置页播放分区共用，单一事实源）═══
  // 范围 0.25–3.0x、步进 0.25；0.25 是 2 的负幂，整数档位索引乘回去无浮点误差
  static readonly SPEED_MIN: number = 0.25;
  static readonly SPEED_MAX: number = 3.0;
  static readonly SPEED_STEP: number = 0.25;

  // 任意倍速值吸附到最近档位：范围钳制 + 按 0.25 步进取整。
  // 旧版本 0.1 粒度的存量值（如 0.8x）读取时经此吸附到 0.75x，保证两处滑杆显示与下发一致
  static snapSpeedToStep(speed: number): number {
    const clamped: number = Math.min(PlayerConstants.SPEED_MAX, Math.max(PlayerConstants.SPEED_MIN, speed));
    return Math.round(clamped / PlayerConstants.SPEED_STEP) * PlayerConstants.SPEED_STEP;
  }

  static readonly BACK_IMAGE: string = '120%';
  // Image.blur 渲染期模糊半径：与旧 effectKit 预模糊的半径语义不同（同数值下视觉更浅），
  // 应用户要求在真机确认值 50 基础上进一步加大
  static readonly IMAGE_BLUR: number = 80;
  static readonly FONT_WEIGHT_700: number = 700;
  static readonly FONT_WEIGHT_500: number = 500;
  static readonly FONT_FAMILY_BLACK: string = 'HarmonyHeiTi';
  static readonly FONT_FAMILY_BOLD: string = 'HarmonyHeiTi-Bold';
  static readonly FONT_FAMILY_MEDIUM: string = 'HarmonyHeiTi-Medium';
}

export enum MusicPlayMode {
  SINGLE_CYCLE = 0,
  ORDER = 1,
  RANDOM = 2
}

export const PlayModeSwitchList = [MusicPlayMode.ORDER, MusicPlayMode.RANDOM, MusicPlayMode.SINGLE_CYCLE];

