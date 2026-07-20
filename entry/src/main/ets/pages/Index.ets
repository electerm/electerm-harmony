/**
 * Index page — WebWindow host for the Electron 鸿蒙 runtime.
 *
 * Uses the WebWindow component from web_engine, which manages the
 * XComponent surface and native context (libadapter.so). The Electron
 * runtime (libelectron.so) starts automatically and loads
 * resfile/resources/app/main.js.
 */

import { WebWindow } from 'web_engine';
import { NativeContext } from 'web_engine/src/main/ets/interface/CommonInterface';
import JsBindingUtils from 'web_engine/src/main/ets/utils/JsBindingUtils';
import { ContextType } from 'web_engine/src/main/ets/common/Constants';

@Entry
@Component
struct Index {
  @LocalStorageLink('xcomponentId') xComponentId: string = '';
  @LocalStorageProp('statusBarHeight') statusBarHeight: number = 0;
  private nativeContext: NativeContext =
    JsBindingUtils.getNativeContext(ContextType.kMainProcess);

  aboutToAppear(): void {
    // WebWindow and the native context are managed by web_engine.
    // No manual initialization needed here.
  }

  onBackPress(): boolean {
    if (this.nativeContext) {
      this.nativeContext.OnBackToLastPage(this.xComponentId);
    }
    return true;
  }

  build() {
    Row() {
      WebWindow()
    }
    .width('100%')
    .height('100%')
  }
}
