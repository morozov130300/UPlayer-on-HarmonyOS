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

import Logger from "./Logger";
import { window } from "@kit.ArkUI";
import { AppStorageKeyConstants } from "../constants/AppStorageKeyConstants";

const TAG = 'WindowUtil'

@Observed
export class WindowInfo {
  // Width/height breakpoint.
  public widthBp: WidthBreakpoint = WidthBreakpoint.WIDTH_XS;
  public heightBp: HeightBreakpoint = HeightBreakpoint.HEIGHT_SM;
}

export class WindowUtil {
  constructor(window: window.Window, uiContext: UIContext) {
    this.mainWindow = window;
    this.uiContext = uiContext;
  }

  private uiContext: UIContext | undefined = undefined;
  private mainWindow: window.Window | undefined = undefined;
  public mainWindowInfo: WindowInfo = new WindowInfo();
  public onWindowSizeChange: (windowSize: window.Size) => void = (windowSize: window.Size) => {
    if (!this.uiContext) {
      return;
    }
    this.mainWindowInfo.widthBp = this.uiContext.getWindowWidthBreakpoint();
    this.mainWindowInfo.heightBp = this.uiContext.getWindowHeightBreakpoint();
  };
  public onAvoidAreaChange: (avoidAreaOptions: window.AvoidAreaOptions) => void =
    (avoidAreaOptions: window.AvoidAreaOptions) => {
      this.setAvoidArea();
    }
  public onTitleButtonRectChange: (titleButtonRect: window.TitleButtonRect) => void =
    (titleButtonRect: window.TitleButtonRect) => {
      this.updateTitleButtonRect(titleButtonRect)
    }

  private updateTitleButtonRect(titleButtonRect: window.TitleButtonRect): void {
    if (this.uiContext === undefined) {
      return
    }
    const buttonWidth: number = this.uiContext.px2vp(titleButtonRect.width)
    const buttonHeight: number = this.uiContext.px2vp(titleButtonRect.height)
    AppStorage.setOrCreate(AppStorageKeyConstants.KEY_TITLE_BUTTON_WIDTH, buttonWidth)
    AppStorage.setOrCreate(AppStorageKeyConstants.KEY_TITLE_BUTTON_HEIGHT, buttonHeight)
  }

  setupImmersiveTitleButtons(): void {
    if (!this.mainWindow) {
      return
    }
    try {
      this.mainWindow.setWindowDecorVisible(false)
      this.mainWindow.setWindowTitleButtonVisible(true, true, true)
      this.mainWindow.setWindowTitleMoveEnabled(true)
      const decorButtonStyle: window.DecorButtonStyle = {
        buttonBackgroundSize: 40,
        spacingBetweenButtons: 8,
        closeButtonRightMargin: 8,
        buttonIconSize: 18,
        buttonBackgroundCornerRadius: 8
      }
      this.mainWindow.setDecorButtonStyle(decorButtonStyle)
      this.updateTitleButtonRect(this.mainWindow.getTitleButtonRect())
      this.mainWindow.on('windowTitleButtonRectChange', this.onTitleButtonRectChange)
    } catch (err) {
      Logger.error(TAG, `setupImmersiveTitleButtons failed: ${JSON.stringify(err)}`)
    }
  }

  setAvoidArea() {
    if (!this.mainWindow) {
      return;
    }
    if (!this.uiContext) {
      return;
    }
    let topArea: window.AvoidArea;
    let bottomArea: window.AvoidArea;
    try {
      topArea = this.mainWindow.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
      bottomArea = this.mainWindow.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR)
    } catch (err) {
      Logger.error(TAG, `getWindowAvoidArea failed: ${JSON.stringify(err)}`);
      return;
    }
    let topHeight: number;
    let bottomHeight: number;
    if (!topArea) {
      topHeight = 0;
    } else {
      topHeight = this.uiContext.px2vp(topArea.topRect.height)
    }
    if (!bottomArea) {
      bottomHeight = 0;
    } else {
      bottomHeight = this.uiContext.px2vp(bottomArea.bottomRect.height)
    }
    AppStorage.setOrCreate(AppStorageKeyConstants.KEY_TOP_HEIGHT, topHeight)
    AppStorage.setOrCreate(AppStorageKeyConstants.KEY_BOTTOM_HEIGHT, bottomHeight)
    Logger.info(TAG, `topHeight is ${topHeight}`)
    Logger.info(TAG, `bottomHeight is ${bottomHeight}`)
  }

  updateAvoidArea(): void {
    if (!this.mainWindow) {
      return;
    }
    if (!this.uiContext) {
      return;
    }
    this.mainWindow.on('avoidAreaChange', this.onAvoidAreaChange);
  }

  // ...
  updateWindowInfo(): void {
    if (!this.mainWindow) {
      return;
    }
    if (!this.uiContext) {
      return;
    }
    try {
      // First time get width/height breakpoint.
      this.mainWindowInfo.widthBp = this.uiContext.getWindowWidthBreakpoint();
      this.mainWindowInfo.heightBp = this.uiContext.getWindowHeightBreakpoint();
      // Register for window size change monitoring, update window size and width/height breakpoint.
      Logger.info(TAG, `windowSizeChange is onChange`)
      this.mainWindow.on('windowSizeChange', this.onWindowSizeChange);
    } catch (error) {
      let err = error as BusinessError;
      Logger.error(0x0000, `TestLog`, `Failed to update window info. Code: ${err.code}, message: ${err.message}`);
    }
  }
}
