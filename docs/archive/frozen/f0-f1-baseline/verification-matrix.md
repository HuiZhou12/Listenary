# 验证矩阵

本文件只登记能由仓库文档、脚本或配置证实的命令。命令的“最近确认”表示于该日期核对了命令来源，不表示本次执行通过；实际结果必须记录到 `docs/AI_PROGRESS.md` 或相关 Spec。

## 环境、依赖与运行

| 命令 ID | 适用范围 | 完整命令 | 前置条件 | 是否写入工作区或访问外部服务 | 证据路径 | 最近确认日期 |
|---|---|---|---|---|---|---|
| ENV-001 | Flutter、Windows 工具链环境核对 | `flutter doctor -v` | 已安装满足版本要求的 Flutter | 可能读取系统配置、更新 Flutter 本地缓存或访问网络；不应修改业务源码 | `page/docs/dev/build.md:16-24` | 2026-08-27 |
| ENV-002 | Rust 工具链可用性 | `cargo --version` | 已安装 stable Rust/Cargo | 不写项目文件；不访问外部服务 | `page/docs/dev/build.md:16-24` | 2026-08-27 |
| DEP-001 | Flutter 依赖解析 | `flutter pub get` | Flutter/Dart 可用；允许依赖解析 | 写入 `.dart_tool/`，可能更新 `pubspec.lock` 并访问包服务；禁止自动执行 | `README.md:44-53`；`page/docs/dev/build.md:26-35` | 2026-08-27 |
| RUN-001 | Windows 本地启动与人工运行验证 | `flutter run -d windows` | 已完成 DEP-001；Windows C++/SDK/CMake、Rust、BASS 和桌面歌词文件可用 | 写入构建缓存并启动本地应用；使用在线功能时会访问第三方服务 | `README.md:44-53`；`page/docs/dev/build.md:26-35` | 2026-08-27 |

## 静态检查、测试与格式

| 命令 ID | 适用范围 | 完整命令 | 前置条件 | 是否写入工作区或访问外部服务 | 证据路径 | 最近确认日期 |
|---|---|---|---|---|---|---|
| ANA-001 | Flutter/Dart 全仓静态分析 | `flutter analyze` | 已完成依赖解析；Flutter SDK 可用 | 可能写入 `.dart_tool/` 或 SDK 缓存；正常情况下不访问外部服务 | `README.md:44-53`；`page/docs/dev/build.md:154-161`；`analysis_options.yaml` | 2026-08-27 |
| TEST-001 | Flutter 单元和 widget 测试 | `flutter test` | 已完成依赖解析；测试所需本地资源可用 | 写入测试/编译缓存；正常情况下不访问外部服务 | `README.md:44-53`；`page/docs/dev/build.md:154-161`；`test/` | 2026-08-27 |
| FMT-001 | Rust 格式检查 | `cargo fmt --manifest-path rust/Cargo.toml -- --check` | stable Rust 与 rustfmt 可用 | 不修改源码；缺少工具链组件时 rustup 可能尝试访问网络 | `page/docs/dev/build.md:154-161`；`rust/rust-toolchain.toml` | 2026-08-27 |
| TEST-INT-001 | Flutter/Windows 集成测试 | 待确认：项目未登记 `integration_test/` 的标准执行命令 | 需真实 Windows 环境、Flutter/Rust/BASS/系统媒体控制能力 | 预计会构建并启动应用，部分测试会访问系统能力；未确认前禁止自动执行 | `integration_test/`；`pubspec.yaml:43-48`；构建文档未给出命令 | 2026-08-27 |
| TEST-RUST-001 | Rust 内嵌单元测试 | 待确认：仓库存在 Rust 测试，但项目文档未登记标准命令 | 需 stable Rust、crate 依赖及 Windows 目标条件 | 预计写入 `rust/target/`，依赖未缓存时可能访问网络；未确认前禁止自动执行 | `rust/src/api/tag_reader.rs`；`rust/src/api/amll_ttml.rs`；`page/docs/dev/build.md` 未登记 | 2026-08-27 |
| FMT-DART-001 | Dart 格式检查 | 待确认：项目文档未登记 Dart 格式命令 | 需 Flutter/Dart SDK | 未确认 | `page/docs/dev/build.md` 未登记 | 2026-08-27 |

## 构建、生成与文档站

| 命令 ID | 适用范围 | 完整命令 | 前置条件 | 是否写入工作区或访问外部服务 | 证据路径 | 最近确认日期 |
|---|---|---|---|---|---|---|
| BUILD-DBG-001 | Windows Debug 构建 | `flutter build windows --debug` | DEP-001；Visual Studio C++、Windows SDK、CMake、Rust 与本地运行资源齐全 | 写入 `build/` 及工具缓存；依赖未缓存时可能访问网络 | `README.md:44-53`；`page/docs/dev/build.md:47-53` | 2026-08-27 |
| BUILD-REL-001 | Windows Release 构建 | `flutter build windows --release` | 与 BUILD-DBG-001 相同 | 写入 `build/` 及工具缓存；依赖未缓存时可能访问网络 | `page/docs/dev/build.md:68-76` | 2026-08-27 |
| FRB-GEN-001 | Rust 对外 API 签名或类型变更后的绑定生成 | `flutter_rust_bridge_codegen generate` | 已安装严格匹配 `2.12.0` 的 codegen；当前请求已授权生成 | 修改 `lib/native/rust/` 与 `rust/src/frb_generated.rs` 等生成文件；不应访问外部服务 | `page/docs/dev/build.md:55-67`；`flutter_rust_bridge.yaml` | 2026-08-27 |
| DOC-DEP-001 | 文档站依赖安装 | 在 `page/` 执行 `npm ci` | Node 20、npm 可用；允许安装依赖 | 写入 `page/node_modules/` 并访问 npm；禁止自动执行 | `page/docs/dev/build.md:130-138`；`.github/workflows/sync-release-docs.yml:26-36` | 2026-08-27 |
| DOC-BUILD-001 | VitePress 静态站构建 | 在 `page/` 执行 `npm run build` | 已完成 DOC-DEP-001 | 写入 `page/docs/.vitepress/dist/`；正常情况下不应修改业务源码，插件可能访问其配置的数据源 | `page/docs/dev/build.md:130-138`；`page/package.json:4-9` | 2026-08-27 |

## 人工与平台验证

| 命令 ID | 适用范围 | 完整命令 | 前置条件 | 是否写入工作区或访问外部服务 | 证据路径 | 最近确认日期 |
|---|---|---|---|---|---|---|
| MANUAL-WIN-001 | Windows UI、播放、窗口、BASS、桌面歌词和系统集成人工验收 | 使用 RUN-001 启动；具体检查清单待确认 | 真实 Windows 10/11 环境及完整运行目录 | 会启动应用并可能访问本地媒体、系统能力和用户选择的在线服务；需人工授权 | `README.md:17-46`；`page/docs/dev/build.md:26-35,151-161` | 2026-08-27 |
| PERF-BG-001 | 播放页背景/流光性能验证 | 待确认：仓库有 `tool/measure_windows_background_performance.ps1`，但协作文档未登记标准调用参数 | 真实 Windows、可运行 profile 构建和性能采样环境 | 会启动应用、写性能结果并访问系统计数器；未确认前禁止自动执行 | `tool/measure_windows_background_performance.ps1`；`page/docs/dev/index.md` | 2026-08-27 |

## 禁止自动执行

以下操作会安装工具/依赖、修改版本或生成文件、迁移用户数据、发布或修改外部状态，仅在用户当前请求明确授权后执行：

| 操作 | 命令或入口 | 原因 | 证据路径 |
|---|---|---|---|
| 修改全局 Flutter 配置 | `flutter config --enable-windows-desktop` | 修改本机 Flutter 配置 | `page/docs/dev/build.md:16-24` |
| 安装 FRB codegen | `cargo install flutter_rust_bridge_codegen --version 2.12.0 --locked` | 安装全局工具并可能访问网络 | `page/docs/dev/build.md:55-64` |
| Flutter/npm 依赖安装 | DEP-001、DOC-DEP-001 | 写依赖目录/锁文件并访问外部包服务 | 对应矩阵行 |
| 正式打包 | `.\build_windows.ps1 -Version <version> -Mode <1-5> [-NonInteractive]` | 会改写 `pubspec.yaml`、`windows/runner/Runner.rc`、`update/version.json`，清理构建目录并写入 `output/` | `build_windows.ps1`；`page/docs/dev/build.md:68-128` |
| 发布文档同步 | `.github/workflows/sync-release-docs.yml` | 有 `contents: write` 权限，会提交并推送版本文档 | `.github/workflows/sync-release-docs.yml` |
| 用户数据迁移 | `tool/upgrade_from_previous.ps1`、`installer/import_portable_data.ps1` | 会读取、复制或迁移用户持久化数据 | `tool/upgrade_from_previous.ps1`；`installer/import_portable_data.ps1` |
| 发布、提交、推送 | Git commit/push、Release 或部署入口 | 修改仓库或外部发布状态 | `skills/listenary/rules/git-workflow.md`；`page/docs/guide/contribute.md` |

## 覆盖缺口

- `integration_test/` 有测试资产，但标准 Windows 执行命令和环境矩阵待确认。
- Rust 源码含内嵌测试，但 `cargo test` 未被现有项目文档登记，不能自行视为标准命令。
- 未登记 Dart 格式检查、Rust clippy、文档 lint/test 或自动化真实设备命令。
- 当前 CI 只同步 Release 文档，没有 pull request/push 上的 `flutter analyze`、`flutter test`、Rust 检查或 Windows 构建。
