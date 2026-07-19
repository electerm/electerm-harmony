# Porting Plan — From electerm-android to electerm-harmony

> A concrete, actionable design for porting the working Android port of
> electerm-web (`temp/electerm-android/`) to HarmonyOS.
>
> This document is the single source of truth for the porting effort. It maps
> every Android-side mechanism to its HarmonyOS equivalent, lists the files to
> create or change, and breaks the work into shippable phases.

---

## 0. TL;DR

The Android port works because it runs the **full electerm-web Node.js backend
on-device** and lets a WebView talk to it over `http://127.0.0.1:5577`. The
current HarmonyOS project has the right *idea* (see `ARCHITECTURE.md`) but the
*implementation* in `entry/src/main/ets/pages/Index.ets` only loads a
**static, pre-rendered HTML** file via `file://`. That means SSH / SFTP /
Telnet / FTP / RDP / VNC / Spice **do not work**, because there is no Node.js
backend running.

The fix is to mirror the Android architecture:

```
ArkUI Shell (ArkTS)            ohos-node + electerm-web (Node.js)
 ┌───────────────┐              ┌──────────────────────────────┐
 │  Web component│  http GET    │  Express server              │
 │  (ArkWeb)     │ ───────────► │  on 127.0.0.1:5577           │
 │  loads loading│              │  SSH/SFTP/Telnet/FTP/RDP/VNC/ │
 │  page, then   │  WebSocket   │  Spice engine (pure JS/WASM)  │
 │  redirects to │ ◄──────────► │                              │
 │  127.0.0.1    │              │  SQLite via node:sqlite       │
 └───────────────┘              └──────────────────────────────┘
        ▲                                  ▲
        │ child_process.spawn              │
        └──────────────────────────────────┘
                  ArkTS spawns the node binary
                  extracted from rawfile/node/
```

Everything that works on Android (SSH, SFTP, Telnet, FTP, RDP, VNC, Spice,
Zmodem, trzsz, sync, themes, bookmarks, AI) will work on HarmonyOS with
**the same set of caveats** (local terminal + serial port disabled until the
native modules are ported).

---

## 1. State Audit

### 1.1 What the Android port does (the reference)

Source: `temp/electerm-android/`.

| Concern | Android implementation | File(s) |
|---|---|---|
| Native shell | Capacitor + Android WebView | `build/android/capacitor.config.ts` |
| Node.js runtime on device | `@capawesome/capacitor-nodejs` plugin (embeds Node 18) | `build/android/package.json` |
| Frontend build | Vite → `www/nodejs/dist/assets/` | `build/android/vite.android.mjs`, `build/android/build.mjs` (`runVite`) |
| Backend build | esbuild bundle → `www/nodejs/app.bundle.mjs` | `build/android/build.mjs` (`bundleBackend`) |
| Native modules not buildable for the platform (`node-pty`, `serialport`, `node-bash`, `font-list`) | Kept `external` in esbuild; loaded via guarded `import('x').catch(...)` in source; `DISABLE_LOCAL_TERMINAL=1` env var | `build/android/build.mjs` (`external`), `src/app/server/session-local.js`, `src/app/lib/serial-port.js`, `src/app/lib/font-list.js` |
| `node:sqlite` shim (Node 18 has no built-in) | sql.js (pure JS + WASM), base64-embedded wasm, aliased via esbuild | `build/android/build.mjs` (`genSqliteShim`, `bundleBackend` alias) |
| path-to-regexp v8 Unicode regex (Node 18 lacks full ICU) | esbuild plugin rewrites `\p{ID_Start}` / `\p{ID_Continue}` to ASCII classes | `build/android/build.mjs` (`patchPathToRegexpPlugin`) |
| `.node` native addon files | Marked `external` in esbuild | `build/android/build.mjs` (`nativeNodePlugin`) |
| Loading page | Tiny `www/index.html` polls `http://127.0.0.1:5577`, redirects via `location.replace` once up | `build/android/build.mjs` (`writeLoadingPage`) |
| Node entry script | `www/nodejs/index.js` does `process.chdir`, sets `HOST/PORT/SERVER_SECRET/DISABLE_LOCAL_TERMINAL/VIEW_FOLDER/DB_PATH/HOME`, then `await import('./app.bundle.mjs')` | `build/android/build.mjs` (`writeNodeEntry`) |
| Stable user-data dir (survives app updates) | `<nodeProjectParent>/electerm-data/` sibling of the extracted node project | `build/android/build.mjs` (`writeNodeEntry` `userDataDir`) |
| Cleartext HTTP to localhost | `network_security_config.xml` permits `127.0.0.1` cleartext | `build/android/res-overlay/xml/network_security_config.xml` |
| Keep navigation to backend in-app | `allowNavigation: ['127.0.0.1']` in Capacitor config | `build/android/capacitor.config.ts` |
| App icons / splash | res-overlay with density-specific PNGs + adaptive icon XML | `build/android/res-overlay/` |
| CI | GitHub Actions on `ubuntu-latest`, builds debug + release APKs, publishes GitHub Release | `.github/workflows/build-android.yml` |

### 1.2 What the current HarmonyOS project does (the broken state)

| Concern | HarmonyOS current state | File(s) |
|---|---|---|
| Native shell | ArkUI `EntryAbility` + `Web` component | `entry/src/main/ets/entryability/EntryAbility.ets`, `entry/src/main/ets/pages/Index.ets` |
| Node.js runtime | `ohos-node` (Node 24 ARM64) downloaded into `rawfile/node/` — **but never executed** | `scripts/prepare-node.sh` |
| Frontend build | `npm run build` of electerm-web, then **pre-render pug to static HTML** at build time | `scripts/prepare-web.sh` |
| Backend build | **None.** The whole `node_modules/` (≈60 MB) and `src/app/` are copied verbatim into rawfile, expecting Node to run them — but Node never runs | `scripts/prepare-web.sh` |
| `node:sqlite` | Source uses built-in `node:sqlite` (works on Node 24, no shim needed) | `temp/electerm-android/src/app/lib/sqlite.js` |
| Loading page | **None.** `Index.ets` shows a native `Text` "Starting electerm..." while extracting files, then loads `file://.../dist/index.html` | `entry/src/main/ets/pages/Index.ets` |
| WebView URL | `file://${webDir}/dist/index.html` — **static file URL, no backend** | `entry/src/main/ets/pages/Index.ets` |
| Node entry script | **None.** No equivalent of `www/nodejs/index.js` | — |
| Stable user-data dir | Not handled — data would be lost on app update if Node were running | — |
| Cleartext HTTP to localhost | `.mixedMode(MixedMode.All)` is already set on the `Web` component — sufficient for `http://127.0.0.1` | `entry/src/main/ets/pages/Index.ets` |
| Resource extraction | `manifest.json` lists every rawfile path; `Index.ets` extracts them all to `context.filesDir/electerm-web/` at first launch | `scripts/gen-manifest.sh`, `entry/src/main/ets/pages/Index.ets` (`extractAllRawfiles`) |
| Process spawning | `Index.ets` comment: *"HarmonyOS does not support spawning child processes (no child_process.spawn)"* — this is the **root cause** of the broken state | `entry/src/main/ets/pages/Index.ets` |
| CI | GitHub Actions on `ubuntu-latest`, two-phase signing with `hap-sign-tool.jar` | `.github/workflows/build.yml`, `scripts/build-app.sh` |

### 1.3 The critical gap

> **The current HarmonyOS project loads a static HTML file. The Android
> project runs a Node.js backend. That backend is what makes SSH/SFTP/etc.
> work. Without a running backend, electerm-harmony is a non-functional
> shell.**

Everything else (build pipeline, signing, resource extraction, icons) is
already in place and works. The single missing piece is **starting the
Node.js backend as a child process and pointing the WebView at it.**

---

## 2. HarmonyOS Capability Check

Before designing, we must confirm what HarmonyOS APIs are available for
spawning a native binary. The `Index.ets` comment claiming "HarmonyOS does
not support spawning child processes" is either stale or refers to a limited
subset. Here are the actual options, in order of preference:

### 2.1 Option A — `@ohos.child_process` (preferred)

HarmonyOS provides the `@ohos.child_process` module (API 10+ / HarmonyOS 4.0+)
with `runCmd` and the lower-level `spawn` / `exec` APIs. On HarmonyOS 5.0
(API 12+, which is the SDK targeted by `build-profile.json5`
`compatibleSdkVersion: 5.0.1(13)`), the child_process module supports:

- `child_process.spawn(command, args?, options?)` → returns a
  `ChildProcess` with `pid`, `stdio`, `on('exit')`, `on('error')`, etc.
- `options.env` — pass a custom environment (this is how we inject
  `HOST`, `PORT`, `SERVER_SECRET`, `DISABLE_LOCAL_TERMINAL`, `DB_PATH`,
  `HOME`, `VIEW_FOLDER`).
- `options.cwd` — set the working directory to the extracted node project.
- Stdout/stderr pipes for log capture.

This is the **direct equivalent** of Node's own `child_process.spawn`, and is
exactly what we need to run `./node bin/node app.bundle.mjs`.

> **Action item (verification):** Before writing production code, write a
> 30-line spike that:
> 1. Extracts `rawfile/node/bin/node` to `context.filesDir/bin/node`
> 2. `chmod`s it executable (HarmonyOS `fs.chmodSync`)
> 3. Spawns it via `child_process.spawn` with `['--version']`
> 4. Reads stdout and logs it
>
> If this prints `v24.2.0`, Option A is viable and the rest of this document
> applies as written. If it fails (e.g. `EACCES` or `EPERM` because the
> sandbox disallows executing downloaded binaries), fall back to Option B.

### 2.2 Option B — NAPI / native module embedding libnode

If the HarmonyOS sandbox refuses to execute a standalone binary extracted
from rawfile (this is plausible — both iOS and modern Android disallow
executing downloaded binaries via `W^X` / `exec-space` protections), we need
to embed Node.js as a **shared library loaded through a NAPI module**.

This means:
1. Rebuild `ohos-node` (or fork `hqzing/ohos-node`) to produce
   `libnode.so` instead of a standalone `node` binary.
2. Write a small NAPI C++ module (`entry/src/main/cpp/node_runner/`) that
   calls `node::Start(argc, argv)` in a background thread.
3. Expose a TS-callable `startNodeBackend(entryScript: string, env: Record<string, string>): Promise<void>` from the NAPI module.
4. ArkTS calls `startNodeBackend` in `aboutToAppear()`.
5. The Node.js event loop runs in the NAPI module's thread, sharing the
   process with ArkTS. The Express server binds `127.0.0.1:5577` and the
   `Web` component reaches it via the same loopback HTTP as on Android.

This is the same architecture as `@capawesome/capacitor-nodejs` on Android
(which embeds `nodejs-mobile` — a libnode build). The Android plugin
auto-extracts the node project to `getFilesDir()/nodejs/` and starts it; the
HarmonyOS NAPI module would do the equivalent.

> **Cost:** Significant. Requires native C++ build via NDK + CMake, plus a
> fork of `hqzing/ohos-node` that emits a `.so`. Defer to Phase 3 if
> Option A works.

### 2.3 Option C — `node:sqlite` and other Node 24 built-ins

Unlike the Android port (which runs Node 18), `ohos-node` is Node 24. That
means we **do not** need:
- The `sql.js` shim for `node:sqlite` — Node 24 has `node:sqlite` built-in.
- The `path-to-regexp` regex patch — Node 24 has full ICU.
- The `node:diagnostics_channel` stub for the browser build — irrelevant to
  the backend bundle.

We can drop those Android-specific shims entirely.

### 2.4 Option D — Filesystem layout for execution

HarmonyOS app sandbox paths:

| Path | API | Writable | Executable | Use |
|---|---|---|---|---|
| `context.filesDir` | `common.Context.filesDir` | Yes | **Verify** | Node binary + bundled node project |
| `context.cacheDir` | `common.Context.cacheDir` | Yes | No | Scratch / downloads |
| `context.distributedFilesDir` | — | Yes | No | Synced files |
| `context.resourceManager.getRawFileContent()` | — | Read-only | n/a | Bundled assets (rawfile/) |

The node binary must be **extracted from rawfile to `filesDir`** before it
can be spawned — rawfile is read-only and inside the HAP. This is already
done for the static web content by `extractAllRawfiles`; we just need to do
the same for `rawfile/node/bin/node`.

### 2.5 Network permissions

`module.json5` already requests:

- `ohos.permission.INTERNET` — allows the Web component to fetch
  `http://127.0.0.1:5577` and the Node backend to open outbound SSH/SFTP/etc.
  sockets.
- `ohos.permission.RUNNING_LOCK` — keeps the CPU running while the app is
  backgrounded, so long-running SSH sessions don't die.

No additional permissions are needed.

---

## 3. Target Architecture

```
┌──────────────────────────────────────────────────────────────┐
│                    HarmonyOS Device                          │
│                                                              │
│  ┌─────────────────────────┐    ┌─────────────────────────┐ │
│  │   Native Shell (ArkTS)  │    │  electerm-web (Node 24) │ │
│  │   EntryAbility          │    │                         │ │
│  │                         │    │  ohos-node binary       │ │
│  │  ┌───────────────────┐  │    │  (extracted to          │ │
│  │  │  Web component    │──┼────│   filesDir/bin/node)    │ │
│  │  │  (ArkWeb)         │  │    │                         │ │
│  │  │                   │  │    │  Express + ws server    │ │
│  │  │  1. loading page  │  │    │  on 127.0.0.1:5577      │ │
│  │  │  2. redirect to   │  │    │                         │ │
│  │  │     127.0.0.1:5577│  │    │  ssh2 / basic-ftp /     │ │
│  │  └───────────────────┘  │    │  telnet / RDP(WASM) /   │ │
│  │                         │    │  VNC / Spice / etc.     │ │
│  │  child_process.spawn(   │    │                         │ │
│  │    nodeBin,             │    │  node:sqlite (built-in) │ │
│  │    [entryScript],       │    │                         │ │
│  │    { env, cwd })        │    │  User data:             │ │
│  │                         │    │   filesDir/electerm-data│ │
│  │  Extracts rawfile/*     │    │     /sqlite/*.db        │ │
│  │  → filesDir/electerm/   │    │     /log/electerm.log   │ │
│  │     bin/node            │    │     /.ssh/              │ │
│  │     web/app.bundle.mjs  │    │     /uploads/           │ │
│  │     web/index.js        │    │                         │ │
│  │     web/dist/assets/... │    │                         │ │
│  │     web/views/index.pug │    │                         │ │
│  └─────────────────────────┘    └─────────────────────────┘ │
│                                                              │
└──────────────────────────────────────────────────────────────┘
```

Key differences from the Android port:

| Aspect | Android | HarmonyOS (target) |
|---|---|---|
| Native shell | Capacitor (Java/Kotlin) | ArkUI (ArkTS) |
| WebView | Android System WebView | ArkWeb `Web` component |
| Node runtime | `@capawesome/capacitor-nodejs` plugin | `ohos-node` binary spawned via `@ohos.child_process` (Option A) **or** NAPI-embedded libnode (Option B) |
| Node version | 18 | 24 |
| `node:sqlite` | sql.js shim | built-in (no shim) |
| ICU | stripped → patch regex | full → no patch |
| Loading page | `www/index.html` (served by Capacitor local server) | rawfile asset loaded via `file://`, then JS polls + `location.replace` |
| Cleartext to localhost | `network_security_config.xml` | `MixedMode.All` on Web component (already set) |
| App-update-safe data dir | `getFilesDir()/electerm-data/` | `context.filesDir/electerm-data/` |
| Resource extraction | plugin extracts `www/nodejs/` automatically | manual via `manifest.json` (already implemented) |
| CI signing | Gradle + keystore | `hap-sign-tool.jar` two-phase (already implemented) |

---

## 4. Component-by-Component Porting Plan

For each Android-side mechanism, here is exactly what to create or change in
the HarmonyOS project.

### 4.1 `Index.ets` — replace static-HTML loader with Node.js spawner

**File:** `entry/src/main/ets/pages/Index.ets`

**Current behavior:** Extract rawfile to sandbox, then load
`file://.../dist/index.html` in the `Web` component. No backend.

**New behavior:**

1. On `aboutToAppear()`:
   - Determine sandbox paths:
     - `filesDir` (already `context.filesDir`)
     - `binPath = ${filesDir}/electerm/bin/node`
     - `webProjectDir = ${filesDir}/electerm/web`
     - `entryScript = ${webProjectDir}/index.js`
     - `userDataDir = ${filesDir}/electerm-data` (sibling of `electerm/`,
       survives updates — same pattern as Android's
       `../electerm-data`)
   - If `binPath` does not exist (first launch or app update):
     - Read `rawfile/manifest.json`, extract every listed file to its
       destination under `${filesDir}/`. Existing extraction logic
       (`extractAllRawfiles`) is reused; just change the target layout from
       `${filesDir}/electerm-web/...` to `${filesDir}/electerm/...`.
     - After extraction, `fs.chmodSync(binPath, 0o755)` so the binary is
       executable.
   - Prepare env for the child process:
     ```
     NODE_ENV=production
     HOST=127.0.0.1
     PORT=5577
     SERVER_SECRET=<from rawfile/.env or from a compile-time constant>
     DISABLE_LOCAL_TERMINAL=1
     VIEW_FOLDER=${webProjectDir}/views
     DB_PATH=${userDataDir}
     HOME=${userDataDir}
     ```
   - Create `${userDataDir}/.ssh` (mkdir -p) so SSH key enumeration works.
   - Spawn the node binary:
     ```ts
     const child = child_process.spawn(binPath, [entryScript], {
       env,
       cwd: webProjectDir
     })
     child.stdout.on('data', d => hilog.info(...))
     child.stderr.on('data', d => hilog.error(...))
     child.on('exit', code => hilog.warn(...))
     ```
   - Start polling `http://127.0.0.1:5577/` every 500ms (use
     `@ohos.net.http` or a simple `fetch` inside the Web component).
   - When the poll succeeds, set `@State serverReady = true`.

2. In `build()`:
   - If `!serverReady`, show the native loading UI (current `Text` block is
     fine — just update the message to "Starting engine…").
   - If `serverReady`, render:
     ```
     Web({ src: 'http://127.0.0.1:5577/', controller: this.controller })
       .javaScriptAccess(true)
       .domStorageAccess(true)
       .mixedMode(MixedMode.All)   // allow http://127.0.0.1 from https file origin
       .fileAccess(true)
       .imageAccess(true)
       .onlineImageAccess(true)
     ```
   - **Alternative (cleaner, matches Android):** Always load a tiny
     `loading.html` from `file://` first; that page's JS polls the backend
     and calls `location.replace('http://127.0.0.1:5577/')` when ready.
     This avoids the ArkTS-side polling and matches the Android UX exactly
     (see §4.4 below).

3. On `aboutToDisappear()` (or `onWindowStageDestroy()` in `EntryAbility`):
   - `child.kill('SIGTERM')` and wait briefly, then `SIGKILL` if still alive.
   - This mirrors Android's "kill the Node process when the app is closed".

**Why this works:** The Android port proved that a localhost HTTP server is
the right IPC mechanism between a WebView shell and a Node backend. ArkWeb is
chromium-based and supports the same `http://127.0.0.1` pattern; the
`MixedMode.All` setting already permits mixed content (https file origin
loading http backend). The only new piece is `child_process.spawn`, which
HarmonyOS 5.0 supports.

### 4.2 `EntryAbility.ets` — lifecycle hooks

**File:** `entry/src/main/ets/entryability/EntryAbility.ets`

Add minimal lifecycle management:

- `onForeground()` — if the Node child was suspended (e.g. `SIGSTOP` during
  background), send `SIGCONT`. Actually HarmonyOS keeps the app process
  alive while backgrounded thanks to `RUNNING_LOCK`, so this is likely a
  no-op.
- `onBackground()` — keep the Node process running. We **do not** kill it
  on background because long-running SSH sessions must survive.
- `onDestroy()` — kill the Node child with `SIGTERM`. The `Index` component
  owns the child process reference; expose it via a module-level variable
  or pass it up to `EntryAbility` through a callback registered in
  `onWindowStageCreate`.

### 4.3 Backend bundle — port `build/android/build.mjs` to `build/harmony/build.mjs`

**New file:** `build/harmony/build.mjs`

This is the heart of the alignment with the Android port. It produces the
contents that will end up in `rawfile/electerm-web/` (renamed to
`rawfile/electerm/` for clarity).

Steps (mirroring `temp/electerm-android/build/android/build.mjs`):

1. **Frontend (Vite)**
   - Copy `temp/electerm-android/build/android/vite.android.mjs` →
     `build/harmony/vite.harmony.mjs`.
   - Change the `outDir` from
     `build/android/www/nodejs/dist/assets` to
     `build/harmony/rawfile/electerm/dist/assets` (or wherever the
     HarmonyOS rawfile lives — see §4.5).
   - Keep the rest identical (same entry points
     `src/client/entry-web/electerm.jsx`, `basic.js`, `worker.js`; same
     aliases for `ironrdp-wasm`, `@novnc/novnc/core/rfb`,
     `node:diagnostics_channel` stub).

2. **Static assets**
   - Same as Android: copy `src/client/statics/`, `electerm-icons/icons/`,
     `@electerm/electerm-resource/res/imgs/` and `tray-icons/` into
     `dist/assets/`.
   - Copy `src/app/views/index.pug` to `views/index.pug`.

3. **Loading page** (new — see §4.4)
   - Write `rawfile/electerm/loading.html` — the equivalent of Android's
     `www/index.html`. This is what the `Web` component loads first.

4. **Backend (esbuild)**
   - Entry: `src/app/app.js`.
   - Format: `esm`, platform: `node`, target: `node24` (not `node18`).
   - **Drop the `node:sqlite` alias** — Node 24 has it built-in.
   - **Drop the `patchPathToRegexpPlugin`** — Node 24 has full ICU.
   - Keep the `nativeNodePlugin` (mark `.node` files external).
   - Keep `external: ['node-pty', 'serialport', 'node-bash', 'font-list']`
     — same set of native modules that aren't buildable for the target.
   - Keep the `banner.js` that defines `require`, `__filename`, `__dirname`
     from `import.meta.url` (esbuild ESM bundles still need this for CJS
     deps that reference `__dirname`).
   - Output: `rawfile/electerm/app.bundle.mjs`.

5. **Node entry script**
   - Port `writeNodeEntry()` from
     `temp/electerm-android/build/android/build.mjs` almost verbatim.
   - Differences:
     - `process.env.HOST = '127.0.0.1'`
     - `process.env.PORT = '5577'`
     - `process.env.SERVER_SECRET` — read from the `.env` file bundled into
       rawfile (already produced by `prepare-web.sh`), **or** injected by
       `Index.ets` via the `env` argument to `child_process.spawn` (the
       latter is cleaner because the secret never has to live in the bundle;
       see §4.6).
     - `process.env.DISABLE_LOCAL_TERMINAL = '1'`
     - `process.env.VIEW_FOLDER = resolve(__d, 'views')`
     - `userDataDir = resolve(__d, '..', 'electerm-data')` — sibling of the
       node project, survives updates.
     - `process.env.DB_PATH = userDataDir`
     - `mkdirSync(userDataDir/.ssh, { recursive: true })`
     - `process.env.HOME = userDataDir`
     - `process.chdir(__d)` — same fix as Android, because the spawned
       binary's cwd will be the cwd passed by `child_process.spawn`, but
       the entry script should be defensive.
   - Write to `rawfile/electerm/index.js` and a matching
     `rawfile/electerm/package.json`
     (`{ "name": "electerm-node", "version": "...", "main": "index.js", "type": "module" }`).

6. **`.env`**
   - The Android build copies `build/android/.env` to `www/nodejs/.env`.
   - For HarmonyOS we can do the same, **but** prefer injecting env via
     `child_process.spawn` options from ArkTS. The `.env` file is then only
     used as a fallback / for `dotenv.config()` inside the bundle.

### 4.4 Loading page — port `writeLoadingPage()`

**New file:** `build/harmony/rawfile/electerm/loading.html`

Copy `temp/electerm-android/build/android/build.mjs`'s `writeLoadingPage()`
output almost verbatim:

- `http://127.0.0.1:5577/` is the target.
- On HarmonyOS, `window.Capacitor` is undefined, so the script falls into
  the `fetch(BASE, { mode: 'no-cors' })` branch — that works fine in ArkWeb.
- The 4-second `setTimeout` fallback (`location.replace(BASE)`) also works.

ArkWeb specifics:

- The page is loaded from `file://`, so the fetch to `http://127.0.0.1` is a
  cross-origin request from a `file://` origin. ArkWeb's
  `.mixedMode(MixedMode.All)` already permits this.
- If `fetch` is blocked by CORS in some ArkWeb version, fall back to the
  top-level navigation immediately (the 4-second timeout already does this).

This page is loaded by the `Web` component via:

```ts
Web({ src: `file://${webDir}/loading.html`, controller: this.controller })
```

Once it detects the backend, it calls `location.replace('http://127.0.0.1:5577/')`,
which navigates the same `Web` component to the real backend — no ArkTS
polling needed. This is the **exact** pattern the Android port uses, and it
elegantly sidesteps the issue of "how do I know the server is ready from
ArkTS?".

### 4.5 rawfile layout — reorganize

**Target rawfile structure:**

```
entry/src/main/resources/rawfile/
├── manifest.json              # generated by scripts/gen-manifest.sh
└── electerm/
    ├── bin/
    │   └── node               # ohos-node binary (from prepare-node.sh)
    ├── loading.html           # tiny loading page (from build.mjs)
    ├── index.js               # node entry script (from build.mjs)
    ├── app.bundle.mjs         # esbuild backend bundle (~10 MB)
    ├── package.json           # { name, version, main, type:module }
    ├── .env                   # server config (optional, env injection preferred)
    ├── views/
    │   └── index.pug          # pug template for the Express index route
    └── dist/
        └── assets/
            ├── js/            # vite-built frontend (electerm-*.js, basic-*.js, worker-*.js)
            ├── chunk/         # vite code-split chunks
            ├── css/           # style-*.css
            └── images/        # electerm logos, icons, etc.
```

Compared to the current layout:

- `rawfile/node/` → `rawfile/electerm/bin/` (grouped with the web project
  so they're extracted together; the binary is just another asset from
  rawfile's perspective).
- `rawfile/electerm-web/` → `rawfile/electerm/` (one tree, not two).
- Add `loading.html`, `index.js`, `app.bundle.mjs`, `package.json`.
- Drop the entire `node_modules/` directory (≈60 MB) — the esbuild bundle
  replaces it.
- Drop `src/app/` — same reason.

**Expected size reduction:** from ~230 MB to ~80 MB (node binary ~129 MB +
frontend ~5 MB + backend bundle ~10 MB + pug ~1 KB). The node binary is the
dominant cost; stripping it can save another ~80 MB (see BUILD.md §7).

### 4.6 `prepare-web.sh` — replace with `build/harmony/build.mjs` invocation

**File:** `scripts/prepare-web.sh`

Current behavior: `npm install` + `npm run build` + pre-render pug + copy
`node_modules/` + `src/app/` + `dist/` + `package.json` + `.env` into rawfile.

New behavior:

```bash
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
WEB_SRC_DIR="${PROJECT_ROOT}/electerm-web"

cd "${WEB_SRC_DIR}"
npm install --legacy-peer-deps
# .env is created with OHOS_SERVER_SECRET (unchanged)
cp .sample.env .env
[ -n "${OHOS_SERVER_SECRET:-}" ] && sed -i.bak "s/^SERVER_SECRET=.*/SERVER_SECRET=${OHOS_SERVER_SECRET}/" .env && rm -f .env.bak

# Build the harmony rawfile bundle (vite frontend + esbuild backend + loading page + node entry)
node "${PROJECT_ROOT}/build/harmony/build.mjs" \
  --web-src "${WEB_SRC_DIR}" \
  --out "${PROJECT_ROOT}/entry/src/main/resources/rawfile/electerm"
```

The heavy lifting moves into `build/harmony/build.mjs`, which is a direct
port of `temp/electerm-android/build/android/build.mjs` with the
HarmonyOS-specific adjustments noted in §4.3.

### 4.7 `prepare-node.sh` — adjust output path

**File:** `scripts/prepare-node.sh`

Change:

```diff
-RAWFILE_NODE_DIR="${PROJECT_ROOT}/entry/src/main/resources/rawfile/node"
+RAWFILE_NODE_DIR="${PROJECT_ROOT}/entry/src/main/resources/rawfile/electerm/bin"
```

After extraction, `chmod +x ${RAWFILE_NODE_DIR}/bin/node` (already a regular
file, but make sure it's executable in case the tarball preserved perms).

### 4.8 `gen-manifest.sh` — adjust paths

**File:** `scripts/gen-manifest.sh`

No logic change — it already walks `rawfile/` recursively. Just verify the
new layout produces sensible relative paths like `electerm/bin/node`,
`electerm/index.js`, etc.

### 4.9 `module.json5` — no change needed

The current `entry/src/main/module.json5` already requests the right
permissions (`INTERNET`, `RUNNING_LOCK`). No new permissions are required
for `child_process.spawn` — it's a sandboxed API available to all apps.

### 4.10 `build-profile.json5` — no change needed

Generated by `build-app.sh` at build time. The esbuild/vite outputs land in
`rawfile/` which is packaged automatically by `hvigorw assembleApp`.

### 4.11 `.github/workflows/build.yml` — minor adjustment

**File:** `.github/workflows/build.yml`

The workflow already does:

1. `prepare-node.sh` — downloads ohos-node.
2. `prepare-web.sh` — builds electerm-web.
3. `gen-manifest.sh` (called inside `build-app.sh`).
4. `ohpm install`.
5. `hvigorw assembleApp -p enableSignTask=false`.
6. `hap-sign-tool.jar sign-app`.

Changes needed:

- Step 1 (`prepare-node.sh`) — output path moves from
  `rawfile/node/` to `rawfile/electerm/bin/`. No workflow change, just the
  script change from §4.7.
- Step 2 (`prepare-web.sh`) — now invokes
  `build/harmony/build.mjs` instead of inlining the build logic. The
  workflow still passes `OHOS_SERVER_SECRET`. Optionally drop the secret
  entirely and let `Index.ets` inject it via env (see §4.12).
- No other workflow changes.

### 4.12 Server secret handling

The Android port hardcodes `SERVER_SECRET=electerm-android-local-dev-secret`
in `writeNodeEntry()` because it's a local-only app with no real auth (the
`ENABLE_AUTH` env var is unset, so the JWT middleware is skipped). We should
do the same for HarmonyOS — there's no point in having a per-build secret
when the server is only reachable from `127.0.0.1` inside the device.

**Recommendation:** drop `OHOS_SERVER_SECRET` from the build pipeline
entirely. Hardcode a constant in `build/harmony/build.mjs`'s
`writeNodeEntry()`:

```js
process.env.SERVER_SECRET = 'electerm-harmony-local-dev-secret'
process.env.ENABLE_AUTH = '0'   // explicitly disable JWT auth
```

This simplifies CI (one fewer secret) and matches the Android approach.

If you want to keep the secret for defense-in-depth (in case some future
HarmonyOS version allows other apps to reach `127.0.0.1:5577`), keep the
current `OHOS_SERVER_SECRET` flow but inject it via `child_process.spawn`'s
`env` option in `Index.ets`, read from `process.env.OHOS_SERVER_SECRET` at
runtime — do **not** bake it into the bundle.

### 4.13 Icons / splash — already handled

HarmonyOS uses `entry/src/main/resources/base/media/` for app icons and
`entry/src/main/resources/base/element/color.json` + `profile/main_pages.json`
for splash configuration. The current project already has `app_icon`,
`start_icon`, and `start_window_background` configured. No changes needed.

If you want to regenerate icons from `temp/electerm-resource/` source
artwork (like the Android `scripts/gen-assets.py` does), add a
`scripts/gen-icons.sh` that uses ImageMagick or a small Python script to
produce the required sizes. This is cosmetic and can be deferred.

### 4.14 Logging

The Android port replaces `electron-log` with a dependency-free logger that
writes to `${DB_PATH}/log/electerm.log` (see
`temp/electerm-android/src/app/common/log.js`). The electerm-web source
already has this logger built-in — we just need to make sure `DB_PATH` is
set (which it is, via the entry script). The log file ends up at
`${filesDir}/electerm-data/log/electerm.log` and can be pulled via `hdc file
recv` for debugging.

---

## 5. Native Module Handling

The Android port's approach to native modules is the **gold standard** and
should be replicated exactly:

### 5.1 Modules kept external (not in the esbuild bundle)

| Module | Why it's native | Android behavior | HarmonyOS behavior |
|---|---|---|---|
| `node-pty` | C++ binding to openvt/posix_openpt | external, guarded `import()` | **same** |
| `serialport` | C++ binding to serial device files | external, guarded `import()` | **same** |
| `node-bash` | shell binding | external, guarded `import()` | **same** |
| `font-list` | native font enumeration | external, guarded `import()` | **same** |

### 5.2 Guarded import pattern (already in electerm-web source)

The electerm-web source already uses the right pattern. From
`temp/electerm-android/src/app/server/session-local.js`:

```js
let nodePtyPromise = null
function loadNodePty () {
  if (!nodePtyPromise) {
    nodePtyPromise = import('node-pty')
      .then(m => m.default)
      .catch(err => {
        log.warn('node-pty is not available, local terminal disabled:', err.message)
        return null
      })
  }
  return nodePtyPromise
}
```

And from `temp/electerm-android/src/app/lib/serial-port.js`:

```js
export async function listSerialPorts () {
  return import('serialport')
    .then(({ SerialPort }) => SerialPort.list())
    .catch(err => {
      log.error('SerialPort not available or failed to list ports:', err)
      return []
    })
}
```

And from `temp/electerm-android/src/app/lib/font-list.js`:

```js
function loadGetFonts () {
  if (!fontsPromise) {
    fontsPromise = import('font-list')
      .then(m => m.getFonts)
      .catch(err => {
        log.warn('font-list is not available:', err.message)
        return null
      })
  }
  return fontsPromise
}
```

And the feature flag in `session-local.js`:

```js
export const terminalLocal = function (initOptions, ws) {
  if (process.env.DISABLE_LOCAL_TERMINAL) {
    return Promise.reject(new Error('Local terminal is disabled'))
  }
  return (new TerminalLocal(initOptions, ws)).init()
}
```

**No source changes are needed** for these guards — they're already in the
electerm-web codebase. The esbuild `external` array in
`build/harmony/build.mjs` just ensures the bundler doesn't try to resolve
them at build time.

### 5.3 `.node` addon files

The Android `nativeNodePlugin` esbuild plugin marks any `*.node` import as
external:

```js
const nativeNodePlugin = {
  name: 'native-node-files',
  setup (build) {
    build.onResolve({ filter: /\.node$/ }, (args) => ({
      path: args.path,
      external: true
    }))
  }
}
```

Keep this plugin in `build/harmony/build.mjs` unchanged. It handles
transitive dependencies like `ssh2 → cpu-features → cpufeatures.node` and
`ssh2 → sshcrypto.node` — these have pure-JS fallbacks guarded by try/catch
in `ssh2`'s internals.

### 5.4 Future: enabling local terminal on HarmonyOS

Once someone ports `node-pty` to HarmonyOS (build it against the OpenHarmony
NDK with `posix_openpt`), the guarded `import('node-pty')` will succeed and
the local terminal will work automatically — no source changes needed, just
remove `DISABLE_LOCAL_TERMINAL=1` from the entry script's env. Same for
`serialport` (once someone cross-compiles it for OpenHarmony).

This is the **same upgrade path** the Android port has, and it's a key
reason to keep the guarded-import pattern intact.

---

## 6. Implementation Phases

### Phase 1 — Spike: prove `child_process.spawn` works (½ day)

Goal: verify Option A from §2.1 before committing to the architecture.

1. Build the current project once with `./scripts/prepare-node.sh &&
   ./scripts/build-app.sh --debug` to get a baseline HAP.
2. Modify `Index.ets` to:
   - Extract only `rawfile/node/bin/node` to `filesDir/electerm/bin/node`.
   - `chmod 0o755` it.
   - `child_process.spawn(binPath, ['--version'])`.
   - Log stdout/stderr to hilog.
3. Install on device, check hilog for `v24.2.0`.

**Exit criteria:** hilog shows `v24.2.0`. If yes, proceed to Phase 2. If no
(EACCES/EPERM), pivot to Option B (NAPI embedding) — significantly more
work, but the rest of this document still applies once the runtime is
available.

### Phase 2 — MVP: get the backend serving HTTP (1–2 days)

Goal: a HarmonyOS app where `http://127.0.0.1:5577` returns the electerm UI
and SSH works.

1. Write `build/harmony/build.mjs` (port from
   `temp/electerm-android/build/android/build.mjs`, drop sqlite shim and
   path-to-regexp patch per §4.3).
2. Write `build/harmony/vite.harmony.mjs` (port from
   `temp/electerm-android/build/android/vite.android.mjs`, change outDir).
3. Update `scripts/prepare-web.sh` to invoke `build/harmony/build.mjs`.
4. Update `scripts/prepare-node.sh` output path to
   `rawfile/electerm/bin/`.
5. Rewrite `Index.ets` per §4.1:
   - Extract rawfile to `filesDir/electerm/`.
   - `chmod` the node binary.
   - `child_process.spawn(binPath, [entryScript], { env, cwd })`.
   - Load `loading.html` in the `Web` component.
6. Write the loading page (`build/harmony/rawfile/electerm/loading.html`).
7. Write the node entry script (`writeNodeEntry()` in `build.mjs`).
8. Build, install on device, open app, verify:
   - hilog shows "server runs on http://127.0.0.1:5577".
   - WebView navigates to the backend.
   - electerm UI renders.
   - Can create an SSH bookmark and connect.

**Exit criteria:** SSH session works end-to-end on a real device.

### Phase 3 — Polish (1–2 days)

1. Lifecycle: kill the Node child on `EntryAbility.onDestroy()` (§4.2).
2. Stable user-data dir: verify data survives app update (install v1, add
   bookmark, install v2, bookmark still present).
3. SSH keys: verify `${userDataDir}/.ssh/` is created and keys are found.
4. Logs: pull `${userDataDir}/log/electerm.log` via `hdc file recv` and
   verify it's populated.
5. Background behavior: start a long SSH session, background the app, wait
   5 minutes, foreground — session should still be alive (thanks to
   `RUNNING_LOCK`).
6. Drop `OHOS_SERVER_SECRET` from CI (§4.12) — replace with hardcoded
   constant + `ENABLE_AUTH=0`.
7. Update `docs/ARCHITECTURE.md` to remove the "HarmonyOS does not support
   spawning child processes" caveat and reflect the actual architecture.
8. Update `docs/BUILD.md` with the new rawfile layout and the
   `build/harmony/build.mjs` step.

**Exit criteria:** all of the above pass on a real device; docs match
reality.

### Phase 4 — Feature parity with Android (ongoing)

These features work once Phase 2 is done because they're pure JS/WASM, but
they need end-to-end testing on HarmonyOS:

- [ ] SSH (password + public key auth)
- [ ] SSH tunnel / proxy
- [ ] SFTP file transfer
- [ ] FTP / FTPS
- [ ] Telnet
- [ ] RDP (via `ironrdp-wasm`)
- [ ] VNC (via `@novnc/novnc`)
- [ ] Spice (via `spice-client`)
- [ ] Zmodem (rz/sz)
- [ ] trzsz (trz/tsz)
- [ ] Bookmarks / bookmark groups
- [ ] Terminal themes
- [ ] Quick commands
- [ ] Settings sync (GitHub gist / Gitee / WebDAV / electerm cloud)
- [ ] AI assistant (DeepSeek / OpenAI-compatible)
- [ ] Multi-language UI

### Phase 5 — Local terminal & serial port (future, blocked on native ports)

Track upstream ports of `node-pty` and `serialport` to OpenHarmony. When
available:

1. Cross-compile the `.node` files for `arm64-linux-ohos`.
2. Bundle them into `rawfile/electerm/native/`.
3. Add an esbuild alias so `import('node-pty')` resolves to the bundled
   path.
4. Remove `DISABLE_LOCAL_TERMINAL=1` from the entry script.

No source changes in electerm-web are needed — the guarded imports already
handle the "module present" case.

---

## 7. File Manifest

### New files to create

| Path | Purpose |
|---|---|
| `build/harmony/build.mjs` | Port of `temp/electerm-android/build/android/build.mjs` — produces the rawfile bundle |
| `build/harmony/vite.harmony.mjs` | Port of `temp/electerm-android/build/android/vite.android.mjs` — Vite config for frontend |
| `build/harmony/rawfile/electerm/loading.html` | Loading page (generated by `build.mjs`) |
| `build/harmony/rawfile/electerm/index.js` | Node entry script (generated by `build.mjs`) |
| `build/harmony/rawfile/electerm/package.json` | Node project manifest (generated by `build.mjs`) |
| `build/harmony/rawfile/electerm/app.bundle.mjs` | esbuild backend bundle (generated by `build.mjs`) |
| `build/harmony/rawfile/electerm/.env` | Optional runtime env (generated by `build.mjs`) |

### Existing files to modify

| Path | Change |
|---|---|
| `entry/src/main/ets/pages/Index.ets` | Replace static-HTML loading with `child_process.spawn` + loading page redirect (§4.1) |
| `entry/src/main/ets/entryability/EntryAbility.ets` | Add child process lifecycle management (§4.2) |
| `scripts/prepare-web.sh` | Replace inline build logic with `node build/harmony/build.mjs` invocation (§4.6) |
| `scripts/prepare-node.sh` | Change output path to `rawfile/electerm/bin/` (§4.7) |
| `scripts/gen-manifest.sh` | No logic change, just verify new paths work (§4.8) |
| `docs/ARCHITECTURE.md` | Update to reflect actual architecture, remove "no child_process" caveat |
| `docs/BUILD.md` | Update rawfile layout and build steps |
| `.github/workflows/build.yml` | Minor: drop `OHOS_SERVER_SECRET` if adopting §4.12 (optional) |

### Files explicitly NOT changed

- `AppScope/app.json5` — version is bumped by `build-app.sh`.
- `entry/src/main/module.json5` — permissions already correct.
- `entry/build-profile.json5` — generated by `build-app.sh`.
- `entry/oh-package.json5` — no native ArkTS dependencies needed.
- `scripts/build-app.sh` — signing pipeline unchanged.
- `signing/*` — unchanged.

---

## 8. Risk Register

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| HarmonyOS sandbox disallows executing extracted binaries (`exec-space` protection) | Medium | Critical (blocks Option A) | Phase 1 spike validates before committing. Fallback: NAPI-embedded libnode (Option B). |
| `child_process.spawn` API has restrictions on env or cwd in release builds | Low | High | Test in release build early. Workaround: pass config via a temp file the entry script reads. |
| ArkWeb blocks `http://127.0.0.1` from a `file://` origin despite `MixedMode.All` | Low | High | Use the loading page's `location.replace` fallback (top-level navigation is exempt from CORS). Alternative: load the backend URL directly via ArkTS-side polling. |
| `ohos-node` binary is too large (~129 MB) for AppGallery | Medium | Medium | Strip debug symbols (`strip` command) to reduce to ~50 MB. AppGallery allows up to 4 GB per HAP. |
| App update wipes `${filesDir}/electerm/` (re-extracts from rawfile) and loses the node binary | Low | Low | Expected behavior — the binary is re-extracted on next launch. User **data** lives in the sibling `electerm-data/` dir which is not touched. |
| `RUNNING_LOCK` doesn't prevent the OS from killing the Node child in low-memory conditions | Medium | Medium | Graceful: the loading page will re-trigger if the WebView polls and fails. Add a "restart engine" button in the ArkTS shell. |
| `express-ws` WebSocket upgrade fails in HarmonyOS network stack | Low | High | Test early. Fallback: use `@ohos.net.websocket` on the ArkTS side to proxy. Unlikely to be needed — `express-ws` uses standard Node `http.Server#upgrade`. |
| esbuild can't bundle some electerm-web dependency due to dynamic require | Low | Medium | The Android port already solved this (see the `banner.js` defining `require`/`__dirname`). Reuse the same banner. |

---

## 9. Testing Strategy

### 9.1 Manual smoke test (per release)

1. Install the signed `.app` on a real HarmonyOS device (phone or tablet).
2. Open the app — should show "Starting engine…" for 1–3 seconds, then the
   electerm UI.
3. Add an SSH bookmark (use a public test server like
   `test.rebex.net:22`, user `demo`, password `password`).
4. Connect — terminal should render, `ls` should work.
5. Open the SFTP tab — file listing should render, upload a small file.
6. Disconnect, kill the app, reopen — bookmark should persist (proves
   SQLite + user-data dir work).
7. Background the app during an SSH session, wait 2 minutes, foreground —
   session should still be alive (proves `RUNNING_LOCK` works).
8. Check `hdc file recv /data/app/.../files/electerm-data/log/electerm.log`
   — should contain startup logs.

### 9.2 Automated (future)

- Port the electerm-web Playwright e2e tests to run against the device's
  `http://127.0.0.1:5577` via `hdc fport tcp:5577 tcp:5577` (port forward).
- Run them in CI after the HAP is built and installed on an emulator.

---

## 10. Appendix A: Android `build.mjs` → HarmonyOS `build.mjs` diff

Below is a conceptual diff showing what changes when porting
`temp/electerm-android/build/android/build.mjs` to
`build/harmony/build.mjs`. Items marked `−` are removed, `+` are added,
unchanged lines are elided with `...`.

```diff
 const WWW = path.resolve(__dirname, 'www')
-const NODEJS_DIR = path.resolve(WWW, 'nodejs')
+const NODEJS_DIR = path.resolve(WWW, 'electerm')  // rawfile/electerm/

 ...

 async function genSqliteShim () {
-  // sql.js shim for Node 18 ...
-  return shimPath
+  // Node 24 has built-in node:sqlite — no shim needed.
+  return null
 }

 async function bundleBackend (shimPath) {
   await esbuild.build({
     entryPoints: [path.resolve(ROOT, 'src/app/app.js')],
     bundle: true,
     format: 'esm',
     platform: 'node',
-    target: 'node18',
+    target: 'node24',
     outfile: path.resolve(NODEJS_DIR, 'app.bundle.mjs'),
-    alias: {
-      'node:sqlite': shimPath
-    },
+    // No alias — use built-in node:sqlite
     external: [
       'node-pty',
       'serialport',
       'node-bash',
       'font-list'
     ],
     banner: { js: "..." },  // unchanged
-    plugins: [nativeNodePlugin, patchPathToRegexpPlugin],
+    plugins: [nativeNodePlugin],  // drop path-to-regexp patch (Node 24 has full ICU)
     logLevel: 'info'
   })
 }

 function writeNodeEntry () {
   const entry = `...
 process.env.HOST = '127.0.0.1'
 process.env.PORT = '5577'
-process.env.SERVER_SECRET = 'electerm-android-local-dev-secret'
+process.env.SERVER_SECRET = 'electerm-harmony-local-dev-secret'
+process.env.ENABLE_AUTH = '0'
 process.env.DISABLE_LOCAL_TERMINAL = '1'
 ...
 await import('./app.bundle.mjs')`
   fs.writeFileSync(path.resolve(NODEJS_DIR, 'index.js'), entry)
   ...
 }
```

The `writeLoadingPage()`, `copyFrontendAssets()`, `copyEnv()`, and
`applyResOverlay()` (the latter is Android-specific and not needed on
HarmonyOS) functions are either unchanged or trivially adjusted for the new
output path.

---

## 11. Appendix B: Reference: Android port file map

For quick cross-referencing during implementation:

| Android file | HarmonyOS equivalent | Notes |
|---|---|---|
| `build/android/build.mjs` | `build/harmony/build.mjs` | Port per §4.3 and Appendix A |
| `build/android/vite.android.mjs` | `build/harmony/vite.harmony.mjs` | Change `outDir` only |
| `build/android/capacitor.config.ts` | n/a | Capacitor is Android-only; ArkUI replaces it |
| `build/android/package.json` | n/a | No Capacitor deps on HarmonyOS |
| `build/android/res-overlay/` | `entry/src/main/resources/base/media/` + `element/` | HarmonyOS uses standard resource dirs |
| `build/android/res-overlay/xml/network_security_config.xml` | n/a | `MixedMode.All` on `Web` component suffices |
| `build/android/res-overlay/AndroidManifest.xml` | `entry/src/main/module.json5` | Already configured |
| `build/android/scripts/gen-assets.py` | (optional) `scripts/gen-icons.sh` | Deferred — icons already exist |
| `src/app/app.js` | (unchanged electerm-web source) | Bundled by esbuild |
| `src/app/common/log.js` | (unchanged) | Already dependency-free |
| `src/app/lib/sqlite.js` | (unchanged) | Uses built-in `node:sqlite` (Node 24) |
| `src/app/server/session-local.js` | (unchanged) | Guarded `import('node-pty')` |
| `src/app/lib/serial-port.js` | (unchanged) | Guarded `import('serialport')` |
| `src/app/lib/font-list.js` | (unchanged) | Guarded `import('font-list')` |
| `.github/workflows/build-android.yml` | `.github/workflows/build.yml` | Already exists, minor tweaks |

---

## 12. Next Actions

1. **Run the Phase 1 spike** (§6.1) to confirm `child_process.spawn` works
   on HarmonyOS 5.0 with the `ohos-node` binary. This is the only
   make-or-break unknown.
2. If the spike succeeds, implement Phase 2 (§6.2) — port `build.mjs`,
   rewrite `Index.ets`, write the loading page and node entry script.
3. If the spike fails, pivot to Option B (NAPI-embedded libnode) —
   significantly more work but the rest of this document still applies.

This document is the design. Implementation should reference it for every
decision.
