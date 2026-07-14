# electerm-harmony

<h1 align="center" style="padding-top: 60px;padding-bottom: 40px;">
    <a href="https://electerm.org">
        <img src="https://github.com/electerm/electerm-resource/raw/master/static/images/electerm.png", alt="" />
    </a>
</h1>

[![GitHub version](https://badgers.space/github/release/electerm/electerm?corner_radius=m)](https://github.com/electerm/electerm/releases)
[![Build Status](https://github.com/electerm/electerm/actions/workflows/mac-test-1.yml/badge.svg)](https://github.com/electerm/electerm/actions)
[![license](https://img.shields.io/badge/license-MIT-blue.svg)](https://github.com/electerm/electerm/blob/master/LICENSE)
[![Get it from the Snap Store](https://img.shields.io/badge/Snap-Store-green)](https://snapcraft.io/electerm)
[![Get it from the Microsoft Store](https://img.shields.io/badge/Microsoft-Store-blue)](https://www.microsoft.com/store/apps/9NCN7272GTFF)
[![GitHub Sponsors](https://img.shields.io/github/sponsors/electerm?label=Sponsors)](https://github.com/sponsors/electerm)
[![star](https://atomgit.com/electerm/electerm/star/badge.svg)](https://atomgit.com/electerm/electerm)



- [electerm.org](https://electerm.org): Homepage, downloads, videos, etc
- [electerm-web](https://github.com/electerm/electerm-web): Web app version running in browser(including mobile device)
- [electerm-web-docker](https://github.com/electerm/electerm-web-docker): Docker image for electerm-web
- [electerm online](https://cloud.electerm.org): Public free online electerm app
- [electerm demo](https://demo.electerm.org): Online demo of electerm
- [electerm AI](https://ai.electerm.org): Free AI for electerm users
- [electerm deb repo](https://repos.electerm.org/deb): Debian repo of electerm
- [electerm rpm repo](https://repos.electerm.org/rpm): RPM repo of electerm

---

**electerm** is a free and open-sourced terminal/ssh/sftp/telnet/serialport/RDP/VNC/Spice/ftp client (linux, mac, win, HarmonyOS).

This project brings electerm to **HarmonyOS** by bundling [electerm-web](https://github.com/electerm/electerm-web) with [ohos-node](https://github.com/hqzing/ohos-node) (Node.js for OpenHarmony), rendered via the native ArkWeb component.

---

## Features

- Terminal/ssh/sftp/telnet/serialport/RDP/VNC/Spice/ftp client
- Works as a file manager or ssh/sftp/telnet/serialport/RDP/VNC/Spice/ftp client
- Multi-platform: Linux, macOS, Windows, and now **HarmonyOS**
- Multi-language support
- Double click to directly edit remote files
- Auth with publicKey + password
- Support Zmodem(rz/sz)
- Support ssh tunnel
- Support trzsz (trz/tsz), similar to rz/sz, and compatible with tmux
- Transparent window(Mac, win)
- Terminal background image
- Global/session proxy
- Quick commands
- UI/terminal theme
- Sync bookmarks/themes/quick commands to github/gitee secret gist
- Quick input to one or all terminals
- Init from URL query string
- Support mobile device(responsive design)

---

## Architecture

```
┌─────────────── HarmonyOS App ───────────────┐
│                                              │
│  ┌─────────────┐    ┌──────────────────────┐ │
│  │  ArkUI Shell │    │  electerm-web (Node) │ │
│  │             │    │                      │ │
│  │  Web View   │◄──►│  Express server      │ │
│  │  (ArkWeb)   │    │  on 127.0.0.1:5577   │ │
│  │             │    │  ssh/sftp/telnet/etc. │ │
│  └─────────────┘    └──────────────────────┘ │
│                                              │
└──────────────────────────────────────────────┘
```

See [`build/ARCHITECTURE.md`](build/ARCHITECTURE.md) for full details.

---

## Quick Start

### Prerequisites

- **HarmonyOS developer account** at <https://developer.huawei.com/>
- **GitHub repo** with Actions enabled
- **Signing materials** (`.p12`, `.cer`, `.p7b`) — see [`build/ENV_SETUP.md`](build/ENV_SETUP.md)

### CI Build (Recommended)

1. **Configure GitHub Secrets** — see [`build/ENV_SETUP.md`](build/ENV_SETUP.md):

   | Secret | Description |
   |--------|-------------|
   | `OHOS_KEYSTORE_B64` | Base64-encoded `.p12` keystore |
   | `OHOS_CERT_B64` | Base64-encoded `.cer` certificate |
   | `OHOS_PROFILE_B64` | Base64-encoded `.p7b` profile |
   | `OHOS_KEYSTORE_PASSWORD` | Keystore password |
   | `OHOS_KEY_PASSWORD` | Key password |
   | `OHOS_KEY_ALIAS` | Key alias (e.g. `electerm_key`) |
   | `OHOS_BUNDLE_NAME` | `org.electerm.electerm` |
   | `OHOS_APP_ID` | From AppGallery Connect |
   | `OHOS_CMDLINE_TOOLS_URL` | HarmonyOS Command Line Tools download URL |

2. **Push to `main`** or **create a `v*` tag** to trigger the workflow

3. **Download the `.hap`** from the Actions artifacts or Releases page

### Local Build

```bash
# 1. Download ohos-node
./scripts/prepare-node.sh

# 2. Build electerm-web
./scripts/prepare-web.sh

# 3. Build & sign the HAP
./scripts/build-app.sh --release
```

See [`build/BUILD.md`](build/BUILD.md) for detailed instructions.

---

## Project Structure

```
electerm-harmony/
├── .github/workflows/
│   └── build.yml              # CI/CD workflow (GitHub Actions)
├── build/
│   ├── ARCHITECTURE.md        # Architecture overview
│   ├── BUILD.md               # Step-by-step build guide
│   └── ENV_SETUP.md           # Environment & signing setup guide
├── scripts/
│   ├── prepare-node.sh        # Download ohos-node prebuilt binary
│   ├── prepare-web.sh         # Clone & build electerm-web
│   ├── build-app.sh           # Build & sign HarmonyOS HAP
│   └── gen-secrets.sh         # Generate GitHub Secrets values
├── entry/                     # HarmonyOS app module
│   └── src/main/
│       ├── ets/               # ArkTS source
│       │   ├── entryability/EntryAbility.ets
│       │   └── pages/Index.ets  # Web component page (ArkWeb)
│       ├── resources/
│       │   └── rawfile/       # Bundled node + electerm-web (generated)
│       └── module.json5
├── AppScope/app.json5        # App-level config (version, bundle name)
├── build-profile.json5        # Build & signing config (generated)
├── oh-package.json5          # HarmonyOS package manifest
└── README.md
```

---

## Key Components

| Component | Source | Role |
|-----------|--------|------|
| [ohos-node](https://github.com/hqzing/ohos-node) | `hqzing/ohos-node` | Node.js runtime for OpenHarmony ARM64 |
| [electerm-web](https://github.com/electerm/electerm-web) | `electerm/electerm-web` | Free and open-sourced terminal/ssh/sftp/telnet/serialport/RDP/VNC/Spice/ftp web app server |
| ArkWeb | HarmonyOS SDK | Built-in WebView engine for rendering |

---

## Documentation

| Document | Content |
|----------|---------|
| [build/ARCHITECTURE.md](build/ARCHITECTURE.md) | System architecture, runtime flow, design decisions |
| [build/BUILD.md](build/BUILD.md) | Local and CI build instructions, troubleshooting |
| [build/ENV_SETUP.md](build/ENV_SETUP.md) | Huawei Developer account, certificates, GitHub Secrets |

---

## Sponsors

[GitHub Sponsors](https://github.com/sponsors/electerm)

## License

MIT — same as [electerm](https://github.com/electerm/electerm)
