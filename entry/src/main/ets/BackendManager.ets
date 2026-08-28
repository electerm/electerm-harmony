/**
 * BackendManager — tracks the Node.js backend for the app lifetime.
 *
 * pages/Index starts the backend and records how it runs:
 *   - in-process (node::Start on a thread of the MAIN app process, via
 *     libnode_ctl.so startBackend — the electron-harmony pattern; dodges
 *     the nativespawn child's stricter seccomp) → inProcess = true
 *   - native child process (libnode_launcher.so:Main) → pid
 *
 * EntryAbility.onDestroy() calls BackendManager.killBackend() so the port
 * is freed when the app is terminated — killing is only possible for the
 * child variant (in-process node dies with the app itself).
 */

import { killNode } from 'libnode_ctl.so';

export class BackendManager {
  static pid: number = -1;
  static inProcess: boolean = false;

  static setPid(pid: number): void {
    BackendManager.pid = pid;
    BackendManager.inProcess = false;
  }

  static setInProcess(): void {
    BackendManager.inProcess = true;
    BackendManager.pid = -1;
  }

  static killBackend(): void {
    if (BackendManager.inProcess) {
      // node runs on a thread of the app process itself — it ends with the
      // process; killing "our own pid" would kill the UI too.
      return;
    }
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
