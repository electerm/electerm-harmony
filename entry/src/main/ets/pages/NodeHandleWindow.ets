/**
 * NodeHandleWindow page — alternative WebWindow host for devices that
 * support the NodeHandle rendering path.
 *
 * Uses the WebNodeHandleWindow component from web_engine, which manages
 * the ContentSlot surface and native context (libadapter.so). The Electron
 * runtime (libelectron.so) starts automatically and loads
 * resfile/resources/app/main.js.
 *
 * This page is loaded by WebAbility when nativeContext.IsSupportNodeHandleFeature()
 * returns true. If the device does not support NodeHandle, pages/Index is used instead.
 */

import { WebNodeHandleWindow } from 'web_engine';
import { NativeContext } from 'web_engine/src/main/ets/interface/CommonInterface';
import JsBindingUtils from 'web_engine/src/main/ets/utils/JsBindingUtils';
import { ContextType } from 'web_engine/src/main/ets/common/Constants';

@Entry
@Component
struct NodeHandleWindow {
  @LocalStorageLink('xcomponentId') xComponentId: string = '';
  @LocalStorageProp('statusBarHeight') statusBarHeight: number = 0;
  private nativeContext: NativeContext =
    JsBindingUtils.getNativeContext(ContextType.kMainProcess);

  aboutToAppear(): void {
    // WebNodeHandleWindow and the native context are managed by web_engine.
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
      WebNodeHandleWindow()
    }
    .width('100%')
    .height('100%')
  }
}
