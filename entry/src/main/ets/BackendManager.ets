/**
 * BackendManager — tracks the Node.js child process for the app lifetime.
 *
 * pages/Index starts the backend and records the pid here;
 * EntryAbility.onDestroy() calls BackendManager.killBackend() so the port
 * is freed when the app is terminated.
 */

import { killNode } from 'libnode_ctl.so';

export class BackendManager {
  static pid: number = -1;

  static setPid(pid: number): void {
    BackendManager.pid = pid;
  }

  static killBackend(): void {
    if (BackendManager.pid > 0) {
      try {
        killNode(BackendManager.pid);
        console.info(`[BackendManager] killed node pid=${BackendManager.pid}`);
      } catch (e) {
        console.error(`[BackendManager] kill failed: ${JSON.stringify(e)}`);
      }
      BackendManager.pid = -1;
    }
  }
}
