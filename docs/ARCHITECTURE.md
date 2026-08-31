# Architecture — electerm-harmony

> **This branch (`dev2`) uses Node.js + ArkWeb. No Electron runtime is involved.**
> (Other branches in this repo — `main`/`dev`/`dev1` — used the Electron 鸿蒙
> runtime. That does not apply here.)

## 1. Overview

electerm-harmony brings the [electerm-web](https://github.com/electerm/electerm-web) ssh/sftp/telnet/RDP/VNC/Spice/ftp client to HarmonyOS using a lightweight on-device runtime:

- **ArkWeb** (`@kit.ArkWeb`) — the `Web` component renders the electerm-web frontend UI.
- **Node.js** (a shared library `libnode.so`) — runs the electerm-web Express/Node backend, which serves the UI and the SSH/SFTP/telnet/ftp/RDP/VNC/Spice protocol logic, all on `http://127.0.0.1:5577`.
- **Native glue** — small NAPI/C modules bridge ArkTS and the Node.js runtime.

```
┌──────────────────────── HarmonyOS App ────────────────────────┐
│                                                                │
│  ┌──────────────────┐        ┌─────────────────────────────┐  │
│  │ ArkUI / ArkTS     │        │ Native (same app process)    │  │
│  │                   │        │                             │  │
│  │  pages/Index.ets  │        │  libnode_ctl.so (NAPI)      │  │
│  │    ├─ Web (ArkWeb)│──http──│    startBackend()           │  │
│  │    │   src=        │ 5577  │      └─ bootstrap thread    │  │
│  │    │   ://127.0.0.1│◄───────│          └─ dlopen(libnode.so)│ │
│  │    │   :5577       │        │              └─ node::Start │  │
│  │    └─ Boot overlay │        │                             │  │
│  │                   │        │  libnode_launcher.so        │  │
│  │                   │        │    (fallback child process) │  │
│  └──────────────────┘        └─────────────────────────────┘  │
│                                                                │
│  resfile/electerm/  ── read-only app bundle (frontend +       │
│                        app.bundle.mjs backend) used by node    │
│  <filesDir>/electerm-data/  ── writable data dir (db, keys,   │
│                               node-boot.log)                  │
└────────────────────────────────────────────────────────────────┘
```

Key design points:

- **No Electron, no Chromium-on-the-side.** The UI is a plain ArkWeb `Web` component; the protocol engine is Node.js running in-process. There is no BrowserWindow / web_engine HAR / libelectron.so.
- **In-process Node.js is the primary path.** The Electron-style pattern (Node core shipped as `.so` inside the app process) avoids the stricter seccomp filter that a spawned native child runs under — node's libuv dies in the child on event-loop syscalls. So node lives in the main process.
- **Native child process is a fallback only.** If in-process boot fails, the app falls back to `libnode_launcher.so:Main` via `childProcessManager.startNativeChildProcess`.

## 2. Components

### 2.1 Node.js runtime — `libnode.so` (electerm/ohos-node-shared)

- **Repo**: <https://github.com/electerm/ohos-node-shared>
- **What it is**: a *real* shared library build of Node.js for OpenHarmony (built with `--shared`, so it is a PIC `.so` with dynamic TLS and a `libnode.so.<vernum>` SONAME). It must **not** be the PIE executable form that some third-party builds ship — that form aliases the host TLS and crashes V8.
- **Version**: `24.2.0` (configured in `scripts/prepare-node.sh` and `.github/workflows/build-web.yml` as `NODE_VERSION`). The release tag is `ohos-node-shared-v${NODE_VERSION}`; the asset is `libnode-${arch}.so`.
- **Placement**: downloaded into `entry/libs/<abi>/libnode.so` (e.g. `entry/libs/arm64-v8a/libnode.so`). hvigor packages it into the HAP's native libs dir, and the app `dlopen`s it from there at runtime.
- **Launch flags**: node is started with `--jitless --no-verify-heap`. `--jitless` avoids V8's runtime `PROT_EXEC` mapping, which the OpenHarmony W^X policy rejects (the old `# Check failed: 12 == (*__errno_location())` SIGTRAP in `node::Start`). `--no-verify-heap` is defensive against allocation checks under the constrained runtime.
- **io_uring**: node's libuv unconditionally probes `io_uring_setup` (425) at loop init; the sandbox seccomp-traps it. A SIGSYS shim in `libnode_ctl.c` (and `node_launcher.c`) converts the trap to a logged `-1` (exactly `-1`, not `-ENOSYS`) so libuv's guard passes. `UV_USE_IO_URING=0` is also set (though the getenv guard in this libuv build is not actually consulted).

### 2.2 Native glue

- **`entry/src/main/cpp/node_ctl.c` → `libnode_ctl.so`** (NAPI module for the main process):
  - `startBackend(entryParams)` — spawns a detached bootstrap thread that `dlopen`s `libnode.so` and calls `node::Start`. `dlopen`/`dlsym`/`node::Start` are deliberately **not** on the ArkTS UI thread (doing them inline blocked the UI thread long enough to trip the `APP_INPUT_BLOCK` ANR watchdog).
  - `getBackendStatus()` — returns `idle | launching:<msg> | running:<msg> | failed:<msg>` so the ArkTS page can detect a hard bootstrap failure in milliseconds and fall back to the child process.
  - `killNode(pid)` — terminate the native-child-process backend.
  - Also installs: a crash-marker signal handler (writes a backtrace + fault PC to `node-boot.log`/hilog and parks the node thread instead of dying), and the SIGSYS seccomp shim described above.
  - Redirects fd 1/2 onto a 1 MB pipe drained by a reader thread into `node-boot.log` (filtering ArkWeb/Chromium noise) — keeping the pipe drained is what prevents Chromium's IO thread from blocking and wedging the `Web` component.
- **`entry/src/main/cpp/node_launcher.c` → `libnode_launcher.so`** (native child process entry, `Main`):
  - Started by `childProcessManager.startNativeChildProcess('libnode_launcher.so:Main', { entryParams })`. Parses `key=value` params, locates `libnode.so`, redirects stdio to the boot log, and `execv`s node with the electerm entry script. Falls back to a `memfd` + `execveat` path if the lib dir is `noexec`.

### 2.3 ArkTS layer (`entry` module)

- **`AbilityStage.ets`** — standard `AbilityStage` (no Electron `WebAbilityStage`).
- **`entryability/EntryAbility.ets`** — standard `UIAbility`; on `onDestroy()` it calls `BackendManager.killBackend()`.
- **`pages/Index.ets`** — the boot orchestrator:
  1. creates the writable data dir (`filesDir/electerm-data`, with an `el2` junction fallback);
  2. calls `startBackend()` (in-process primary, native child fallback);
  3. polls `http://127.0.0.1:5577` with plain HTTP until it answers;
  4. once ready, `controller.loadUrl(SERVER_URL)` swaps the `Web` component from the local `loading.html` to the backend.
  - While booting or on failure, a native overlay (`Stack` over the `Web`) shows the status / last boot-log lines, so a stuck boot is diagnosable from the screen alone.
- **`BackendManager.ets`** — tracks how the backend runs (`inProcess` vs `pid`) for clean shutdown.

### 2.4 Web app source (bundled in the HAP `resfile`)

- **Repo**: <https://github.com/electerm/electerm-web>
- **Source**: in the project root (`src/`, `build/`), built with:
  - **Vite** — builds the React frontend → `dist/assets/`
  - **esbuild** — bundles the Node.js backend → `app.bundle.mjs` (ESM)
- **Entry**: `resfile/electerm/index.js` (reads the bundled `app.bundle.mjs`, serves the UI and the protocol API).
- **Placement**: copied to `entry/src/main/resources/resfile/electerm/` and packaged read-only into the HAP. The node process runs from there; it writes its mutable state to `<filesDir>/electerm-data/`.

## 3. Build Flow

```
┌──────────────────────────────────────────────────────────────────┐
│  Build Pipeline (web variant — no Electron runtime)                │
├──────────────────────────────────────────────────────────────────┤
│                                                                    │
│  1. prepare-node.sh                                                │
│     └── Download libnode-<arch>.so from the ohos-node-shared      │
│         release → entry/libs/<abi>/libnode.so (verified ELF is a  │
│         shared lib, NOT a PIE)                                    │
│                                                                    │
│  2. prepare-web.sh                                                 │
│     ├── npm install (project root)                                 │
│     ├── build/harmony/build.js:                                     │
│     │   ├── npm run b (complete electerm build):                  │
│     │   │   ├── clean / compile (vite + copy + pug) → work/app/   │
│     │   │   └── prepare-file (src copy + deps install + cleanup)  │
│     │   ├── HarmonyOS delta:                                       │
│     │   │   ├── package.json main → index.js                      │
│     │   │   └── Remove native modules (node-pty, serialport, ...)  │
│     │   └── Copy work/app → resfile/electerm                       │
│     └── Verify output → entry/src/main/resources/resfile/electerm  │
│                                                                    │
│  3. build-web-app.sh                                               │
│     ├── Generate build-profile.json5 (entry module only)          │
│     ├── ohpm install                                               │
│     ├── hvigorw assembleApp (unsigned)                            │
│     └── hap-sign-tool.jar sign-app → electerm-harmony-arm64-<ver>.app
│                                                                    │
└──────────────────────────────────────────────────────────────────┘
```

Prepared artifacts inside the HAP:

- `libs/arm64-v8a/libnode.so` — the Node.js runtime
- `libs/arm64-v8a/libnode_ctl.so` — NAPI glue (in-process)
- `libs/arm64-v8a/libnode_launcher.so` — native child fallback
- `resources/resfile/electerm/index.js`, `app.bundle.mjs`, `views/index.pug`, `dist/assets/...` — the web app

## 4. Runtime Flow

```
App Launch
    │
    ▼
AbilityStage.onCreate() / EntryAbility.onWindowStageCreate()
    │
    ▼
Index.aboutToAppear() → startBackend()
    │  try IN-PROCESS first:
    │    libnode_ctl.startBackend() → background thread:
    │      dlopen(libnode.so) → node::Start (V8 --jitless)
    │      serves electerm on http://127.0.0.1:5577
    │
    │  poll http://127.0.0.1:5577 (getBackendStatus consulted for
    │  hard failures → fall back if 'failed:')
    │
    ▼ (if in-process fails)
childProcessManager.startNativeChildProcess('libnode_launcher.so:Main')
    │  node runs as a separate native child process
    │
    ▼
Web component loadUrl("http://127.0.0.1:5577")  ← UI appears
```

## 5. Key Design Decisions

| Decision | Rationale |
|----------|-----------|
| Use a shared `libnode.so` (ohos-node-shared) instead of an Electron runtime | Provides Node.js in-process without pulling in Chromium-as-a-second-runtime; the `Web` component already supplies Chromium for the UI |
| Run Node.js **in-process** (dlopen + `node::Start`) | The spawned native child runs under a stricter seccomp filter that kills libuv; the main process already runs libuv-class loops (NETSTACK/curl) |
| Keep a native **child-process fallback** | A hard in-process bootstrap failure (missing script / no libnode.so / dlopen failure) is detected fast and recovered without an ANR |
| `--jitless` Node.js | OpenHarmony W^X policy rejects V8's runtime `PROT_EXEC` mapping; jitless runs node as a pure interpreter |
| SIGSYS shim for `io_uring_setup` | libuv probes it unconditionally and the sandbox traps it; the shim returns exactly `-1` so the guard passes |
| `resfile/electerm` for app code | Directly readable by the node process; writable state goes to `filesDir/electerm-data` |
| Download `libnode.so` at build time, not committed | The binary is ~90–120 MB and is fetched from the ohos-node-shared release |

## 6. What's Committed vs. Downloaded

| Path | Committed? | Description |
|------|-----------|-------------|
| `entry/src/main/ets/` | Yes | Our ArkTS source (AbilityStage, EntryAbility, Index, BackendManager) |
| `entry/src/main/cpp/` | Yes | Native glue: `node_ctl.c`, `node_launcher.c`, `CMakeLists.txt` |
| `entry/src/main/module.json5` | Yes | Module configuration with permissions |
| `src/`, `build/`, `package.json` | Yes | Web app source code |
| `scripts/` | Yes | `prepare-node.sh`, `prepare-web.sh`, `build-web-app.sh`, … |
| `docs/` | Yes | Documentation |
| `AppScope/` | Yes | App-level config |
| `entry/libs/` | **No** (downloaded) | `libnode.so` from the ohos-node-shared release (gitignored) |
| `entry/src/main/resources/resfile/electerm/` | **No** (generated) | Web app build output (gitignored) |
| `build-profile.json5` | **No** (generated) | Generated by `build-web-app.sh` (gitignored) |
