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
 * Changes file permissions (chmod) via path.
 * NOTE: This may NOT work on HarmonyOS sandbox virtual paths.
 * Use fchmodFd instead for sandbox files.
 * @param path - File path.
 * @param mode - Permission mode (e.g. 0o755 = 493).
 * @returns true if successful.
 */
export const chmod: (path: string, mode: number) => boolean;

/**
 * Changes file permissions via file descriptor (fchmod).
 * Works on HarmonyOS sandbox files because it operates on the fd
 * directly, bypassing path resolution.
 * @param fd   - File descriptor from ArkTS fs.openSync().
 * @param mode - Permission mode (e.g. 0o755 = 493).
 * @returns true if successful.
 * @throws Error if fchmod fails.
 */
export const fchmodFd: (fd: number, mode: number) => boolean;

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

/**
 * Resolves the real physical path of an open file descriptor.
 *
 * HarmonyOS sandbox paths (e.g. /data/storage/el2/base/...) are virtual —
 * only accessible via ArkTS fs APIs, not via native POSIX calls.
 * This function takes an fd opened by ArkTS fs.openSync() and reads
 * /proc/self/fd/<fd> to discover the real path on disk.
 *
 * @param fd - File descriptor from ArkTS fs.openSync().
 * @returns The real physical path string.
 * @throws Error if readlink fails.
 */
export const resolveFd: (fd: number) => string;

/**
 * Spawns a child process using /proc/self/fd/<fd> as the binary path.
 *
 * This bypasses the sandbox virtual path issue — the fd opened by ArkTS
 * is a real kernel fd, and /proc/self/fd/<fd> is accessible to execve.
 *
 * @param fd   - File descriptor of the binary (from ArkTS fs.openSync()).
 * @param args - Array of string arguments.
 * @param env  - Optional environment variables.
 * @returns The child process PID (>0).
 * @throws Error if posix_spawn fails.
 */
export const spawnFromFd: (
  fd: number,
  args: string[],
  env?: Record<string, string>
) => number;

/**
 * Diagnoses a binary via its file descriptor (bypasses path resolution).
 * @param fd - File descriptor of the binary.
 */
export interface FdDiagnostics {
  fdValid: boolean;
  stat: string;
  magic: string;
  interpreter: string;
  interpreterExists: boolean;
  fdPath: string;
  fdPathAccessible: boolean;
}
export const diagnoseFd: (fd: number) => FdDiagnostics;

/**
 * Checks which common paths are accessible from NAPI native code.
 * @returns Array of path accessibility info.
 */
export interface PathInfo {
  path: string;
  exists: boolean;
  executable: boolean;
  stat: string;
}
export const checkPaths: () => PathInfo[];
