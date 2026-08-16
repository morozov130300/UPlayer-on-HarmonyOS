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

import { BusinessError } from '@kit.BasicServicesKit';
import { ComponentContent, promptAction, UIContext } from '@kit.ArkUI';
import Logger from '../common/utils/Logger';

const DOMAIN = 0x0000;


export  class Params {
  public text: string | Resource = '';

  constructor(text: string | Resource) {
    this.text = text;
  }
}

@Builder
export function buildText(params: Params) {
  Column() {
    Text(params.text)
      .fontSize(16)
      .fontWeight(FontWeight.Bold)
  }
  .width('90%')
  .backgroundColor('rgba(241,243,245,0.7)')
  .padding({ top: 20, bottom: 20 })
  .borderRadius(35)
}

export class PromptActionClassNew {
  static ctx: UIContext;
  static contentNode: ComponentContent<Object>;
  static options: promptAction.BaseDialogOptions;

  static setContext(context: UIContext) {
    PromptActionClassNew.ctx = context;
  }

  static setContentNode(node: ComponentContent<Object>) {
    PromptActionClassNew.contentNode = node;
  }

  static setOptions(options: promptAction.BaseDialogOptions) {
    PromptActionClassNew.options = options;
  }

  // 打开弹窗
  static openDialog() {
    if (PromptActionClassNew.ctx === undefined) {
      return;
    }
    if (PromptActionClassNew.contentNode !== null) {
      PromptActionClassNew.ctx.getPromptAction()
        .openCustomDialog(PromptActionClassNew.contentNode, PromptActionClassNew.options)
        .then(() => {
          Logger.info(DOMAIN, 'testTag', 'testTag', 'OpenCustomDialog complete.');
        })
        .catch((error: BusinessError) => {
          let message = (error as BusinessError).message;
          let code = (error as BusinessError).code;
          Logger.error(DOMAIN, 'testTag', 'testTag',
            'OpenCustomDialog args error code is ${code}, message is ${message}');
        })
    }
  }

  static closeDialog() {
    if (PromptActionClassNew.ctx === undefined) {
      return;
    }
    if (PromptActionClassNew.contentNode !== null) {
      PromptActionClassNew.ctx.getPromptAction()
        .closeCustomDialog(PromptActionClassNew.contentNode)
        .then(() => {
          Logger.info(DOMAIN, 'testTag', 'testTag', 'CloseCustomDialog complete.');
        })
        .catch((error: BusinessError) => {
          let message = (error as BusinessError).message;
          let code = (error as BusinessError).code;
          Logger.error(DOMAIN, 'testTag', 'testTag',
            'CloseCustomDialog args error code is ${code}, message is ${message}');
        })
    }
  }

  static updateDialog(options: promptAction.BaseDialogOptions) {
    if (PromptActionClassNew.ctx === undefined) {
      return;
    }
    if (PromptActionClassNew.contentNode !== null) {
      PromptActionClassNew.ctx.getPromptAction()
        .updateCustomDialog(PromptActionClassNew.contentNode, options)
        .then(() => {
          Logger.info(DOMAIN, 'testTag', 'testTag', 'UpdateCustomDialog complete.');
        })
        .catch((error: BusinessError) => {
          let message = (error as BusinessError).message;
          let code = (error as BusinessError).code;
          Logger.error(DOMAIN, 'testTag', 'testTag',
            'UpdateCustomDialog args error code is ${code}, message is ${message}');
        })
    }
  }
}
