# F0–F1 审计基准（冻结副本，**只读**）

- 冻结日期：2026-10-09
- 冻结原因：为「F1 作者面修复」建立**可复现的 Spec 审计基准** —— 让后续审计能对着**固定版本**的规范，而不是会随时被改写的本地工作文档。
- **F0 代码边界**：`197e25b..d7b628e`（分支 `feat/multi-platform-aggregation`；`main` = `2bfaaf0`，本阶段全程未动）
- 冻结时的验证基线：`flutter analyze` → No issues found（exit 0）；`flutter test` → **1253 passed**（exit 0）

---

## 1. 这个目录是什么（以及不是什么）

**是**：一组**逐字节冻结**的规范/报告副本，供 F1 审计与复算使用。

**不是**：
- **不是**这些文档的"最新版本" —— 它们对应上面的日期与 F0 代码边界；
- **不是**可编辑的工作副本。**本目录只读**：任何 Spec 变化都必须通过**新的、有独立版本记录的冻结提交**处理（例如将来的 `f2-baseline/`），**不得直接改写本目录的文件**。

**与 `.gitignore` 的关系**：本目录**不在** `.gitignore` 的任何忽略规则内（被忽略的是 `docs/specs/`、`docs/dev/`、`docs/history/`、`docs/AI_PROGRESS.md`、`skills/` 这几条**逐条点名**的路径）。因此这是一次**新增可跟踪路径**，**没有修改 `.gitignore`**，也没有改变"本地工作文档不跟踪"的既有约定。

**与既有守卫的关系**：`test/docs/decision_list_consistency_test.dart` 只读 `docs/AI_PROGRESS.md` 与另外两个固定路径，**不扫描本目录** ⇒ 冻结副本不会与文档一致性守卫互相干扰。

---

## 2. 文件清单与校验和

`git` 只存**副本**；原始文件保持不动。要复算：对"原始路径"与"冻结副本"分别求 SHA-256 并比对下表。

| 冻结副本（本目录） | 原始路径 | 原始 SHA-256 | 副本 SHA-256 | 字节 |
|---|---|---|---|---|
| `provider-f0-migration-spec.md` | `docs/specs/provider-f0-migration-spec.md` | `FCC485D71D3560ED596BE0B249FD8722DA5D208B7534D1200524E1D1BBB3C945` | `059B32FCAB16513BA5936234479013CD0E3D5945B9CF36FA1841F0C58437319B` | 22824 |
| `provider-f0-security-migration-acceptance-2026-10-09-report.md` | `docs/history/provider-f0-security-migration-acceptance-2026-10-09-report.md` | `084E8A4FBC8E7A724A247C69BB4DCA6CF2EF8C3AEA815B5D267EE510CD660ACD` | `084E8A4FBC8E7A724A247C69BB4DCA6CF2EF8C3AEA815B5D267EE510CD660ACD` | 35733 |
| `provider-system-audit-2026-10-09.md` | `docs/specs/provider-system-audit-2026-10-09.md` | `83E33F3A7F34B77B1D468404AAA2EAE98B603435939D3B556BA2C2B546411D35` | `83E33F3A7F34B77B1D468404AAA2EAE98B603435939D3B556BA2C2B546411D35` | 14044 |
| `provider-system-audit-defects-2026-10-09.md` | `docs/specs/provider-system-audit-defects-2026-10-09.md` | `A3611FBF629EBD48CBD66615BB2A5B9329FA17A19A2E8FE12EDA9395B96F1CD7` | `A3611FBF629EBD48CBD66615BB2A5B9329FA17A19A2E8FE12EDA9395B96F1CD7` | 14207 |
| `provider-system-redesign-proposal-2026-10-09.md` | `docs/specs/provider-system-redesign-proposal-2026-10-09.md` | `FBC02D586B4A9C4EDF323D44EAA096301A69C86256BA53D5C5A1E907F446D0E3` | `FBC02D586B4A9C4EDF323D44EAA096301A69C86256BA53D5C5A1E907F446D0E3` | 22749 |
| `multi-platform-aggregation-spec.md` | `docs/specs/multi-platform-aggregation-spec.md` | `01A1B701A9F6FE9F421244897A21DCDA669F5874788BD03C6567DD8CDCFAD5A0` | `01A1B701A9F6FE9F421244897A21DCDA669F5874788BD03C6567DD8CDCFAD5A0` | 73509 |
| `verification-matrix.md` | `docs/dev/verification-matrix.md` | `8C03FA92B696BDAC9C2489FC25840FF2DC77781E0F5BAD5CD4FA27F8A2228F40` | `8C03FA92B696BDAC9C2489FC25840FF2DC77781E0F5BAD5CD4FA27F8A2228F40` | 8159 |
| `search.json` | `docs/dev/netease-bindings/search.json` | `F1A32928A0E3F89B5E1402A97712E448040D528ECE35351200564907E94E94C2` | `F1A32928A0E3F89B5E1402A97712E448040D528ECE35351200564907E94E94C2` | 1464 |
| `playlist.json` | `docs/dev/netease-bindings/playlist.json` | `B5FA9E418859D82EDDCB50BB3B6C6FA716AC30AA0CE96BAD0AA674820149204A` | `B5FA9E418859D82EDDCB50BB3B6C6FA716AC30AA0CE96BAD0AA674820149204A` | 2031 |
| `playlistCollection.json` | `docs/dev/netease-bindings/playlistCollection.json` | `009AF0645A4E7F24B69C7270F03A3DF80071DFD3ED4DF9361C768E9AE4FE2EBE` | `009AF0645A4E7F24B69C7270F03A3DF80071DFD3ED4DF9361C768E9AE4FE2EBE` | 1500 |
| `playlistCategories.json` | `docs/dev/netease-bindings/playlistCategories.json` | `2ACA1929149D70E44002E5754C9175B06030639EA9A9A47CF4465D8C3E44DE71` | `2ACA1929149D70E44002E5754C9175B06030639EA9A9A47CF4465D8C3E44DE71` | 894 |
| `chartList.json` | `docs/dev/netease-bindings/chartList.json` | `EA4242EB49DADD1B047C714677E7D40F039BDD1E9E6A246D6E0AF4B0D2588D12` | `EA4242EB49DADD1B047C714677E7D40F039BDD1E9E6A246D6E0AF4B0D2588D12` | 1196 |
| `newSongs.json` | `docs/dev/netease-bindings/newSongs.json` | `5A95CBE9A86A240224C944A32B84FEEEA35F7AF7FB0BADD0A4FE92CE19CB1186` | `5A95CBE9A86A240224C944A32B84FEEEA35F7AF7FB0BADD0A4FE92CE19CB1186` | 1541 |

**12 / 13 个副本与原始文件逐字节相同**；唯一不同的是 `provider-f0-migration-spec.md`，差异见下。

### 2.1 行尾与复现性（重要）

上表的 SHA-256 是**冻结当时工作树里的字节**，实测 13 个副本与 13 个原始文件**全部为 LF**，且**每个文件的工作树字节 == git 暂存 blob 字节**（逐条验证过）。

但本机 `core.autocrlf = true` ⇒ **将来某次 clone/checkout 会把文本文件的行尾改写成 CRLF**，那时工作树文件的 SHA-256 将不再等于上表。**因此"可复现"的权威标识是 git blob 哈希**（它记录的是提交里真正存下的内容，不受 checkout 行尾策略影响）：

| 冻结副本 | git blob（SHA-1） |
|---|---|
| `MANIFEST.md` | `4facdfaeaa3195a7757d582f4fbac789e87b34cd`（本文件，改一次即变，不作为基准） |
| `provider-f0-migration-spec.md` | `ce5f9f0f0e54e60ede55ab9abf6a0667cb9c31e5` |
| `provider-f0-security-migration-acceptance-2026-10-09-report.md` | `ca8924540450b9e50b4a1e8c1b9aaabc01b406a6` |
| `provider-system-audit-2026-10-09.md` | `ec5c39d928648ea101e728fcb8f315daefddb9a3` |
| `provider-system-audit-defects-2026-10-09.md` | `ce901bb0e246806ee9a963a76bcf6cb11d4d9517` |
| `provider-system-redesign-proposal-2026-10-09.md` | `434e50d8f68ca136969bbf6c004ba3328ad828fb` |
| `multi-platform-aggregation-spec.md` | `28833ae5410c861afdc832fe3e469dd968fc6aab` |
| `verification-matrix.md` | `bc433e22ef9d593c60901bdac99d659f0d89a8f4` |
| `search.json` | `59df4569b97ee4134ca31b7b85edc0bc21d99db9` |
| `playlist.json` | `1e9a0b0afeffde2f194186a916760c237b273a10` |
| `playlistCollection.json` | `b5cf99b3da6e2e9cf0abd2eb94ff1039e25e0222` |
| `playlistCategories.json` | `d284cbeda5f6238e0f44ac31ac3cc9dc36da6015` |
| `chartList.json` | `fc24e33f4cedb4a3d50e51ec98390f85b0e1566c` |
| `newSongs.json` | `d8c79b2ca30d2a6b17a41e41432891390030b7bd` |

三种复算方式（任选其一，结果应一致）：
1. **blob 方式（推荐，免疫行尾）**：`git ls-files -s docs/archive/frozen/f0-f1-baseline` 或 `git cat-file blob <sha>`;
2. **工作树方式**：直接对文件求 SHA-256，与 §2 的"副本 SHA-256"列比对（**前提是行尾未被改写**）;
3. **交叉方式**：`git hash-object docs/archive/frozen/f0-f1-baseline/<file>` 应等于上表 blob。

---

## 3. 唯一一处有意差异（D1）

| 项 | 内容 |
|---|---|
| 文件 | `provider-f0-migration-spec.md`（仅**冻结副本**） |
| 替换规则 | 绝对路径里的用户目录段 `C:\Users\<用户名>` → `%USERPROFILE%`（在**本机**即 `'C:\Users\' + $env:USERNAME`；出现 **1** 次） |
| 位置 | 原第 14 行：Debug 数据目录的绝对路径（`%USERPROFILE%\Desktop\Listenary\build\…`，替换前为同一路径的 `C:\Users\<用户名>\…` 写法） |
| 理由 | 仓库**已跟踪**文件里同类路径一律用占位符（`test/core/app_data_path_test.dart` 用 `C:\Users\listener\…`；`page/docs/guide/install.md` 用 `C:\Users\<用户>\…`），且真实用户名在已跟踪文件里 **0 命中** ⇒ 冻结副本（含**本文件**）一律不写入它 |
| 等价性 | `%USERPROFILE%` 就是 `C:\Users\<当前用户>`，替换后路径语义与原意完全一致（相对路径只是换了一种写法，指向不变） |
| **原始文件** | **未修改**（`docs/specs/provider-f0-migration-spec.md` 仍是 `FCC485D7…`） |
| 复算方法 | 对原始文件做同一替换后求 SHA-256，应等于副本的 `059B32FC…7319B` |

除 D1 之外，**没有对任何文档正文做改写**：决策记录、裁定（含 F0 §11 的 A/B 裁定与存储冲突约束）、缺陷编号与证据均按原样冻结。

---

## 4. 复算命令

```powershell
# 1) 逐个打印冻结副本的 SHA-256（应与 §2 的"副本 SHA-256"列逐条相等）
Get-ChildItem docs/archive/frozen/f0-f1-baseline -File |
  Where-Object { $_.Name -ne 'MANIFEST.md' } |
  ForEach-Object { "$($_.Name)  $((Get-FileHash $_.FullName -Algorithm SHA256).Hash)" }

# 2) 验证 12 个副本与原始文件逐字节相同
$pairs = @{
  'provider-f0-security-migration-acceptance-2026-10-09-report.md' = 'docs/history/provider-f0-security-migration-acceptance-2026-10-09-report.md'
  'provider-system-audit-2026-10-09.md'      = 'docs/specs/provider-system-audit-2026-10-09.md'
  'provider-system-audit-defects-2026-10-09.md' = 'docs/specs/provider-system-audit-defects-2026-10-09.md'
  'provider-system-redesign-proposal-2026-10-09.md' = 'docs/specs/provider-system-redesign-proposal-2026-10-09.md'
  'multi-platform-aggregation-spec.md'       = 'docs/specs/multi-platform-aggregation-spec.md'
  'verification-matrix.md'                   = 'docs/dev/verification-matrix.md'
  'search.json'               = 'docs/dev/netease-bindings/search.json'
  'playlist.json'             = 'docs/dev/netease-bindings/playlist.json'
  'playlistCollection.json'   = 'docs/dev/netease-bindings/playlistCollection.json'
  'playlistCategories.json'   = 'docs/dev/netease-bindings/playlistCategories.json'
  'chartList.json'            = 'docs/dev/netease-bindings/chartList.json'
  'newSongs.json'             = 'docs/dev/netease-bindings/newSongs.json'
}
$pairs.GetEnumerator() | ForEach-Object {
  $a = (Get-FileHash "docs/archive/frozen/f0-f1-baseline/$($_.Key)" -Algorithm SHA256).Hash
  $b = (Get-FileHash $_.Value -Algorithm SHA256).Hash
  "{0,-52} identical={1}" -f $_.Key, ($a -eq $b)     # 应全部为 True
}

# 3) D1 复算：对原始 spec 做同一替换后求哈希 ⇒ 应等于 059B32FCAB16513BA5936234479013CD0E3D5945B9CF36FA1841F0C58437319B
$orig = [System.IO.File]::ReadAllText('docs/specs/provider-f0-migration-spec.md', [System.Text.Encoding]::UTF8)
$replaced = $orig -replace [regex]::Escape('C:\Users\' + $env:USERNAME), '%USERPROFILE%'
[System.IO.File]::WriteAllText("$env:TEMP\f0-spec-recomputed.md", $replaced, (New-Object System.Text.UTF8Encoding($false)))
(Get-FileHash "$env:TEMP\f0-spec-recomputed.md" -Algorithm SHA256).Hash
```

---

## 5. 这批副本**不**包含什么（避免误读为"基准=全集"）

- **本地长期活文档**：`docs/AI_PROGRESS.md`（持续改写，冻结它没有意义）。F0 阶段的实时状态摘要只作为线索，**权威以本目录的冻结副本为准**。
- **上一阶段（Home/Explore）的规范与报告**：`docs/specs/home-explore-*.md`、`docs/history/home-explore-r*.md`（与 F1 八项无依赖关系）。
- **服务接口证据**：`docs/specs/netease-discovery-api-evidence.md`、`qq-kugou-discovery-api-evidence.md`（体量大，且 F1 的"真实服务验证"是可选项；需要时按 F0 的六项配方副本即可复现）。
- **参考截图**：`docs/specs/evidence/*.png`（构建产物性质的二进制，与 F1 无关）。
- **`docs/dev/manual-acceptance-home-explore.md`**：与本轮 P-02 相关（其配方受 P-01 阻塞），但按"最小基准 + 不擅自纳入"原则**未纳入**；如需，用**新的冻结提交**追加。

---

## 6. F1 与本基准的关系（供审计）

F1 的八项范围、证据矩阵与切片计划在提交信息与（若有）后续报告中给出；其**判定基准**即本目录中的：

- `provider-system-audit-defects-2026-10-09.md`（P-01/P-02/P-19/P-20/P-21/P-23/P-45/P-64 的原始条目与证据指针）
- `provider-system-redesign-proposal-2026-10-09.md`（F1 目标/范围/Non-goals/完成标准/准入条件；F2–F5 的排除边界）
- `provider-f0-migration-spec.md` + `provider-f0-security-migration-acceptance-2026-10-09-report.md`（**F0 安全边界**：敏感头、凭据引用、Base URL 校验、迁移、请求摘要脱敏 —— F1 不得削弱其中任何一条）
- `multi-platform-aggregation-spec.md`（能力体系 / Provider 路由 / 音质 / 来源身份模型 —— F1 的所有改动都要与它一致）
- `verification-matrix.md` + `netease-bindings/*.json`（可复现的验证命令与六项真实服务配方）
