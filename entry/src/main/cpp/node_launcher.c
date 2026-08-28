/**
 * node_launcher.c — native child-process entry that becomes the Node.js
 * backend on HarmonyOS.
 *
 * ArkTS cannot exec() a binary. It starts this library as a *native child
 * process* via childProcessManager.startNativeChildProcess(
 *   'libnode_launcher.so:Main', { entryParams }) — the system forks a child
 * (through appspawn), loads this .so into it and calls Main() below.
 *
 * Main() then:
 *   1. parses the entryParams string ("key=value" lines — plain text, no
 *      JSON parser needed);
 *   2. locates the node binary (installed as libnode.so in the app's native
 *      lib dir, discovered via /proc/self/maps where this very library was
 *      loaded from, plus fallback candidates);
 *   3. redirects stdout/stderr to a boot log for on-device debugging;
 *   4. execv()s node with the electerm entry script.
 *
 * If execv fails (e.g. the lib dir turns out to be noexec) a memfd fallback
 * is attempted: the binary is copied into an anonymous executable memory
 * file and execveat()d — bypassing mount noexec flags entirely.
 *
 * Every step is logged to <dataDir>/node-boot.log (plus the errno of any
 * failure), so `hdc file recv` of that one file answers "why is the engine
 * not starting" on a real device.
 */

#include <stdbool.h> /* native_child_process.h uses `bool` */

#include "AbilityKit/native_child_process.h"

#include <errno.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/types.h>
#include <unistd.h>

#define LOG_BUF_SIZE 4096
#define MAX_ENV_VARS 32
#define MAX_LINE 1024

typedef struct {
  char dataDir[MAX_LINE];   /* writable app data dir (el2 filesDir) */
  char script[MAX_LINE * 2]; /* path to resfile/electerm/index.js */
  char port[16];
  char secret[MAX_LINE];   /* SERVER_SECRET */
} LauncherConfig;

static int g_logFd = -1;

static void logWrite(const char *fmt, ...) {
  char buf[LOG_BUF_SIZE];
  va_list ap;
  va_start(ap, fmt);
  int n = vsnprintf(buf, sizeof(buf) - 1, fmt, ap);
  va_end(ap);
  if (n < 0) return;
  buf[n] = '\n';
  if (g_logFd >= 0) {
    ssize_t ignored = write(g_logFd, buf, (size_t)n + 1);
    (void)ignored;
  }
  /* also surface in hilog (stderr was dup2'd to the log file, so keep a
   * copy on fd 1 before redirection happens via this early path) */
}

/* Parse "key=value\n" lines into the config struct. Unknown keys are
 * also exported as environment variables for the node process. */
static void parseEntryParams(const char *params, LauncherConfig *cfg,
                             char extraEnv[MAX_ENV_VARS][MAX_LINE],
                             int *extraEnvCount) {
  /* defaults */
  snprintf(cfg->port, sizeof(cfg->port), "5577");
  cfg->dataDir[0] = '\0';
  cfg->script[0] = '\0';
  cfg->secret[0] = '\0';

  char line[MAX_LINE];
  const char *p = params;
  while (p && *p) {
    const char *eol = strchr(p, '\n');
    size_t len = eol ? (size_t)(eol - p) : strlen(p);
    if (len >= sizeof(line)) len = sizeof(line) - 1;
    memcpy(line, p, len);
    line[len] = '\0';
    p = eol ? eol + 1 : NULL;

    char *eq = strchr(line, '=');
    if (!eq) continue;
    *eq = '\0';
    const char *key = line;
    const char *value = eq + 1;

    if (strcmp(key, "dataDir") == 0) {
      snprintf(cfg->dataDir, sizeof(cfg->dataDir), "%s", value);
    } else if (strcmp(key, "script") == 0) {
      snprintf(cfg->script, sizeof(cfg->script), "%s", value);
    } else if (strcmp(key, "port") == 0) {
      snprintf(cfg->port, sizeof(cfg->port), "%s", value);
    } else if (strcmp(key, "secret") == 0) {
      snprintf(cfg->secret, sizeof(cfg->secret), "%s", value);
    } else if (*extraEnvCount < MAX_ENV_VARS) {
      snprintf(extraEnv[(*extraEnvCount)++], MAX_LINE, "%s=%s", key, value);
    }
  }
}

/* Find the directory this library was loaded from by scanning
 * /proc/self/maps for "libnode_launcher.so" — the sibling libnode.so lives
 * in the same (executable) native lib dir. */
static int findSelfDir(char *out, size_t outSize) {
  FILE *f = fopen("/proc/self/maps", "r");
  if (!f) return -1;
  char line[MAX_LINE];
  while (fgets(line, sizeof(line), f)) {
    char *hit = strstr(line, "libnode_launcher.so");
    if (hit) {
      /* trim trailing newline */
      char *nl = strchr(hit, '\n');
      if (nl) *nl = '\0';
      char *slash = strrchr(hit, '/');
      if (slash) {
        *slash = '\0';
        snprintf(out, outSize, "%s", hit);
        fclose(f);
        return 0;
      }
    }
  }
  fclose(f);
  return -1;
}

static int fileExists(const char *path) {
  return access(path, F_OK) == 0;
}

/* Build the candidate node binary paths. Returns the number of candidates
 * actually appended. */
static int buildNodeCandidates(char (*candidates)[MAX_LINE * 2],
                               int maxCandidates) {
  int n = 0;
  char selfDir[MAX_LINE];
  char bundleDir[MAX_LINE * 2];

  if (findSelfDir(selfDir, sizeof(selfDir)) == 0) {
    snprintf(candidates[n++], MAX_LINE * 2, "%s/libnode.so", selfDir);
    logWrite("[launcher] self dir: %s", selfDir);
  } else {
    logWrite("[launcher] could not locate self dir via /proc/self/maps");
  }

  /* Fallbacks based on the standard install layout */
  const char *bundleCodeDir = getenv("ELECTERM_BUNDLE_CODE_DIR");
  if (bundleCodeDir && bundleCodeDir[0]) {
    snprintf(bundleDir, sizeof(bundleDir), "%s", bundleCodeDir);
  } else {
    snprintf(bundleDir, sizeof(bundleDir), "/data/storage/el1/bundle");
  }
  if (n < maxCandidates)
    snprintf(candidates[n++], MAX_LINE * 2, "%s/entry/libs/arm64-v8a/libnode.so", bundleDir);
  if (n < maxCandidates)
    snprintf(candidates[n++], MAX_LINE * 2, "%s/entry/libs/arm64/libnode.so", bundleDir);
  if (n < maxCandidates)
    snprintf(candidates[n++], MAX_LINE * 2, "%s/libs/arm64-v8a/libnode.so", bundleDir);
  return n;
}

/* execveat on a memfd copy of the binary — the noexec-bypass fallback. */
static int execFromMemfd(const char *binaryPath, char *const argv[],
                         char *const envp[]) {
  int src = open(binaryPath, O_RDONLY);
  if (src < 0) {
    logWrite("[launcher] memfd: open(%s) failed: %s", binaryPath,
             strerror(errno));
    return -1;
  }
  int mfd = (int)syscall(__NR_memfd_create, "node", 0);
  if (mfd < 0) {
    logWrite("[launcher] memfd_create failed: %s", strerror(errno));
    close(src);
    return -1;
  }
  char buf[65536];
  ssize_t r;
  while ((r = read(src, buf, sizeof(buf))) > 0) {
    ssize_t off = 0;
    while (off < r) {
      ssize_t w = write(mfd, buf + off, (size_t)(r - off));
      if (w < 0) {
        logWrite("[launcher] memfd write failed: %s", strerror(errno));
        close(src);
        close(mfd);
        return -1;
      }
      off += w;
    }
  }
  close(src);
  if (r < 0) {
    logWrite("[launcher] read failed: %s", strerror(errno));
    close(mfd);
    return -1;
  }
  fchmod(mfd, 0755);
  lseek(mfd, 0, SEEK_SET);
  logWrite("[launcher] execveat(memfd) ...");
  char *const empty[] = {NULL};
  /* OHOS musl does not export the execveat() wrapper — call the syscall
   * directly (__NR_execveat, AT_EMPTY_PATH). */
  (void)syscall(__NR_execveat, mfd, "", argv, envp ? envp : empty, AT_EMPTY_PATH);
  logWrite("[launcher] execveat failed: %s", strerror(errno));
  close(mfd);
  return -1;
}

/* The native child-process entry point.
 * Signature mandated by OH_Ability_StartNativeChildProcess /
 * childProcessManager.startNativeChildProcess. */
__attribute__((visibility("default"))) void Main(NativeChildProcess_Args args) {
  char extraEnv[MAX_ENV_VARS][MAX_LINE];
  int extraEnvCount = 0;
  LauncherConfig cfg;

  const char *params = args.entryParams ? args.entryParams : "";
  parseEntryParams(params, &cfg, extraEnv, &extraEnvCount);

  /* 1. Open the boot log inside the writable data dir. The dataDir string
   * from the parent process may not be mounted in this child's namespace
   * (sandbox paths differ) — retry via the per-process el2 junction, which
   * points at the same files dir. */
  if (cfg.dataDir[0]) {
    char logPath[MAX_LINE * 2];
    snprintf(logPath, sizeof(logPath), "%s/node-boot.log", cfg.dataDir);
    g_logFd = open(logPath, O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (g_logFd < 0) {
      snprintf(logPath, sizeof(logPath),
               "/data/storage/el2/base/electerm-data/node-boot.log");
      g_logFd = open(logPath, O_WRONLY | O_CREAT | O_APPEND, 0644);
    }
  }
  logWrite("[launcher] Main() entered, pid=%d", (int)getpid());
  logWrite("[launcher] entryParams: %s", params);

  if (!cfg.script[0] || !fileExists(cfg.script)) {
    logWrite("[launcher] FATAL: script missing: %s", cfg.script);
    _exit(40);
  }

  /* 2. Locate node */
  char candidates[6][MAX_LINE * 2];
  int nCand = buildNodeCandidates(candidates, 6);
  const char *nodePath = NULL;
  for (int i = 0; i < nCand; i++) {
    if (fileExists(candidates[i])) {
      nodePath = candidates[i];
      break;
    }
    logWrite("[launcher] candidate not found: %s", candidates[i]);
  }
  if (!nodePath) {
    logWrite("[launcher] FATAL: no libnode.so candidate exists");
    _exit(41);
  }
  logWrite("[launcher] node binary: %s", nodePath);

  /* 3. Environment for the node process */
  setenv("NODE_ENV", "production", 1);
  setenv("HOST", "127.0.0.1", 1);
  setenv("PORT", cfg.port, 1);
  setenv("ELECTERM_DATA_DIR", cfg.dataDir, 1);
  if (cfg.secret[0]) {
    setenv("SERVER_SECRET", cfg.secret, 1);
  }
  for (int i = 0; i < extraEnvCount; i++) {
    putenv(extraEnv[i]);
  }

  /* 4. Redirect stdout/stderr into the boot log so node console output and
   *    crash messages are captured on device. */
  if (g_logFd >= 0) {
    dup2(g_logFd, 1);
    dup2(g_logFd, 2);
  }

  /* 5. Ensure the executable bit is set (it should already be, but a
   *    remounted/restored file could lose it) and exec. */
  chmod(nodePath, 0755);

  char nodeArg0[MAX_LINE * 2];
  snprintf(nodeArg0, sizeof(nodeArg0), "%s", nodePath);
  char *const argv[] = {nodeArg0, cfg.script, NULL};

  logWrite("[launcher] execv: %s %s", nodeArg0, cfg.script);
  execv(nodeArg0, argv);
  int execErr = errno;
  logWrite("[launcher] execv failed: %s — trying memfd fallback",
           strerror(execErr));

  /* 6. noexec fallback */
  if (execFromMemfd(nodeArg0, argv, NULL) == 0) {
    _exit(0); /* unreachable */
  }

  logWrite("[launcher] FATAL: all exec strategies failed (execv errno=%d)",
           execErr);
  _exit(42);
}
