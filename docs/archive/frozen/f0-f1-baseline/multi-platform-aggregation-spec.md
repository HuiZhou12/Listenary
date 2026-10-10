# Spec (Final) — multi-platform-aggregation

- Artifact ID: `spec-multi-platform-aggregation`
- Revision: 1（Final）
- Artifact status: `implementation-ready`（等待用户「确认架构，开始实施」）
- Goal：`docs/specs/multi-platform-aggregation-goal.md`（rev 1）
- Grill + Decision List：`docs/specs/multi-platform-aggregation-grill.md`（rev 1，**用户已全部确认**）
- 基线：`main` @ `2bfaaf0`
- 日期：2026-10-05
- **纪律：用户回复「确认架构，开始实施」之前，不修改任何源码 / 测试，不改变 main。**

---

## 1. 已确认决策（21 条）

| ID | 选择 | 规范含义 |
|---|---|---|
| D1 | **A** | 内容身份**只含** `(platform, remoteId)`；Provider 在每次调用时由路由决定，**不落库、不进身份** |
| D2 | **A** | 保留内部全局音质**抽象层**；由 Provider 声明"该平台支持哪些档位" |
| D3 | **A** | 平台参与 Search 的**硬条件 = 存在可用的 Stream 能力**；Lyric / Playlist 属可选增强，缺失只在被使用时给明确 `unavailable`，**不得阻止 Search** |
| D3b | **a** | 缺必要能力的平台**不出现在搜索平台筛选里**，并在设置页说明原因 |
| D4 | **A** | 选择粒度 = `(platform, capability) → 有序候选 Provider 列表`；默认取第一个支持该平台的 |
| D4b | **A** | **不**允许同平台多 Provider 并行聚合 |
| D5 | **A** | 允许回退：网络失败 / 超时 / 5xx / 未配置凭据；**禁止回退**：401/403、404、业务"资源不存在"、**空结果** |
| D5b | **B** | 回退**默认静默**（不弹提示）；但**必须保留可观测性**：内部记录回退原因、诊断信息能看出实际用了哪个 Provider、全部候选失败则返回最终错误 |
| D6 | **A** | 并行请求全部**已启用**平台；UI 提供「全部 / 各平台」筛选；结果保留平台分组与来源；各平台独立分页 |
| D6b | **a** | **不跨平台去重**（同名同艺术家也各自独立，因 remoteId / 歌词 / 播放 / 音质都可能不同） |
| D6c | **a** | 「加载更多」= 每个平台各加载各的 |
| D7 | **A** | 一个 Provider 只服务一个 Platform（`contentPlatform` 单值）；未来出现真实多平台代理需求再单独扩展 |
| D8 | **A** | 能力分配 UI = **每个平台一张卡**（卡头：平台 + 启用开关 + 不可用原因；卡内每能力选该平台下的 Provider） |
| D8b | **b** | Provider 创建后 **`contentPlatform` 不可修改**；需要别的平台请新建条目；未来若要改平台，作为独立产品操作，不进普通编辑流程 |
| D9 | **A** | 在线歌词一律走 **Provider 路由（按 Track platform）**；`lyric_sources` / `preferredOnlineSource` 继续只负责本地歌曲等范围外场景；**禁止**"在线曲目已带 platform 却仍走全局 preferredOnlineSource" |
| D10 | **A** | 全局偏好档位 + 每平台映射；平台无该档时回落到**不高于期望的最接近档位**并提示已回落 |
| D10b | **a** | 平台档位为**静态声明**（Provider 声明），不做运行期探测 |
| D11 | **A** | 本地文件歌单与在线歌单**不合并**；本阶段只保证 personal 在线歌单混平台可用 + 补测试 |
| D12 | **A** | Playlist 与 TrackList **保持一个能力**（`playlist` 覆盖元数据 + 曲目） |
| D13 | **A** | **不做一次性迁移**：旧 `capabilities{cap→providerId}` 在读入时解释为 `(该 Provider 的 contentPlatform, cap) → [该 Provider]` |
| **D14** | **确认** | `defaultProvider` **彻底退出实际业务路由**：只作旧配置兼容/可读字段，**不再参与** `(platform, capability)` 的候选解析、fallback 或默认选择。任何能力都必须**首先基于 platform + capability 找候选 Provider** |
| **D15** | **确认** | `invalidResponse`（映射失败）**不允许 fallback** —— 这是当前 Provider 的配置/映射错误，不应通过切换 Provider 隐藏。并且必须**区分两类"找不到"**：`endpointMismatch`（Provider endpoint / schema 配置导致）与 `notFound`（业务语义明确表示资源不存在）。**两者都不回退，但错误分类与用户诊断信息必须不同**；对用户自配 Path / Response Mapping 的声明式 Provider，必须明确告知「当前接口定义无法匹配响应」，不得让它看起来像普通的业务资源不存在。详见 §6.5 |

## 2. 用户补充口径（9 条，与上表同效力）

1. **D3 的真实意图**：不是四能力齐全才能搜；硬条件只有 **Stream**。Lyric / Playlist 缺失**不阻止 Search**，使用时明确 `unavailable`。
2. **D5b=B 的边界**：静默，但**必须可观测** —— 内部记录回退原因；诊断/调试信息能知道**实际使用了哪个 Provider**；全部候选失败时返回最终错误。
3. **D8b=b 的理由**：Platform 已参与 Track / Playlist / Lyric / Stream 的来源语义，把用过的 Provider 从 netease 改成 qq 会造成"已有内容来源与 Provider 语义不一致"。
4. **D2/D10 的关键约束**：全局质量枚举是**内部抽象/偏好层**，**不代表所有平台显示相同质量名称**。UI 必须按当前 Track 的 Platform 显示**该平台实际对应的名称与可用档位**（如 标准/无损/Hi-Res/SQ/臻品…）；内部通过平台映射把用户偏好对应到实际播放参数。**不得把平台差异强行统一成相同文案。**
5. **D6**：默认允许「全部」聚合搜索，同时允许按平台筛选；结果**必须始终保留 platform / remoteId 等来源身份**。
6. **D6b**：不强制去重，保留各 Platform 独立结果。
7. **D7**：暂保持一 Provider 一 Platform。
8. **D9**：已有 Online Track 的歌词请求**优先按 Track 的 Platform 进入新的 Provider 路由**；旧 `lyric_sources` 体系继续负责本地歌曲；**不得出现**在线歌曲带 platform 却无视来源走全局 `preferredOnlineSource`。
9. **本阶段最重要的不是补 Playlist/Lyric 接口**，而是让 **Source Identity 从数据产生开始一路贯穿**：`Search → SearchResult → Track → Playlist/PlaylistItem → Lyric → Stream → Quality`，**任何环节都不能丢失 Platform / remoteId**。

---

## 3. 核心不变量（本阶段的验收内核）

> **I1（来源不丢）**：任何在线内容对象（搜索结果项、Track、Playlist、PlaylistItem、歌词请求、播放解析、音质解析）在链路任何环节都必须可回答"它属于哪个 Platform、remoteId 是什么"。
>
> **I2（Provider 不进身份）**：`provider` 只决定"通过谁访问"，不进入对象身份、不落库；同一 `(platform, remoteId)` 在不同 Provider 下仍是同一首歌。
>
> **I3（按来源选 Provider）**：`resolve(ref, q)` / `fetchLyrics(ref)` 必须用 `ref.platform` 参与 Provider 选择；不存在"全局唯一 Stream/Lyric Provider"的隐式假设。
>
> **I4（平台差异不改写文案）**：音质等平台特有的呈现必须来自该平台自己的声明，不用内部抽象名称覆盖。

**I1 的可验证形式**（每条都要有自动化测试）：搜索结果每一项的 `ref` 可回溯到发起该请求的平台；`RemotePlaylist.platform` 与其 `tracks[*].ref.platform` 一致（订阅歌单）；personal 歌单条目的 platform 各不相同也成立；`resolve` 收到的 `expectedRef` 与队列项 `ref` 相同；歌词请求的 `ref` 与当前 Track 相同。

---

## 4. 目标架构

```
┌ 配置层（app_preference.json → onlineMusic）
│   providers[]: ProviderDefinition{ id, displayName, contentPlatform, capabilities{cap→binding} }
│   routing{ platform → { cap → [providerId, …] } }        ← 新增（D4:A）
└──────────────────────────────────────────────────────────
        ↓
┌ 装配层 OnlineMusicComposition
│   逐 definition 建一个 OnlineMusicProvider（复用 _ConfiguredMusicProvider：按 binding 分派 builtin/声明式/未配置）
└──────────────────────────────────────────────────────────
        ↓
┌ 路由层 OnlineMusicProviderRouter（改造 OnlineMusicProviderRegistry）
│   candidates(platform, capability) → 有序 List<OnlineMusicProvider>
│   过滤：platformsFor(capability).contains(platform) 且该能力已配置
│   顺序：用户配置的 routing[platform][cap] 优先，其后按 providers 列表顺序补齐
│   执行：按序尝试（D5 回退分类）→ 成功即返回；全失败抛最终错误
└──────────────────────────────────────────────────────────
        ↓
┌ 契约层 OnlineMusicService
│   search(platform)                    保留（单平台，供内部/筛选用）
│   searchAggregated(platforms)          新增：并行 + 每平台分页 + 每平台错误
│   playlistPlatforms / lyricPlatforms / streamPlatforms / searchablePlatforms（按 D3 门槛推导）
│   fetchPlaylist(platform,id) / fetchLyrics(ref) / resolve(ref,q) / defaultQualityFor(platform)
└──────────────────────────────────────────────────────────
        ↓
┌ 音质层
│   内部偏好层：MusicQuality（有序枚举，兼容旧 defaultQuality 字符串）
│   平台档位声明：Provider.qualityTiersFor(platform) → [QualityTier{ internalLevel, displayLabel, requestValue }]
│   解析：偏好 → 该平台档位（同级优先；否则"不高于期望的最接近"；再否则该平台最低档 + 记录）
└──────────────────────────────────────────────────────────
        ↓
┌ 模型层 models/music_models.dart
│   PlatformTrackRef（身份，不变）  MusicLyrics 增加只读 ref 回填  ResolvedStream 增加 servedByProviderId（仅诊断，不持久化）
│   新增 AggregatedSearchResult{ perPlatform: Map<MusicPlatform, MusicSearchPage>, failures: Map<MusicPlatform, OnlineMusicException> }
└──────────────────────────────────────────────────────────
        ↓
┌ 持久化 online_library（**预计零迁移**：(platform, track_id) 已是主键；personal 歌单已允许混平台）
└──────────────────────────────────────────────────────────
        ↓
┌ UI 设置页平台卡 / 搜索页平台筛选 + 来源标签 / 播放页按来源显示该平台音质名称
```

**复用而非重造**：`ProviderDefinition`、`CapabilityBinding`（builtin/http/unsupported）、请求/响应映射、HTTP 执行器、组合根、设置控制器、`HotkeysHelper`/`SettingsTile` 等 UI 惯例全部沿用第一阶段。

---

## 5. 配置结构与兼容读取

### 5.1 新增 `routing`

```json
"onlineMusic": {
  "providers": [ /* 不变 */ ],
  "routing": {
    "netease": { "search": ["chksz"], "stream": ["chksz"], "playlist": ["chksz"], "lyric": ["chksz"] },
    "qq":      { "search": ["qqProv"], "stream": ["qqProv"] }
  }
}
```

### 5.2 兼容读取（D13:A，不做迁移）

| 情况 | 解释 |
|---|---|
| `routing` 存在 | 直接用；缺省项按 §6.2 补齐 |
| `routing` 不存在、`capabilities` 存在（旧配置） | 对每个 `cap → providerId`：写进 `routing[该Provider.contentPlatform][cap] = [providerId]`；**不写盘** |
| 两者都不存在（更旧/默认） | 默认条目 `chksz` 的 `contentPlatform=netease`，四能力候选 = `[chksz]`（= 今天的行为） |
| `routing` 指向未注册 providerId | 忽略该项并在诊断中记录；若该 (platform,cap) 因此为空 → 该组合 `unavailable`（**不再静默回落默认 Provider**，见 §6.4） |

### 5.3 `defaultProvider` 的处置（**D14 已确认**）

D4:A + D7:A 之下，"能力 → 单个默认 Provider"这个平台无关的回落规则**不再成立**（它会让 qq 的内容掉到 netease 的 Provider 上，直接违反 I3 与 D3）。用户已确认：

- `defaultProvider` **保留为可读键**（旧配置不报错、不写盘改写）；
- **彻底退出实际业务路由** —— 不参与 `(platform, capability)` 的候选解析、fallback、默认选择；
- 其 UI 位置（「默认提供商」块）由 S8 的平台卡取代。

---

## 6. 路由规则

### 6.1 候选生成

```
candidates(platform, capability) =
    [ 用户 routing[platform][capability] 中已注册且 supports(platform, capability) 的条目 ]
  + [ 其余 providers 中 contentPlatform == platform 且 supports(platform, capability) 的条目，按 providers 顺序 ]
supports(platform, cap) := bindingFor(cap) != Unsupported && platformsFor(cap).contains(platform)
```
（D4b：候选**顺序执行**，不做并行。）

### 6.2 平台 × 能力支持集合

- `streamPlatforms` / `lyricPlatforms` / `playlistPlatforms`：由候选是否非空推导（与今天 `capabilities` 的推导方式一致，只是变成按平台）。
- `searchablePlatforms`（**D3 门槛**）= `{ p | streamPlatforms.contains(p) && (该平台至少有一个 Search 候选) }`。
- 缺少 Stream 的平台：**不进** `searchablePlatforms` ⇒ D3b(a)：不出现在搜索筛选里；设置页平台卡显示原因"缺少播放解析能力"。

### 6.3 执行与回退（D5:A + D15 确认；**fail-closed**：只有明确允许的才回退）

```
for provider in candidates(platform, capability):
    try:
        result = provider.<op>(...)
        return result              // 成功但空结果也直接返回：不回退、不报错
    catch e:
        if (canFallback(e) && 还有后续候选):
            记录诊断 {platform, capability, providerId, kind, attemptIndex}
            continue
        else:
            throw e                // 立即失败，保留原始分类与诊断
return 最后一个错误                // 全部候选失败
```

| `OnlineMusicErrorKind` | 是否回退 | 理由 |
|---|---|---|
| `network`（连接失败 / **超时**归此类） | **允许** | Provider 级故障，换一个可能成功 |
| `unavailable`（5xx / 服务暂时不可用） | **允许** | 同上 |
| `notConfigured`（该 Provider 未配置凭据，401 也归此类） | **允许** | 不是内容问题；换有凭据的 Provider 合理 |
| `quotaExhausted`(402) / `rateLimited`(429) | **允许**（D16 确认） | 该 Provider 暂时没有余量 / 被限流；换有额度的候选正是回退的合理用途，且不影响内容来源身份 |
| `endpointMismatch`（**新增**：接口定义 / 响应 schema 不匹配，见 §6.5） | **禁止** | 配置错误；换 Provider 会掩盖问题 |
| `invalidResponse`（映射失败） | **禁止** | D15 明确要求 |
| `notFound`（业务语义明确"资源不存在"） | **禁止** | 换 Provider 会造成来源语义混乱 |
| `businessFailure`（业务 code 表示失败 / 不存在） | **禁止** | 同上 |
| `forbidden`(403) / `badRequest`(400) | **禁止** | 认证 / 请求问题，非 Provider 故障 |
| `cancelled` | **禁止** | 用户取消 |
| `unknown` | **禁止** | 未知一律 fail-closed，避免掩盖问题 |
| **空结果**（成功但无数据） | **禁止**（也不视为错误） | 直接返回空结果 |

> 现有枚举（`lib/services/music_platform/online_music_error.dart:1-14`）为
> `{badRequest, notConfigured, quotaExhausted, forbidden, notFound, rateLimited, unavailable, businessFailure, invalidResponse, cancelled, network, unknown}`。
> 注意**没有**独立的 `unauthorized` 与 `timeout`：401 现归 `notConfigured`，超时归 `network`。本阶段新增 **`endpointMismatch`** 一个 kind。

### 6.4 诊断与可观测性（D5b:B）

- 静默：不弹 snackbar、不打断播放/搜索。
- 内部记录（保留最近 N 次）：`{ platform, capability, attempts: [ {providerId, errorKind} ], winnerProviderId }`。
- 暴露面：诊断/调试视图（以及播放信息面板可显示"由 X 提供"，只读）。
- 模型侧：`ResolvedStream.servedByProviderId`（**仅内存，不落库**）。
- 未注册 id 的忽略、回退发生、平台档位回落等一律进同一诊断记录。

### 6.5 错误分类与用户诊断（D15 细化确认）

**问题**：HTTP 404 与"业务说没有"这两件事，前者可能是**用户自己的接口配置错了**，后者是**这个资源真的不存在**。若都报成"找不到"，用户会去别处找原因，永远发现不了自己的 Path / Response Mapping 配错了。

| 场景 | 分类 | 用户可见文案（示例） | 诊断信息 |
|---|---|---|---|
| HTTP 404，Provider 为**声明式**（path 由用户配置） | **`endpointMismatch`（新增）** | 「当前接口定义无法匹配响应：请检查服务地址与请求路径（HTTP 404）」 | baseUrl + path + 候选 id |
| HTTP 404，Provider 为**内置**（path 由代码拥有） | `notFound` | 「音乐服务没有该资源」 | providerId + ref / playlistId |
| 成功判定**不通过**，但响应是合法 JSON 且能读到业务 code/msg | `businessFailure` | 「音乐服务返回失败：<code / msg>」 | code / msg（脱敏后） |
| 成功判定**不通过**，且响应不是可读 JSON / 无法判定业务语义 | **`endpointMismatch`** | 「当前接口定义无法匹配响应」 | 状态码 + 响应片段（脱敏截断） |
| 成功判定通过、但**字段映射失败** —— 声明式 | **`endpointMismatch`** | 「当前接口定义无法匹配响应：缺少必填字段 `<field>`」 | 缺失字段 + JSON 路径 |
| 成功判定通过、但字段映射失败 —— 内置 | `invalidResponse` | 「音乐服务返回了无法识别的数据」 | 同上 |
| 成功、但列表为空 | **不报错** | （正常空结果） | 记录"空结果，未回退" |

**实现要点**
- 声明式 Provider 知道"本次请求是用哪份绑定发出的"，因此能给出"接口定义不匹配"这一层诊断；内置 Provider 无此概念，保持原有分类（`notFound` / `invalidResponse`）。
- 新增 kind `endpointMismatch` **只影响分类与文案**；与 `notFound` 一样**禁止回退**（§6.3）；**不进内容身份、不落库**。
- 所有诊断沿用第一阶段脱敏规则（查询串与 JSON 键值对同时脱敏），不得把凭据或签名带进界面 / 日志。
- 该分类必须可被自动化测试断言（S2 验收项）。

---

## 7. 音质模型（D2:A + D10:A + D10b:a + 补充口径 4）

### 7.1 三层

| 层 | 内容 | 是否持久化 |
|---|---|---|
| **内部偏好层** | `MusicQuality`（有序枚举，沿用现有 7 个 key 以兼容 `defaultQuality='lossless'`） | 是（`AppPreference.defaultQuality`，字符串键） |
| **平台档位层** | `QualityTier { internalLevel, displayLabel, requestValue }`，由 Provider 声明 `qualityTiersFor(platform)` | 否（代码/模板声明，静态） |
| **播放参数层** | `requestValue` 传给该平台（ChkSz/netease：`exhigh`…；QQ：`sq`…） | 否 |

> 内部 key 沿用 `standard/exhigh/lossless/hires/jymaster/sky/jyeffect` 只是**兼容既有偏好字符串**，不代表这些名称会展示给用户，也不代表其它平台拥有同名档位。

### 7.2 偏好 → 该平台档位（解析规则，确定式）

```
tiers = qualityTiersFor(platform)            // 非空；空 ⇒ 该平台 stream 视为不可用(D3)
if 存在 tier.internalLevel == preference: 选它
else if 存在 tier 的内部序 ≤ preference 序: 选其中序最大者     // "不高于期望的最接近"
else: 选该平台最低档（并记录 "平台无更低档"）
```
- UI 显示 `tier.displayLabel`（**平台自己的名称**）。
- 回落发生时给出明确提示（"已回落为 SQ"），并进诊断记录。
- 用户切换档位时，**写入的是内部偏好级别**（保持跨平台语义）。

### 7.3 UI

- 设置页：默认音质一项改为「**偏好级别**」，并展示"各平台对应档位"的映射说明（只读）。
- 播放页：档位菜单**只列当前 Track 所在平台支持的档位，且用该平台的名称**；不支持的档位不出现（D2/D10 的核心要求）。

---

## 8. 搜索聚合（D6:A / D6b:a / D6c:a）

- 新增 `searchAggregated(Iterable<MusicPlatform> platforms, keyword, …)`：
  - 只接受 ∈ `searchablePlatforms` 的平台（D3 门槛）；
  - **并行**请求（`Future.wait`），单平台失败不影响其它平台；
  - 返回 `AggregatedSearchResult{ perPlatform: Map<platform, MusicSearchPage>, failures: Map<platform, OnlineMusicException> }`；
  - **不改动 `MusicSearchPage` 类型**（改动面最小）。
- UI：搜索页顶部「全部 / 网易云 / QQ / 酷狗」（只列可搜索平台）；每项结果带**来源标签**；"加载更多"按平台各自加载（D6c:a）；**不做跨平台去重**（D6b:a）。
- 每项结果保留 `ref.platform` + `ref.trackId`（I1/D6 补充口径 5）。

---

## 9. 歌词（D9:A + 补充口径 8）

- 在线 Track 的歌词**唯一入口**：`OnlineMusicService.fetchLyrics(ref)` → 路由按 `ref.platform` 选 Provider。
- 明确**禁止**：在线 Track 走 `lib/services/online_lyric/` 的 `preferredOnlineSource` 全局源。
- 旧 `lyric_sources(path, source, id)` + `LyricSourceType` 继续只服务**本地歌曲**（范围外，不改）。
- Provider 不支持该平台 / 无候选 ⇒ `unavailable`（明确文案），不静默换源。
- `MusicLyrics` 增加只读 `ref`（回填请求来源），使 I1 可测。

---

## 10. 声明式 Playlist / Lyric 开放

- 移除两处"第二阶段"守卫：`online_music_response_spec.dart:336-337`、`online_music_provider_settings_controller.dart:254-262`；能力编辑器的"第二阶段"禁用态改为正常可配。
- **实施前核实（2026-10-05，S7 准备阶段）**：**映射器缺失** —— 全仓只有
  `mapDeclarativeSearchResponse` 与 `mapDeclarativeResolveResponse`
  （`declarative/declarative_response_mapper.dart:47,106`），**没有**
  playlist / lyric 的映射器；`DeclarativeMusicProvider` 的 `fetchPlaylist` / `fetchLyrics`
  目前直接抛 `unsupportedCapability()`。
  ⇒ **只移除守卫会让用户存下一份"运行时静默 `unavailable`"的配置**，属于半成品，禁止。
  因此 S7 必须按 S7a / S7b 两步：
  - **S7a（映射落地）**：新增 `mapDeclarativePlaylistResponse` → `RemotePlaylist`、
    `mapDeclarativeLyricsResponse` → `MusicLyrics`，并接进 `DeclarativeMusicProvider`
    的 `fetchPlaylist` / `fetchLyrics`；用 fake transport + 结构样本测试。
  - **S7b（开放）**：确认 S7a 可用后再移除两处守卫并放开编辑器，补"可保存 / 可试跑 / 字段映射生效"的测试。
- 字段**定义**确实已完整（`domainFieldsFor(playlist|lyric)`、`requiredFieldsFor`），
  缺的是**映射实现**——这一点在评审 Spec 时被低估了，此处更正。
- **无真实服务样本** ⇒ 只能用结构/fake 验证；真实接通**标注未验证**（延续 MSAPI Stream 的口径）。

---

### 10.1 S7 实施状态与 S7b-3 接手指令（2026-10-05）

**已完成**：
- S7a `9cc3218`：`mapDeclarativePlaylistResponse` / `mapDeclarativeLyricsResponse` 落地并接进
  `DeclarativeMusicProvider.fetchPlaylist` / `fetchLyrics`。
- S7b-1 `33d0d15`：`validationIssues` 的 playlist/lyric 分支由"第二阶段"改为真实规则
  （playlist：至少要有 `fieldsRootPath` 或 `listPath`；lyric：至少一个歌词字段）。
- S7b-2 `947af85`：`testCapability` 去掉阶段短路，补齐 playlist / lyric 分支与
  `playlistId` 参数及前置条件（playlist 需歌单 ID、lyric 需曲目 ID）。

**未完成 = S7b-3（只碰 UI，一次做完再提交）**。逐处改动清单（行号以 `947af85` 为准）：

| # | 文件 | 位置 | 改动 |
|---|---|---|---|
| 1 | `page/settings_page/online_music_capability_editor.dart` | `:44-50` | 去掉 `isPhaseTwo(capability) ? null : …` 与 `'第二阶段'` 文案，改为始终 `onPressed: () => onEditCapability(capability)` / `label: const Text('配置')` |
| 2 | 同上 | `:1080-1082` | 删除 `isPhaseTwo` 函数（改完 #1 后无人引用，否则 lint） |
| 3 | 同上 | `:96-108` | `onTest` 的签名加第三个参数 `String? playlistId` |
| 4 | 同上 | `:461-463` | `_runTest` 调用处透传：`playlistId: widget.capability == OnlineMusicCapability.playlist ? _testTrackId.text.trim() : null`，`trackId` 反向同理 |
| 5 | 同上 | `:757` | 试跑字段标签由 `'试跑用的曲目 ID'` 改为对三者都成立的 `'试跑用的 ID（曲目 / 歌单）'`（复用同一个 `_testTrackId` 控制器，无需新增状态） |
| 6 | `page/settings_page/online_music_settings.dart` | `:197` | `onTest: (binding, trackId, playlistId) => _controller.testCapability(…, trackId: trackId, playlistId: playlistId)` |

**验收（S7b-3）**：能力列表里 playlist / lyric 不再显示"第二阶段"且按钮可点；能进入配置、保存后绑定正确；
`flutter analyze` 干净 + `flutter test` 全绿（含既有 15 个 widget 测试）。

**设计取舍（已定，不必再问）**：playlist 的试跑 ID 复用同一个"试跑用的 ID"输入框，而不是新增一个控制器 ——
三者互斥（一次只编辑一个能力），复用一个字段更少状态、更少出错面。

**仍未验证**：声明式 playlist / lyric 的**真实服务接通**（无真实样本）；只能用 fake transport + 结构样本证明映射正确。

**2026-10-07 复核**：上表 #1 / #2 / #5 已落地（`isPhaseTwo` 与「第二阶段」文案已移除、
试跑字段标签已改为「试跑用的 ID（曲目 / 歌单）」）。**#3 / #4 未按字面实现** ——
`onTest` 仍只有 `(binding, trackId)` 两个参数，playlist 试跑靠
`testCapability` 里的 `effectivePlaylistId = playlistId ?? trackId` 取到同一个输入框的值，
对外行为与 #3/#4 等价（playlist / lyric 都能试跑）。若将来要区分两个 ID，再按 #3/#4 改签名。

---

## 11. UI（D8:A / D8b:b）


- 设置页「在线音乐」：`服务提供商` 保留（含新建/编辑/删除/凭据）；`能力分配` 与 `默认提供商` 两块被**平台卡**取代：
  - 卡头：平台显示名 + 启用开关 + （不可用时）原因（如"缺少播放解析能力"）；
  - 卡内：每能力一行 → 选择该平台下的 Provider（或"未配置"）；
  - 未启用平台：不参与搜索、其内容的后续能力明确 `unavailable`。
- Provider 编辑：`contentPlatform` **创建后只读**（D8b:b）；需要新平台 → 新建条目。
- 搜索页：平台筛选 + 来源标签。播放页：按来源显示该平台音质名称。
- 视觉沿用现有设置页体系，不做整体重设计。

---

## 12. 持久化

- **本阶段目标包含"证明零迁移"**：`(platform, track_id)` 已是 `online_tracks` / `online_play_history` / `online_playlist_items` 的主键，`online_playlists.kind` 的 CHECK 已表达"歌单来源 ≠ 条目来源"。
- 若实施中发现必须变更 schema（触发条件：D1 改选 B、或平台档位需要落库、或需要记录 provider 来源），**立即停止并按 §16 报告**，不擅自改库。

---

## 13. 兼容性

- 默认 ChkSz 配置：搜索 / 播放 / 歌词 / 歌单行为与今天一致（含音质：ChkSz 声明的档位集合必须覆盖今天的 7 档或等价）。
- 旧配置（无 `routing`）可读并按 §5.2 解释；**不写盘改写**。
- 第一阶段全部既有测试继续通过。
- 用户现有数据（在线歌单、历史、收藏）不被静默破坏。

---

## 14. 最终实施方案（按真实代码重新划分，非照搬用户建议）

| 切片 | 范围 | 独立验收标准 | 明确不混入 |
|---|---|---|---|
| **S1 平台感知路由（无行为变化）** | `OnlineMusicProviderRegistry` → 支持 `candidates(platform, capability)`；`routing` 结构 + 旧 `capabilities` 兼容读（D13:A）；`CompositeOnlineMusicService` 改为走候选列表（首元素） | 现有测试全绿；新增：同能力多候选按序取首个、平台过滤、未注册 id 被忽略、旧配置解释正确 | 不做回退、不做聚合、不改 UI |
| **S2 受限回退 + 诊断（D5:A / D5b:B / D15）** | 候选按序尝试；fail-closed 回退表；**`endpointMismatch` 新分类 + 声明式/内置的 404 与映射失败区分**（§6.5）；静默；诊断记录（尝试/赢家/忽略项）；全失败返回最终错误 | 网络类错误回退成功且结果正确；**404 / 空结果 / 401 / invalidResponse / endpointMismatch 一律不回退**（各有测试）；**声明式 404 报"接口定义不匹配"、内置 404 报"资源不存在"（文案与分类都不同）**；诊断能读出实际使用 Provider；`ResolvedStream.servedByProviderId` 只读可见 | 不改音质、不改 UI |
| **S3 平台门槛与可用性（D3:A / D3b:a）** | `searchablePlatforms` = 有 Stream 且有 Search 候选；平台可用性 + 原因集合 | 缺 Stream 的平台不进搜索集合、且能给出原因；补齐 Stream 后自动进入 | 不做搜索 UI |
| **S4 多平台搜索聚合（D6:A / D6b:a / D6c:a）** | `searchAggregated` + `AggregatedSearchResult`（每平台 page + 每平台错误）；并行；来源保留 | fake 双平台并行；单平台失败不影响其它；关闭某平台后不参与；**不去重**；每项来源可回溯；分页各自独立 | 不改歌词/音质 |
| **S5 平台音质模型（D2:A / D10:A / D10b:a）** | `qualityTiersFor(platform)`；偏好→档位解析（同级/不高于期望最接近/最低档兜底）；回落提示；`defaultQualityFor` 改为走改档规则 | 不同平台显示不同文案；不支持档位不出现；无同级时按规则回落并有提示；旧 `defaultQuality` 行为兼容（默认配置下 ChkSz 结果不变） | 不改搜索/歌词 |
| **S6 来源感知歌词（D9:A）** | 在线 Track 歌词一律走 Provider 路由；新增 `MusicLyrics.ref`；**禁止**落到 `preferredOnlineSource` | netease track → netease Provider；qq track → qq Provider；设置 `preferredOnlineSource=qqmusic` 时 netease 在线曲目**不**被第二套接管（回归测试）；不支持时 `unavailable` | 不动本地歌词源 |
| **S7 声明式 Playlist / Lyric 开放** | 去掉两处"第二阶段"守卫；编辑器开放；补齐 playlist/lyric 的映射落地与试跑 | 声明式 playlist/lyric 可保存、可试跑、字段映射生效；结构测试覆盖；真实服务接通**标注未验证** | 不改路由 |
| **S8 设置页平台卡（D8:A / D8b:b）** | 平台卡（启用 + 原因 + 卡内每能力选 Provider）；`contentPlatform` 创建后只读；替换「能力分配」「默认提供商」块 | widget 测试：多平台渲染、不可用原因、只读平台；旧配置正常渲染 | 不做整体视觉重设计 |
| **S9 身份贯穿 + 兼容收尾** | I1 端到端不变量测试（Search→Track→Queue→Stream→Lyric→Quality）；默认 ChkSz 兼容回归；**零迁移证明**；文档 | `flutter analyze` + `flutter test` 全绿；I1 每条都有测试；schema 未变（可核 `latestAppDatabaseVersion` 与建表 SQL 不变） | 不做无关重构 |

顺序依赖：S1 → S2 → S3 → S4 → S5 → S6 → S7 → S8 → S9（S7 与 S5/S6 无强依赖，可提前）。

### 14.1 实施状态（2026-10-07 更新）

**S1–S9 全部完成；D17 已实现。** 分支 `feat/multi-platform-aggregation`（off `2bfaaf0`），
`main` 全程未被改动、未 push。最终验证：`flutter analyze` → `No issues found!`（exit 0）；
`flutter test` → **936 passed**（exit 0）。

S8 由四个提交落地（它必须一次做完：扩契约会打破 6 个实现 `OnlineMusicService` 的测试替身）：

| 提交 | 范围 |
|---|---|
| `8cf2e37` S8-1 | `OnlineMusicService` 增加 `searchAggregated` / `qualityTiersFor` / `selectQualityFor`（`CompositeOnlineMusicService` 加 `@override`），同步 6 个测试替身 |
| `30c68cc` S8-2 | 设置页**平台卡**（卡头 = 平台名 + 启用开关 + 不可用原因；卡内每能力一行选该平台下的 Provider）；`OnlineMusicSettings.enabledPlatforms`（空集 = 全部启用，落盘只在停用过时才写键）；注册表按启用集合过滤；`contentPlatform` 创建后只读；删除「能力分配」「默认提供商」两块 |
| `8e57312` S8-3 | 搜索页多平台聚合：默认「全部」走 `searchAggregated` 并行请求全部 `searchablePlatforms`；≥2 个平台时显示「全部 / 各平台」筛选；每行来源标签；**按平台各自分页**；单平台失败只影响该分组 |
| `c7ab4ac` S8-4 | 播放页档位菜单改为按**当前 Track 的平台**渲染 `qualityTiersFor(platform)`（平台自己的文案），回落时给出「已回落为 X」提示；平台无档位声明时回到内部档位列表（既有行为不变）；选中的内部偏好写回 `AppPreference.defaultQuality` |

**S8 的两个刻意的取舍（已写入代码注释，需人工确认）**：
1. 平台卡每个能力多了一个 **「自动」** 段位（= 清除该 `(platform, capability)` 的显式候选）。
   D17:b 之后"显式指定过"意味着隐式条目不再救场，因此必须给用户一条回到"自动"的路。
2. **不允许停用最后一个启用的平台**：`enabledPlatforms` 用空集表示"全部启用"，
   若允许关掉最后一个，"全部停用"会退化成"全部启用"。界面在该情形下禁用开关并给出说明。

---

## 15. 验证矩阵

| 验证方式 | 覆盖 |
|---|---|
| `flutter analyze` + `flutter test` | 每切片，提交前必须全绿 |
| 新增自动化测试 | S1 路由、S2 回退与诊断、S3 门槛、S4 聚合、S5 音质解析、S6 歌词来源、S7 声明式 playlist/lyric 映射、S9 I1 不变量 |
| widget 测试 | S4 搜索筛选与来源标签、S5 音质菜单、S8 平台卡 |
| 仓储级测试 | personal 在线歌单混平台（D11 的客观证明） |
| 零迁移证明 | `latestAppDatabaseVersion` 与建表 SQL 未变 + 旧数据读取测试 |
| **必须单独标记为未验证** | QQ / 酷狗真实服务接通；声明式 playlist/lyric 的真实服务样本；真实网络下的多平台并行表现；人工 Windows 验收 |

---

## 16. 风险与停止条件

**风险**
1. `routing` 结构变更影响旧配置 ⇒ 用 §5.2 兼容读 + 不写盘规避（D13:A）。
2. 音质改动可能让用户觉得"档位变少" ⇒ ChkSz 支持集合必须覆盖今天的 7 档。
3. 聚合搜索引入并行的错误处理复杂度 ⇒ 单平台失败与整体失败必须区分（§8）。
4. 声明式 playlist/lyric 无真实样本 ⇒ 只能结构验证，**不得声称已接通**。
5. `preferredOnlineSource` 与 Provider 歌词的边界若处理不当，会出现"来源错乱" ⇒ S6 必须有回归测试。

**立即停止并报告的条件（沿用用户 §26）**：必须大范围重构来源模型；必须改库且迁移语义无法确定；无法确定旧数据属于哪个平台；搜索聚合/多 Provider 选择/回退/音质映射出现新的产品取舍；需要扩大 Goal；需要改禁止项；同一问题修两次仍失败；无法客观验证；无法证明改动不破坏现有数据。

**派生项处置**
- **D14**：`defaultProvider` 退出业务路由 ⇒ **已确认**（2026-10-05），落地于 §5.3。
- **D15**：`invalidResponse` 不回退 + 两类"找不到"必须分类与诊断分离 ⇒ **已确认**（2026-10-05），落地于 §6.3 与 §6.5。
- **D16（已确认 2026-10-05）**：`quotaExhausted`(402) 与 `rateLimited`(429) **允许回退**。落地于 §6.3。
- **D17（已确认 2026-10-05，选项 b；已实现 2026-10-07，提交 `a35acba`）**：`notConfigured`（以及其它允许回退的错误）**只能回退到"用户显式指给该 `(platform, capability)` 的候选"**；
  **隐式候选不参与"救场"**。落地规则（修改 §6.1 的候选生成）：
  - 若 `explicitCandidateIdsFor(platform, capability)` **非空** ⇒ 候选列表 = **仅**这些显式条目（已注册且支持该平台+能力的），**不再按注册顺序补齐隐式条目**；
  - 若**为空** ⇒ 候选列表 = 按注册顺序推导的隐式条目（行为与本阶段之前一致），此时回退仍按 §6.3 的 fail-closed 表在隐式条目之间进行
    （用户没有表达偏好，故不存在"违背显式指定"的问题）；
  - 理由（用户口径）：避免"我为搜索指定的服务缺 Key 时，系统静默改用另一个我从未指派给搜索的条目"。
  - **实现点**：`provider/online_music_provider_registry.dart` 的 `providersFor`。
  - **实现时补充的一条语义（人工确认项）**：注册表内部那条**平台无关**的旧单值回落
    （`_explicitCapabilityProviders`，只在直接构造注册表、没有传 `explicitCandidates` 时使用）
    只有在"该 Provider 确实支持 `(platform, capability)`"时才被算作**显式**候选；
    否则该组合按"没有显式候选"处理，继续用隐式条目。
    这与配置层 `explicitCandidateIdsFor`（`contentPlatform != platform ⇒ 空`）的语义一致，
    也避免"一个 qq 条目的旧映射把 netease 的候选全部清空"。生产路径永远传 `explicitCandidates`，
    因此这条只影响直接构造注册表的测试/嵌入用法；`online_music_provider_selection_test.dart`
    的"S3 平台集合按候选求并集"用例正是靠它保持原语义。
  - **测试**：`online_music_provider_routing_test.dart` 改成"显式配置时只用这些候选"，
    新增"没有显式配置时才按注册顺序使用隐式候选"与"显式候选项不支持该平台时该组合没有候选"两条；
    `online_music_routing_settings_test.dart` 期望改为 `['neB']`；
    `online_music_settings_test.dart` 的"缺凭据不再静默回退到 playback 条目"改为以 `notConfigured` 失败
    （`winnerProviderId == null`，且 playback 只有 resolve 那一次请求）。
- 用户已回复「**确认架构，开始实施**」⇒ 本阶段状态转为 `implementing`，按 §14 的 S1–S9 推进，每切片独立验证后再提交。

---

## 17. Non-goals

- 不引入脚本 / 表达式语言 / OAuth2 子系统 / WebSocket / 多步工作流（第一阶段禁止项继续有效）。
- 不实现 QQ / 酷狗 的**具体 API 适配**（无真实样本；本阶段只保证模型与路由可接入）。
- 不合并在线歌词 Provider 与本地 `lyric_sources` / `LyricFormat` 两套机制（D9:A）。
- 不合并本地文件歌单与在线歌单（D11:A）。
- 不做播放队列持久化（队列仍为内存态，但已带 `ref`）。
- 不做整体视觉重设计。
- 不做一次性配置迁移（D13:A）。

---

## 18. 状态

- 本 Spec 为 **Final rev 1**。
- 2026-10-05：用户回复「确认架构，开始实施」⇒ 进入实施。
- **2026-10-07：S1–S9 与 D17 全部实施完成**（分支 `feat/multi-platform-aggregation`，
  HEAD `c7ab4ac`，`main` 仍为 `2bfaaf0` 未被改动、未 push）。
  最终验证：`flutter analyze` 无 issue（exit 0）、`flutter test` **936 passed**（exit 0）。
  收尾报告：`docs/history/provider-definition-multi-platform-s8-2026-10-07-report.md`。
- **仍未验证（不得声称已验证）**：QQ / 酷狗的**真实服务接通**；声明式 playlist / lyric 的
  **真实服务样本**（全程只有 fake transport + 结构样本）；真实网络下的多平台并行表现；
  **人工 Windows 验收从未进行**（S8 的三块 UI 只经过 widget 测试与静态分析）。
- **2026-10-08：§19 的 W1–W8 全部实施完成**（HEAD `f2490e9`）。
  `flutter analyze` 无 issue（exit 0）、`flutter test` **959 passed**（exit 0）。
  QQ 的真实搜索/歌单列表/歌单详情/歌词与网易云的搜索/歌单/歌词/播放解析**已真实跑通**（详见 §19.9 与收尾报告）；
  **QQ 播放解析因匿名需登录态而未接通**，**网易云的 3000 实例卡死**（用 3001 临时实例验证后已关闭）。
- **2026-10-08（同日）：长期路线第二段（全应用页面接入）完成一轮**（HEAD `529f22b`）：
  `flutter analyze` 无 issue、`flutter test` **961 passed**。逐页结论见 §20。
- **2026-10-08（同日）：长期路线第三段（新增聚合主页）完成一轮**（HEAD `e6d26e6`）：
  `flutter analyze` 无 issue、`flutter test` **966 passed**。主页功能与数据来源见 §21。
- **2026-10-08（同日）：长期路线第四段（完整性与回归验收）完成一轮**（HEAD `08f31d5`）：
  `flutter analyze` 无 issue、`flutter test` **968 passed**（本阶段起点 936 ⇒ 净增 32，测试只增不减）。
  审计结论、已知限制、真实服务 vs 模拟的分别结论见 §22；报告
  `docs/history/provider-definition-multi-platform-acceptance-2026-10-08-report.md`。
- **长期路线的四段（基础设施收尾 → 全应用页面接入 → 聚合主页 → 完整性与回归验收）均已完成**。
  **剩余的是需要用户或环境的事**：重启网易云 3000 实例、QQ 播放解析所需的登录态、
  **人工 Windows 验收**（含窄窗口/高 DPI 观感）、App 内真实服务端到端。

---

### 18.1 审计阶段确认的模型边界与决策（2026-10-09）

> 本节是**只读审计**（`197e25b`）的结论落点。完整内容见三份配套文档：
> - `provider-system-audit-2026-10-09.md`（现状 / 设计矛盾 / 用户场景失败点 / 安全专报 / 审计边界）
> - `provider-system-audit-defects-2026-10-09.md`（68 项缺陷复核：判定 / 级别 / 证据 / 三分类）
> - `provider-system-redesign-proposal-2026-10-09.md`（根因收敛 / 依赖图 / F0–F5 整改计划 / Scope 与 Non-goals / 风险 / 安全迁移与回滚）

**用户裁定（D1–D8）对本文档的修改**：

| 决策 | 对 Spec 的影响 |
|---|---|
| **D1:A 支持静态常量参数** | §5 配置结构需增加"固定值参数"，原"来源封闭"表述修正为"**来源封闭 + 允许静态常量**" |
| **D2:B 不支持"一个能力多请求"** | **本节正式确立为模型边界**：不得声称支持多请求 API 编排；QQ 榜单/复杂艺人页待真实样本后单独设计。§3 不变量不受影响 |
| **D3 拆分认证** | 支持"静态 Cookie / 敏感请求头值 + 安全凭据引用"；**不承诺**自动登录、Cookie 生命周期、动态签名、令牌刷新；**不支持的认证方式必须明确报出边界，不得静默忽略**（修正 §5 认证闭集表述） |
| **D4:A** | `null` 与缺失同义、转换集合有限 —— **接受为边界**，但必须在配置界面 / 本 Spec / 诊断中写明支持范围；**不支持的转换必须在保存或试跑时明确报错，不得静默返回 null** |
| **D5:A 支持自定义平台标识** | 平台需"**稳定唯一 ID + 展示名分离**"；**未知平台不得静默回落 netease**；平台身份必须贯穿 Track / PlaylistItem / Lyric / Stream / Quality 路由；**不得为自定义平台推翻现有来源身份模型**（§3 不变量 I1 仍成立） |
| **D6:A 安全迁移** | 敏感请求头改为**凭据引用**；迁移需**逐项**处理、不可靠识别者**不删不合并**并提示重配；**不得以保留明文为最终方案**；必须含迁移与迁移失败测试（修正 §12 持久化章） |
| **D7:A 重启生效维持** | 维持 §5/§19 的"条目/能力/路由重启后生效、凭据立即生效"；UI 必须显式区分**草稿 / 已保存待重启 / 运行时生效**三态；"试跑成功 ≠ 已投入运行" |
| **D8:A** | 授权落盘上述三份文档（**仅文档**） |

**审计发现的两条与既有 Spec 冲突、需按本 Spec 修正实现的项**：
1. **§19.5「不得因缺少探测模板而隐藏能力入口」** —— 审计发现探测被实现成"2 个写死模板的服务指纹"，且只有 search 能露出，**违反本 Spec**（缺陷 P-05/P-07/P-52）。
2. **§6.4「回退静默但必须可观测」** —— 审计发现 `routeLog`/`servedByProviderId` **没有接口出口也没有 UI 呈现**，**违反本 Spec**（缺陷 P-29）。

**公开的模型边界（本阶段不做，不是缺陷）**：多请求编排（D2）、自动登录/动态签名/令牌刷新（D3）、`null` 与缺失区分及更多转换（D4）、"保存即生效"（D7 维持重启生效）。

---

## 19. 第二轮确认（2026-10-07，人工验收后）

> 本节是**当前唯一待实现清单**；与前面章节冲突时，以本节为准。

### 19.1 用户新确认的三个决定（① `0058fc1` ② `a8791bb` ③ `a8791bb` —— **均已实现**）
1. **去掉播放页写回 `AppPreference.defaultQuality`**（S8-4 引入的行为变更要回退：播放页切档位不再改全局偏好）。
2. **删除设置页的「· 默认」标记**（D14 后 `defaultProvider` 已不参与路由，保留会误导）。
3. **补上 §7.3**：设置页默认音质改为「**偏好级别**」，并展示"各平台对应档位"的只读映射说明。

### 19.2 问题 1 → **方案 A（已确认）**：新增第 5 个能力 `playlistCollection`
- 新增 Provider 能力 **`playlistCollection`（歌单集合 / 歌单列表）**，与现有 `playlist`（歌单详情 + tracks）**并列**。
- 新增领域类型 **`RemotePlaylistSummary{ platform, id, name, coverUri, creator, trackCount }`**，**不含 tracks**。
- 设置页把现有「歌曲列表」改名为「**歌单详情**」，并新增「**歌单列表**」能力配置。
- 与 **D12 不冲突**：D12 说的是"歌单详情与其曲目列表不拆"，这里拆的是"**歌单集合**"与"**单个歌单详情**"两个业务语义。
- 落地范围：`OnlineMusicCapability` 枚举、`OnlineMusicProvider` 契约（`fetchPlaylistCollection`）、按能力路由、
  声明式模型（新能力的请求/响应字段与映射器）、组合根分派、设置页与能力编辑器、必要的领域字段（歌单集合字段集）。

### 19.3 QQ 真实音质契约（**以真实源码为依据，禁止编造**）
```
qq-music-api/getMusicPlay.ts : type AudioQuality = 'm4a' | '128' | '320' | 'ape' | 'flac';  DEFAULT_QUALITY = '128'
qq-music-api/api-metadata.ts : quality.enumValues = ['m4a','128','320','ape','flac']，defaultValue '128'
播放解析参数                  : { songmid, quality, resType }   （resType = 'play'）
```
- QQ 的档位 `requestValue` **只能是** `128 / 320 / flac / ape / m4a`；**严禁**使用未经真实依据的 `sq` 等值
  （早先 Spec 草稿里的 `sq` 是编造的，**作废**）。
- **展示名用平台自己的取值**；内部档位映射是我们的抽象，必须标注为我们的决定。
- 首批只落地语义明确的 **128→standard、320→exhigh、flac→lossless**；`ape` / `m4a` 暂不暴露，
  并在报告中标注"真实语义待确认"。

### 19.4 真实服务（必须真跑并如实记录）
- **3000 = 网易云**（`api-enhanced`，README：默认端口 3000）；**3200 = QQ**（`qq-music-api`，用户确认本阶段所用能力**无需登录**）。
- 必须真实验证：搜索、歌单列表、歌单详情、歌词、播放解析、各档位对应参数、原始响应→领域模型的映射。
- **8080 = `go-music-api` 是聚合/归一化响应，不视为酷狗原生接口契约**；**酷狗真实协议继续标记为未验证**。
- 结果如实标注；**不得**把模拟结果描述成"真实服务已验证"。

### 19.5 能力配置与"探测 / 试跑"的边界（用户第 5、6 条）
- **五个能力**（search / playlist / playlistCollection / lyric / stream）都必须支持"未知服务无法自动探测时仍可手工配置 + 试跑验证"。
- **探测不是能力存在的前提**：没有探测模板**不得**隐藏能力入口，**不得**再标记"第二阶段"。
- **职责必须不同**：**探测** = 服务级（baseUrl 可达性 + 协议基本形态），面向**条目**而非每个能力；
  **试跑** = 用**当前编辑中的**配置发一次真实请求，展示请求信息、HTTP 状态、原始响应（脱敏）、映射结果与错误分类。
- 错误分类需可区分：网络 / HTTP / 认证 / 业务 / 响应格式 / 映射失败。
- **脱敏必须覆盖**：查询串、JSON 键值对、**`Cookie` / `Authorization` 等敏感请求头**；不得把秘密写入普通日志。
- **配置隔离**：试跑只读当前编辑中的配置，不得改写正式配置、播放状态或其它 Provider 的设置。

### 19.6 搜索页（问题 3 / 4）
- **来源标签改为轻量辅助信息**：不得占固定大块横向空间、不得挤压歌曲标题；标题/艺术家/专辑需有合理布局、间距与溢出处理；
  不得影响点击播放、选中态与上下文菜单；沿用现有设计体系。
- **平台选择**：默认「**全部**」⇒ 对所有满足门槛的已启用平台**并行搜索**；**单平台模式只请求该平台**
  （**推翻**早先假设 #5 的"只做显示过滤、不重新发请求"）。
- 平台列表由**实际能力与启用状态**动态生成（不得把未配置/不满足门槛的平台伪装成可用）；
  分页状态**按平台隔离**；单平台失败不影响其它平台结果；筛选不改变歌曲真实来源身份。

### 19.7 音质缺陷（**已全部修复**：A/B 于 `0058fc1`；降权提示于 `b917659` = 方案 B）
- **缺陷**：`quality_menu_button.dart:56` 用 `tier.internalLevel` 作为选中值 → `page.dart:756/768` → `session.switchQuality(level)`
  → `_requestedQuality` = **内部档位** → 一路传给 `resolve(ref, requestedQuality:)`。
  ⇒ **QQ 曲目会收到网易云的档位参数**（`lossless` 而不是 `flac`）。只有"从列表开始播放"那条路（`defaultQualityFor(platform)`）做了转换。
- **缺陷**：`remote_playback_queue_controller.dart:188-203` 的降级候选**仍按 `MusicQuality.values` 下标**生成 —— 违反"不得仅用枚举下标推断平台真实等级"。
- 要求：解析时**必须**把内部偏好按该 Track 所属平台的档位声明转换成**平台请求值**再发出；降级同样基于**平台档位**而非内部枚举下标；切歌必须重新按新 Track 的来源平台解析，**不得沿用上一首的平台专属参数**。

### 19.7.1 第三轮收尾（2026-10-08）

- **默认落地页 = 聚合主页**（用户确认）：`556ed29`。**两处默认值必须同步改**
  （字段初始值 `preference.dart` 的 `startPage` + 加载路径 `applyStoredMap` 的 `defaultValue`），
  只改一处会被加载路径的 `0` 覆盖；`test/core/preference_start_page_test.dart` 守住两者一致。
  **不做迁移**：已存过该键的老安装仍沿用用户自己的选择。
- **降权提示缺陷 → 方案 B 已实现**：`b917659`。
  判定搬到档位模块的纯函数 `resolveQualityDowngrade`（按**平台档位序**；**认不出该取值就不提示**，绝不误报）；
  `RemotePlaybackSessionController` 只做委托，且**签名只用核心类型** ——
  `lib/play_service` 不得依赖 provider 层类型（`online_music_dependency_boundary_test` 守住这条边界）。
  回调 `onQualityDowngraded` 现在携带**要展示的档位名**（平台自己的文案），`entry.dart` 不再用内部枚举反查。
  测试：`test/services/music_platform/online_music_quality_downgrade_test.dart`（9 条）+ 会话控制器转发用例。
- **验收**：`flutter analyze` 无 issue；`flutter test` **981 passed**（972 → +9）。
- **主页 UI 需要重做**：用户明确交给另一个会话；本阶段不再改主页视觉。

#### 真实服务验证（2026-10-08 第三轮，实测）

| 服务 | 结果 |
|---|---|
| 网易云 `127.0.0.1:3000` | **已由用户重启、恢复可用**。`/search` → `code=200`（命中「海阔天空」）；`/song/url/v1` 四档（standard/exhigh/lossless/hires）**均 HTTP 200、都拿到 url**，但**匿名一律 `br=128008` 且 size 相同** ⇒ 档位**差异**仍无法真验（需登录/VIP）；可确认的是我们的档位参数**被服务接受**（无参数错误）。 |
| QQ `127.0.0.1:3200` | 服务本身可用（`/user/getCookie` 已返回配置的 cookie；`service-config.json` 的 `fallbackMode` / `useGlobalCookie` 均为 true）。**但 `/getMusicPlay` 三档（128/320/flac）都返回 `url:""`，错误为「Cookie 已失效或 uin 缺失」**；把 cookie 显式放进查询串同样失败 ⇒ **这条 cookie 被上游 QQ 拒绝**，不是本地配置问题，也**不是**我们的档位取值有问题。⇒ **QQ 播放解析继续标记未验证**，需要一条**有效的** QQ 登录 cookie。 |
| 酷狗 | 无原生服务；`go-music-api` 是聚合/归一化响应，不算原生契约 ⇒ **仍未验证**。 |

### 19.8 仍未验证（不得声称已验证）
酷狗真实协议；真实网络下的多平台并行/超时/限流表现；人工 Windows 验收。

---

### 19.9 实施状态：第一段 W1–W8 **全部完成**（2026-10-08）

分支 `feat/multi-platform-aggregation`，本轮 HEAD `f2490e9`（回退单点 `c7ab4ac`）；
`main` 仍为 `2bfaaf0` 未被改动、未 push。
最终验证：`flutter analyze` → `No issues found!`（exit 0）；`flutter test` → **959 passed**（exit 0，基线 936 ⇒ 净增 23）。
报告：`docs/history/provider-definition-multi-platform-infrastructure-2026-10-08-report.md`。

| 项 | 状态 | 提交 | 要点 |
|---|---|---|---|
| W1 音质缺陷 | ✅ | `0058fc1` | `resolve` 按该 Track 平台的档位声明把内部偏好转成平台请求值；降级链基于平台声明；去掉播放页写回偏好；切歌按新平台重解析 |
| W2 QQ 真实档位 | ✅ | `0058fc1` | `qqQualityTiers`（`128→standard`/`320→exhigh`/`flac→lossless`，`ape`/`m4a` 暂不暴露）；依据 = `api-metadata.ts` 的 `enumValues`（本轮已亲自核对源码） |
| W3 `playlistCollection` | ✅ | `cac2207` | 新能力 + `RemotePlaylistSummary` + 声明式映射器 + 契约/组合根/候选链；7 个测试替身同步 |
| W4 设置页/编辑器 | ✅ | `cac2207` | 「歌单详情」/「歌单列表」文案；五能力都有配置入口；歌单列表不需要试跑 ID |
| W5 探测/试跑 | ✅ | `f2490e9` | 试跑展示请求摘要（含参数名与值）+ 失败大类（网络/HTTP/认证/业务/响应格式/映射/配置）；脱敏覆盖 `Authorization`/`Cookie` 等敏感头；配置隔离有测试 |
| W6 搜索页 | ✅ | `1b95ab7` | 来源标签轻量化（行尾小圆点+小号低对比文字）；**单平台模式只请求该平台**；单平台时显示「当前平台：X」 |
| W7 设置页音质 | ✅ | `a8791bb` | 「偏好级别」+ 各平台档位只读映射 |
| W8 去掉「· 默认」 | ✅ | `a8791bb` | Provider 行不再显示默认标记（字段仍可读） |

**真实服务实测结论（详见报告 §5）**
- **QQ（3200）**：搜索 ✅、歌单列表 ✅、歌单详情 ✅、歌词 ✅；
  **播放解析 ✗** —— 匿名返回「播放链接需要登录态才能获取…传递有效 Cookie」，
  与"本阶段所用能力无需登录"的用户口径**冲突**；按红线未触碰任何凭据文件 ⇒ QQ `stream` 标记**未接通/未验证**。
- **QQ 实测字段修正**：搜索是 `response.data.song.list[*]` 的 **`mid`/`name`/`singer[].name`/`album.mid`/`interval`**；
  **传 `remoteplace=song` 会返回空结果**；歌单详情在 **`response.cdlist[0]`**；歌词在 `response.lyric`
  （`isFormat=1` 时为对象 `{lyric,trans}`，否则为纯字符串）；`getSongLists` **不返回曲目数**。
- **网易云（3000）**：该实例**整体卡死**（根路径 200，一切 API >70s 超时；本机直连 `music.163.com` 200、代理 7890 亦 200）。
  用同一份代码临时新起 3001 实例后**全部正常**（用完已关闭）：搜索 ✅、`/top/playlist` ✅、`/playlist/detail` ✅、
  `/lyric` ✅、`/song/url/v1` ✅。⇒ 判定为**用户那台 3000 进程自身卡死**，需重启（本轮未重启，避免干预用户服务）。
- **网易云匿名只给 standard**：`/song/url/v1` 请求 `standard/exhigh/lossless/hires` 四个档位都返回同一条
  `br=128012`、`level=standard` 的 URL（真实降级）⇒ 高音质需要登录态。
- **接口字段差异（重要）**：`/search` 用 `artists/album/duration`，`/cloudsearch` 与 `/playlist/detail` 用 `ar/al/dt`；
  声明式字段路径必须按所选接口写。

---

## 20. 长期路线：第二段「全应用页面接入」（2026-10-08）

> 本节记录**逐页审计**的结论与落地状态；与前面章节冲突时仍以 §19 为准。

### 20.1 状态

**第二段已完成一轮（提交 `4a0c1a6`、`529f22b`）**：在线音乐相关的页面全部接入或明确标注"保持本地语义"。
验证：`flutter analyze` 无 issue（exit 0）、`flutter test` **961 passed**（exit 0）。
报告：`docs/history/provider-definition-multi-platform-pages-2026-10-08-report.md`。

### 20.2 逐页结论

| 页面 | 结论 |
|---|---|
| 在线搜索 `online_music_page` | ✅ W6 已接入（来源标签 + 单平台只请求该平台 + 平台筛选） |
| 在线歌单订阅 `online_playlists_page` | ✅ **本轮接入**：添加订阅可选来源平台（`capabilities.playlistPlatforms` 驱动、无候选 fail-closed）、ID 校验按平台、列表逐行标注来源 |
| 统一歌单页 `playlists_page` | ✅ **本轮接入**：同上 + 订阅项副标题显示平台 |
| 订阅详情 `online_playlist_detail_page` | ✅ **本轮接入**：头部显示订阅平台，每行按曲目 `ref` 标注来源 |
| 自建在线歌单详情 `personal_playlist_detail_page` | ✅ **本轮接入**：混平台（D11）时逐行标注来源 |
| 在线收藏 `favorites_detail_page` | ✅ **本轮接入**：逐行标注来源 |
| 在线历史 `stats_page/online_history_stats_view` | ✅ **本轮接入**：逐行标注来源（共用 `OnlineSourceLabel`） |
| 播放队列 `current_playlist_view` | ✅ **R6 已接入**（本行原为"⏸ 审计后不改"；现按本行**自己给出的路径**实现）：给 `ActivePlaybackSessionItem` 加**可空** `sourceLabel`，本地构造点**一个字未改**；在线投影时填 `musicPlatformLabel(item.ref.platform)`，`_RemotePlaylistItem` 副标题行尾复用 `OnlineSourceLabel`。见 `docs/history/home-explore-r6-report.md` |
| 本地艺术家/专辑/歌曲/文件夹/本地歌单页 | ⏸ **保持本地语义**（审计确认无在线依赖） |
| 设置页在线音乐 / 能力编辑器 | ✅ W5/W7/W8 已平台化 |
| 设置页本地歌词源（QQ/酷狗/网易） | ⏸ **不动**（D9 边界，`online_lyric_source_boundary_test` 守卫） |

### 20.3 新增共享件（避免规则走偏）

- `component/online_playlist_source.dart`：`onlinePlaylistPlatformsOf(context)`、`validateOnlinePlaylistId(...)`
- `component/online_playlist_draft.dart`：`OnlinePlaylistDraft{platform, id}`（来源身份从 UI 起完整）
- `component/online_source_label.dart`：`OnlineSourceLabel`（轻量来源标记，已用于结果行与历史行）

### 20.4 仍未验证（沿用 §19.8 + §19.9）

QQ 播放解析（匿名需登录态）；网易云 3000 实例卡死待重启；酷狗真实协议；真实网络下多平台并行表现；
**人工 Windows 验收从未进行**；App 内的歌单订阅端到端流程未在真实服务上跑过（只有接口级真实 curl 证据）。

---

## 21. 长期路线：第三段「新增聚合主页」（2026-10-08）

### 21.1 状态

**第三段已完成一轮**（提交 `e6d26e6`）：主页落地并接入侧边栏（首位）与路由。
`flutter analyze` 无 issue（exit 0）、`flutter test` **966 passed**（exit 0）。
报告：`docs/history/provider-definition-multi-platform-home-2026-10-08-report.md`。

### 21.2 主页 = 组合与呈现，不重复实现

| 区块 | 数据来源 | 类型 |
|---|---|---|
| 平台状态（5 项能力 + 不可用原因 + 未配置） | `OnlineMusicService.capabilities` | 能力状态 |
| 最近播放（逐行来源标签，点击按历史起播） | `OnlineHistoryController` | 应用内部数据 |
| 我的收藏（跨平台，逐行来源标签） | `PersonalOnlinePlaylistController.readFavorites()` | 应用内部数据 |
| 我的在线歌单（混平台自建） | `PersonalOnlinePlaylistController.snapshot` | 应用内部数据 |
| 平台歌单（按平台分组、各自加载、可订阅） | `OnlineMusicService.fetchPlaylistCollection` | **平台原生内容**（W3 能力） |

**未做的数据源（如实记录缺失能力）**：平台原生推荐 / 排行榜 / 登录态账号数据 ——
本地服务里没有原生契约依据，**不实现、不编造 API**；将来接入须先扩展 Provider 能力。

### 21.3 融入现有结构的约束（本轮遵守）

- 侧边栏：主页放**第一位**；第一个分组改名「聚合」；**分组数量与各下标前的分组头数量不变** ⇒
  既有侧边栏几何与依赖它的布局/缓存行为不变。
- 路由：`HOME_PAGE = '/home'` 作为状态化外壳的**第一个 branch**（与侧边栏顺序一致）。
- 启动页：`HOME_PAGE` **追加**在 `START_PAGES` 表尾（`HOME_START_PAGE_INDEX = 5`）；
  **不得**插到表中间（`AppPreference.startPage` 按下标存储）。
- **默认落地页保持「音乐」**（不改 `startPage` 默认值，避免静默改变用户启动页）；
  主页在侧边栏第一项，点击后即被记为启动页。
- 主题 / 播放栏 / 窗口行为未改动；主页不重复实现搜索/歌单/播放/收藏。

### 21.4 验收（本轮）

- 自动化：`test/page/home_page_test.dart` 5 条（空状态 / 能力与原因 / 跨平台来源标签 /
  单平台失败隔离 / 订阅来源身份）+ 侧边栏两个测试更新；全量 **966 passed**。
- **未验证**：真实平台歌单在默认配置下看不到数据（默认条目没有「歌单列表」能力，UI 已说明）；
  窄窗口与高 DPI 观感；人工验收。

---

## 22. 长期路线：第四段「完整性与回归验收」（2026-10-08）

> 报告：`docs/history/provider-definition-multi-platform-acceptance-2026-10-08-report.md`。
> 本轮补了 2 条守卫：`START_PAGES`/侧边栏目的页**不允许重复路径**、主页**窄窗口不溢出**。

### 22.1 审计结论

| 审计项 | 结论 |
|---|---|
| 页面/组件里的单平台硬编码 | **无不合理项**：剩下的都是"注入式单平台测试通道"、"平台特有输入提示"、新建条目默认值、无 service 时的测试回落 —— 全部有注释与理由 |
| I1 搜索→歌单→队列→歌词→音质 | **全链路有测试**（逐环节证据见验收报告 §3.2） |
| 加载/空/错误/分页 | 搜索页（含按平台分页）、主页（含单平台失败隔离）、订阅/收藏/历史状态机均有测试 |
| 设置改动后页面更新 | 平台/能力改动"下次启动生效"（界面已提示）；同一次会话内页面与服务读同一份 `capabilities`，无中间态 |
| 旧配置与网易云兼容 | 默认兼容回归、旧 `capabilities` 读法、**零迁移契约**、网易云"内部键 == 请求值"与降级链等价性均有测试 |
| 静态分析 / 全量测试 | `flutter analyze` 无 issue；`flutter test` **968 passed**（起点 936 ⇒ 净增 32） |

### 22.2 已知限制（**不是"已完成"**，需人工确认）

1. **非网易云平台的"音质降级提示"不触发**：会话层用内部档位比较平台返回的 `actualQuality`，
   平台取值（`128/320/flac`）查到内部下标 -1 ⇒ 不弹提示（也不误报）。**请求参数与播放均正确**。
   两个候选修法（见验收报告 §4.1）：(a) 在 `resolve` 的 stamp 里把平台取值反查回内部档位
   （会改变该字段语义）；(b) 让会话层拿到平台档位声明，在平台序上判断（改动面更大、语义最干净）。
2. **平台原生推荐 / 排行榜 / 登录态账号数据**：本地服务无原生契约依据 ⇒ 未实现、未编造。
3. **主页「平台歌单」在默认配置下无真实数据**（默认条目没有「歌单列表」能力）⇒ UI 显示"未配置 + 去配置"。
4. ~~**播放队列行不加来源标签**（第二段审计结论）。~~ → **R6 已解决**：按该结论自己给出的
   路径（可空 `sourceLabel`）实现，在线队列每一行都标出来源，本地观感不变。
5. ~~**默认落地页仍是「音乐」**（第三段假设 1；改成主页只需改一处默认值）。~~ → **`556ed29` 已改为聚合主页**。

### 22.3 真实服务 vs 模拟（分别结论）

- **真实服务**：QQ 搜索/歌单列表/歌单详情/歌词 ✅、**播放解析 ✗（匿名需登录态）**；
  网易云 搜索/`/top/playlist`/`/playlist/detail`/`/lyric`/`/song/url/v1` ✅（匿名只给 standard）。
  网易云 3000 实例卡死（用同一份代码的 3001 临时实例完成验证，已关闭）。
- **模拟测试**：全部 968 条自动化测试基于 fake provider / fake transport / 内存数据库，
  **不构成真实服务接通证据**。
- **App 内真实服务端到端**：未跑。

### 22.4 仍未验证

QQ 播放解析；酷狗真实协议；真实网络下多平台并行/超时/限流；App 内真实服务端到端；
**人工 Windows 验收（含窄窗口与高 DPI 观感）**。

### 22.5 阻塞项（需用户或环境）

1. **网易云 3000 实例卡死** ⇒ 需重启该服务。
2. **QQ 播放解析需要登录态** ⇒ 在用户明确许可前不会读写任何 Cookie 文件。

---

## 23. QQ 播放解析实测（2026-10-09）—— 已打通，并发现一条平台特性

### 23.1 实测结果（真实服务 `127.0.0.1:3200`，登录态已生效）

在此之前 QQ 播放解析一直"未验证"。本轮用**免费歌曲**打通了：

| 请求 | 结果 |
|---|---|
| `/getSearchByKey?key=…&limit=N` | ✅ 命中数据；**同请求在假 cookie 下只有 212B/0 首** ⇒ 登录态确实生效 |
| `/user/getUserLikedSongs?uin=…` | ✅ 返回「我喜欢」 |
| `/user/getVipInfo` | ✅ `code:0`（90 个权限字段） |
| `/getMusicPlay?...quality=128` | ✅ **有播放地址**（`audio/mpeg`，**2941 KB**） |
| `/getMusicPlay?...quality=m4a` | ✅ **有播放地址**（`audio/mp4`，**2240 KB**） |
| `/getMusicPlay?...quality=320` | ❌ 无 `purl` |
| `/getMusicPlay?...quality=flac` | ❌ 无 `purl` |

测试曲目：张艺兴《Bad Girl》（`mid=000Tr7g14TfdUK`）。⇒ **QQ 的 `quality` 取值被服务真实接受**，
`128 → mp3`、`m4a → m4a` 得到实证；而 `320` / `flac` 对该账号**不可得**。

### 23.2 关键修正：服务那条报错是**泛化**的，不能当作"cookie 失效"的证据

```ts
// qq-music-api/src/services/apis/music/getMusicPlay.ts:101
const isUnauthenticated = (midurlinfo) =>
  midurlinfo.length === 0 || midurlinfo.every(item => !item.purl);
// 拿不到 purl ⇒ 一律报 "Cookie 已失效或 uin 缺失，请重新获取有效的登录 Cookie"
```

⇒ 只要 QQ 没给 `purl`（**包括"该账号没有这个档位的权限"**），都会显示成"cookie 失效"。
本轮据此把 QQ 播放解析从未验证推进到**部分验证**：`128` / `m4a` 已实证，`320` / `flac` 因账号权限未实证。

### 23.3 ★ 平台特性（用户指出，直接影响提供商配置）

**QQ 音乐提供商必须配置 cookie，否则连播放解析都做不到**：
匿名（或无有效 cookie）时 vkey 不返回任何 `purl`，播放链路整体不可用 —— 不像搜索那样还能勉强返回。
⇒ 落地要求：
1. QQ 的提供商**必须把凭据标记为必需**（`requiresCredential: true`），并在配置界面明确提示"不填 cookie 无法播放"；
2. 这条要写进 QQ 的配方/模板说明（与 §19.5 的"探测不是能力存在的前提"不冲突：这里说的是**凭据**前提，不是探测前提）。

### 23.4 档位可用性受**账号权限**限制（新事实）

`/user/getVipInfo` 显示该测试账号 `vip=0`、`yearflag=0`、`HugeVip=0`、`btn_msg=升级为绿钻`
⇒ **非会员账号**。免费账号只拿得到 `128`/`m4a`；`320`/`flac` 需要会员权限。

对我们模型的影响（已由既有设计覆盖，此处记录依据）：
- 我们声明的档位是**平台契约**（QQ 的枚举里有 `320`/`flac`），**不代表每个账号都能拿到**；
- 请求档位不可得时（无 `purl`）应当**能降级**到更低档 —— 这条已由 `platformQualityFallbackChain`（§19.7 缺陷 B 的修复）承担，
  空链时保持旧行为；**不应**把它误判成"接口定义不匹配"。

### 23.5 仍未验证（QQ）

`320` / `flac` 的真实返回（需会员账号）；真实网络下的多平台并行/限流表现。

### 23.6 本轮同时修复的 UI 缺陷（P1 / P4）

> ⚠️ **本节的代码改动已全部回退（2026-10-09）**：用户人工查看后判定这批改动
> "改不到点上、问题多的数不过来"，已 `git reset --hard 197e25b` 回到本节之前的基线。
> 下面保留的是**问题诊断**（仍然成立、可供重做参考）与原实现记录；
> 逐提交取回见备份分支 `backup-ui-round-20261009`（`4f82af7` P1+P4 / `7c8fa1e` 滚动 / `0591bd4` P2+P3）。
> 回退后基线已复验：`flutter analyze` 无 issue、`flutter test` **1195 passed**。
> **重做前必须先问清用户到底要什么样的交互**，不要按本节的实现再走一遍。
>
> 保留的两个**更早**的改动（用户明确要过，未回退）：`556ed29` 默认落地页=聚合主页、`b917659` 降权提示按平台档位序。

用户人工验收发现：**除搜索外的能力在配置界面几乎没法用** —— 每个能力的参数都被默认成"搜索关键词"。

- **根因**：`_ParamRow.empty()` 把新参数行的默认来源**硬编码为 `keyword`**；
  而模板层（`OnlineMusicProviderTemplate`）只有 `search` 一个绑定，从未按能力泛化。
- **P1（已回退；原 `4f82af7`）**：新增**能力 × 输入源**的单一事实来源
  `provider/online_music_capability_inputs.dart`（`onlineMusicInputsFor` 用**穷举 switch**，新增能力时编译期提醒）：
  新建行的默认来源按能力给（stream/lyric → 曲目 ID、playlist → 歌单 ID、search → 关键词）；
  下拉把该能力相关的来源前置但**不隐藏**其它来源；从"未配置"进入时预填该能力的主输入源那一行
  （**不**对内置实现预填 —— 避免误伤"只是进来看看"的配置）。
- **P4（已回退；原 `4f82af7`）**：`OnlineMusicDeclarativeCapabilityBinding.validationIssues` 增加
  **必需输入校验**：缺少该能力必需的输入源（如歌单详情缺 `playlistId`、播放解析缺 `trackId`）直接报出；
  查询串 / 请求体字段 / **路径占位符 `{trackId}`** 都算已绑定（避免误报）；
  浏览类能力（可能一次请求不带业务输入）不产生该提示。
- 测试：`online_music_capability_inputs_test.dart`（11 条，含"把搜索形状的参数照搬到播放解析必须报缺曲目 ID"这条针对用户原问题的回归）
  + `online_music_capability_editor_test.dart`（5 条 widget 守卫，含"打开已有声明式配置时不预填"）。
- **P2（已回退；原 `0591bd4`）**：六项网易云配方从**测试文件提到产品层**
  （`declarative/provider_recipes.dart`：`OnlineMusicProviderRecipe` + `onlineMusicProviderRecipes()`），
  测试改为**读产品层那份**（同名薄别名，既有断言一行未改）⇒ 界面填出来的与测试验的是同一份，不会分叉；
  能力编辑器新增「**从内置配方填充**」（`MenuAnchor`，只列出**确实有这个能力**的配方项，
  没有则该按钮不出现）。ChkSz / MSAPI **只有搜索**有真实依据 ⇒ 标签如实写「仅搜索」，**不编造**。
- **P3（已回退；原 `0591bd4`）**：「探测该服务」从能力编辑器**移到提供商条目**（设置页条目行的雷达图标），
  结果以对话框呈现（命中协议 / 逐候选明细），并明确它只回答"能不能连通 + 像不像已知协议"；
  能力编辑器只留「试跑」（按能力、用当前编辑中的配置发真请求）。
  ⇒ 与 §19.5 的"探测 = 服务级 / 试跑 = 按能力"完全对齐，也修掉了"只有搜索能露出探测按钮"的不一致。
- **附带修复（已回退；原 `7c8fa1e`）**：「能力配置」列表此前是**不可滚动、无高度上限的 `Column`** ——
  能力涨到 8 个后矮窗口下超出部分**根本点不到**。改为限高可滚动的 `ListView`，
  并按仓库既有约定（歌词视图同样写法）`copyWith(scrollbars: false)` **不显示滚动条**；
  编辑器表单/JSON 区一并处理。守卫测试用 900×420 窗口断言"无溢出 + `maxScrollExtent > 0` + 最后一个能力点得到"。




