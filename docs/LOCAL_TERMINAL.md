# Local terminal (node-pty) on HarmonyOS

The local terminal runs the user's own shell inside the app sandbox, backed by
[node-pty](https://github.com/microsoft/node-pty). Whether it is *offered* is
decided at runtime by a probe — the answer differs per ROM, and a device-type
guess gets it wrong in both directions.

## 1. Pipeline

```
scripts/prepare-node-pty.sh                 # native addon
  └─ GitHub release node-pty-ohos-v1  →  pty.node  (built on-device by @FiveHair:
     aarch64-linux-ohos + musl; cross-compiling it is not possible)
     ├─ md5 check (bd6da61b3a096c5c041ab991b6e3b236)
     ├─ ELF-patch DT_NEEDED: libc++_shared.so → libnode.so
     └─ install → entry/libs/arm64-v8a/libpty.node

build-src/web/build.mjs                     # JS layer
  └─ node_modules/node-pty  +  build-src/node-pty-ohos/lib/*.js (overrides)
     → resfile/electerm/node_modules/node-pty
     (NO .node file here on purpose — see trap 2)

entry/src/main/cpp/node_ctl.c
  └─ exports ELECTERM_PTY_ADDON = <dirname of the resolved libnode.so>/libpty.node

app/server/local-terminal.js                # the runtime probe
app/server/session-local.js                 # the session (HOME/cwd/PATH fixes)
app/lib/view.js                             # hasNodePty + supportSessionTypes
```

## 2. The two traps that make `require('pty.node')` fail on OHOS

**Trap A — a `dlopen()`ed addon cannot see the host process's symbols.**
OHOS's loader does not give a natively-dlopened object the process-global scope.
`dlsym(RTLD_DEFAULT)` finds `napi_fatal_error`, but the addon's relocation only
searches its own `DT_NEEDED` closure, so it dies with
`Error relocating …: napi_fatal_error: symbol not found`. Preloading a shim with
`RTLD_GLOBAL` does **not** help. The fix is to make the host an explicit
dependency by rewriting an existing `DT_NEEDED` in place
(`scripts/elf-patch-dynamic.py`). Use the **filename** `libnode.so`, never the
SONAME `libnode.so.137` — this loader treats `DT_NEEDED` as a literal filename.
`libnode.so` re-exports the libc++ symbols, so dropping `libc++_shared.so` is
safe.

**Trap B — OHOS refuses to map native code out of `resources/resfile/`.**
An addon under resfile fails at *load* with musl's useless
`No error information`. Only the app's **libs** dirs
(`entry/libs/<abi>/` → `libs/arm64/` in the HAP) may contain loadable native
code. Hence the addon is staged there and found through `ELECTERM_PTY_ADDON`;
`node-pty`'s `lib/unixTerminal.js` and `lib/utils.js` read that variable first
(our overrides in `build-src/node-pty-ohos/`). No decoy `pty.node` is shipped in
resfile, so a missing addon produces a clear error instead of a baffling one.

Two further OHOS patches come from the upstream asset and are kept:

* `pty.cc` returns an extra `slaveFd` and exports `writeToSlave(fd, slaveFd, buf)`
  — `write(master_fd)` is blocked by SELinux on some ROMs, so writes try
  `write(master)` → `ioctl(master, TIOCSTI)` → `ioctl(slave, TIOCSTI)` →
  `write(slave)` in order.
* `unixTerminal.js` replaces `tty.ReadStream(term.fd)` (which fails with
  `uv_tty_init EINVAL` on OHOS) with a custom `Duplex` over `fs.read`/`fs.write`,
  including a pre-WebSocket buffer flushed by `markConnected()`.

## 3. The runtime probe (`app/server/local-terminal.js`)

Runs once at boot, memoized, warmed on import:

| step | failure means |
| --- | --- |
| `pty.native.open(80, 24)` — openpty, **no fork** | the sandbox exposes no usable `/dev/ptmx` / devpts |
| `pty.spawn(<shell>, ['-c','exit 0'])` | openpty was fine, the **fork/exec** was refused |

`pty.native.open` is used deliberately instead of the public `pty.open()`: the
latter hands the fds to libuv, which returns `uv_tty_init EINVAL` even where the
pty is healthy — a probe that cries wolf is worse than no probe.

`<shell>` is resolved the way a session would (`resolveShell()`), not hardcoded,
and the chosen path is reported.

The verdict is published to `<dataDir>/local-terminal.json` (with the full
sandbox diagnosis) and logged once. `Index.ets` echoes that file to hilog as
`lt<N>/<total>:` chunks — the only readable channel on a sealed ROM, where the
sandbox is unreadable from outside and, once the feature is disabled, there is
no terminal pane to print into.

Consumers: `view.js` (`hasNodePty`, `supportSessionTypes`) and `session-local.js`
(`terminalLocal`, `testConnectionLocal`). `DISABLE_LOCAL_TERMINAL` overrides
everything and is checked inside the probe, so every consumer sees one answer.
Set it at build time with `ELECTERM_DISABLE_LOCAL_TERMINAL=1`, or at launch by
passing `DISABLE_LOCAL_TERMINAL=1` through `entryParams`.

## 4. Measured results

| device | result |
| --- | --- |
| 2-in-1 emulator (MateBook Pro) | `enabled (ok: openpty + forkpty ok (shell=/bin/sh))` — sessions run |
| phone emulator (Mate 70 Pro) | `disabled (openpty: openpty(3) failed.)` |

On the phone image, the report explains itself completely:

```
platform = openharmony arm64 node=v24.2.0
selinux domain = u:r:normal_hap:s0:<per-app categories>
native openpty (no fork) = FAIL openpty(3) failed.
spawnSync /bin/sh (no fork) = FAIL EACCES        ← children are fine, exec is not
/dev stat       = mode=40755                     ← the dir node itself is reachable …
/dev list       = FAIL EACCES                    ← … but readdir is denied
/dev/ptmx stat  = FAIL EACCES ; open = FAIL EACCES
/dev/pts  stat  = FAIL EACCES ; list = FAIL EACCES
/dev/tty  stat  = FAIL EACCES
mountinfo /dev  = tmpfs rw,seclabel,mode=755 | /dev/pts devpts rw,seclabel,mode=600,ptmxmode=000
```

devpts **is** mounted there, so this is not "no pty in the kernel" — it is a MAC
(SELinux) denial of the app domain over `/dev`, and it applies to
`/dev/ptmx` and `/dev/pts` even from the `hdc shell` domain:

```
$ hdc shell toybox ls -l /dev/ptmx      → ls: /dev/ptmx: Permission denied
$ hdc shell toybox head -c 0 /dev/ptmx  → head: /dev/ptmx: Permission denied
```

Labels involved: `/system/bin/sh` = `u:object_r:sh_exec:s0`,
`/system/bin/toybox` = `u:object_r:toybox_exec:s0`, `/dev/tty` =
`u:object_r:tty_device:s0` (the shell domain can read it; the app domain gets
`EACCES`).

### What an app can do about it: nothing

`ohos.permission.ACCESS_PTY` does not exist, and the release signing profile
pins the app:

```json
"bundle-info": { "apl": "normal", "app-feature": "hos_normal_app" },
"acls": { "allowed-acls": [] },
"app-distribution-type": "app_gallery"
```

`apl: normal` + `hos_normal_app` is what puts the app in the `normal_hap`
SELinux domain with an app UID, permanently, and it is issued by Huawei's
certificate chain. Granting another permission in `module.json5` cannot lift a
domain policy restriction, and requesting a `system_basic`/`system_core`
permission without an ACL entry fails the *install* (`9568289`).

### What would actually fix it

Either, for the app's bundle/domain:

1. allow `open`/`read`/`write`/`ioctl` on the pty node types — `/dev/ptmx` and
   `/dev/pts/*` — i.e. mirror what the 2-in-1 emulator policy already allows; and
2. allow `execute` of `u:object_r:sh_exec:s0` (`/system/bin/sh`), otherwise a
   working pty still has nothing to run (`spawnSync /bin/sh` = `EACCES` today);

or reissue the signing profile as a system app (`apl: system_basic` /
`system_core`, `app-feature: hos_system_app`, preinstalled), which is a business
decision rather than a technical one.

Corroborating precedent: a PuTTY port to HarmonyOS PC hit the same wall
(`posix_openpt()` → `EACCES`) and reached the same conclusion.

## 5. Verifying

```bash
# 1. probe verdict + full sandbox diagnosis (works on a sealed ROM)
hdc shell hilog -x | grep -a 'lt[0-9]*/'
hdc shell hilog -x | grep -a '\[io\]' | grep -a 'local terminal'

# 2. what the UI will offer
hdc fport tcp:16677 tcp:5577
curl -s http://127.0.0.1:16677/ | grep -oE '"(hasNodePty|supportSessionTypes)":[^,]*\[[^]]*\]'

# 3. drive a real local session over the backend's own HTTP+WebSocket API
#    (no UI automation, no screenshots)
node scripts/verify-local-terminal.mjs
```

`scripts/verify-local-terminal.mjs` scrapes the JWT out of the rendered page,
creates a `local` terminal over `/common/s`, then runs commands on
`/terminals/<pid>`. Healthy transcript on the 2-in-1 emulator:

```
$ pwd          → /data/storage/el2/base/files/electerm-data
$ echo ~       → /data/storage/el2/base/files/electerm-data
$ ls ~         → local-terminal.json  log  node-boot.log  pty-duplex.log  uploads
$ echo $PATH   → …:/data/service/hnp/bin::/system/bin
$ /system/bin/toybox uname -a → Linux localhost … aarch64 Toybox
```

`HOME` and `cwd` are both the app's data dir because appspawn supplies no HOME;
`/system/bin` is **appended** to `PATH` (never prepended), so a public HNP's
richer binaries still shadow toybox.
