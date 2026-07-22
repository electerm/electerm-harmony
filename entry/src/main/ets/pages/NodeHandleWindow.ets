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
import { uiObserver } from '@kit.ArkUI';

let storage = LocalStorage.getShared();
@Entry(storage)
@Component
struct NodeHandleWindow {
  @LocalStorageLink('xcomponentId') xComponentId: string = '';
  @LocalStorageProp('statusBarHeight') statusBarHeight: number = 0;
  @State density: number = 0;
  private nativeContext: NativeContext =
    JsBindingUtils.getNativeContext(ContextType.kMainProcess);

  aboutToAppear(): void {
    uiObserver.on('densityUpdate', this.getUIContext(), (info: uiObserver.DensityInfo) => {
      this.density = info.density;
    });
  }

  aboutToDisappear(): void {
    uiObserver.off('densityUpdate', this.getUIContext());
  }

  onBackPress(): boolean {
    this.nativeContext.OnBackToLastPage(this.xComponentId);
    return true;
  }

  build() {
    Row() {
      WebNodeHandleWindow()
    }
    .width('100%')
    .height('100%')
    .padding({
      top: this.getStatusBarHeight(),
    })
  }

  getStatusBarHeight(): number {
    return this.getUIContext().px2vp(this.statusBarHeight);
  }
}
