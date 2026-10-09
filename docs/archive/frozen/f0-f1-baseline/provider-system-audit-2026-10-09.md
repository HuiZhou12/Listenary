# Provider 系统审计报告（现状 · 矛盾 · 场景 · 安全 · 边界）

- 日期：2026-10-09
- 被审对象：`feat/multi-platform-aggregation` @ **`197e25b`**（`main` = `2bfaaf0` 未动）
- 性质：**只读审计**。审计期间未修改任何源码/测试/数据库/配置/分支/提交历史。
- 配套：缺陷清单见 `provider-system-audit-defects-2026-10-09.md`；目标架构与整改计划见 `provider-system-redesign-proposal-2026-10-09.md`。
- 决策：本阶段确认的 **D1–D8** 见本文 §6（用户 2026-10-09 裁定）。

---

## 0. 证据分级（全文适用）

| 标记 | 含义 |
|---|---|
| **代码事实** | 有 `文件:行号` 证据，跨文件因果链闭合，可静态复核 |
| **合理推断** | 基于代码路径的推理，**未经运行时复现** |
| **未验证假设** | 需要真实服务样本 / 运行环境 / 迁移实测才能确认 |

> 本次审计**未运行** `flutter analyze|test`、**未启动 GUI**、**未访问真实服务**。
> 因此所有"真实服务已接通"的说法均为**文档声称**（`docs/` 内报告），不是本轮实测。
> 例外：审计早期本人用只读 HTTP 请求实测过网易云 `127.0.0.1:3000` 与 QQ `127.0.0.1:3200` 的部分接口（搜索/歌单/歌词/播放解析），结论只覆盖那些接口。

---

## 1. 现状：真实调用链（代码事实）

### 1.1 定义与配置
- 一个条目 = `OnlineMusicProviderDefinition`：`id / protocol / baseUrl / 3×timeout / credentialReference / requiresCredential / parameterName / contentPlatform / capabilities / capabilityAuth`（`provider/online_music_provider_settings.dart:47-115`）。
- 逐能力绑定是**三形态闭集**：`builtin`（仅 `chksz`）/ 声明式（request+response spec）/ `unsupported`（`provider/online_music_binding.dart:14-139`）。
- 旧条目判别：`capabilities == null && protocol == 'chksz'` ⇒ **该条目 8 个能力全为 builtin**（`:118-128`）。
- **路由不在条目上**，在 `OnlineMusicSettings`：`providers / defaultProviderId / capabilityProviders(旧单值) / routing(platform→capability→有序 id) / enabledPlatforms`（`:445-484`）。

### 1.2 候选选择（运行时问答）
- `providersFor(platform, capability)`（`provider/online_music_provider_registry.dart:88-111`）：平台被停用 ⇒ 空；有显式候选 ⇒ **只取**这些（D17:b，不补齐隐式）；无显式 ⇒ 按注册顺序取所有 `_supports`。
- `_supports` 由**实现类**回答 `platformsFor(capability)`（`:146-150`）——这是"运行时真实能力"的唯一权威。
- `defaultProvider` 仅喂 `_selectedProviders` 与 `providerFor/providerIdFor`，**lib 内无调用者**（`:43-51,68-72`）。

### 1.3 装配与生效时机
- `main.dart:127-150` 启动时读取一次 `AppPreference.onlineMusicSettings` 并 `createOnlineMusicComposition(...)` **一次**；设置页保存只**写盘 + notify**，**不重建 service**（`provider/online_music_provider_settings_controller.dart:273-284`）。
- ⇒ 能力/平台/路由改动**下次启动生效**（**已确认设计**，见 §6 D7）；凭据改动**当次可用**（同一 `ChkszCredentialAccess` 实例）。

### 1.4 分发、回退与身份
- 应用层只依赖 `OnlineMusicService`（`online_music_service.dart:138-247`）；实现 `CompositeOnlineMusicService._dispatch`（`:355-387`）：候选空 ⇒ 请求前抛 `unavailable`；按序 try，仅 `allowsProviderFallback(kind)` 为真才继续，否则原样 rethrow；全失败抛最后一个。
- 回退白名单：`network / unavailable / notConfigured / quotaExhausted / rateLimited`（`online_music_error.dart:30-37`）。
- 每次分发记 `_routeLog`（上限 32）；`resolve`/`fetchLyrics` 回填 `servedByProviderId` 作为**诊断标记**（`composite:225-228`、`models:100-104`）。
- 音质：`resolve` 在**每次尝试内**用该 provider 的档位表把内部偏好转成平台请求值（`composite:217-224`）。

### 1.5 生命周期与资源
- 实例启动创建一次；释放链完整（`entry.dart:364` → `composite:343-347` → `_ConfiguredMusicProvider.dispose` → `ChkszRuntime.dispose` / 声明式 Dio）。
- 例外：**探测/试跑每次新建 Dio 且从不关闭**（`controller:676-693`；`declarative_http_transport.dart:20-34` 无 close）。

### 1.6 扩展成本（按文件计数的改动面）
| 扩展类型 | 改动面 | 备注 |
|---|---|---|
| **新增能力** | **8–10 个文件** | `capability.dart` / `online_music_service.dart` / `online_music_provider.dart` / `composite` / `registry+capabilities` / `response_spec`(校验+域字段+必填) / 声明式映射 / `composition` / 编辑器 / 测试替身 |
| 新增平台 | ~10 个文件 | 枚举 + 展示名 + UI 文案 + **netease 专属 codec** + UI 组件里的平台规则 |
| 新增参数来源 | 4 个文件 | request_spec / builder / templates / 编辑器 |
| 新增认证方式 | 2 个文件 + 编辑器 19 处 | auth 是 sealed 闭集 |
| 新增类型转换 | 4 个文件 | response_spec / mapper / templates / 编辑器 |
| 新增音质档位 | 1 个表 + **必须由代码里的 Provider 返回** | 声明式无法声明（见缺陷 P-13） |

**静默漏改点**（新增能力时不会报错、但行为错）：`component/platform_capability_view.dart:14-21`（手写 5 行）、`controller:510-674`（if 链无 else，落到 stream 分支 → `trackId!` 抛错被 `catch(_)` 变成"网络不可达"**误诊**）。

---

## 2. 设计矛盾清单（产品目标 — 配置模型 — 运行时 — UI — 测试）

| # | 功能 | 产品目标 | 配置模型 | 运行时 | UI | 测试 | 结论 |
|---|---|---|---|---|---|---|---|
| 1 | 能力可用性 | 界面如实反映 | builtin ⇒ **全 8 能力** | 只认 **4** | 显示"自动：使用 chksz" | 断言"8 能力皆 builtin" | **四层不一致**（P-19 / P-46） |
| 2 | 配置生效 | 配完能验 | — | 启动快照 | "重启后生效" | 只测草稿 | 状态三态未显式（P-04；D7 已裁定维持重启生效） |
| 3 | 探测职责 | 验证配置 | 不参与 | 不参与 | 仅 search 可见 | 只覆盖模板 | 实现是"服务指纹"（P-05） |
| 4 | 错误语义 | 一致可诊断 | — | 表A + 枚举1 | 表C | 表B | **三层三结论**（P-16） |
| 5 | 音质档位 | 按平台映射 | **声明式无法声明** | 空表透传 | 用网易云文案 | 只测内置 | 模型 vs 多平台目标（P-13/P-56） |
| 6 | 歌词来源 | 按曲目平台 | **3 个来源枚举** | 双轨 | "默认在线源"未限定作用域 | 各自单测 | 双轨未说明（P-15） |
| 7 | 回退可观测 | Spec §6.4 要求诊断 | — | 有 routeLog | **无出口** | 仅测试读 | 契约未暴露（P-29） |
| 8 | 一键填充 | 帮用户省事 | 整表替换 | — | 无确认 | — | 命名 vs 行为不符（P-20/P-24） |

---

## 3. 技术用户端到端场景：目前在哪一步失败

| 场景 | 失败点（顺序） | 共同造成的缺陷 |
|---|---|---|
| **A 已有模板的服务**（创建→URL→探测→初稿→编辑→试跑→保存→运行） | 探测可能给出**必失败初稿**（模板认证残留）→ 初稿 body/分页未回填 → 保存后需重启（预期）但界面未显式区分三态 | P-06 / P-25 / P-04 |
| **B 未适配的自建 API** | **第一步就断**：非搜索能力**存不下**（表单互斥）；改用 JSON 也撞 body/分页不可编辑、静态常量缺失、键名限制、非 JSON Content-Type、档位无法声明 | **P-01（主断点）** / P-21 / P-08 / P-41 / P-40 / P-13 |
| **C 排查配置失败** | 探测无分类无证据 → 三层错误结论不同 → 诊断无出口 → 类型错报成"缺字段" → 新能力误诊"网络不可达" → 超时不可区分 | P-07 / P-16 / P-29 / P-31 / P-45 / P-50 |
| **D 切换/修改 Provider** | 候选集合与运行时不一致 → 一键填充毁配置 → 旧值不可见不可清 → builtin 忽略平台 → 同平台多 Provider 可能错歌 → 凭据明文 | P-19 / P-20 / P-22 / P-24 / P-42 / P-17 |

---

## 4. 安全风险专报

| ID | 实际影响 | 触发条件 | 凭据泄露 | 错误目标 | 配置丢失 | 错误成功态 | 判定 |
|---|---|---|---|---|---|---|---|
| **P-17** | 请求头里的 `Cookie`/`X-Api-Key`/签名串**明文展示 + 明文写入 `app_preference.json`** | 在"请求头"里填敏感值并保存 | **是（本机磁盘 + 界面）** | 否 | 否 | 否 | **代码事实**。修复方向：值来源脱敏 + 敏感值走凭据槽位（**已有安全路径可比照**：`auth.header` + 凭据槽位） |
| **P-18** | 非法 `baseUrl` **静默替换为 `https://api.chksz.com`**；若条目配了 query/header 认证，**可能把凭据发往第三方** | baseUrl 笔误 / 空 / 非 http(s) | **可能（未验证）** | **是** | 否 | **是**（请求"看起来"发出） | 静默替换 = **代码事实**；"凭据实际外发" = **未验证假设**，须运行验证后定级（可能升 P0） |
| **P-01** | 校验与真实运行不一致：4 能力存不下、playlist **静默丢曲目** | 编辑歌单列表/分类/榜单/新歌/歌单详情 | 否 | 否 | **是** | **是（playlist 试跑绿灯）** | **代码事实（P0）** |
| **P-04** | 试跑成功 ≠ 运行时同一配置 | 保存后立即观察 | 否 | 否 | 否 | **是**（把"试跑成功"读成"已生效"） | **代码事实**（D7 裁定维持重启生效，故只剩"三态未显式"） |
| **P-20** | 「一键按 ChkSz 兼容方式填充」**整表替换 `capabilities`**：另 4 能力配置直接消失、已有声明式绑定被覆盖，无确认无撤销 | 任意已配置条目点一次 | 否 | 否 | **是（严重）** | 否 | **代码事实（P1，本轮范围加重）** |

**安全优先级结论**：**P-17 / P-18 必须先于所有功能性整改**（一个已确证的本机明文泄露；一个可能把凭据发往第三方且被静默的路径）。P-17 的修复**无需重写存储层**（见整改计划 §4 迁移设计）。

---

## 5. 已澄清的"非缺陷"（避免把已确认设计当 Bug）

- **重启生效**：条目/能力/路由改动下次启动生效、凭据当次生效 —— **已确认设计**（D7 维持）。
- **平台是闭集**：`MusicPlatform` 闭集是既有决策；**静默回落 netease** 才是缺陷（P-39，D5 已裁定改为支持自定义平台标识）。
- **单凭据槽位**：一个条目一个 secret 属模型边界；**没有 Cookie/签名**才是缺口（D3 已拆分裁定）。
- **`defaultProvider` 字段保留**：属 D13:A 兼容策略；死代码清理可选（P-53）。
- **试跑不发起第二次请求**：有意取舍；"可用"文案过强属文案问题（P-51）。
- **`null` 与缺失同义 / 转换闭集**：属已接受边界（D4），但**必须显式报错而非静默 null**。
- **探测不测所有能力**：探测定位为服务级；但当前实现连"服务级"都没做对（P-05）。

---

## 6. 本阶段确认的决策（D1–D8，2026-10-09）

| # | 裁定 | 要点 |
|---|---|---|
| **D1** | **A 支持静态常量参数** | query/body 允许固定值（`format=json` 这类） |
| **D2** | **B 本阶段不支持"一个能力多请求"** | **明确列为模型边界**；不得声称支持多请求编排；QQ 榜单/复杂艺人页待有真实样本后**单独设计** |
| **D3** | **拆分**：支持"用户手工提供静态 Cookie 或敏感请求头值 + 通过安全凭据引用使用"；**不承诺**自动登录/Cookie 生命周期/动态签名/令牌刷新；**不支持的认证方式必须明确报出模型边界，不得静默忽略** |
| **D4** | **A 接受 `null`≡缺失 + 有限转换集合**，但必须在**配置界面 / Spec / 诊断**写明支持范围；**不支持的转换必须在保存或试跑时明确报错，不得静默返回 null** |
| **D5** | **A 支持自定义平台标识**：平台有**稳定唯一 ID，与展示名分离**；**未知平台不得静默回落 netease**；平台身份必须贯穿 Track / PlaylistItem / Lyric / Stream / Quality 路由；**不得为自定义平台推翻现有来源身份模型** |
| **D6** | **A 安全迁移**，但**先核对凭据存储能否保存每个敏感请求头**（已核对：存储层多槽位 ✅）；能安全迁移的**迁移后验证行为兼容**；**无法识别/无法安全迁移的不得静默删除、覆盖或错误合并**；若"只能存一个秘密而旧配置有多个敏感头"须先报最小模型调整；无法自动迁移的**明确提示重配**；**不得以保留明文为最终方案**；**必须含迁移测试与迁移失败测试** |
| **D7** | **A 维持"配置重启后生效"**，但 UI 必须显式区分三态：**当前编辑草稿 / 已保存待重启 / 运行时实际生效**；"试跑成功 ≠ 已投入运行" |
| **D8** | **A 授权落盘审计文档、缺陷清单与整改计划**（**仅文档**；不含源码/测试/DB/配置/Git） |

---

## 7. 审计边界（本轮）

**已覆盖**：定义/注册/装配/生命周期/路由/回退、声明式模型表达力（12 步推演）、探测与试跑、能力不对称与 UI、身份与持久化、测试覆盖量化、安全与脱敏、扩展成本、文档漂移。

**未覆盖 / 证据不足**：
1. **运行时行为未复现**：Dio 泄漏规模、同平台多 Provider 错歌、半迁移库、跨平台 `fallbackQuality`、聚合异常吞噬 —— 均需运行环境。
2. **真实服务样本**：QQ/酷狗**无任何响应固件**（`live_response_fixtures.g.dart` 仅网易云六项）；酷狗在新聚合链路中**缺席**（实现在旧歌词链路 + native）；QQ 高档位受账号权限限制（实测免费账号仅 `128`/`m4a`）。
3. **若干测试文件未逐行读**（迁移测试、schema 契约测试、probe 测试全文）⇒ `platformQualityFallbackChain` 是否已有间接覆盖**未确认**。
4. **`docs/` 内 70+ 份报告的声称未逐条核验**（仅抽查到 2 处文档与代码矛盾）。
5. 未审计 `play_service`、`library`、native 层的大部分实现。
