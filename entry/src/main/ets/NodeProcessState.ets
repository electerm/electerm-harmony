/**
 * Holds a reference to the Node.js child process PID so it can be cleaned
 * up from EntryAbility.onDestroy().
 *
 * ArkTS components (Index.ets) are destroyed/recreated on configuration
 * changes, but UIAbility lifecycle (EntryAbility) spans the entire app
 * session. Storing the PID here lets both layers access it.
 *
 * We use the NAPI spawn module (libspawn) to start the process and
 * obtain a PID, rather than @ohos.process.runCmd which is a @systemapi
 * unavailable to third-party apps.
 */

import { killProcess } from 'libspawn';

export class NodeProcessState {
  static nodePid: number = -1;

  static set(pid: number): void {
    NodeProcessState.nodePid = pid;
  }

  static clear(): void {
    NodeProcessState.nodePid = -1;
  }

  static kill(): boolean {
    if (NodeProcessState.nodePid > 0) {
      try {
        const result = killProcess(NodeProcessState.nodePid, 9);
        NodeProcessState.clear();
        return result;
      } catch {
        NodeProcessState.clear();
        return false;
      }
    }
    return false;
  }
}
