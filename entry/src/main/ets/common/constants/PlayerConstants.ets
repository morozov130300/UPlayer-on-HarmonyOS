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
  static readonly BACK_IMAGE: string = '120%';
  // Image.blur 渲染期模糊半径：与旧 effectKit 预模糊的半径语义不同（同数值下视觉更浅），
  // 50 为用户真机对比旧 effectKit blur(15) 观感确认后的值
  static readonly IMAGE_BLUR: number = 50;
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

