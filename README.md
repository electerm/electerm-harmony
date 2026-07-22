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
- [electerm Android](https://github.com/electerm/electerm-android): electerm for Android
- [electerm deb repo](https://repos.electerm.org/deb): Debian repo of electerm
- [electerm rpm repo](https://repos.electerm.org/rpm): RPM repo of electerm

---

**electerm** is a free and open-sourced ssh/sftp/telnet/RDP/VNC/Spice/ftp client (linux, mac, win, HarmonyOS, Android).

This project brings electerm to **HarmonyOS** using the [Electron Harmony OS runtime](https://gitcode.com/openharmony-sig/electron) (Chromium + Node.js).

---

## Current Status

This project is a **work in progress**. The current goal is to make electerm work as a web app on HarmonyOS — building and running successfully. Publishing to the HarmonyOS AppGallery may take months (requires software copyright certificate and other compliance steps).

## TODO

- [x] Basic project structure with Electron Harmony OS runtime integration
- [x] Build pipeline (CI + local) that downloads pre-built runtime tarball
- [x] ArkTS layer using web_engine HAR module (WebAbility, WebWindow)
- [ ] **Get the app to build and run successfully on HarmonyOS**
- [ ] Test electerm-web frontend + backend in the Electron Harmony OS runtime
- [ ] Fix any runtime issues (API compatibility, file paths, permissions)
- [ ] Add more Electron-specific features (or evaluate using electerm's original Electron code)
- [ ] Obtain software copyright certificate (软件著作权登记) — required for AppGallery publishing
- [ ] Publish to HarmonyOS AppGallery

## Documentation

| Document | Content |
|----------|---------|
| [docs/BUILD.md](docs/BUILD.md) | Build instructions (local + CI), troubleshooting |
| [docs/ENV_SETUP.md](docs/ENV_SETUP.md) | Huawei Developer account, certificates, GitHub Secrets |
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | Architecture overview and design decisions |

## Sponsors

[GitHub Sponsors](https://github.com/sponsors/electerm)

## License

MIT — same as [electerm](https://github.com/electerm/electerm)
