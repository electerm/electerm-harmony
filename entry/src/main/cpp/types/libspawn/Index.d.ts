/**
 * NAPI module: spawn
 *
 * Provides process spawning capability via posix_spawn(3).
 * This bypasses the @systemapi restriction on @ohos.process.runCmd.
 */

/**
 * Spawns a new child process.
 * @param binPath - Full path to the executable binary.
 * @param args    - Array of string arguments to pass to the process.
 * @param env     - Optional object of environment variables to set/override.
 * @returns The child process PID (>0).
 * @throws Error if posix_spawn fails.
 */
export const spawnProcess: (
  binPath: string,
  args: string[],
  env?: Record<string, string>
) => number;

/**
 * Sends a signal to a process.
 * @param pid    - Process ID to signal.
 * @param signal - Signal number (default: 9 = SIGKILL).
 * @returns true if the signal was sent successfully.
 */
export const killProcess: (pid: number, signal?: number) => boolean;

/**
 * Waits for a child process to exit.
 * @param pid - Process ID to wait for.
 * @returns A Promise that resolves with the exit code, or rejects with -1 on error.
 */
export const waitProcess: (pid: number) => Promise<number>;

/**
 * Changes file permissions (chmod).
 * @param path - File path.
 * @param mode - Permission mode (e.g. 0o755 = 493).
 * @returns true if successful.
 */
export const chmod: (path: string, mode: number) => boolean;

/**
 * Diagnoses a binary file — checks ELF magic, interpreter path, etc.
 * @param path - File path to diagnose.
 * @returns An object with diagnostic information.
 */
export interface Diagnostics {
  exists: boolean;
  executable: boolean;
  stat: string;
  magic: string;
  interpreter: string;
  interpreterExists: boolean;
  cwd: string;
  realpath: string;
  dirListing: string;
}
export const diagnose: (path: string) => Diagnostics;
