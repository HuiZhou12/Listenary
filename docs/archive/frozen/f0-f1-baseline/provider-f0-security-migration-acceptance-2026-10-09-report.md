# F0 验收报告：敏感请求头安全存储 / Base URL 校验 / 旧配置安全迁移

- 日期：2026-10-09
- 分支：`feat/multi-platform-aggregation`（**未 push、未切 main、未开 PR**）
- 起点：`197e25b`（F0 审计基线）；F0 切片提交：**`d25331b`(F0-1) → `191e4c1`(F0-2) → `ca72922`(F0-3) → `5a230c5`(F0-4) → `d9d1034`(F0-5) → `ce17ff8`(F0-6 Review 整改) → `67dff99`(裁定边界 2) → `d7b628e`(真机发现的凭据存储缺陷)**
- 范围：**仅 F0**（① 敏感请求头安全存储与显示 ② Base URL 校验 ③ 旧配置安全迁移 ④ 直接相关的错误提示与测试）
- **未进入 F1–F5**；探测系统 / 声明式执行器 / 能力路由 / 设置页整体重构**均未触碰**
- **独立 Review 已完成并整改**（§9）；**两条安全边界已裁定**、**最终 diff 只读复核通过**、**Windows 真机凭据读写与重启验证通过**（§10）
- **F0 冻结边界：`197e25b..d7b628e`**；`flutter analyze` → No issues found，全量 `flutter test` 见 §3

---

## 1. 变更文件清单

| 切片 | 提交 | 变更 |
|---|---|---|
| F0-1（上轮已完成） | `d25331b` | `provider/online_music_request_spec.dart` + 新测试 `online_music_sensitive_header_test.dart`（7 条） |
| F0-2 运行期拒绝 + 脱敏改按值来源 | `191e4c1` | **新增** `provider/online_music_header_slot.dart`；改 `provider/online_music_request_spec.dart`、`declarative/declarative_errors.dart`、`declarative/declarative_request_builder.dart`、`declarative/declarative_music_provider.dart`、`provider/online_music_provider_credentials.dart`、`provider/online_music_provider_settings_controller.dart`、`chksz/index.dart`；**新增测试** `online_music_sensitive_header_runtime_test.dart`（15 条） |
| F0-3 Base URL 校验 | `ca72922` | 改 `provider/online_music_provider_settings.dart`、`online_music_composition.dart`、`provider/online_music_provider_settings_controller.dart`、`declarative/provider_probe.dart`、`page/settings_page/online_music_settings.dart`、`page/settings_page/online_music_capability_editor.dart`；**新增测试** `online_music_base_url_test.dart`（10 条）；改写 3 处固化 P-18 的旧断言 |
| F0-4 编辑器 | `5a230c5` | 改 `page/settings_page/online_music_capability_editor.dart`、`page/settings_page/online_music_settings.dart`、`provider/online_music_provider_settings_controller.dart`、`provider/online_music_header_slot.dart`；测试 +3（`page/settings_page/online_music_settings_test.dart`） |
| F0-5 迁移 | `d9d1034` | **新增** `provider/online_music_header_migration.dart`；改 `provider/online_music_provider_settings_controller.dart`、`page/settings_page/online_music_settings.dart`；**新增测试** `online_music_header_migration_test.dart`（15 条）+ UI 2 条 |
| F0-6 Review 整改 | `ce17ff8` | 改 `provider/online_music_header_migration.dart`、`provider/online_music_provider_settings_controller.dart`、`page/settings_page/online_music_capability_editor.dart`、`page/settings_page/online_music_settings.dart`；测试 +4（含**替换掉一条名不副实的用例**） |
| 裁定边界 2 | `67dff99` | 改 `provider/online_music_provider_settings_controller.dart`（摘要遮蔽加"值形态可疑"判据）；测试 +1 |
| 真机缺陷修复 | `d7b628e` | 改 `chksz/chksz_windows_credential_store.dart`（FALSE + ERROR_SUCCESS ⇒ 按"不存在"处理）；测试 +1 |

合计：生产代码 **8 个文件改动 + 2 个新文件**；测试 **3 个新增测试文件 + 既有文件内新增 10 条 + 替换 1 条名不副实的用例** = **+51 条**。
**未改动**：`skills/**`、`pubspec*`、`update/version.json`、`windows/runner/Runner.rc`、数据库 schema、`main`。

---

## 2. 迁移前识别报告（真实配置，只读实测）

探针：**用 F0 的实现代码**读取真实配置文件后分类（临时探针文件已删除；全程只读、无写入）。
文件：`build\windows\x64\runner\Debug\ListenaryData\settings\app_preference.json`（3913B，2026-10-09 10:45，**实测未变**）。

| 项 | 实测结果 |
|---|---|
| Provider entry 数 | **3**（`chksz` / `localhost` / `qq_music`） |
| 请求头总数 | **0** |
| 声明式（http）绑定数 | 1（`localhost` 的 `search`） |
| **敏感请求头命中数** | **0**（规则 A 名称命中 0；规则 B 显式标记 0） |
| **`needs-user` 候选数** | **0** |
| **逐请求头凭据引用数** | **0** |
| baseUrl 合法性 | **3/3 合法**，且 3 条都是**显式提供**（非缺失） |
| 条目级 auth 槽位 | 3 条都有（与逐请求头引用是两件事） |

⇒ **真机迁移在本机是空操作**（无对象可迁移），报告里的迁移逻辑一律由**合成夹具**证明。

### 2.1 ⚠️ 实测更正（Spec §1.2 的一处事实错误）

| 条目 | 原始键（只列键名） | `capabilities` 键 | 能力键 | 按现判别式的结果 |
|---|---|---|---|---|
| `chksz` | id,protocol,baseUrl,contentPlatform,超时×3,auth | **不存在** | — | 旧条目（按 `protocol` 解释） |
| `localhost` | +displayName,capabilities | 存在 | `search` | 新模型：1 个声明式能力 |
| `qq_music` | +displayName,capabilities | **存在** | **（空）** | 新模型：**0 个能力 ⇒ 什么都不服务** |

Spec §1.2 把 `qq_music` 记成"无 `capabilities` 的旧条目 ⇒ 8 能力全内置 ⇒ 被当成 netease 候选"，
**与数据不符**：它有 `capabilities` 键但为空 ⇒ 按 `online_music_provider_settings.dart` 的判别式
是**新模型零能力**条目。
⇒ 据此登记的"P-24 真实配置实例"**不成立**；已在 Spec 里加"实测更正"块（只更正事实，不改裁定）。
**P-24 作为代码层缺陷类仍然存在**（`capabilities` 键缺失 + `protocol=chksz` ⇒ 8 能力全内置），
仍是**独立后续项**；F0 **未修改**该条目的配置或行为，**未**把它标记为已修复。

---

## 3. 自动化测试结果

### 3.1 命令与输出（实际执行）

```
$ flutter analyze
No issues found! (ran in 10.4s)                      exit code 0

$ flutter test
01:34 +1253: All tests passed!                       exit code 0
```

- 基线（F0-1 之后）：**1202 passed**；本次 **1253 passed** ⇒ **净增 51 条，测试只增不减**
- 中途每片都跑了**受影响目录**（`test/services/music_platform` + `test/page/settings_page`）全绿后才提交；
  全量按你的要求只在收尾跑（整改前：1247 绿；Review 整改后：1251 绿；三条追加指令后：1253 绿）
- 为记录诚实：F0-2、F0-3、F0-4、F0-5 的**中间提交**并未各自跑过全量（按你的指示），
  全量绿是在**全部切片 + Review 整改完成后**针对最终 `ce17ff8` 工作树
- ⚠️ 全量跑**第一次**时骨架里红了一条：项目自带的**文档一致性守卫**
  （`test/docs/decision_list_consistency_test.dart`）抓到我在 `AI_PROGRESS` 里写死的
  "1247 passed" 与整改后的真实数字不一致 —— **守卫生效**，已把三处"当前总数"同步为 1251
  （并把 Home/Explore 那处标注为历史快照，避免两份"最近验证"互相矛盾）

### 3.2 Spec §10.4 + §11.5 共 14 项验收 → 对应用例

| # | 要求 | 用例（文件：用例名） |
|---|---|---|
| 1 | 迁移成功（写槽位→回读→改写→重解析→明文移除） | `online_music_header_migration_test.dart`：★写槽位 → 回读一致 → 配置改写 → 重新解析 → 明文已移除 |
| 2 | 凭据写入失败（不半迁移） | 同文件：★凭据写入失败 ⇒ 配置不变，且先写进去的槽位被删掉 |
| 3 | 回读不一致 | 同文件：★回读不一致 ⇒ 回滚槽位、配置不变 |
| 4 | 配置保存失败 | 同文件：★配置保存失败 ⇒ 槽位已写也要回滚 |
| 5 | 回滚失败 ⇒ 停止整个迁移 | 同文件：★回滚失败 ⇒ 停止整个迁移，后面的 entry 一个都不碰 |
| 6 | 幂等重放 | 同文件：★重复执行：不新建重复槽位、不改名、plain 项不动 |
| 7 | 旧配置不再含明文 | 用例 1 内断言（序列化结果不再包含该值） |
| 8 | §11.5-1 `sensitive`+明文 ⇒ 报错且 **0 请求** | `online_music_sensitive_header_runtime_test.dart`：★传输层调用次数 = 0，错误与 missingCredential 可区分 |
| 9 | §11.5-2 保存被拒 | `online_music_sensitive_header_test.dart`：★sensitive + 明文 ⇒ 校验报错；`online_music_sensitive_header_runtime_test.dart`：★有引用还留着明文 ⇒ 校验失败；`page/settings_page/online_music_settings_test.dart`：F0-4 敏感 + 明文 ⇒ 保存被拒 |
| 10 | §11.5-3 槽位冲突停止不覆盖 | migration：★目标槽位已存在且内容不同 ⇒ 停止、不覆盖、报告（另有"读失败⇒同样不覆盖"一条） |
| 11 | §11.5-4 槽位相同幂等通过 | migration：★目标槽位已存在且内容相同 ⇒ 幂等通过、不重复写 |
| 12 | §11.5-5 归一化碰撞失败 | migration：★Header 名归一化碰撞 ⇒ 失败并报告；runtime：★Header 名归一化碰撞 ⇒ 校验失败并点名双方 |
| 13 | §11.5-6 portable 跳过且不报成功 | migration：★跳过迁移：配置逐字节不变、未写内存槽位、不报成功；settings：F0-5 便携版：只提示不可迁移，不给「开始迁移」按钮 |
| 14 | §11.5-7 主动轮换允许覆盖 | migration：★迁移不得覆盖；用户在凭据界面主动更新必须能覆盖（用**真实** `ChkszCredentialAccess` 验证覆盖生效） |

补充（超出 14 项，同属 F0 要求）：Base URL 10 条、编辑器 3 条、识别三态 3 条。

---

## 4. 安全验证证据（模拟传输层 + 假凭据；**未用真实 Key 打任何地址**）

| 断言 | 实测证据 |
|---|---|
| 敏感头 + 明文 ⇒ **不发请求** | 记录型 adapter：`requests.isEmpty`（0 次）；错误为 `badRequest`（**不是** `notConfigured`，避免被路由当成"换个 Provider"盖掉） |
| 敏感头 + 有效引用 ⇒ 正常注入 | 请求头值 = 槽位里的假凭据；**配置里的明文一个字都没发出** |
| 非法 baseUrl ⇒ **0 请求、0 次建连** | `dioFactoryCalls == 0`、`requests.isEmpty`；**目标不被替换**：所有记录到的 baseUrl 中 `api.chksz.com` 出现 **0 次** |
| 试跑 / 探测 | 非法地址下 `requests.isEmpty`；探测返回 `blockedReason` 而不是"候选都没通过" |
| 假凭据外发次数 | **0**（`seenAnywhere(fakeKey)` 为 false；非法地址路径下没有任何请求，也就没有任何主机收到它） |
| 目标 host（合法路径对照） | 缺省配置 ⇒ 命中默认地址；显式 `http://127.0.0.1:8080` ⇒ 命中该地址（**未被改成默认**） |
| 明文不外泄到界面/配置 | 迁移后配置序列化不含明文；编辑器 JSON 视图与请求摘要都不含秘密；凭据输入框 `obscureText == true` |
| 临时文件 | F0 **不新增任何临时文件**；配置落盘沿用既有 `writeTextFileAtomically`（临时文件内容 = **已移除明文后**的配置，成功即 rename、失败即删除）。既有 3 个 `playback_pref.json.tmp.*`（安装版目录，10-02，432B）**未被触碰/清理/覆盖** |

脱敏判据已按 **值来源**（反模式 6 / P-35）：`BuiltDeclarativeRequest` 记录"哪些请求头/查询参数的
值来自凭据"，摘要据此遮蔽；名字白名单降级为兜底并补齐 `appkey/session/jwt/…`；
响应预览改为**结构化递归**遮蔽（覆盖非字符串值、嵌套 JSON、数组元素）。

---

## 5. 旧配置兼容结果

| 路径 | 结果 |
|---|---|
| 缺省 baseUrl（配置里没有该键） | ✅ 仍走默认地址；请求真的打到默认 host（对照用例） |
| 显式合法 baseUrl | ✅ 生效该地址，**不被替换** |
| `sensitive` 字段缺失的旧配置 | ✅ 读作 `false`；`toJson` **不写该键** ⇒ 往返后字节语义不变（F0-1 已有） |
| `reference` 字段缺失的旧配置 | ✅ 读作 `null`；同样不写盘 |
| 旧条目（`capabilities` 键缺失） | ✅ 未进入迁移计划（`_planFor` 直接跳过），配置与行为不变 |
| `plain`（名字未命中、值不可疑）请求头 | ✅ 原样保留，迁移不碰 |
| 真实配置 | ✅ 3 entry 全部仍可解析；真实配置本次**一个字节都没被改写**（探针只读，且 `write()` 会直接 fail） |

⚠️ **有意的语义变更（P-18 修复本身）**：非法 baseUrl **不再**被静默改写成默认地址。
因此 3 处固化该缺陷行为的旧断言被改写（详见 F0-3 提交说明与 §7）：
`chksz_runtime_factory_test` 的 normalize 用例、`online_music_settings_test` 的 per-entry normalize 用例、
`online_music_provider_settings_controller_test` 的 "keeps an unusable base URL at the documented default"。

---

## 6. 未验证项与原因（**不得计入通过项**）

| # | 未验证项 | 原因 |
|---|---|---|
| 1 | **真实敏感凭据迁移**（真机上把明文搬进 Windows 凭据管理器） | 本机**没有明文敏感头样本**（0 个）⇒ 只能由合成夹具覆盖 |
| 2 | **真实 Windows 凭据槽位读写**（`CredWrite`/`CredRead`/`CredDelete` 的实际往返） | F0 的测试用内存实现与假件；`WindowsChkszCredentialStore` 本身不是本次改动，未在真机跑通写-读-删 |
| 3 | **安装版构建下的迁移**（`PORTABLE_BUILD=false`） | 本机 Debug 产物是**便携布局**（`portableBuild` 编译期默认 `true`）⇒ 真机走的是"跳过迁移"分支 |
| 4 | **便携版真实运行的提示文案** | UI 提示路径用注入的 `isPortableBuild` 覆盖；未用真便携产物跑一遍 |
| 5 | 迁移后**重启应用**的端到端（引用能真的被运行期读到） | 需要真实构建 + 真实槽位（依赖 #1/#2）；运行期读取逻辑本身有单测（逐头凭据注入 + 槽位为空即报错） |
| 6 | 非 Windows 平台 | 项目仅 Windows 产物；凭据层走 win32 |
| 7 | `needs-user` 用户在界面上的**裁定动作**（把可疑项手勾成敏感并迁移） | 已实现（F0-4 勾选即写引用）并有单测，但"从 needs-user 候选 → 手勾 → 迁移成功"的**完整人工链路**未在真机走一遍 |

---

## 7. 与 Spec 的偏差、以及假定

### 7.1 与 Spec 的偏差（均已在此说明原因）

| # | Spec 说 | 实际做法 | 原因 |
|---|---|---|---|
| 1 | §3 槽位命名 `<capability>` 括注"`capability.name` 已小写" | 能力段**显式转小写** | 枚举实际是 camelCase（`playlistCollection`/`newSongs`/`chartList`/`playlistCategories`），Spec 括注与事实不符；统一小写才稳定可读 |
| 2 | §2 名单含 `key` 之类的泛化名（原文列举里没有裸 `key`） | 名单**刻意不含**裸 `key`/`auth` | 自动迁移宁可少认；漏掉的由规则 C（用户手勾）兜底。**这是收窄，不是放宽** |
| 3 | §1.2 `qq_music` 是旧条目、P-24 实例 | 实测是**新模型零能力**条目（§2.1） | 数据如此；已在 Spec 加"实测更正"，**未**改任何裁定、**未**动该条目 |
| 4 | §1.3 两个目录都有 `.tmp` | 实测 `.tmp` **只在安装版目录** | 事实更正；两处都未触碰 |
| 5 | §11.1 只规定新增 `sensitive` 字段 | 另新增可选 `reference`（凭据引用）字段 | §4.3 要求"header 改为引用形式"，模型必须能表达引用；缺省不写盘，旧配置不受影响 |

### 7.2 我自行的假定（需要你确认）

1. **引用字段形态**：`OnlineMusicHeaderSpec.credentialReference`（JSON 键 `reference`），
   缺省不写盘；与 `sensitive` 的合法组合是 `sensitive:true + reference`（值必须为空）。
2. **敏感头的"值入口"**：按你确认的方案 —— 行内可编辑「凭据引用」+「填写凭据」按钮，
   秘密**只**经凭据访问层写进槽位，**不进入**能力绑定 / 编辑草稿 / JSON 视图。
3. **迁移触发点**：按你确认的方案 —— 设置页「凭据安全 → 检查并迁移敏感请求头」，
   **先只显示识别结果**，用户点「开始迁移」才执行。
4. **未配引用但已标敏感的头**（`sensitive:true` 且无 reference 且值为空）：运行期按
   "缺少可用凭据"**明确失败**（不发空头、不发明文）。Spec 未规定这一态，我按"绝不静默降级"处理。
5. **识别启发式**（`needs-user` 候选）判据：长度 ≥16，或长度 ≥8 且无空白、字符集受限、
   同时含字母与数字。**只用于候选清单**，永不作为自动迁移依据。
6. **`OnlineMusicErrorKind` 未新增枚举值**：敏感头明文 ⇒ `badRequest`（不换 Provider，避免掩盖配置错误）；
   引用缺凭据 ⇒ `notConfigured`（换 Provider 是合理出路）。若你希望"敏感头缺凭据"也禁止换 Provider，
   需要新增一个错误大类（影响 `allowsProviderFallback`）。
7. **迁移的明文检查范围**：只检查**该 entry 自己**序列化结果（另一条未迁移 entry 持有相同明文是合法的）。
   这是我实现时**自己写出来又抓到的缺陷**（见 §8 复盘）。
8. **`portableBuild` 事实**：编译期默认 `true`（便携是默认产物形态）。本机 Debug 走便携 ⇒ 真机迁移为
   "跳过 + 提示"，符合决策 B，但这意味着**在本机这套构建里永远不会有真迁移**。
9. **不新增页面**：设置在既有「在线音乐」页内加一节「凭据安全」。

### 7.3 我自己复核出来的两条边界（**已核实，未隐藏**）

**边界 1：配置落盘的临时文件里会出现"尚未迁移"的明文（不是新增暴露）**
`AppPreference.save()` 走既有 `writeTextFileAtomically`：整份 `app_preference.json`
先写 `<path>.tmp.<ts>.<pid>`，成功后 rename、失败即删。因此**只要配置里任何一处**
仍有明文（本条目迁移失败的、`needs-user` 候选、`plain` 请求头），这次写盘的临时文件里
就会有那份明文 —— 与目标文件**本来就有**的内容相同，且随即 rename/删除、不留残留。
我的判断：这**不构成新的暴露面**（同路径原子替换，不是"额外文件"），但**严格按字面**
读 Spec §6.1（"临时文件不包含明文秘密"）只有"配置里已无任何明文"时才完全满足。
若你要求"迁移期间连这种瞬时副本都不允许出现"，需要**扩大范围**（改 `writeTextFileAtomically`
的调用方式，影响所有偏好落盘，属全应用改动）⇒ 按规则**先报给你裁定，未自行扩范围**。

**边界 2：`needs-user` 候选值仍会出现在「试跑」的请求摘要里（**既有行为，未修**）**
请求摘要的遮蔽判据现在是 **值来源**（凭据 ⇒ 一律 `[redacted]`）＋ 名字兜底。
但 `needs-user`（名字未命中、值可疑）的请求头是**以明文发出去的**（F0 不改其行为），
若它的名字也不在兜底名单里，摘要会把它的**值**原样渲染到界面上。
这是**既有**行为（不是我引入的），且属 P-35 同一类问题；最小修法是"值可疑的请求头在摘要里
也遮蔽"（一行判据 + 一条测试）。**按规则先报给你，未自行改动**（它不在 14 项验收里，
且会改变试跑的诊断可读性）。

---

## 8. 回滚与恢复方法

### 8.1 迁移失败的自动回滚（代码保证）

- 粒度：**以 entry 为原子单位**。任一步失败 ⇒ 删除**本次新建**的槽位、配置**不改**；
  幂等重放时已存在的相同槽位**不删**（不是我们建的）。
- 顺序（**永不颠倒**）：冲突检查 → 写凭据 → 立即回读逐字节校验 → 全部成功才改写配置 →
  重新解析校验 + 确认该 entry 明文已移除。
- **回滚失败 ⇒ 停止整个迁移并报告**，其余 entry 记为"未处理"，不再继续。
- 槽位冲突 / 无法可靠确认内容 ⇒ **停止且不覆盖**。

### 8.2 人工恢复步骤

1. **配置快照**：F0 **不额外写快照文件**（那本身就是"额外文件"）。真迁移前的配置即
   `app_preference.json` 本体；如需保险，**迁移前自行复制该文件**到安全位置。
2. 若迁移报"停止/失败"：配置**未变**（或已由代码还原），可直接重试；
   修复报出的原因（例如槽位冲突时先在凭据界面处理该槽位）后再重来。
3. 若要**丢弃**已写入的凭据槽位：在设置页对应请求头的「填写凭据」里更新为新值，
   或用 Windows「凭据管理器 → Windows 凭据」删除该槽位名（槽位名可在编辑器行内的
   「凭据引用」里读到）。
4. 若要**回退代码**：`git revert d9d1034 5a230c5 ca72922 191e4c1`（F0-1 视需要）。
   ⚠️ **顺序有讲究**：**若已经真的迁移过**（明文已搬进凭据槽位），回退代码并不会把明文
   搬回配置 —— 旧版 `OnlineMusicHeaderSpec.fromJson` 只读 `name`/`value`，会把
   `reference` 当成无关键忽略，于是那些请求头会以**空值**发出。
   正确做法：先把秘密从凭据槽位读回并写回配置（或在编辑器里重新填写明文），**再**回退代码。
   也就是说"回退代码"与"回退数据"是两件事，F0 不做自动的数据回退。

---

## 9. 独立 Review 结果

**执行方式**：另起一个**只读**审核者（不参与实现、无本次会话上下文），
自行读 Spec 与缺陷清单、自行看 `197e25b..d9d1034` 的 diff、自行重跑命令。
它**未修改任何文件**，并独立复跑 `flutter analyze`（No issues found，exit 0）与
`test/services/music_platform + test/page/settings_page`（**506 passed**）——
与我声称的数字**精确吻合**。

### 9.1 四个必答问题的裁定

| 问题 | 裁定 | 关键证据 |
|---|---|---|
| 1 明文禁止面（日志/报告/Git/备份/额外文件） | ⚠️ **无新增逃逸路径** + 设计内残留 | 落盘只有一条路径（controller→preference.save→writeTextFileAtomically）；F0 新增源码**零** logger/print/LogInterceptor；运行期不发明文（builder:137-170，0 请求）；诊断报告不含 onlineMusic；Git 侧我另行核对：F0 diff 内**无任何形似真实凭据的字符串**（只有 `*_TEST_ONLY` 夹具与槽位名） |
| 2 临时文件 | ✅ **clean** | F0 自身不建/不清理任何临时文件；唯一间接路径是既有原子写（失败即删、成功 rename）；既有 3 个 `playback_pref.json.tmp.*`（10-02）**未被触碰**，Debug 目录 0 个 |
| 3 半迁移路径 | ⚠️ **无未处理的半迁移**；两处"停止并报告"的半态 | 分支逐条核过（写前停止 / 写失败 / 回读失败 / 配置失败 / 重解析失败 / 回滚失败）；顺序永不颠倒；回滚失败 ⇒ `rollbackFailed` + stop ⇒ 其余 `skippedAfterStop`。**抓到 1 处报告不一致（已修，见 9.2-3）** |
| 4 界面不明文回显 / 不静默降级 | ✅ 主体 + ❌ **1 处标题** | 勾敏感后值输入框整行消失、凭据框 `obscureText`、写失败显式报错且不 pop；**❌ 迁移结果标题不看失败（已修，见 9.2-1）** |

### 9.2 审核发现 → 我的整改（提交 `ce17ff8`）

| # | 发现 | 我的处理 |
|---|---|---|
| 1 | ❌ **假阳性成功**：全部条目写失败但回滚成功时（`stopped=false`、`migratedCount=0`），结果标题是「没有需要迁移的内容」，与每行的"失败"自相矛盾；`report.anyFailure` 已实现却未使用 | **已修**：`anyFailure` 优先 → 标题「迁移未完成」；**新增用例**（F0-6 迁移失败时标题不得说"没有需要迁移的内容"） |
| 2 | ⚠️ 预览的「将迁移 N 项」把"已带引用/空值"也算进去，而计划会跳过 | **已修**：新增 `OnlineMusicHeaderFinding.actionable` 作为**唯一判据**，识别报告与迁移计划共用；预览另列「已用安全凭据引用（N 项，本次不动）」；**新增用例** |
| 3 | ⚠️ `_restore` 失败时磁盘已是改写版但 `report.settings` 仍是旧值 ⇒ 界面/内存与磁盘不一致，且文案与实际相反 | **已修**：该分支改为报**磁盘真实状态**，并写明"凭据已写入且未删除，请人工核对" |
| 4 | 🧹 `alsoRestoredConfig` 声明并传入但**从未被读取**（死参数） | **已删** |
| 5 | ❌ **测试标题不实**：`runtime_test` 那条"响应预览的非字符串/嵌套 JSON 也被遮蔽"实际只断言了 `describeDeclarativeRequest`，导致 P-35 的结构化遮蔽**零覆盖** | **已换成两条真测试**（非字符串值：数字/布尔/null；嵌套 JSON + 数组；并断言无关字段不被牺牲），另补一条"普通请求不被过度遮蔽" |
| 6 | 🧹 两处**与代码不符的注释**：F0-4 的"敏感头绝不把明文写进配置"（实际值仍留在表单里，拦下它的是保存校验）；F0-2 的"试跑与运行期完全同一条路"（读取口共用，但存储**读异常**两侧分类不同） | **两处注释均已订正为准确说法**，后者写明为已知差异（未在 F0 修） |
| 7 | ⚠️ 迁移进行中「检查」按钮可重入 | **已修**：加 `_migrating` 守卫，按钮禁用并显示"迁移中" |

### 9.3 审核发现但**我未修**的部分（已如实登记，等你裁定）

| # | 项 | 为什么没修 |
|---|---|---|
| 1 | 迁移写整份配置时，其它尚未处理的 entry 明文会随原子写进入瞬时 `tmp` 文件 | 与目标文件**本来就有**的内容一致、随即 rename/删除，**非新增暴露**；要彻底消除需改全应用的落盘方式 ⇒ 属扩范围，按规则先报（见 §7.3 边界 1） |
| 2 | `needs-user`（名字未命中但值可疑）请求头的**值**仍可能进入试跑摘要 | **既有**行为，不在 14 项验收内，且会改变试跑诊断可读性 ⇒ 按规则先报（见 §7.3 边界 2） |
| 3 | 响应预览脱敏仍是名字判据 ⇒ 服务端把凭据回显在**未列名**键下时仍会显示 | 名字判据的天花板；"凡不白名单即遮蔽"会摧毁诊断价值 ⇒ 登记为残留 |
| 4 | 规则 A 命中但**未勾敏感**的明文头仍会落盘并按明文发出（`sensitive:false`） | **与 Spec §11.4 情形③一致**（未标记 ⇒ 行为与今天完全一致），是设计内，不是回归 |
| 5 | 探测路径 `probeDeclarativeSearch` 调 builder 时未传 `headerCredentials` | 模板是**编译期闭集**且当前无敏感头；真出现会报"无凭据"（正确失败，不发明文）⇒ 登记 |
| 6 | `_restore` 失败 / `plaintextStillPresent` 两条分支**无测试覆盖** | 当前不变式下**无法由外部注入构造**（纯防御性分支）；已在代码注释写明。通过侧是覆盖的：每个迁移成功用例都必须先过这次重新解析校验 |
| 7 | `docs/` 未纳入版本控制 ⇒ 提交无法对着**固定版本**的 Spec 审计 | 项目既有约定（`docs/` 是未跟踪目录），非 F0 引入 |
| 8 | 保存时拒绝只在 **UI** 层（`OnlineMusicSettingsStore.write` 本身不校验） | 与 F0-1 的既有设计一致（校验在 `validationIssues` + 编辑器 `_submit`）；非 UI 的写入调用是同进程代码，当前不存在这样的调用点 ⇒ 登记 |

### 9.4 审核者核实为**真**的声明（对账）

- `flutter analyze` → No issues found；`506 passed`（它实跑）与我声称的一致；
  静态计数 489 / 486 / 506 逐个精确吻合（F0-4 / F0-3 / F0-5 各自那次）
- "3 处旧断言按新语义改写"确为**纠正 P-18 行为**，不是削弱测试
- F0-2 的 1217 与静态计数自洽（循环生成用例）

### 9.5 关于审核者提到的"工作区噪音"

它注意到 `test/_tmp_real_config_probe_test.dart` 短暂存在后消失。**那是我自己的临时只读探针**：
用于对真实配置跑识别报告（§2），**只读、不写配置、不含任何值、用完立即删除、从未被 git 跟踪**。
不是泄漏，也不在提交范围内 —— 在此说明以免被误读成异常。

### 9.6 审核者未能验证的项（与 §6 一致）

真机迁移未执行（本机 0 条明文，仅计数核实）／基线 1202 的整套未复跑（需切 commit）／
真实 Windows 凭据管理器语义未实机验证／F0 范围外其它写盘路径未审计。

---

## 10. 三条追加指令的执行结果（2026-10-09 第二轮）

用户指令：① 裁定两个安全边界；② 对最终 diff 与工作树做只读复核（重点：敏感值不进日志/摘要/测试报告/Git）；
③ 完成 Windows 安装版的真实凭据读写与迁移后重启验证。通过后冻结 F0，再单独做 F1 准入审查。

### 10.1 裁定（提交 `67dff99`）

| 边界 | 裁定 | 理由 / 落地 |
|---|---|---|
| **边界 1**：原子写的瞬时副本里会有"尚未迁移"的明文 | **接受，不扩范围改**（记为**边界属性**，不是缺陷） | 目标文件本来就有同一份内容、同目录、随即 rename 或删除；不是新增文件类别也不是新位置；要"连瞬时副本都不许有"必须改**全应用**的偏好落盘方式（F0 范围外）。见 §7.3 边界 1 |
| **边界 2**：`needs-user`（名字未命中、值可疑）的**值**会进入试跑摘要 | **判定为缺陷，修** | `needs-user` 的定义就是"还不知道是不是秘密"；名字白名单对它们**必然**漏，漏了就泄到界面。已给摘要加第三条判据：**值形态可疑的请求头也 `[redacted]`**（复用识别层同一个 `looksLikeSensitiveHeaderValue`，不新造判据）。代价：长但不敏感的请求头值也被遮蔽（名字仍在，够排查）—— 按"宁可多遮蔽"取。**只对请求头**做形状判据，query 参数不糊（否则用户自己搜的关键词也没了） |

### 10.2 只读复核证据（最终 diff `197e25b..d7b628e` + 最终工作树）

| 检查面 | 结论 | 证据 |
|---|---|---|
| **日志** | ✅ 无 | F0 的 13 个生产文件里 `logger.` / `print(` / `debugPrint` / `LogInterceptor` 命中 **0** 处 |
| **异常文案 / toString** | ✅ 无值 | 迁移报告的 `reason`/`stopReason` 逐条只用 **providerId + 请求头名 + 槽位名 + 静态文案**；`OnlineMusicRequestSpec.toString` 只打方法/路径/计数；`BuiltDeclarativeRequest.toString` 只打计数；映射层的 `DeclarativeMappingException` 全部是静态文案或**字段名**（`缺少必填字段 ${field.name}`），从不带值 |
| **测试报告** | ✅ 无 | 跑 F0 的 5 个测试文件（**79 passed**），把 **15 个夹具秘密**逐个在完整输出里计数 ⇒ **全部 0 次** |
| **Git** | ✅ 无 | F0 提交范围里 `chksz_*`/`sk-*`/`AIza*`/`ghp_*` 等形似真实凭据的模式命中 **0**；唯一的 `_TEST_ONLY` 字面量共 10 个、全是明示夹具；`[0-9a-f]{32}` 的 6 次命中经核对**全部是 git 自己的 commit 行**。改动文件 22 个，**无** 配置/构建产物（`app_preference`/`ListenaryData`/`.json`）进入提交 |
| **额外文件 / 临时文件** | ✅ 无 | F0 生产文件里 `dart:io`/`.tmp`/`File(`/`Directory(` 命中 **0**；既有 3 个 `playback_pref.json.tmp.*` 仍是 10-02、432B、未被触碰；工作树只有既有的两个未跟踪文件与 `docs/` |
| **真实配置** | ✅ 未被改写 | 会话中途该文件 mtime 变过（应用自身被启动过），复核内容仍是 **3 entry / 0 请求头 / baseUrl 3×合法**；SHA-256 已记基线，第 ③ 项验证前后**一致** |

### 10.3 真机验证（Windows 安装版路径 + Windows 凭据管理器）

**这一项暴露了一个只有真机才会出现的既有缺陷**（见下），修掉后验证通过。

| 步骤 | 结果 |
|---|---|
| 编译期路径 | `--dart-define=PORTABLE_BUILD=false` ⇒ `portableBuild == false`；`createChkszCredentialProvider(portableBuild: false)` 是 `PersistentChkszCredentialProvider`（**真 Windows 凭据管理器**，不是内存） |
| **真实读写** | 进程 1：真 `CredWrite` → 真 `CredRead` 读回**逐字节一致**（专用测试槽位 `listenary-f0-verify/selfcheck/raw`，42 字节假值） |
| **真实迁移** | 进程 1：对**合成配置**（不是用户配置）跑真 `OnlineMusicHeaderMigration` ⇒ `migrated=1`、配置里只剩槽位引用、`CredRead` 读回等于原明文、**原子写 0 个 tmp 残留** |
| **重启验证** | 进程 2（**全新进程**）：配置里无明文、只剩引用；**全新** `ChkszCredentialAccess`（无任何内存缓存）从 OS 读出凭据；实际构造请求（记录型 adapter，不联网）时 **请求头拿到了该值**、目标 host **未被替换** |
| **安全边界** | 只用 `listenary-f0-verify/...` 专用槽位，**从未触碰用户的 `PureMusic/...` 槽位**；验证后用 `cmdkey` 确认测试槽位 **0 个残留**；`%TEMP%` 验证目录已删；**用户真实配置 SHA-256 与验证前一致** |

**真机缺陷（已修，提交 `d7b628e`）**：全新进程里的**第一个**凭据调用，
`CredRead`/`CredDelete` 返回 FALSE 而 `GetLastError()` 是 **0（ERROR_SUCCESS）**；
从第二次调用起正确返回 `ERROR_NOT_FOUND(1168)`。实测序列：
`index0=threw(code=0)` → `index1/2/3=returned null`（三个独立进程一致）。
后果正好打在 F0 的关键路径上：重启后第一次凭据访问会把"槽位不存在"误判成"读取失败" ⇒
界面凭据状态读不出来、"清除凭据"抛错、**F0-5 迁移的冲突预检会把"不存在"判成"无法可靠确认"从而停止且拒绝迁移**。
修法（2 处判据，用户授权）：FALSE + ERROR_SUCCESS 这个自相矛盾的结果按"目标不存在"处理
（`read()`→null、`clear()`→幂等返回），并用单测把该组合钉住。

**未做（如实登记）**：
- **没有**构建/安装真实的安装器 Exe，也**没有**在 GUI 里点一次"开始迁移"再由人重启应用 ——
  本机没有可自动驱动 GUI 的集成测试通道；且重建 `build/` 有抹掉用户 Debug 数据目录的风险。
  **但代码路径本身没有条件编译**：`PORTABLE_BUILD` 只影响一个运行时 `bool`，
  因此"安装版分支"与便携版是**同一份已编译源码**，差别只在 `portableBuild` 的取值 ——
  上面用 `--dart-define=PORTABLE_BUILD=false` 跑的正是该取值下的真实行为。
- 安装包打包（Inno Setup）与 GUI 点击→重启的人工闭环，仍属**人工验收**。

### 10.4 复核中发现并说明的一处不一致

`decision_list_consistency_test`（项目自带的文档一致性守卫）在我改完测试数后**变红**：
它要求 `AI_PROGRESS` 里的"当前总数"与两份自检文档一致。我在 `AI_PROGRESS` 里写死的 1247
与整改后的真实数字不符 —— **守卫生效**。已把三处"当前总数"同步，并把 Home/Explore 那处
标注为**历史快照**（避免两份"最近验证"互相矛盾）。这也说明"一份信息写两处"确实会漂。

---

## 11. 阻塞项与下一步

- **无阻塞项**。F0 四件事 + 三条追加指令（裁定 / 只读复核 / 真机验证）均已完成。
- **按你的指令：通过后冻结 F0。** F0 的代码边界即 `197e25b..d7b628e`；**不再改动**，
  除非你提出新裁定。
- **F1 准入审查**请单独发起（F1 的准入条件与 P-01/P-19/P-20 有关，不在本报告范围）。
- 已登记、明确**不属于 F0** 的后续项（未动、未标记已修）：
  P-24（代码层缺陷类仍在；且其"真实配置实例"已按实测更正，见 §2.1）、
  portable 下的安全凭据存储、"一个能力多请求"（D2:B 模型边界）、
  以及 §9.3 里那 8 条 Review 残留（其中"响应预览按名字判据"是天花板、"探测未传 headerCredentials"是低风险）。
