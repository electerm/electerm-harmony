/**
 * node_ctl.c — NAPI module for the main (ArkTS) process.
 *
 * Two jobs:
 *   1. killNode(pid) — terminate the native-child-process node backend.
 *   2. startBackend(entryParams) — run node IN THIS (main app) PROCESS:
 *      dlopen the bundled libnode.so and call node::Start on a dedicated
 *      32MB-stack pthread (the nodejs-mobile / electron-harmony pattern).
 *
 * Why in-process: the nativespawn CHILD process runs under a stricter
 * seccomp filter than the app itself — node's libuv dies there (SIGSYS /
 * abort) because event-loop syscalls are fenced off. The MAIN app process
 * demonstrably runs libuv-class loops (NETSTACK/curl, the ArkTS runtime),
 * so node lives there. electron-harmony works the same way: its node core
 * ships as .so libraries inside the app process, never a spawned binary.
 *
 * Everything is logged to <dataDir>/node-boot.log (same file the child
 * launcher writes) and to hilog (tag electerm.embed), so the on-screen
 * boot-log overlay shows this path's ladder exactly like the child's.
 *
 * Returns "ok" synchronously once the node thread is launched; on any
 * failure returns "err:<reason>" so ArkTS can fall back to the native
 * child process.
 */

#include "napi/native_api.h"

#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/types.h>
#include <ucontext.h>
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
  char secret[MAX_LINE]; /* SERVER_SECRET */
} CtlConfig;

static int g_logFd = -1;
static char g_logPath[MAX_LINE * 2] = "";
static int g_started = 0; /* startBackend may only run once per process */

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
  (void)OH_LOG_Print(LOG_APP, LOG_ERROR, 0xE1EC, "electerm.embed",
                     "%{public}s", buf);
}

/* ── Crash markers — name the killer signal in the boot log AND hilog (the
 * process may die right after; hilog keeps the line). If the signal came
 * from node's own thread, PARK that thread instead of dying: the app UI
 * process survives, the ArkTS probe times out and the on-screen overlay
 * shows the boot-log tail — instead of the app just closing. ── */
static pid_t g_nodeTid = 0; /* tid of the node thread once launched */

static void crashMarkerHandler(int sig, siginfo_t *si, void *ctx) {
  (void)si;
  (void)ctx;
  int saved = errno;
  long tid = (long)syscall(__NR_gettid);
  char b[128];
  int n = snprintf(b, sizeof(b), "[embed] fatal: signal %d on tid %ld",
                   sig, tid);
  if (n > 0) {
    if (g_logFd >= 0) {
      ssize_t ign = write(g_logFd, b, (size_t)n);
      ign = write(g_logFd, "\n", 1);
      (void)ign;
    }
    (void)OH_LOG_Print(LOG_APP, LOG_ERROR, 0xE1EC, "electerm.embed",
                       "%{public}s", b);
  }
  errno = saved;
  if (g_nodeTid > 0 && tid == (long)g_nodeTid) {
    /* node's thread crashed — freeze it, keep the app alive. Never returns;
     * if the crash corrupted a libc lock the UI may eventually freeze too,
     * but the evidence is already on disk and in hilog. */
    for (;;) {
      pause();
    }
  }
  signal(sig, SIG_DFL);
  raise(sig);
}

static void installCrashMarkers(void) {
  struct sigaction sa;
  memset(&sa, 0, sizeof(sa));
  sa.sa_sigaction = crashMarkerHandler;
  sa.sa_flags = SA_SIGINFO;
  const int sigs[] = {SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGFPE};
  for (size_t i = 0; i < sizeof(sigs) / sizeof(sigs[0]); i++) {
    if (sigaction(sigs[i], &sa, NULL) != 0) {
      logWrite("[embed] sigaction(%d) failed: %s", sigs[i], strerror(errno));
    }
  }
}

/* ── SIGSYS shim — same as the child launcher's: if a seccomp filter in
 * THIS process traps a syscall node probes (perf_event_open, membarrier,
 * …), convert the kill into a logged ENOSYS. node's ResetSignalHandlers()
 * preserves SA_SIGINFO handlers, so this survives into node's lifetime. ── */
static const char *syscallName(int sc) {
  switch (sc) {
    case 19: return "eventfd2";
    case 20: return "epoll_create1";
    case 220: return "clone";
    case 221: return "execve";
    case 241: return "perf_event_open";
    case 265: return "open_by_handle_at";
    case 270: return "process_vm_readv";
    case 272: return "kcmp";
    case 277: return "seccomp";
    case 278: return "getrandom";
    case 280: return "bpf";
    case 281: return "execveat";
    case 282: return "userfaultfd";
    case 283: return "membarrier";
    case 288: return "pkey_mprotect";
    case 291: return "statx";
    case 293: return "rseq";
    case 403: return "clock_gettime64";
    case 424: return "pidfd_send_signal";
    case 425: return "io_uring_setup";
    case 434: return "pidfd_open";
    case 435: return "clone3";
    case 436: return "close_range";
    case 437: return "openat2";
    case 439: return "faccessat2";
    case 440: return "process_madvise";
    default: return "?";
  }
}

static void sigsysHandler(int sig, siginfo_t *si, void *ctx) {
  (void)sig;
  static int seen[32];
  static int seenCount = 0;
  int sc = si->si_syscall;
  int known = 0;
  for (int i = 0; i < seenCount; i++) {
    if (seen[i] == sc) {
      known = 1;
      break;
    }
  }
  if (!known && seenCount < 32) {
    seen[seenCount++] = sc;
    logWrite("[embed] SIGSYS: syscall %d (%s) blocked by seccomp → ENOSYS",
             sc, syscallName(sc));
  }
  ucontext_t *uc = (ucontext_t *)ctx;
  uc->uc_mcontext.pc += 4; /* skip the 4-byte svc instruction */
  uc->uc_mcontext.regs[0] = (unsigned long)-ENOSYS;
}

static void installSigsysShim(void) {
  struct sigaction sa;
  memset(&sa, 0, sizeof(sa));
  sa.sa_sigaction = sigsysHandler;
  sa.sa_flags = SA_SIGINFO;
  if (sigaction(SIGSYS, &sa, NULL) != 0) {
    logWrite("[embed] sigaction(SIGSYS) failed: %s", strerror(errno));
  }
}

/* Parse "key=value\n" lines (same format the child launcher parses). */
static void parseEntryParams(const char *params, CtlConfig *cfg,
                             char extraEnv[MAX_ENV_VARS][MAX_LINE],
                             int *extraEnvCount) {
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
  char path[MAX_LINE * 2];
  snprintf(path, sizeof(path), "%s/libnode.so", dir);
  for (int i = 0; i < *n; i++) {
    if (strcmp(candidates[i], path) == 0) return;
  }
  snprintf(candidates[(*n)], MAX_LINE * 2, "%s", path);
  logWrite("[embed] candidate(%s): %s", tag, candidates[(*n)]);
  (*n)++;
}

typedef int (*node_start_fn)(int argc, char *argv[]);

struct NodeThreadArgs {
  node_start_fn start;
  char *argv[3];
  int rc;
};

static struct NodeThreadArgs g_nodeArgs;

/* node::Start returning is abnormal (the server should run forever) — log
 * it and let the thread end; the ArkTS probe timeout surfaces the failure.
 * NEVER _exit() here: this is the app's main process. */
static void *nodeThreadMain(void *p) {
  struct NodeThreadArgs *a = (struct NodeThreadArgs *)p;
  g_nodeTid = (pid_t)syscall(__NR_gettid);
  logWrite("[embed] node thread tid=%ld, calling node::Start", (long)g_nodeTid);
  a->rc = a->start(2, a->argv);
  logWrite("[embed] node::Start returned %d (backend stopped)", a->rc);
  return NULL;
}

static const char *startEmbeddedNode(const char *params) {
  static char errBuf[256];

  if (g_started) {
    return "err:already started";
  }

  char extraEnv[MAX_ENV_VARS][MAX_LINE];
  int extraEnvCount = 0;
  CtlConfig cfg;
  parseEntryParams(params, &cfg, extraEnv, &extraEnvCount);

  /* boot log — same file the child launcher uses, so the ArkTS overlay and
   * hilog dump cover both paths. Truncated per attempt: the overlay only
   * shows the last lines, and hilog keeps the history anyway. el2 junction
   * fallback like the child. */
  if (cfg.dataDir[0]) {
    char logPath[MAX_LINE * 2];
    snprintf(logPath, sizeof(logPath), "%s/node-boot.log", cfg.dataDir);
    g_logFd = open(logPath, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (g_logFd < 0) {
      snprintf(logPath, sizeof(logPath),
               "/data/storage/el2/base/files/electerm-data/node-boot.log");
      g_logFd = open(logPath, O_WRONLY | O_CREAT | O_APPEND, 0644);
    }
    if (g_logFd >= 0) {
      snprintf(g_logPath, sizeof(g_logPath), "%s", logPath);
    }
  }
  logWrite("[embed] startBackend: pid=%d params=%s", (int)getpid(), params);

  if (!cfg.script[0] || access(cfg.script, F_OK) != 0) {
    logWrite("[embed] FATAL: script missing: %s", cfg.script);
    snprintf(errBuf, sizeof(errBuf), "err:script missing");
    return errBuf;
  }

  /* locate libnode.so — parent-provided path, then this .so's own dir
   * (libnode_ctl.so and libnode.so sit in the same app libs dir), then the
   * el1/bundle junction layouts. */
  char candidates[MAX_CANDIDATES][MAX_LINE * 2];
  int nCand = 0;
  if (cfg.node[0]) {
    snprintf(candidates[nCand], MAX_LINE * 2, "%s", cfg.node);
    logWrite("[embed] candidate(parent): %s", candidates[nCand]);
    nCand++;
  }
  {
    Dl_info info;
    if (dladdr((void *)&startEmbeddedNode, &info) && info.dli_fname &&
        info.dli_fname[0]) {
      const char *slash = strrchr(info.dli_fname, '/');
      if (slash) {
        char dir[MAX_LINE * 2];
        snprintf(dir, sizeof(dir), "%.*s", (int)(slash - info.dli_fname),
                 info.dli_fname);
        addCandidate(candidates, &nCand, dir, "dladdr");
      }
    }
  }
  {
    const char *bundleDir = "/data/storage/el1/bundle";
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
    if (access(candidates[i], F_OK) == 0) {
      nodePath = candidates[i];
      break;
    }
    logWrite("[embed] candidate not found: %s", candidates[i]);
  }
  if (!nodePath) {
    logWrite("[embed] FATAL: no libnode.so candidate exists (tried %d)", nCand);
    snprintf(errBuf, sizeof(errBuf), "err:no libnode.so");
    return errBuf;
  }
  logWrite("[embed] node binary: %s", nodePath);

  /* environment — mirrors the child launcher exactly */
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

  /* fds 0/1/2 stay VALID (node's PlatformInit only fstats them) — but node's
   * stderr must land in the boot log or abort()/assert messages vanish into
   * the app's own stderr (/dev/null). Redirect 1/2 onto the log fd; the app
   * runtime logs via hilog, not stdio, so nothing of value is lost. */
  installCrashMarkers();
  installSigsysShim();
  if (g_logFd > 2) {
    dup2(g_logFd, 1);
    dup2(g_logFd, 2);
    logWrite("[embed] stdout/stderr redirected to node-boot.log");
  }

  if (cfg.dataDir[0] && chdir(cfg.dataDir) == 0) {
    logWrite("[embed] cwd: %s", cfg.dataDir);
  }

  logWrite("[embed] in-process(main): dlopen(%s)", nodePath);
  void *h = dlopen(nodePath, RTLD_NOW | RTLD_LOCAL);
  if (!h) {
    /* retry by bare name — the linker namespace search path contains the
     * app libs dir even when an absolute-path dlopen is refused */
    const char *e1 = dlerror();
    logWrite("[embed] dlopen(abs) failed: %s — retrying bare name", e1 ? e1 : "?");
    h = dlopen("libnode.so", RTLD_NOW | RTLD_LOCAL);
    if (!h) {
      const char *e2 = dlerror();
      logWrite("[embed] dlopen failed: %s / %s", e1 ? e1 : "-", e2 ? e2 : "-");
      snprintf(errBuf, sizeof(errBuf), "err:dlopen failed");
      return errBuf;
    }
  }
  dlerror();
  node_start_fn start = (node_start_fn)dlsym(h, "_ZN4node5StartEiPPc");
  const char *e = dlerror();
  if (!start || (e && e[0])) {
    logWrite("[embed] dlsym(node::Start) failed: %s", e ? e : "null sym");
    snprintf(errBuf, sizeof(errBuf), "err:node::Start not found");
    return errBuf;
  }
  logWrite("[embed] node::Start resolved at %p", (void *)start);

  /* argv must outlive the thread — static storage */
  static char arg0[MAX_LINE * 2];
  static char arg1[MAX_LINE * 2];
  snprintf(arg0, sizeof(arg0), "%s", nodePath);
  snprintf(arg1, sizeof(arg1), "%s", cfg.script);
  g_nodeArgs.start = start;
  g_nodeArgs.argv[0] = arg0;
  g_nodeArgs.argv[1] = arg1;
  g_nodeArgs.argv[2] = NULL;

  pthread_attr_t attr;
  pthread_attr_init(&attr);
  pthread_attr_setstacksize(&attr, 32 * 1024 * 1024); /* node wants a big stack */
  pthread_t th;
  int prc = pthread_create(&th, &attr, nodeThreadMain, &g_nodeArgs);
  if (prc != 0) {
    logWrite("[embed] pthread_create failed: %s", strerror(prc));
    snprintf(errBuf, sizeof(errBuf), "err:pthread_create failed");
    return errBuf;
  }
  pthread_detach(th);
  g_started = 1;
  logWrite("[embed] node thread launched in main app process");
  return "ok";
}

/* ── NAPI surface ── */

static napi_value StartBackend(napi_env env, napi_callback_info info) {
  size_t argc = 1;
  napi_value args[1];
  napi_get_cb_info(env, info, &argc, args, NULL, NULL);

  char params[8192] = "";
  if (argc >= 1) {
    size_t copied = 0;
    napi_get_value_string_utf8(env, args[0], params, sizeof(params), &copied);
  }
  const char *result = startEmbeddedNode(params);

  napi_value napiResult = NULL;
  napi_create_string_utf8(env, result, NAPI_AUTO_LENGTH, &napiResult);
  return napiResult;
}

static napi_value KillNode(napi_env env, napi_callback_info info) {
  size_t argc = 1;
  napi_value args[1];
  napi_get_cb_info(env, info, &argc, args, NULL, NULL);

  int32_t pid = -1;
  if (argc >= 1) {
    napi_get_value_int32(env, args[0], &pid);
  }
  int32_t result = -1;
  if (pid > 1) {
    /* TERM first so express can close listening sockets cleanly; KILL if it
     * survives. */
    result = kill((pid_t)pid, SIGTERM);
    if (result == 0) {
      usleep(200 * 1000); /* 200ms grace */
      kill((pid_t)pid, SIGKILL);
    }
  }
  napi_value napiResult = NULL;
  napi_create_int32(env, result, &napiResult);
  return napiResult;
}

EXTERN_C_START
static napi_value Init(napi_env env, napi_value exports) {
  napi_property_descriptor desc[] = {
      {"killNode", NULL, KillNode, NULL, NULL, NULL, napi_default, NULL},
      {"startBackend", NULL, StartBackend, NULL, NULL, NULL, napi_default, NULL}};
  napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
  return exports;
}
EXTERN_C_END

static napi_module demoModule = {
    1, 0, NULL, Init, "node_ctl", NULL, {0}};

__attribute__((constructor)) void RegisterModule(void) {
  napi_module_register(&demoModule);
}
