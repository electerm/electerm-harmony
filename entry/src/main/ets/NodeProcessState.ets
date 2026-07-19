/**
 * Holds a reference to the Node.js child process so it can be cleaned up
 * from EntryAbility.onDestroy().
 *
 * ArkTS components (Index.ets) are destroyed/recreated on configuration
 * changes, but UIAbility lifecycle (EntryAbility) spans the entire app
 * session. Storing the ChildProcess reference here lets both layers
 * access it.
 *
 * We use process.ChildProcess (added to the SDK type declarations by
 * build-app.sh) to ensure type compatibility with the return value of
 * process.runCmd() without relying on structural typing (which ArkTS
 * does not support).
 */

import { ChildProcess } from '@ohos.process';

export class NodeProcessState {
  static childProcess: ChildProcess | null = null;
  static nodePid: number = -1;

  static set(cp: ChildProcess, pid: number): void {
    NodeProcessState.childProcess = cp;
    NodeProcessState.nodePid = pid;
  }

  static clear(): void {
    NodeProcessState.childProcess = null;
    NodeProcessState.nodePid = -1;
  }

  static kill(): boolean {
    if (NodeProcessState.childProcess) {
      try {
        const result = NodeProcessState.childProcess.kill(9);
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
