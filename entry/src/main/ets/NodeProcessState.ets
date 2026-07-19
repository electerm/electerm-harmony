/**
 * Holds a reference to the Node.js child process so it can be cleaned up
 * from EntryAbility.onDestroy().
 *
 * ArkTS components (Index.ets) are destroyed/recreated on configuration
 * changes, but UIAbility lifecycle (EntryAbility) spans the entire app
 * session. Storing the ChildProcess reference here lets both layers
 * access it.
 *
 * We store the process as `object` to avoid importing the full
 * ChildProcess type interface (which may differ across SDK versions).
 * The only method we actually need is `kill(signal)`.
 */

interface Killable {
  kill(signal: number): boolean;
}

export class NodeProcessState {
  static childProcess: Killable | null = null;
  static nodePid: number = -1;

  static set(cp: Killable, pid: number): void {
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
