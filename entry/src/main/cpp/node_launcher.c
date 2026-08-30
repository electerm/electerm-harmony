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
 * Exit codes: 40 script missing · 41 node binary not found · 42 in-process
 * start failed AND all exec strategies failed · else node's own exit code
 * (in-process mode exits from nodeThreadMain).
 */

#include <stdbool.h> /* native_child_process.h uses `bool` */

#include "AbilityKit/native_child_process.h"

#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
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
  char secret[MAX_LINE];     /* SERVER_SECRET */
} LauncherConfig;

static int g_logFd = -1;
static char g_logPath[MAX_LINE * 2] = ""; /* for the stdio rebuild below */

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

/* ── Crash markers: log which signal killed the child before dying ──
 * (node's assert → abort() = SIGABRT; without this the boot log just ends). */
static void crashMarkerHandler(int sig) {
  int saved = errno;
  char b[64];
  int n = snprintf(b, sizeof(b), "[launcher] process dying: signal %d\n", sig);
  if (n > 0) {
    if (g_logFd >= 0) {
      ssize_t ign = write(g_logFd, b, (size_t)n);
      (void)ign;
    } else if (g_logPath[0]) {
      int fd = open(g_logPath, O_WRONLY | O_CREAT | O_APPEND, 0644);
      if (fd >= 0) {
        ssize_t ign = write(fd, b, (size_t)n);
        (void)ign;
        close(fd);
      }
    }
  }
  errno = saved;
  signal(sig, SIG_DFL);
  raise(sig);
}

static void installCrashMarkers(void) {
  const int sigs[] = {SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGSYS};
  for (size_t i = 0; i < sizeof(sigs) / sizeof(sigs[0]); i++) {
    signal(sigs[i], crashMarkerHandler);
  }
}

/* ── Deterministic stdio for the embedded node runtime ──
 *
 * nodejs-mobile lesson + libuv's `assert(fd > STDERR_FILENO)` in uv__close:
 * whatever fd state the nativespawn child is born with, node must see
 * 0=/dev/null, 1=2=our log — every slot open, no aliasing with higher fds,
 * so no uv handle can ever end up on fd 0/1/2 through a closed-then-reused
 * slot. Also snapshots the inherited fd table into the boot log (answers
 * "what was the child born with" for good). */
static void setupStdioForNode(void) {
  for (int fd = 0; fd <= 9; fd++) {
    struct stat st;
    if (fstat(fd, &st) == 0) {
      const char *tag = "other";
      if (S_ISCHR(st.st_mode)) tag = "chardev";
      else if (S_ISREG(st.st_mode)) tag = "regular";
      else if (S_ISFIFO(st.st_mode)) tag = "fifo/pipe";
      else if (S_ISSOCK(st.st_mode)) tag = "socket";
      logWrite("[launcher] fd %d open at birth: %s", fd, tag);
    }
  }

  close(0);
  close(1);
  close(2);
  if (g_logFd > 2) {
    close(g_logFd); /* reopen below right on slot 1 */
  }
  g_logFd = -1;

  int f0 = open("/dev/null", O_RDONLY); /* → 0 */
  int f1 = g_logPath[0]
               ? open(g_logPath, O_WRONLY | O_CREAT | O_APPEND, 0644)
               : -1; /* → 1 */
  int f2 = dup2(f1 >= 0 ? f1 : f0, 2); /* → 2 */
  g_logFd = 1;
  logWrite("[launcher] stdio rebuilt: f0=%d f1=%d f2=%d "
           "(0=/dev/null, 1=2=%s)",
           f0, f1, f2, g_logPath[0] ? g_logPath : "?");
  (void)f0;
  (void)f1;
  (void)f2;
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
    if (!strstr(nm, "arm64") && !strstr(nm, "x86_64")) continue;
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

/* Find the system musl  dynamic loader — first from /proc/self/maps (it
 * mapped us, so it is definitely present at that path), then well-known
 * locations. The path is the LAST whitespace-delimited token of the maps
 * line — substring-searching for "ld-musl" and slicing from there drops
 * the directory prefix (device round-trip taught us: "ld-musl-…so.1" alone
 * execve's to ENOENT). */
static int findLoader(char *out, size_t outSize) {
  FILE *f = fopen("/proc/self/maps", "r");
  if (f) {
    char line[MAX_LINE];
    while (fgets(line, sizeof(line), f)) {
      char *nl = strchr(line, '\n');
      if (nl) *nl = '\0';
      char *sp = strrchr(line, ' ');
      char *path = sp ? sp + 1 : line;
      if (strstr(path, "ld-musl") && strstr(path, ".so") &&
          access(path, F_OK) == 0) {
        snprintf(out, outSize, "%s", path);
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

/* ── Strategy 1: run node IN-PROCESS (the nodejs-mobile / WineHua pattern) ──
 *
 * execve of any new image is refused inside an app child process on
 * HarmonyOS (errno EACCES — direct, via the system loader, and via memfd,
 * even with a code-signed binary: XPM blocks the syscall for app uids).
 * But dlopen() of a shared object demonstrably works — nativespawn loaded
 * this very library. The bundled node is a dynamic PIE, and OHOS musl's
 * loader does not reject executables: no PT_INTERP / DF_1_PIE check in
 * load_library(). node exports its embedder entry
 *   int node::Start(int argc, char *argv[])   (_ZN4node5StartEiPPc)
 * so we dlopen the binary, resolve node::Start, and call it on a dedicated
 * big-stack thread (node needs a large stack; nativespawn's Main() thread
 * cannot be assumed to have one).
 *
 * Returns only on failure (-1); on success node::Start runs until exit and
 * the thread wrapper _exit()s the process with node's exit code. */

typedef int (*node_start_fn)(int argc, char *argv[]);

/* ── SIGSYS: the app sandbox's seccomp filter traps syscalls node/V8 probe
 * for at startup (membarrier, pkey_mprotect, perf_event_open, …) and the
 * default action kills the thread (device: signo 31, si_code SYS_SECCOMP).
 * V8/uv handle ENOSYS gracefully for all of those probes — they are
 * optional accelerations. So: catch SIGSYS, log which syscall was trapped
 * (async-signal-safe), skip the svc instruction, and return -1 from it. */

/* aarch64 (asm-generic) syscall numbers worth naming in the log — the
 * suspects an app seccomp policy actually fences off. */
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

/* Async-signal-safe log line for use INSIDE the signal handler — no
 * printf-family/vsnprintf/logWrite: those take libc locks, and a trap that
 * fires while the thread already holds one crashes the handler (see the
 * node_ctl.c twin for the device-proven details). write(2) is safe. */
static void safeAppend(char *b, size_t cap, size_t *n, const char *s) {
  while (*s && *n < cap) {
    b[(*n)++] = *s++;
  }
}

static void safeAppendInt(char *b, size_t cap, size_t *n, int v) {
  char tmp[12];
  int len = 0;
  if (v < 0 && *n < cap) {
    b[(*n)++] = '-';
    v = -v;
  }
  do {
    tmp[len++] = (char)('0' + (v % 10));
    v /= 10;
  } while (v > 0 && len < (int)sizeof(tmp));
  while (len > 0 && *n < cap) {
    b[(*n)++] = tmp[--len];
  }
}

static void sigsysHandler(int sig, siginfo_t *si, void *ctx) {
  (void)sig;
  static unsigned int seenBits[16]; /* 512 syscall numbers, logged once each */
  int sc = si->si_syscall; /* musl: #define si_syscall __si_fields.__sigsys.si_syscall */
  if (sc >= 0 && sc < 512) {
    unsigned int bit = 1u << (sc & 31);
    if (!(seenBits[sc >> 5] & bit)) {
      seenBits[sc >> 5] |= bit;
      char b[96];
      size_t n = 0;
      safeAppend(b, sizeof(b), &n, "[launcher] SIGSYS: syscall ");
      safeAppendInt(b, sizeof(b), &n, sc);
      safeAppend(b, sizeof(b), &n, " (");
      safeAppend(b, sizeof(b), &n, syscallName(sc));
      safeAppend(b, sizeof(b), &n, ") blocked by seccomp -> -1\n");
      if (g_logFd >= 0) {
        ssize_t ign = write(g_logFd, b, n);
        (void)ign;
      }
      /* fd 2 is the boot log here (stdio was rebuilt onto it) — same file,
       * shared offset, so this is belt-and-braces. */
      ssize_t ign = write(2, b, n);
      (void)ign;
    }
  }
  ucontext_t *uc = (ucontext_t *)ctx;
  /* aarch64: the trapped instruction is the 4-byte `svc #0`; skip it and
   * put the failure value in x0 (the syscall return register).
   * Return EXACTLY -1, not -ENOSYS: OHOS musl's syscall() passes raw x0
   * through without __syscall_ret errno-translation, so -38 leaks out as a
   * bogus value — device-proven fatal in libuv uv__iou_init(): ringfd=-38
   * passed its `== -1` guard, mmap/epoll_ctl failed, cleanup called
   * uv__close(-38) → assert(fd > STDERR_FILENO) → abort. */
#if defined(__aarch64__)
  uc->uc_mcontext.pc += 4;
  uc->uc_mcontext.regs[0] = (unsigned long)-1;
#elif defined(__x86_64__)
  uc->uc_mcontext.gregs[REG_RIP] += 2; /* skip 2-byte syscall */
  uc->uc_mcontext.gregs[REG_RAX] = (unsigned long)-1;
#endif
  errno = ENOSYS; /* TLS store — async-signal-safe; for errno-checking callers */
}

static void installSigsysShim(void) {
  struct sigaction sa;
  memset(&sa, 0, sizeof(sa));
  sa.sa_sigaction = sigsysHandler;
  sa.sa_flags = SA_SIGINFO;
  if (sigaction(SIGSYS, &sa, NULL) != 0) {
    logWrite("[launcher] sigaction(SIGSYS) failed: %s", strerror(errno));
  }
}

struct NodeThreadArgs {
  node_start_fn start;
  char *argv[5];  /* node binary, V8 flags, script, NULL */
  int rc;
};

static void *nodeThreadMain(void *p) {
  struct NodeThreadArgs *a = (struct NodeThreadArgs *)p;
  a->rc = a->start(4, a->argv);
  logWrite("[launcher] node::Start returned %d", a->rc);
  _exit(a->rc & 0xff);
  return NULL; /* unreachable */
}

static int runNodeInProcess(const char *nodePath, const char *script) {
  logWrite("[launcher] in-process: dlopen(%s)", nodePath);
  void *h = dlopen(nodePath, RTLD_NOW | RTLD_LOCAL);
  if (!h) {
    const char *e1 = dlerror();
    const char *e2 = dlerror();
    logWrite("[launcher] dlopen failed: %s / %s", e1 ? e1 : "-",
             e2 ? e2 : "-");
    return -1;
  }
  dlerror();
  node_start_fn start = (node_start_fn)dlsym(h, "_ZN4node5StartEiPPc");
  const char *e = dlerror();
  if (!start || (e && e[0])) {
    logWrite("[launcher] dlsym(node::Start) failed: %s", e ? e : "null sym");
    return -1;
  }
  logWrite("[launcher] node::Start resolved at %p", (void *)start);

  /* seccomp shim BEFORE node runs: trapped syscalls become logged ENOSYS
   * instead of a SIGSYS thread kill. */
  installSigsysShim();

  /* argv must outlive the thread — static storage. Include V8 flags
   * to bypass the AllowHeapAllocationInRelease assertion that fires
   * during Isolate::Initialize when the (missing) snapshot path tries
   * to allocate on the heap. */
  static char arg0[MAX_LINE * 2];
  static char arg1[MAX_LINE * 2];
  static char argFlag1[] = "--no-verify-heap";
  static char argFlag2[] = "--no-snap";
  snprintf(arg0, sizeof(arg0), "%s", nodePath);
  snprintf(arg1, sizeof(arg1), "%s", script);

  static struct NodeThreadArgs na;
  na.start = start;
  na.argv[0] = arg0;
  na.argv[1] = argFlag1;
  na.argv[2] = argFlag2;
  na.argv[3] = arg1;
  na.argv[4] = NULL;
  na.rc = -1;

  pthread_attr_t attr;
  pthread_attr_init(&attr);
  pthread_attr_setstacksize(&attr, 32 * 1024 * 1024); /* node wants a big stack */
  pthread_t th;
  int prc = pthread_create(&th, &attr, nodeThreadMain, &na);
  if (prc != 0) {
    logWrite("[launcher] pthread_create failed: %s", strerror(prc));
    return -1;
  }
  void *ret = NULL;
  pthread_join(th, &ret); /* nodeThreadMain _exits, so this returns on error only */
  (void)ret;
  logWrite("[launcher] node thread ended without _exit (rc=%d)", na.rc);
  return -1;
}

/* ── Strategy 2: copy the signed node binary into the writable data dir,
 * chmod +x there, and exec the copy ─────────────────────────────────────────
 *
 * Device log finding: the bundled libnode.so installs with mode 0644 (no
 * execute bit) on a mount that is NOT noexec — execve then fails with
 * EACCES for the plainest Unix reason, and the app cannot chmod a file it
 * does not own inside el1/bundle. The el2 files dir IS app-owned: copy the
 * (code-signed) binary there once, give it 0755, exec it. */

static int copyFile(const char *src, const char *dst) {
  int in = open(src, O_RDONLY);
  if (in < 0) {
    logWrite("[launcher] copy: open(%s) failed: %s", src, strerror(errno));
    return -1;
  }
  int out = open(dst, O_WRONLY | O_CREAT | O_TRUNC, 0755);
  if (out < 0) {
    logWrite("[launcher] copy: open(%s) failed: %s", dst, strerror(errno));
    close(in);
    return -1;
  }
  char buf[262144];
  ssize_t r;
  while ((r = read(in, buf, sizeof(buf))) > 0) {
    ssize_t off = 0;
    while (off < r) {
      ssize_t w = write(out, buf + off, (size_t)(r - off));
      if (w < 0) {
        logWrite("[launcher] copy: write failed: %s", strerror(errno));
        close(in);
        close(out);
        return -1;
      }
      off += w;
    }
  }
  int rc = 0;
  if (r < 0) {
    logWrite("[launcher] copy: read failed: %s", strerror(errno));
    rc = -1;
  }
  close(in);
  close(out);
  return rc;
}

/* Returns only on failure (-1) — like every exec strategy, success never
 * returns. */
static int execFromDataDir(const char *nodePath, const char *dataDir,
                           const char *script) {
  char binDir[MAX_LINE * 2];
  char dest[MAX_LINE * 2];
  char tmp[MAX_LINE * 2];
  snprintf(binDir, sizeof(binDir), "%s/bin", dataDir);
  snprintf(dest, sizeof(dest), "%s/bin/node", dataDir);
  snprintf(tmp, sizeof(tmp), "%s/bin/node.tmp", dataDir);

  mkdir(binDir, 0755); /* ok if it exists */

  /* copy only if missing or different size (96MB copy ~ a few seconds) */
  struct stat ss, sd;
  int needCopy = 1;
  if (stat(dest, &sd) == 0 && stat(nodePath, &ss) == 0 &&
      sd.st_size == ss.st_size) {
    needCopy = 0;
    logWrite("[launcher] el2 copy already present: %s", dest);
  }
  if (needCopy) {
    logWrite("[launcher] copying %s → %s (%ld bytes)", nodePath, tmp,
             (long)ss.st_size);
    if (copyFile(nodePath, tmp) != 0) {
      return -1;
    }
    if (rename(tmp, dest) != 0) {
      logWrite("[launcher] rename failed: %s", strerror(errno));
      unlink(tmp);
      return -1;
    }
    logWrite("[launcher] copy complete");
  }

  if (chmod(dest, 0755) != 0) {
    logWrite("[launcher] chmod(%s, 0755) failed: %s", dest, strerror(errno));
  }
  if (stat(dest, &sd) == 0) {
    logWrite("[launcher] el2 node stat: mode=%o size=%ld", sd.st_mode,
             (long)sd.st_size);
    logMountFlagsFor(dest);
  }
  char arg0[MAX_LINE * 2];
  snprintf(arg0, sizeof(arg0), "%s", dest);
  char *const argv[] = {arg0, (char *)script, NULL};
  logWrite("[launcher] execv(el2): %s %s", arg0, script);
  execv(arg0, argv);
  logWrite("[launcher] execv(el2) failed: errno=%d (%s)", errno,
           strerror(errno));
  return -1;
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
    if (g_logFd >= 0) {
      snprintf(g_logPath, sizeof(g_logPath), "%s", logPath);
    } else {
      snprintf(logPath, sizeof(logPath),
               "/data/storage/el2/base/files/electerm-data/node-boot.log");
      g_logFd = open(logPath, O_WRONLY | O_CREAT | O_APPEND, 0644);
      if (g_logFd >= 0) {
        snprintf(g_logPath, sizeof(g_logPath), "%s", logPath);
      }
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
    snprintf(dir, sizeof(dir), "%s/entry/libs/x86_64", bundleDir);
    addCandidate(candidates, &nCand, dir, "el1");
    snprintf(dir, sizeof(dir), "%s/libs/arm64-v8a", bundleDir);
    addCandidate(candidates, &nCand, dir, "el1");
    snprintf(dir, sizeof(dir), "%s/libs/x86_64", bundleDir);
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
    /* setenv() COPIES. putenv() stores a pointer into `extraEnv`, a stack
     * array of the enclosing frame — fine across an immediate execve (the
     * kernel copies the strings) but a use-after-return for anything that
     * reads environ later in this process. */
    char *eq = strchr(extraEnv[i], '=');
    if (!eq) continue;
    *eq = '\0';
    setenv(extraEnv[i], eq + 1, 1);
  }

  /* 4. Rebuild stdio deterministically (0=/dev/null, 1=2=boot log) so node's
   *    libuv can never see a closed/aliased fd 0/1/2 — the exact condition
   *    behind libuv's `assert(fd > STDERR_FILENO)`. Also installs crash
   *    markers: the boot log records which signal killed the child. */
  setupStdioForNode();
  installCrashMarkers();

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

  /* 5b. node writes relative paths into the data dir — make that the cwd
   *     (the resfile install dir it runs from is read-only). */
  if (cfg.dataDir[0]) {
    if (chdir(cfg.dataDir) == 0) {
      logWrite("[launcher] cwd: %s", cfg.dataDir);
    } else {
      logWrite("[launcher] chdir(%s) failed: %s", cfg.dataDir,
               strerror(errno));
    }
  }

  /* 6. STRATEGY 1 — in-process node::Start via dlopen. Exec of a new image
   *    is blocked on device (direct, loader, memfd: all EACCES, even
   *    code-signed); dlopen is how app code legitimately gets mapped
   *    executable (nativespawn loaded this very library). Runs until exit
   *    on success; falls through to the exec ladder only if it cannot start.
   */
  if (runNodeInProcess(nodePath, cfg.script) == 0) {
    _exit(0); /* unreachable — nodeThreadMain exits the process */
  }

  /* 6b. STRATEGY 2 — the bundled file installs 0644 (no +x) and cannot be
   *    chmod'd in el1; copy the signed binary into the app-owned el2 data
   *    dir, chmod +x, exec the copy. */
  if (cfg.dataDir[0]) {
    if (execFromDataDir(nodePath, cfg.dataDir, cfg.script) == 0) {
      _exit(0); /* unreachable */
    }
  }

  /* 7. exec ladder (kept for environments where exec is permitted). */
  if (chmod(nodePath, 0755) != 0) {
    logWrite("[launcher] chmod(bundle node) failed: %s", strerror(errno));
  }

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

  logWrite("[launcher] FATAL: in-process start failed AND all exec strategies "
           "failed (execv errno=%d)",
           execErr);
  _exit(42);
}
