# Architecture — electerm-harmony

> Building [electerm](https://github.com/electerm/electerm) for HarmonyOS (OpenHarmony)

---

## 1. High-level Overview

```
┌─────────────────────────────────────────────────────┐
│                  HarmonyOS Device                    │
│                                                      │
│  ┌──────────────────┐    ┌────────────────────────┐ │
│  │   Native Shell    │    │   electerm-web (Node)  │ │
│  │   (ArkUI / ETS)   │    │                        │ │
│  │                   │    │  ohos-node runtime     │ │
│  │  ┌─────────────┐  │    │  (Node.js 24 ARM64)    │ │
│  │  │   Web       │──┼────│                        │ │
│  │  │  Component  │  │    │  Express server        │ │
│  │  │ (ArkWeb)    │  │    │  on 127.0.0.1:5577     │ │
│  │  └─────────────┘  │    │                        │ │
│  │                   │    │  ssh/sftp/telnet engine  │ │
│  │  process.start()  │    │  (node-pty, ssh2, ...)  │ │
│  └────────┬──────────┘    └───────────┬────────────┘ │
│           │                            │              │
│           │       localhost HTTP       │              │
│           └────────────────────────────┘              │
│                                                      │
└─────────────────────────────────────────────────────┘
```

The app consists of **two layers** running on the same device:

| Layer | Technology | Role |
|-------|-----------|------|
| **Native Shell** | HarmonyOS ArkUI (ArkTS / ETS) | Creates a full-screen window, launches the Node.js backend, then renders the web UI via the `Web` component (ArkWeb) |
| **Backend** | `ohos-node` + `electerm-web` | Node.js server providing the terminal/ssh/sftp/telnet/serialport/RDP/VNC/Spice/ftp functionality and serving the web UI over localhost |

---

## 2. Component Breakdown

### 2.1 ohos-node (`hqzing/ohos-node`)

- **Repo**: <https://github.com/hqzing/ohos-node>
- **Purpose**: Pre-compiled Node.js binary for OpenHarmony ARM64
- **Latest release**: `v24.2.0` — `node-v24.2.0-openharmony-arm64.tar.gz`
- **How it works**: Cross-compiles Node.js using the OpenHarmony SDK + LLVM-19 toolchain on a Linux x64 host, then signs the resulting binary with the OpenHarmony binary-sign-tool
- **In this project**: The prebuilt `node` binary is bundled into the HarmonyOS app's `rawfile` resources and extracted to the app's sandbox at runtime

### 2.2 electerm-web (`electerm/electerm-web`)

- **Repo**: <https://github.com/electerm/electerm-web>
- **Purpose**: Web-app version of electerm — a free and open-sourced terminal/ssh/sftp/telnet/serialport/RDP/VNC/Spice/ftp client (linux, mac, win, HarmonyOS)
- **Node.js requirement**: `>= 24.0.0` (matches ohos-node v24.x)
- **Build output**: After `npm run build`, produces a server bundle in `build/vite/` and static assets
- **Runtime**: `NODE_ENV=production node ./src/app/app.js` starts an Express server (default `127.0.0.1:5577`)
- **In this project**: The built electerm-web code is bundled alongside the ohos-node binary and launched at app start

### 2.3 Native Shell (HarmonyOS ArkUI App)

- **Language**: ArkTS (TypeScript superset for HarmonyOS)
- **UI Framework**: ArkUI declarative UI
- **Web rendering**: `Web` component from `@kit.ArkWeb` — HarmonyOS's built-in WebView engine (chromium-based, called **ArkWeb**)
- **Process management**: Uses `@ohos.child_process` or `@ohos.process` to spawn the Node.js backend
- **Lifecycle**: 
  1. App `onCreate` → extract bundled `node` binary + electerm-web files to sandbox
  2. Start the Node.js server as a child process
  3. Poll `http://127.0.0.1:5577` until the server responds
  4. Load the URL in the `Web` component
  5. On `onDestroy` → kill the child process

### 2.4 HarmonyOS App Package Structure

```
entry/                              # Main ability module
└── src/
    └── main/
        ├── ets/                    # ArkTS source code
        │   ├── entryability/
        │   │   └── EntryAbility.ets
        │   └── pages/
        │       └── Index.ets       # Web component page
        ├── resources/
        │   └── rawfile/            # Bundled assets
        │       ├── node/           # ohos-node binary (extracted at runtime)
        │       └── electerm-web/   # Built electerm-web server code
        └── module.json5            # Module config
```

---

## 3. Build Pipeline (CI/CD)

```
GitHub Actions (ubuntu-latest, x64)
│
├── 1. Checkout code
├── 2. Setup Node.js 24 (for building electerm-web)
├── 3. Setup JDK 21 (for hap-sign-tool.jar signing)
├── 4. Install system dependencies (build-essential, etc.)
├── 5. Download ohos-node prebuilt binary
│      └── from hqzing/ohos-node releases → rawfile/node/
├── 6. Clone & build electerm-web
│      ├── git clone electerm/electerm-web
│      ├── npm ci
│      ├── npm run build
│      └── Copy to rawfile/electerm-web/
├── 7. Download & extract HarmonyOS Command Line Tools (Linux, ~2 GB)
│      ├── Configure ohpm + hvigorw + SDK
│      └── Configure ohpm registry mirror
├── 8. Decode signing materials from GitHub Secrets
│      ├── OHOS_KEYSTORE_B64 → signing/electerm.p12
│      ├── OHOS_CERT_B64     → signing/electerm_publish.cer
│      └── OHOS_PROFILE_B64  → signing/electermRelease.p7b
├── 9. Configure bundle name (from OHOS_BUNDLE_NAME secret → app.json5)
├── 10. Build unsigned APP (two-phase signing, phase 1)
│       ├── Generate build-profile.json5 (empty signingConfigs)
│       ├── ohpm install
│       └── hvigorw assembleApp -p enableSignTask=false
├── 11. Sign APP with hap-sign-tool.jar (two-phase signing, phase 2)
│       └── java -jar hap-sign-tool.jar sign-app -mode localSign ...
└── 12. Upload .app artifact (retained 30 days)
```

### Two-Phase Signing

This project does **not** use hvigor's built-in signer (which requires DevEco Studio's encrypted passwords). Instead:

1. **Build unsigned** — `hvigorw assembleApp` with `-p enableSignTask=false` and empty `signingConfigs`
2. **Sign separately** — `hap-sign-tool.jar` with plaintext passwords from GitHub Secrets

See [`BUILD.md §5`](./BUILD.md#5-how-signing-works) for details.

---

## 4. Runtime Flow

```
User taps app icon
        │
        ▼
EntryAbility.onCreate()
        │
        ├── Extract rawfile/node → sandbox/elcterm/bin/node
        ├── Extract rawfile/electerm-web → sandbox/elcterm/web/
        │
        ├── child_process.spawn('node', ['src/app/app.js'], {
        │     env: { NODE_ENV: 'production', HOST: '127.0.0.1', PORT: '5577' }
        │   })
        │
        ├── Wait for http://127.0.0.1:5577 to respond (poll)
        │
        └── Web component loads http://127.0.0.1:5577
                    │
                    ▼
            electerm-web UI renders
            User can ssh/sftp/telnet/etc.
```

---

## 5. Key Design Decisions

| Decision | Rationale |
|----------|-----------|
| Use prebuilt `ohos-node` instead of building from source | Building Node.js for OpenHarmony takes ~30 min on CI; prebuilt releases are available and signed |
| Bundle everything into `rawfile` | HarmonyOS `rawfile` resources are accessible at runtime and can be copied to the app sandbox |
| Use `Web` component (ArkWeb) instead of custom renderer | electerm-web is already a web app; ArkWeb provides a full chromium engine |
| Run Node.js as child process (not embedded) | Keeps the native shell simple; Node.js runs independently with its own event loop |
| Localhost HTTP only | No need for HTTPS — traffic never leaves the device; `127.0.0.1` is used for both server and WebView |

---

## 6. References

- [ohos-node](https://github.com/hqzing/ohos-node) — Node.js for OpenHarmony
- [electerm-web](https://github.com/electerm/electerm-web) — Web version of electerm
- [HarmonyOS Web Component (ArkWeb)](https://developer.huawei.com/consumer/cn/doc/harmonyos-references/ts-basic-components-web-V14) — `Web` component docs
- [HarmonyOS Command Line Tools](https://developer.huawei.com/consumer/cn/download/) — SDK & build tools
- [Huawei Developer Console](https://developer.huawei.com/) — App management & certificates
