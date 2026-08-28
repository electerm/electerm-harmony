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

> Language: **English** | [简体中文](README.zh-CN.md)

- [electerm.org](https://electerm.org): Homepage, downloads, videos, etc
- [electerm-web](https://github.com/electerm/electerm-web): Web app version running in browser(including mobile device)
- [electerm-web-docker](https://github.com/electerm/electerm-web-docker): Docker image for electerm-web
- [electerm online](https://cloud.electerm.org): Public free online electerm app
- [electerm demo](https://demo.electerm.org): Online demo of electerm
- [electerm AI](https://ai.electerm.org): Free AI for electerm users
- [electerm theme](https://theme.electerm.org): Create/share theme site with live preview and AI creation
- [electerm Android](https://github.com/electerm/electerm-android): electerm for Android
- [electerm iOS](https://github.com/electerm/electerm-ios): electerm for iOS
- [electerm deb repo](https://repos.electerm.org/deb): Debian repo of electerm
- [electerm rpm repo](https://repos.electerm.org/rpm): RPM repo of electerm

---

**electerm** is a free and open-sourced ssh/sftp/telnet/RDP/VNC/Spice/ftp client (linux, mac, win, HarmonyOS, Android, iOS).

This project brings electerm to **HarmonyOS** using the [Electron Harmony OS runtime](https://gitcode.com/openharmony-sig/electron) (Chromium + Node.js).

> **`dev2` branch — web variant (experimental).** A second build path with no
> electron runtime at all, modelled on [electerm-android](https://github.com/electerm/electerm-android):
> the UI is an **ArkWeb** `Web` component and the electerm-web backend runs as
> an on-device **Node.js** process ([hqzing/ohos-node](https://github.com/hqzing/ohos-node)
> binary, started via `childProcessManager.startNativeChildProcess`).
> CI: `.github/workflows/build-web.yml` (push to `dev2`).
>
> ```
> ArkWeb (frontend) ── http://127.0.0.1:5577 ──► Node.js backend (native child process)
>    loads loading page                          serves UI + SSH/SFTP/telnet/ftp/RDP/VNC/Spice
> ```
>
> The electerm app (frontend + backend bundle) is packaged in the HAP `resfile`
> and read directly by the node process; the node binary is packaged as
> `libs/arm64-v8a/libnode.so`. On-device boot diagnostics land in
> `<filesDir>/electerm-data/node-boot.log`.

---

[Huawei AppGallery](https://appgallery.huawei.com/app/detail?id=org.electerm.electerm) · [Apple App Store](https://apps.apple.com/cn/app/electerm/id6792971552)

## License

MIT — same as [electerm](https://github.com/electerm/electerm)
