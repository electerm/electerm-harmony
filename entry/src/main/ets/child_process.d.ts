/**
 * Type declarations for @ohos.child_process.
 *
 * The @ohos.child_process module provides APIs to create and manage child
 * processes. It is available in HarmonyOS API 10+ (HarmonyOS 4.0+).
 *
 * In some SDK versions (e.g. 5.0.1/13), the runtime module exists but the
 * type declaration files shipped with the SDK may not include it. This
 * declaration file fills that gap so the ArkTS compiler can resolve the
 * import and perform proper type checking.
 */

declare module '@ohos.child_process' {
  /**
   * Represents a child process created by runCmd / spawn / exec.
   */
  interface ChildProcess {
    /** Process ID of the child. */
    pid: number;
    /** Exit code (available after the process exits). */
    exitCode: number;
    /** Whether the child was killed by a signal. */
    killed: boolean;
    /** Send a signal to the child process. Returns true on success. */
    kill(signal: number): boolean;
    /** Wait for the child to exit; resolves with the exit code. */
    wait(): Promise<number>;
    /** Read all stdout output. Resolves once the process exits. */
    getOutput(): Promise<string>;
    /** Read all stderr output. Resolves once the process exits. */
    getErrorOutput(): Promise<string>;
  }

  /**
   * Options passed to runCmd / spawn / exec.
   */
  interface Options {
    /** Max wall-clock seconds the child may run (0 = no limit). */
    timeout?: number;
    /** Signal to send when timeout expires. */
    killSignal?: number;
    /** Max bytes to buffer on stdout/stderr. */
    maxBuffer?: number;
    /** Working directory. */
    cwd?: string;
    /** Environment variables. */
    env?: Record<string, string>;
  }

  /**
   * Execute a command string in a shell-like child process.
   * Resolves with the ChildProcess handle once the process has started.
   */
  function runCmd(command: string, options?: Options): Promise<ChildProcess>;

  /**
   * Spawn a child process with an explicit arg list.
   */
  function spawn(command: string, args?: string[], options?: Options): ChildProcess;

  /**
   * Execute a command and collect its output.
   * Resolves with the ChildProcess handle once the process has started.
   */
  function exec(command: string, options?: Options): Promise<ChildProcess>;

  const child_process: {
    runCmd: typeof runCmd;
    spawn: typeof spawn;
    exec: typeof exec;
  };

  export default child_process;
}
