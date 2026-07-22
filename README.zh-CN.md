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


> 语言 / Language: [English](README.md) | **简体中文**

---

- [electerm.org](https://electerm.org)：官网，下载，视频等
- [electerm-web](https://github.com/electerm/electerm-web)：浏览器端 Web 应用版本（含移动设备）
- [electerm-web-docker](https://github.com/electerm/electerm-web-docker)：electerm-web 的 Docker 镜像
- [electerm 在线版](https://cloud.electerm.org)：免费公共在线 electerm 应用
- [electerm 演示](https://demo.electerm.org)：electerm 在线演示
- [electerm AI](https://ai.electerm.org)：electerm 用户免费 AI
- [electerm Android](https://github.com/electerm/electerm-android)：electerm 安卓版
- [electerm deb 仓库](https://repos.electerm.org/deb)：electerm Debian 仓库
- [electerm rpm 仓库](https://repos.electerm.org/rpm)：electerm RPM 仓库

---

**electerm** 是一个免费开源的 ssh/sftp/telnet/RDP/VNC/Spice/ftp 客户端（支持 Linux、Mac、Windows、HarmonyOS、Android）。

本项目使用 [Electron 鸿蒙运行时](https://gitcode.com/openharmony-sig/electron)（Chromium + Node.js）将 electerm 移植到 **HarmonyOS** 平台。

---

## 当前状态

本项目正在**开发中**。当前目标是让 electerm 以 Web 应用形式在 HarmonyOS 上运行 —— 成功构建并运行。发布到 HarmonyOS 应用市场可能需要数月时间（需要软件著作权证书及其他合规步骤）。

## 待办事项

- [x] 基础项目结构与 Electron 鸿蒙运行时集成
- [x] 构建流程（CI + 本地）自动下载预构建运行时压缩包
- [x] 使用 web_engine HAR 模块的 ArkTS 层（WebAbility、WebWindow）
- [x] **成功在 HarmonyOS 上构建并运行应用**
- [x] 在 Electron 鸿蒙运行时中测试 electerm-web 前端 + 后端
- [ ] 修复运行时问题（API 兼容性、文件路径、权限）
- [ ] 添加更多 Electron 特定功能（或评估使用 electerm 原始 Electron 代码）
- [ ] 获取软件著作权登记证书 —— 应用市场上架必需
- [ ] 发布到 HarmonyOS 应用市场

## 文档

| 文档 | 内容 |
|------|------|
| [docs/BUILD.md](docs/BUILD.md) | 构建说明（本地 + CI）、故障排查 |
| [docs/ENV_SETUP.md](docs/ENV_SETUP.md) | 华为开发者账号、证书、GitHub Secrets 配置 |
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | 架构概览与设计决策 |

## 所有 README

| README | 语言 |
|--------|------|
| [README.md](README.md) | English |
| [README.zh-CN.md](README.zh-CN.md) | 简体中文 |

## 赞助

[GitHub Sponsors](https://github.com/sponsors/electerm)

## 开源协议

MIT —— 与 [electerm](https://github.com/electerm/electerm) 相同
