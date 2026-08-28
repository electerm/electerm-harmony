/**
 * node_launcher.c — native child-process entry that becomes the Node.js
 * backend on HarmonyOS.
 *
 * ArkTS cannot exec() a binary. It starts this library as a *native child
 * process* via childProcessManager.startNativeChildProcess(
 *   'libnode_launcher.so:Main', { entryParams }) — the system forks a child
 * (through nativespawn), loads this .so into it and calls Main() below.
 *
 * Main() then:
 *   1. parses the entryParams string ("key=value" lines — plain text, no
 *      JSON parser needed); recognized keys: dataDir, script, node, port,
 *      secret (unknown keys are exported as env vars for the node process);
 *   2. locates the node binary (installed as libnode.so in the app's native
 *      lib dir): parent-provided "node=" path, then dladdr() on this very
 *      function, then every mapped-.so directory from /proc/self/maps, then
 *      the el1/bundle junction layout;
 *   3. redirects stdout/stderr to a boot log for on-device debugging;
 *   4. execv()s node with the electerm entry script.
 *
 * If execv fails (e.g. the lib dir turns out to be noexec or the binary is
 * blocked by code-integrity checks) a memfd fallback is attempted: the
 * binary is copied into an anonymous executable memory file and execveat()d
 * — bypassing mount noexec flags entirely.
 *
 * Every step is logged BOTH to <dataDir>/node-boot.log AND to hilog
 * (tag electerm.launcher, error level so release builds keep it) — so the
 * boot sequence is visible even when the log file cannot be pulled.
 *
 * Exit codes: 40 script missing · 41 node binary not found · 42 all exec
 * strategies failed.
 */

#include <stdbool.h> /* native_child_process.h uses `bool` */

#include "AbilityKit/native_child_process.h"

#include <dlfcn.h>
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
#include <hilog/log.h>

#define LOG_BUF_SIZE 4096
#define MAX_ENV_VARS 32
#define MAX_LINE 1024
#define MAX_CANDIDATES 12

typedef struct {
  char dataDir[MAX_LINE];    /* writable app data dir (el2 filesDir) */
  char script[MAX_LINE * 2]; /* path to resfile/electerm/index.js */
  char node[MAX_LINE * 2];   /* optional parent-provided libnode.so path */
  char port[16];
  char secret[MAX_LINE];     /* SERVER_SECRET */
} LauncherConfig;

static int g_logFd = -1;

/* Forward declaration — dladdr() below takes Main's address. */
void Main(NativeChildProcess_Args args);

/* Every message goes to the boot log file AND hilog (error level: release
 * builds keep it, and `hdc hilog` shows it under electerm.launcher). */
static void logWrite(const char *fmt, ...) {
  char buf[LOG_BUF_SIZE];
  va_list ap;
  va_start(ap, fmt);
  int n = vsnprintf(buf, sizeof(buf) - 1, fmt, ap);
  va_end(ap);
  if (n < 0) return;
  buf[n] = '\0';
  if (g_logFd >= 0) {
    ssize_t ignored = write(g_logFd, buf, (size_t)n);
    ignored = write(g_logFd, "\n", 1);
    (void)ignored;
  }
  (void)OH_LOG_Print(LOG_APP, LOG_ERROR, 0xE1EC, "electerm.launcher",
                     "%{public}s", buf);
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
  cfg->node[0] = '\0';
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
    } else if (strcmp(key, "node") == 0) {
      snprintf(cfg->node, sizeof(cfg->node), "%s", value);
    } else if (strcmp(key, "port") == 0) {
      snprintf(cfg->port, sizeof(cfg->port), "%s", value);
    } else if (strcmp(key, "secret") == 0) {
      snprintf(cfg->secret, sizeof(cfg->secret), "%s", value);
    } else if (*extraEnvCount < MAX_ENV_VARS) {
      snprintf(extraEnv[(*extraEnvCount)++], MAX_LINE, "%s=%s", key, value);
    }
  }
}

static void addCandidate(char (*candidates)[MAX_LINE * 2], int *n,
                         const char *dir, const char *tag) {
  if (*n >= MAX_CANDIDATES) return;
  if (!dir || !dir[0]) return;
  /* dedupe */
  char path[MAX_LINE * 2];
  snprintf(path, sizeof(path), "%s/libnode.so", dir);
  for (int i = 0; i < *n; i++) {
    if (strcmp(candidates[i], path) == 0) return;
  }
  snprintf(candidates[(*n)], MAX_LINE * 2, "%s", path);
  logWrite("[launcher] candidate(%s): %s", tag, candidates[(*n)]);
  (*n)++;
}

/* Directory this library was loaded from, via the dynamic linker — the most
 * reliable source (works even if /proc is restricted). */
static void selfDirViaDladdr(char *out, size_t outSize) {
  out[0] = '\0';
  Dl_info info;
  if (dladdr((void *)&Main, &info) && info.dli_fname && info.dli_fname[0]) {
    logWrite("[launcher] dladdr dli_fname: %s", info.dli_fname);
    const char *slash = strrchr(info.dli_fname, '/');
    if (slash) {
      snprintf(out, outSize, "%.*s", (int)(slash - info.dli_fname),
               info.dli_fname);
    }
  } else {
    logWrite("[launcher] dladdr failed: %s", dlerror() ? dlerror() : "?");
  }
}

/* Collect the directory of every mapped .so that looks like an app native
 * lib (path contains "arm64"). The child process loads several .so from the
 * app libs dir; any of their directories may hold libnode.so. */
static int collectMapDirs(char (*candidates)[MAX_LINE * 2], int *n) {
  FILE *f = fopen("/proc/self/maps", "r");
  if (!f) {
    logWrite("[launcher] cannot open /proc/self/maps: %s", strerror(errno));
    return -1;
  }
  char line[MAX_LINE];
  int found = 0;
  while (fgets(line, sizeof(line), f)) {
    char *sp = strchr(line, ' ');
    while (sp && *sp == ' ') sp++;
    if (!sp) continue;
    char *nm = sp;
    /* skip perms/offset/dev columns to the pathname */
    for (int col = 0; col < 4 && nm; nm = strchr(nm, ' '), col++) {
      if (nm) nm++;
    }
    if (!nm || *nm != '/') continue;
    char *nl = strchr(nm, '\n');
    if (nl) *nl = '\0';
    if (!strstr(nm, ".so")) continue;
    if (!strstr(nm, "arm64")) continue;
    char *slash = strrchr(nm, '/');
    if (!slash) continue;
    *slash = '\0';
    addCandidate(candidates, n, nm, "maps");
    found++;
  }
  fclose(f);
  return found;
}

static int fileExists(const char *path) {
  return access(path, F_OK) == 0;
}

/* Find the system musl dynamic loader — first from /proc/self/maps (it
 * mapped us, so it is definitely present at that path), then well-known
 * locations. */
static int findLoader(char *out, size_t outSize) {
  FILE *f = fopen("/proc/self/maps", "r");
  if (f) {
    char line[MAX_LINE];
    while (fgets(line, sizeof(line), f)) {
      char *hit = strstr(line, "ld-musl");
      if (hit && strstr(hit, ".so")) {
        char *nl = strchr(hit, '\n');
        if (nl) *nl = '\0';
        snprintf(out, outSize, "%s", hit);
        fclose(f);
        return 0;
      }
    }
    fclose(f);
  }
  const char *fallbacks[] = {
    "/lib/ld-musl-aarch64.so.1",
    "/system/lib/ld-musl-aarch64.so.1",
    "/system/lib64/ld-musl-aarch64.so.1",
    NULL
  };
  for (int i = 0; fallbacks[i]; i++) {
    if (fileExists(fallbacks[i])) {
      snprintf(out, outSize, "%s", fallbacks[i]);
      return 0;
    }
  }
  return -1;
}

/* Log the mount that contains `path` (from /proc/self/mountinfo) so noexec
 * and other enforcement is visible in the boot log. */
static void logMountFlagsFor(const char *path) {
  /* find the deepest mount point that prefixes path */
  char best[MAX_LINE];
  char bestLine[MAX_LINE * 2];
  best[0] = '\0';
  bestLine[0] = '\0';
  FILE *f = fopen("/proc/self/mountinfo", "r");
  if (!f) {
    logWrite("[launcher] cannot open /proc/self/mountinfo: %s",
             strerror(errno));
    return;
  }
  char line[MAX_LINE * 2];
  while (fgets(line, sizeof(line), f)) {
    /* format: id parent maj:min root mountpoint options ... */
    unsigned id, parent;
    unsigned maj, min;
    char root[MAX_LINE], mnt[MAX_LINE], opts[MAX_LINE];
    if (sscanf(line, "%u %u %u:%u %s %s %s", &id, &parent, &maj, &min, root,
               mnt, opts) != 7) {
      continue;
    }
    if (strncmp(path, mnt, strlen(mnt)) == 0 &&
        strlen(mnt) > strlen(best)) {
      snprintf(best, sizeof(best), "%s", mnt);
      snprintf(bestLine, sizeof(bestLine), "mount %s → options: %s", mnt, opts);
    }
  }
  fclose(f);
  if (best[0]) {
    logWrite("[launcher] %s (for %s)", bestLine, path);
  } else {
    logWrite("[launcher] no mountinfo entry prefixes %s", path);
  }
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
               "/data/storage/el2/base/files/electerm-data/node-boot.log");
      g_logFd = open(logPath, O_WRONLY | O_CREAT | O_APPEND, 0644);
    }
  }
  logWrite("[launcher] Main() entered, pid=%d", (int)getpid());
  logWrite("[launcher] entryParams: %s", params);

  if (!cfg.script[0] || !fileExists(cfg.script)) {
    logWrite("[launcher] FATAL: script missing: %s (errno=%d %s)", cfg.script,
             errno, strerror(errno));
    _exit(40);
  }

  /* 2. Locate node */
  char candidates[MAX_CANDIDATES][MAX_LINE * 2];
  int nCand = 0;

  if (cfg.node[0] && nCand < MAX_CANDIDATES) {
    /* parent-provided full path, used verbatim */
    snprintf(candidates[nCand], MAX_LINE * 2, "%s", cfg.node);
    logWrite("[launcher] candidate(parent): %s", candidates[nCand]);
    nCand++;
  }
  {
    char selfDir[MAX_LINE];
    selfDirViaDladdr(selfDir, sizeof(selfDir));
    addCandidate(candidates, &nCand, selfDir, "dladdr");
  }
  collectMapDirs(candidates, &nCand);
  {
    const char *bundleDir = getenv("ELECTERM_BUNDLE_CODE_DIR");
    if (!bundleDir || !bundleDir[0]) bundleDir = "/data/storage/el1/bundle";
    char dir[MAX_LINE * 2];
    snprintf(dir, sizeof(dir), "%s/entry/libs/arm64-v8a", bundleDir);
    addCandidate(candidates, &nCand, dir, "el1");
    snprintf(dir, sizeof(dir), "%s/entry/libs/arm64", bundleDir);
    addCandidate(candidates, &nCand, dir, "el1");
    snprintf(dir, sizeof(dir), "%s/libs/arm64-v8a", bundleDir);
    addCandidate(candidates, &nCand, dir, "el1");
  }

  const char *nodePath = NULL;
  for (int i = 0; i < nCand; i++) {
    if (fileExists(candidates[i])) {
      nodePath = candidates[i];
      break;
    }
    logWrite("[launcher] candidate not found: %s (errno=%d)", candidates[i],
             errno);
  }
  if (!nodePath) {
    logWrite("[launcher] FATAL: no libnode.so candidate exists (tried %d)",
             nCand);
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

  /* 5. Log the node file's mode + the mount flags of its directory —
   * noexec / code-integrity enforcement shows up here. */
  {
    struct stat st;
    if (stat(nodePath, &st) == 0) {
      logWrite("[launcher] node stat: mode=%o size=%ld", st.st_mode,
               (long)st.st_size);
    } else {
      logWrite("[launcher] node stat failed: %s", strerror(errno));
    }
    logMountFlagsFor(nodePath);
  }

  /* 6. exec. */
  chmod(nodePath, 0755); /* no-op on the read-only bundle mount; logged above */

  char nodeArg0[MAX_LINE * 2];
  snprintf(nodeArg0, sizeof(nodeArg0), "%s", nodePath);
  char *const argv[] = {nodeArg0, cfg.script, NULL};

  logWrite("[launcher] execv: %s %s", nodeArg0, cfg.script);
  execv(nodeArg0, argv);
  int execErr = errno;
  logWrite("[launcher] execv failed: errno=%d (%s)", execErr,
           strerror(execErr));

  /* 6a. Loader-exec fallback: exec the SYSTEM dynamic loader (signed, on an
   * exec mount) with the node binary as its program argument. The loader
   * maps the binary itself — the same PROT_EXEC file mapping dlopen() uses,
   * which demonstrably works for app .so files in this very process. This
   * sidesteps execve() of an unsigned app file entirely. */
  {
    char loader[MAX_LINE];
    if (findLoader(loader, sizeof(loader)) == 0) {
      char *const largv[] = {loader, nodeArg0, cfg.script, NULL};
      logWrite("[launcher] execv via loader: %s %s %s", loader, nodeArg0,
               cfg.script);
      execv(loader, largv);
      logWrite("[launcher] loader execv failed: errno=%d (%s)", errno,
               strerror(errno));
    } else {
      logWrite("[launcher] no dynamic loader found for fallback");
    }
  }

  /* 6b. memfd fallback (noexec mounts) */
  if (execFromMemfd(nodeArg0, argv, NULL) == 0) {
    _exit(0); /* unreachable */
  }

  logWrite("[launcher] FATAL: all exec strategies failed (execv errno=%d)",
           execErr);
  _exit(42);
}
