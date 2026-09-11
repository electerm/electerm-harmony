/**
 * AbilityStage — app-level initialization.
 *
 * Minimal for the web app: all backend bootstrapping happens in
 * pages/Index (native child process + HTTP polling). Kept as the module
 * srcEntry for future app-level hooks.
 */

import { AbilityStage } from '@kit.AbilityKit';

export default class ElectermAbilityStage extends AbilityStage {
  onCreate(): void {
    console.info('[ElectermAbilityStage] onCreate');
  }
}
