# Listenary

<p align="center">
  <img src="app_icon.png" width="80" height="80" alt="Listenary Logo">
</p>

<p align="center">
  面向 Windows、以本地曲库为核心的音乐播放器
</p>

<p align="center">
  <img src="https://img.shields.io/badge/Platform-Windows-blue?style=flat-square" alt="Platform">
  <img src="https://img.shields.io/badge/Version-3.0.0-blue?style=flat-square" alt="Version 3.0.0">
  <img src="https://img.shields.io/badge/License-GPL--3.0-green?style=flat-square" alt="License GPL-3.0">
</p>

Listenary 管理和播放本地音乐，也提供可选的在线搜索、在线播放、订阅歌单、在线历史与远程歌词能力。在线功能依赖网络、第三方平台和用户自行配置的服务凭据；不使用这些功能时，本地曲库与本地播放仍可独立工作。

## 功能

- 本地曲库：歌曲、艺术家、专辑、文件夹、歌单、全局搜索与播放统计
- 在线音乐：搜索、在线播放、订阅歌单、在线历史，以及独立的远程播放队列
- 歌词：YRC、QRC、KRC、TTML、LRC，本地、内嵌与多个在线来源，支持原文、翻译和罗马音
- 音频：BASS 播放、10 段 EQ、音调与速度、ReplayGain、WASAPI 独占
- 界面：Material 3、封面取色、流动渐变与流光背景、竖屏/横屏/沉浸布局
- 系统集成：SMTC、全局快捷键、单实例、窗口状态记忆和桌面歌词

当前版本不承诺远程 seek、个人在线歌单、在线队列排序/播放模式或音质选择等尚未完成或仍待确认的能力。

## 截图

**深色模式**

<img src="screenshot/深色主页.png" width="380" alt="深色主页">
<img src="screenshot/深色播放页.png" width="380" alt="深色播放页">
<img src="screenshot/深色专辑页.png" width="380" alt="深色专辑页">
<img src="screenshot/深色沉浸模式.png" width="380" alt="深色沉浸模式">

<img src="screenshot/深色竖屏.png" width="180" alt="深色竖屏">
<img src="screenshot/深色竖屏歌词.png" width="180" alt="深色竖屏歌词">
<img src="screenshot/深色竖屏沉浸模式.png" width="180" alt="深色竖屏沉浸模式">

**浅色模式**

<img src="screenshot/浅色主页.png" width="380" alt="浅色主页">
<img src="screenshot/浅色播放页.png" width="380" alt="浅色播放页">
<img src="screenshot/浅色专辑页.png" width="380" alt="浅色专辑页">
<img src="screenshot/浅色沉浸模式.png" width="380" alt="浅色沉浸模式">

<img src="screenshot/浅色竖屏.png" width="180" alt="浅色竖屏">
<img src="screenshot/浅色竖屏歌词.png" width="180" alt="浅色竖屏歌词">
<img src="screenshot/浅色竖屏沉浸模式.png" width="180" alt="浅色竖屏沉浸模式">

**曲库、桌面歌词与系统集成**

<img src="screenshot/歌单页.png" width="330" alt="歌单页">
<img src="screenshot/文件夹页.png" width="330" alt="文件夹页">
<img src="screenshot/统计页.png" width="330" alt="统计页">
<img src="screenshot/左对齐主题色歌词.png" width="330" alt="左对齐桌面歌词">
<img src="screenshot/居中主题色歌词信息歌词.png" width="330" alt="居中桌面歌词">
<img src="screenshot/右对齐主题色歌词.png" width="330" alt="右对齐桌面歌词">
<img src="screenshot/SMTC.png" width="380" alt="Windows SMTC">
<img src="screenshot/内嵌数据编辑.png" width="330" alt="歌曲信息编辑">

## 下载与支持

- [GitHub Releases](https://github.com/HuiZhou12/Listenary/releases)
- [源码仓库](https://github.com/HuiZhou12/Listenary)
- [问题反馈](https://github.com/HuiZhou12/Listenary/issues)
- [Discussions](https://github.com/HuiZhou12/Listenary/discussions)
- [用户与开发文档](page/docs/)

Listenary 支持 Windows 10 和 Windows 11，提供安装版与便携版。新安装默认位于 `%LOCALAPPDATA%\Programs\Listenary`；安装版数据保存在 `%LOCALAPPDATA%\pure_music`，便携版数据保存在程序旁的 `data/`。新版本可执行文件为 `Listenary.exe`；`pure_music` 仅作为内部数据和兼容标识保留，升级时不要手工迁移数据目录。

## 在线服务与隐私

在线搜索、在线播放、在线歌单与远程歌词会连接第三方服务，内容版权归相应平台和权利人所有。安装版的 ChKSz 凭据使用当前 Windows 用户的 Credential Manager；便携版凭据仅保存在内存中，不写入设置、数据库或日志。项目不随软件分发音乐内容，也不保证第三方服务长期可用。

## 构建

需要 Flutter `>=3.38.4`、Dart `>=3.10.3`、stable Rust、Visual Studio C++、Windows SDK 与 CMake。

```powershell
flutter pub get
flutter run -d windows
flutter build windows --debug
flutter analyze
flutter test
```

正式发布打包由维护者使用 `build_windows.ps1` 完成；普通开发和验证不应运行该脚本。仅在 Rust 对外签名或类型变化时运行 `flutter_rust_bridge_codegen generate`。

## 许可与致谢

Listenary 基于 Pure Music 改造而来。项目保留并扩展了其部分代码、设计和工程基础，经过大量重写后形成独立产品。感谢原项目及其贡献者提供的开源基础，相关上游版权和许可信息见 Pure Music。

同时，Listenary也依据 [GNU General Public License v3.0](LICENSE) 发布。GPL-3.0 允许在遵守许可证条件的前提下使用、修改和再分发，包括商业使用。

Listenary 始于 [coriander_player](https://github.com/Ferry-200/coriander_player)（GPL-3.0），并保留上游及第三方项目的版权、许可和归属信息。主要依赖与资源包括 BASS、flutter_rust_bridge、lofty、dio、provider、go_router、SQLite、MiSans VF 和 Silicon7921 图标；完整清单见[致谢文档](page/docs/guide/credits.md)。

## 免责声明

软件按 GPL-3.0 以“现状”提供，不附带适销性或特定用途适用性的保证。用户应确保自己有权访问和使用本地文件及第三方平台内容，并自行承担使用第三方在线服务产生的风险。

<div align="center">Listenary · Copyright © 2026 HuiZhou12</div>
