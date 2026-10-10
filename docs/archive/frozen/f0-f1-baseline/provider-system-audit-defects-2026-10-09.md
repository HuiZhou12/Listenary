# Provider 系统缺陷清单（68 项，复核后）

- 日期：2026-10-09；被审对象 `feat/multi-platform-aggregation` @ `197e25b`
- 配套：`provider-system-audit-2026-10-09.md`（现状/矛盾/场景/安全/边界）、`provider-system-redesign-proposal-2026-10-09.md`（根因/依赖/整改计划）
- **复核方式**：有 `file:line` 且跨文件因果链闭合 ⇒ `confirmed-defect`；依赖运行时或单一来源 ⇒ `high-confidence-risk`；与已确认设计一致 ⇒ `expected-behavior`；另有 `duplicate-of-*` / `needs-more-evidence`。
- **分类**：`必修` = 本阶段（F0–F5）内必须解决；`后续扩展` = 本阶段明确不做；`设计边界` = 已确认不做或已接受。

## 统计

| 判定 | 数量 |
|---|---|
| `confirmed-defect` | ≈50 |
| `high-confidence-risk` | 6（P-28/42/43/57/58 + P-12 部分） |
| `expected-behavior` | 5（P-03/10/12部分/51/53） |
| `duplicate-of-*` | 2（P-02→P-01、P-52→P-05） |
| `needs-more-evidence` | 1（P-68） |
| `not-reproducible` | 0 |
| **合计** | **68** |

| 严重度 | 数量 | 其中必修 |
|---|---|---|
| **P0** | 2 | 2（P-01/P-02 随 P-01） |
| **P1** | 20 | 19（P-13 降为 P2） |
| **P2** | 26 | 22 |
| **P3** | 20 | 12 |

## 清单

| ID | 判定 | 级别 | 分类 | 证据（file:line） | 摘要 |
|---|---|---|---|---|---|
| P-01 | confirmed-defect | **P0** | 必修 F1 | `editor:385-388,753-756`；`response_spec:341-360`；`mapper:163/173`；`controller:533-546` | 表单把 `listPath`/`fieldsRootPath` 写成互斥 ⇒ 歌单列表/分类/榜单/新歌**不能保存也不能试跑**；playlist 能存但**曲目恒空**且试跑**假阳性绿灯** |
| P-02 | duplicate-of-P-01 | P0 | 必修 F1 | `home_page:352-353`；`explore_page:618-619`；`docs/dev/manual-acceptance-home-explore.md:42,71-74` | 界面/文档指引"配置歌单列表后这里会显示"——P-01 未修则**照做必然失败**；修 P-01 后需同步改文案 |
| P-03 | expected-behavior | — | 设计边界 | `main:127-139`；`controller:240`；`settings_ui:222` | "条目/能力/路由重启后生效、凭据立即生效"**是已确认设计**（D7 维持） |
| P-04 | confirmed-defect | P2 | 必修 F2 | `controller:240-241`；`settings_ui:370-373` | 草稿/已保存待重启/运行时生效**三态在界面不可区分** |
| P-05 | confirmed-defect | P1 | 必修 F3 | `probe:105,172,158`；`controller:363-373` | 探测与用户配置**完全脱钩**（2 个编译期模板的服务指纹） |
| P-06 | confirmed-defect | P1 | 必修 F3 | `probe:158,177-187`；`templates:49`；`builder:98-104` | 探测初稿保留模板 `apikey` ⇒ 运行期**恒 `notConfigured`**（"探测成功但不可用"） |
| P-07 | confirmed-defect | P1 | 必修 F3 | `probe:37-66,228-303` | 探测**无失败分类/无请求摘要/无响应片段** |
| P-08 | confirmed-defect | P1 | 必修 F4 | `request_spec:29-44`；`builder:160-171` | 模型**无静态 query/body 常量值**（D1 已裁定支持） |
| P-09 | confirmed-defect | P2 | 必修 F4 | `request_spec:83-107`；`builder:115-117` | 请求头不能动态/来自输入 |
| P-10 | expected-behavior | — | 设计边界 | `binding:72-96`；`capability:19-21` | **一个能力=一次请求**（D2 已裁定本阶段不支持，列为模型边界） |
| P-11 | confirmed-defect | P1 | 必修 F4 | `builder:33-43`；`declarative:81,200,223,244` | cursor 从未注入、page 恒 1、pagination 无消费者 ⇒ **模型承诺未兑现** |
| P-12 | 拆：单槽位 expected-behavior ／ 无 Cookie·签名 confirmed-defect | P2 | 必修 F0/F4 | `settings:97`；`composition:108-110` | D3 拆分：静态 Cookie/敏感头+安全引用=支持；自动登录/动态签名=**明确报边界** |
| P-13 | confirmed-defect | **P2**（原 P1 下调） | 必修 F4 | `declarative:264`；`composite:217-224`；`quality_tiers:109-119` | 档位**只能写代码声明** ⇒ 内部偏好词原样发给用户接口（存在绕行，故降级） |
| P-14 | confirmed-defect | P1 | 必修 F2 | `settings:448-484` | **4 个"谁服务谁"旋钮**并存（default/capability/legacy/routing/enabledPlatforms） |
| P-15 | confirmed-defect | P1 | 必修 F2 | `lyric_source:9`；`online_lyric/models:2`；`matcher:798-801`；`settings_tabs:2449` | **两套歌词子系统 + 3 个来源枚举**；"默认在线源"只对本地库生效却未说明 |
| P-16 | confirmed-defect | P1 | 必修 F2 | `chksz_error:47-55`；`declarative:390-396`；`controller:111-121` | **3 张错误分类表 + 2 枚举**；同一 401/404 三层结论不同 |
| P-17 | confirmed-defect | **P1** | **必修 F0（安全）** | `editor:866-867`；`request_spec:89,264`；`preference:834-835,876-877` | 请求头敏感值**明文展示 + 明文落盘** |
| P-18 | confirmed-defect | **P1** | **必修 F0（安全）** | `settings:6,12-23` | 非法 baseUrl **静默改写 `api.chksz.com`**；凭据是否外发**待运行验证**（可能升 P0） |
| P-19 | confirmed-defect | P1 | 必修 F1 | `settings:137-143` vs `chksz:44-45`；`settings_ui:543-556` | 平台卡**声称 8 能力**、运行时只 4（默认配置即触发静默 `unavailable`）；无"设为不支持"入口 |
| P-20 | confirmed-defect | **P1**（范围加重） | 必修 F1 | `settings:266-287`；`settings_ui:186-193` | 「一键按 ChkSz 兼容方式填充」**整表替换 capabilities**（另 4 能力配置消失）、无确认无撤销 |
| P-21 | confirmed-defect | P1 | 必修 F1 | `editor:373,392,1382-1407` | 表单不编辑 body/pagination；`required`/`default` 无控件（POST 类只能走 JSON，保存还丢 default） |
| P-22 | confirmed-defect | P1 | 必修 F2 | `settings:548-566`；`settings_ui:566-572` | 「自动」可能无效：旧 `capabilityProviders` 仍回落，且 UI **无入口查看/清除** |
| P-23 | confirmed-defect | P2 | 必修 F1 | `editor` `_ParamRow.empty()` | 新参数行默认来源**硬编码"搜索关键词"**（曾修、被回退，缺陷回归） |
| P-24 | confirmed-defect | P2 | 必修 F1 | `settings:140`；`settings_ui:186-193,385` | builtin 绑定**忽略 `contentPlatform`** ⇒ `qq` 条目变网易云候选 |
| P-25 | confirmed-defect | P2 | 必修 F3 | `editor:436` vs `:373,392` | 探测初稿只回填行、不回填 `_binding`（初稿 body/分页丢失） |
| P-26 | confirmed-defect | P2 | 必修 F3 | `probe:150-158`；`editor:430-433`；`controller:540-546,646-654` | 部分映射/空歌词/空歌单被报**假阳性成功** |
| P-27 | confirmed-defect | P2 | 必修 F3 | `probe:105`；`controller:363-373` | 自建/非模板服务**无法探测**（无自定义候选出口） |
| P-28 | high-confidence-risk | P2 | 必修 F5 | `controller:676-693`；`http_transport:20-34` | 探测/试跑每次新建 Dio 且**从不关闭**（泄漏规模待运行验证） |
| P-29 | confirmed-defect | P2 | 必修 F2 | `composite:72-82`；`service:138-247` | 诊断**无 UI 出口**（`routeLog` 未上接口、`servedByProviderId` 未渲染）——违反 Spec §6.4 |
| P-30 | confirmed-defect | P2 | 必修 F2 | `response_spec:559-576`；`mapper:368-375,408-416` | 校验放行的转换在映射层**必然失败**（静默 null） |
| P-31 | confirmed-defect | P2 | 必修 F2 | `mapper:338-357` | 类型不匹配被报成**"缺少必填字段"**（排查方向被带偏） |
| P-32 | confirmed-defect | P2 | 必修 F2 | `settings:1030-1034`；`editor:167-171` | 损坏的能力 JSON **静默降级为"不支持"** |
| P-33 | confirmed-defect | P2 | 必修 F1 | `editor:172,287-288,595-598` | **JSON 视图与表单不同步** ⇒ 点「应用 JSON」静默回滚表单改动 |
| P-34 | confirmed-defect | P2 | 必修 F2 | `controller:154-156` | 试跑**永不显示请求体**（POST 类无法自查字段名） |
| P-35 | confirmed-defect | P2 | **必修 F0** | `controller:127-135,716-741` | 脱敏是**名字白名单**（漏 `appkey/session/jwt`、JSON 非字符串、嵌套 JSON） |
| P-36 | confirmed-defect | P2 | 必修 F2 | `settings_ui:875-887` vs `editor:686-729` | **两处"认证"语义重叠** ⇒ 运行期 `missingCredential` 但界面无提示 |
| P-37 | confirmed-defect | P2 | 必修 F2 | `settings_ui:543-551` vs `:40-53,407-415` | 平台卡**混用两套状态**（已编辑配置 vs 运行中 service） |
| P-38 | confirmed-defect | P2 | 必修 F1 | `settings_ui:280-324,162,315` | **无 Provider 级启用/禁用**（只能删除，且不能删到只剩一个） |
| P-39 | confirmed-defect（闭集部分=设计边界） | P2 | 必修 F4 | `settings:1040-1047` | 未知平台**静默回落 netease**（D5 已裁定改为自定义平台标识） |
| P-40 | confirmed-defect | P2 | 必修 F4 | `http_transport:49-60` | **非 JSON `Content-Type` 不解析**（返回 JSON 却标 `text/plain` → 报"接口不匹配"） |
| P-41 | 拆：键名限制 confirmed ／ null≡缺失·转换闭集 expected | P2 | 必修 F4 | `json_path:34,77`；`response_spec:48-64` | 路径键名限 `^[A-Za-z0-9_\-]+$`（中文/含点键不可寻址）；另两项为已接受边界（D4） |
| P-42 | high-confidence-risk | P2 | 必修 F2/F5 | `mapper:119-123,131-133`；`composite:217-228` | **同平台多 Provider 回退可能播错歌**，身份由请求方回填、**无法检出** |
| P-43 | high-confidence-risk | P2 | 必修 F5 | `database:7,120-134` vs `:54-91` | v<5 迁移 `CREATE TABLE` 无 `IF NOT EXISTS` ⇒ **半迁移库打不开** |
| P-44 | confirmed-defect | P2 | 必修 F1 | `platform_capability_view:14-21,148-187` | 诊断面板**只有 5 项**（缺榜单/分类/新歌）；"已停用"显示为"未配置" |
| P-45 | confirmed-defect | P2 | 必修 F1 | `platform_capability_view:14-21`；`controller:510-674,657` | **静默漏改点**：手写 5 行 + 试跑 if 链无 else（新能力被误诊"网络不可达"） |
| P-46 | confirmed-defect | P2 | 必修 F1/F5 | 测试点 `.first`=search；`default_compat_test:25-31` | **无 widget 测试覆盖非 search 能力的保存/试跑**；默认兼容测试**固化错误模型** |
| P-47 | confirmed-defect | P2 | 必修 F5 | `live_response_fixtures.g.dart` 仅 netease | **真实服务证据仅网易云**；QQ/酷狗无固件；酷狗在新链路缺席 |
| P-48 | confirmed-defect | P2 | 必修 F5 | `online_library_repository_test:403-421` | 混合平台歌单**缺仓储层测试**；镜像 id 空间、迁移场景**无测试** |
| P-49 | confirmed-defect | P3 | 必修 F3 | `controller:379,428` | 搜索试跑 keyword/limit **写死** `'listenary'`/1 |
| P-50 | confirmed-defect | P3 | 必修 F3 | `controller:471-479`；`http_transport:49-62` | **超时不可区分**（`DioException.type` 未读取） |
| P-51 | expected-behavior（+文案缺陷） | P3 | 设计边界 | `controller:657-673` | 试跑**不发起第二次请求**是有意取舍；"可用"文案过强归入 P-26 |
| P-52 | duplicate-of-P-05 | — | — | `editor:604` | "探测仅 search 可见"是 P-05 同根因的表现面 |
| P-53 | expected-behavior | — | 设计边界 | `settings:744`；`composition:142` | `defaultProvider` 保留属 D13:A 兼容策略；死代码清理可选 |
| P-54 | confirmed-defect | P3 | 必修 F2 | `declarative:62-63`；`settings:169-178` | 认证**三个事实源**；`capabilityAuth` 对声明式零效果（死旋钮） |
| P-55 | confirmed-defect | P3 | 必修 F2 | `settings:476-484` vs `:487-488,758-762` | `enabledPlatforms` **注释与代码语义相反** |
| P-56 | confirmed-defect | P3 | 必修 F2 | `composite:236-253`；`settings_ui:634-707` | 档位取 `candidates.first`；音质偏好用**网易云档位文案**渲染 |
| P-57 | high-confidence-risk | P3 | 必修 F2 | `session_controller:202,440-444`；`queue_controller:216-221` | `fallbackQuality` **跨平台携带**上一首的平台取值 |
| P-58 | high-confidence-risk | P3 | 必修 F5 | `composite:295-306,320-340` | `searchAggregated` **只捕获 `OnlineMusicException`** ⇒ 非归一化异常吞掉全部平台结果 |
| P-59 | confirmed-defect | P3 | 必修 F2 | `settings:548-566,137-143,212-234` | 改 legacy 条目 `contentPlatform` 后旧显式候选**被静默丢弃** |
| P-60 | confirmed-defect | P3 | 必修 F5 | `chksz_credential_access:48-56`；`entry:364` | 凭据 provider 缓存**不释放** |
| P-61 | confirmed-defect | P3 | 必修 F1 | `online_music_page:188,281` | UI 注入通道**硬编码 netease** |
| P-62 | confirmed-defect | P3 | 必修 F5 | `database:202-204`；`repository:309-332,333,898-908` | 无 `ON DELETE CASCADE`；订阅刷新**重置 `added_at`**；刷新删除未引用曲目元数据（含 `last_quality`） |
| P-63 | confirmed-defect | P3 | 必修 F2 | `remote_lyric_controller:122` | 移除镜像条目后历史/收藏条目仍在但播放 `unavailable`（不做可用性复核） |
| P-64 | confirmed-defect | P3 | 必修 F1 | `editor:33/75/568/573/822,989,767-777`；`settings_ui:385,865`；标签表 | 内部细节暴露（内部 id/英文枚举）；标签表不完整；非 search 副标题错写；试跑 ID 输入框错位 |
| P-65 | confirmed-defect | P3 | 必修 F4 | `builder:108-117,133-146` | 认证注入**静默覆盖**同名 query/header 参数（无冲突提示） |
| P-66 | confirmed-defect | P3 | 必修 F5 | Spec §22.5 vs §23；`online_music_page:144-148` | **文档/注释漂移**（§22.5 阻塞项已不成立；注释与 W6 实现相反） |
| P-67 | confirmed-defect | P3 | 必修 F1 | `settings_ui:167` | 残留误导文案：删除确认框仍提"默认提供商回落" |
| P-68 | needs-more-evidence | P3 | 必修 F5 | — | `platformQualityFallbackChain` 是否已有间接覆盖**未确认** |

## 与上一版清单的差异（本轮复核产生）

- **P-03 从 P1 改为"非缺陷"**（重启生效是已确认设计）——我上一轮的定级有误，此处更正。
- **P-09 / P-13 从 P1 下调为 P2**（阻断面较小 / 存在绕行）。
- **P-20 范围加重**（不是覆盖 4 项，而是**整表替换**，另 4 能力配置消失）。
- **P-02 / P-52 归为重复项**（同一根因的下游表现）。
- **P-12 / P-41 拆分**（一部分是设计边界，一部分是缺陷）——对应 D3 / D4。
- **P-11 重新表述为"模型承诺未兑现"**，优先级上升（模型声明了 cursor/page 却不使用）。
