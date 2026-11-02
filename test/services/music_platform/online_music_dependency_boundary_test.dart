import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 应用层不得依赖 Provider 的**实现**。
///
/// 两类受限例外：
/// - 设置页的在线音乐配置面板：职责就是编辑 Provider 配置，允许引用 `provider/`
///   层的配置契约，但仍禁止引用任何 ChkSz 实现类型；
/// - `lib/core/preference.dart`：把 `OnlineMusicSettings` 作为**应用偏好状态**读写。
///   这是基线 HEAD 上**既已存在**的依赖（当时 import 的是 `provider/` 深路径），
///   不是本次新增的分层依据。
const _configurationPanelPaths = {
  'lib/page/settings_page/online_music_settings.dart',
  'lib/page/settings_page/online_music_capability_editor.dart',
};

/// 任何文件（含配置面板）出现即失败。
final _implementationSymbols = RegExp(
  r'\b(?:ChkszRuntime|ChkszException|ChkszCancelToken|ChkszNeteaseCodec'
  r'|ChkszOnlineMusicProvider|ChkszCredentialAccess|ChkszClient'
  r'|OnlineMusicProviderRegistry|CompositeOnlineMusicService'
  r'|OnlineMusicProviderAuth|OnlineMusicAuthResolver'
  r'|MusicCatalogService|NeteaseStreamResolver)\b',
);

/// 允许提及 `OnlineMusicSettings` 的**非面板**文件（**仅此一个**）。
///
/// ⚠️ 这是**接受的现存债务**，不是分层正确性的证明：
/// 它是本文件冻结的 [allowlistedUpwardEdges] 里的一条 L1→L2 向上边。
/// 分层方向规则由本文件与 `test/core/database_engine_boundary_test.dart` 的
/// 层号常量共同定义（代码即 owner）。
///
/// 本集合只豁免**符号提及**，不豁免深路径：这里的消费者仍必须走公开端口
/// `services/music_platform/index.dart`。新增消费者需要显式批准，不得自行加入。
const _configContractConsumers = {'lib/core/preference.dart'};

/// Provider 层**内部**的配置符号；除 [_configurationPanelPaths] 与
/// [_configContractConsumers] 外，任何文件提及即失败。
final _configurationSymbols = RegExp(
  r'\b(?:OnlineMusicSettings|OnlineMusicProviderDefinition'
  r'|OnlineMusicCapability|OnlineMusicProviderSettingsController'
  r'|OnlineMusicCredentialAccess)\b',
);

/// 纳入符号检查的应用层目录。
///
/// `lib/core`、`lib/library` 与外围同一标准：任一判据命中即失败。
const _applicationRoots = [
  'lib/page',
  'lib/component',
  'lib/play_service',
  'lib/core',
  'lib/library',
];

// ═══════════════════════════════════════════════════════════════════════════
// 分层模型（3.1 分层规则的测试侧定义，本段即权威来源）
//
// 层号越小越底层；依赖**只允许向下**（`layer(from) >= layer(to)`）或同层。
// 规则与守卫同源：改层号就是改规则，必须同时更新 allowlist 并解释原因。
// ═══════════════════════════════════════════════════════════════════════════

/// L0 基础模型：纯类型、枚举、常量、值对象与纯函数。
const layerBasicModel = 0;

/// L1 基础设施：IO、持久化、路径、日志、传输、装配。
const layerInfrastructure = 1;

/// L2 领域服务：`music_platform` / `online_lyric` / `play_service` / `matcher`。
const layerDomainService = 2;

/// L3 表现层：`page/`、`component/`。
const layerPresentation = 3;

/// 组合根豁免：不参与方向判定，且**仅此一个**（见 [compositionRootPaths]）。
const layerCompositionRoot = -1;

/// 组合根。`lib/main.dart` 负责装配全部层，天然引用所有层，故豁免方向判定。
///
/// `lib/entry.dart`（约 48KB）同样承担装配职责，但**不**豁免：它把路由常量、
/// Provider 装配与页面混在一起，属于待拆的观察项（规则文档 §7 的 OBS-1）。
const compositionRootPaths = {'lib/main.dart'};

/// 目录默认层。逐文件映射见 [coreFileLayers] 与 [fileLayerOverrides]。
///
/// 判定顺序：组合根 → 逐文件覆盖 → core 逐文件清单 → 目录默认。未命中任何一条
/// 视为**未登记**，由「每个 lib 文件都有层归属」测试直接失败，避免新目录静默
/// 落进规则盲区。
const directoryLayers = <String, int>{
  'lib/page/': layerPresentation,
  'lib/component/': layerPresentation,
  'lib/test/': layerPresentation,
  // 顶层混杂装配文件：承担组合职责但**不**豁免，按表现层计入方向判定。
  'lib/entry.dart': layerPresentation,
  'lib/services/': layerDomainService,
  'lib/play_service/': layerDomainService,
  'lib/core/': layerInfrastructure,
  'lib/library/': layerInfrastructure,
  'lib/lyric/': layerInfrastructure,
  'lib/native/': layerInfrastructure,
};

/// `lib/core/` 的逐文件层归属（33 个文件全量登记，13 L0 / 18 L1 / 2 L2）。
///
/// `lib/core` 是混层目录：同一目录里既有纯模型也有 IO 与领域逻辑，因此不按目录
/// 一刀切。每条都写明依据，便于评审反驳。
const coreFileLayers = <String, int>{
  // ── L0：纯类型 / 常量 / 纯函数 ───────────────────────────────────────────
  'lib/core/design_tokens.dart': layerBasicModel, // 尺寸与圆角 const token
  'lib/core/desktop_lyric_colors.dart': layerBasicModel, // @immutable 颜色值
  'lib/core/enums.dart': layerBasicModel, // 仅 enum 与纯解析辅助
  'lib/core/equalizer_action_state.dart': layerBasicModel, // 边界常量 + 纯判定
  'lib/core/hotkey_focus_state.dart': layerBasicModel, // 纯焦点判定
  'lib/core/list_action_state.dart': layerBasicModel, // 纯可见性判定
  'lib/core/lyric_action_state.dart': layerBasicModel, // 纯歌词状态判定
  'lib/core/menu_styles.dart': layerBasicModel, // const MenuStyle / ButtonStyle
  'lib/core/paths.dart': layerBasicModel, // 路由常量 + 纯函数
  'lib/core/search_action_state.dart': layerBasicModel, // 纯搜索判定
  'lib/core/setting_action_state.dart': layerBasicModel, // 纯设置保存判定
  'lib/core/workload_policy.dart': layerBasicModel, // 纯并发预算计算
  'lib/core/zh_converter.dart': layerBasicModel, // 纯繁简转换
  // ── L1：IO / 持久化 / 状态单例 / 装配 ───────────────────────────────────
  'lib/core/cache.dart': layerInfrastructure, // 封面与专辑色缓存，读索引
  'lib/core/color_extraction.dart': layerInfrastructure, // 主色缓存单例
  'lib/core/database.dart': layerInfrastructure, // sqlite 持久化
  'lib/core/hotkeys.dart': layerInfrastructure, // 全局快捷键注册（系统 IO）
  'lib/core/immersive.dart': layerInfrastructure, // 沉浸模式单例状态
  // 3.5-b：曲库库（library.sqlite）的 Dart owner，开连接 + DDL + 自愈。
  'lib/core/library_db.dart': layerInfrastructure,
  // 3.5-b：本地播放次数的唯一写入口（app.sqlite）。
  'lib/core/local_play_history.dart': layerInfrastructure,
  // @immutable 值对象，但 `displayMode` 用了 `settings.dart` 的 `LyricDisplayMode`；
  // 被依赖拖成 L1，不是内容判定（规则文档 §7 OBS-2）。
  'lib/core/lyric_render_config.dart': layerInfrastructure,
  'lib/core/memory_monitor.dart': layerInfrastructure, // 内存监控与回收
  'lib/core/page_sort.dart': layerInfrastructure, // isolate 排序执行
  'lib/core/preference.dart': layerInfrastructure, // 偏好持久化
  'lib/core/route_visibility.dart': layerInfrastructure, // RouteObserver 实例
  'lib/core/settings.dart': layerInfrastructure, // 设置读写 + 数据路径解析
  // 3.5-b：winsqlite3.dll 版本下限守卫（探测 + 三段式降级判据）。
  'lib/core/sqlite_version_guard.dart': layerInfrastructure,
  'lib/core/system_volume_service.dart': layerInfrastructure, // 系统音量通道
  'lib/core/theme.dart': layerInfrastructure, // 主题装配
  'lib/core/update_checker.dart': layerInfrastructure, // 网络更新检查
  'lib/core/utils.dart': layerInfrastructure, // 日志与通用工具
  // ── L2：领域逻辑住在 core 的两个例外 ────────────────────────────────────
  'lib/core/index.dart': layerDomainService, // barrel，层取 re-export 闭包最大值
  'lib/core/matcher.dart': layerDomainService, // 歌词匹配领域逻辑
};

/// 逐文件覆盖：优先于 [directoryLayers] 与 [coreFileLayers]。
const fileLayerOverrides = <String, int>{
  // REC-1（规则层重归类，未移动文件）：内容只有 enum + ChangeNotifier，没有
  // Widget，也没有 flutter/material；放在 `component/` 只是因为最初消费者是
  // `core/hotkeys.dart`。按内容重归类为 L1 后，`hotkeys → 本文件` 由 L1→L3
  // **向上**变成 L1→L1 同层合法，向上边总数 13 → 12。
  'lib/component/hotkey_ui_feedback.dart': layerInfrastructure,
  // 纯歌词模型 / 枚举 / 常量：`lyric/` 里没有任何 IO 的部分下沉 L0。
  'lib/lyric/exclude_data.dart': layerBasicModel,
  'lib/lyric/lyric.dart': layerBasicModel,
  'lib/lyric/lyric_format.dart': layerBasicModel,
  'lib/lyric/lyric_tag_word_format.dart': layerBasicModel,
};

/// 冻结的**向上依赖**允许清单（L1→L2 / L1→L3 / L2→L3），当前 **12 条**。
///
/// 这是「计数不增」的存量债务清单，不是正确性证明。条数由 [upwardEdgeBudget]
/// 锁定：只能减、不能增。消除一条就同时删掉这里的行、下调预算、并同步规则文档 §6。
const allowlistedUpwardEdges = <String>{
  'lib/core/hotkeys.dart -> lib/play_service/play_service.dart',
  'lib/core/hotkeys.dart -> lib/play_service/playback_source.dart',
  'lib/core/memory_monitor.dart -> lib/core/matcher.dart',
  'lib/core/memory_monitor.dart -> lib/page/now_playing_page/component/lyrics_line_painter.dart',
  'lib/core/memory_monitor.dart -> lib/page/now_playing_page/component/lyrics_line_widget.dart',
  'lib/core/memory_monitor.dart -> lib/play_service/play_service.dart',
  'lib/core/preference.dart -> lib/services/music_platform/index.dart',
  'lib/core/theme.dart -> lib/play_service/play_service.dart',
  'lib/library/audio_library.dart -> lib/play_service/play_service.dart',
  'lib/lyric/lyric_loader.dart -> lib/services/online_lyric/api/krc_decryptor.dart',
  'lib/lyric/lyric_loader.dart -> lib/services/online_lyric/api/qrc_decryptor.dart',
  'lib/play_service/play_service.dart -> lib/page/now_playing_page/component/lyric_view_controls.dart',
};

/// 计数锁：向上边总数上限。**只能减小**。
///
/// 减小步骤：消除依赖 → 删 [allowlistedUpwardEdges] 对应行 → 同步下调本值 →
/// 同步修改规则文档 §6 的计数表。
const upwardEdgeBudget = 12;

/// 同层循环依赖（SCC）的冻结集合基线，当前 **6 组**。
///
/// 同层依赖是**合法**的（规则 L4），所以同层 SCC 本身不是违规；但它同样是
/// 「分层没被违反、却仍在互相咬合」的信号，因此像向上边一样**计数锁定**：
/// 只允许减少，新出现一组就必须显式评审。
///
/// 这份基线统计的是**完整依赖图**（`_dependencyEdges`），即 `import` 与 `export`
/// 都计入——与方向判定的图完全同一份，不做 import-only 削减。因此 barrel 的
/// `export` 会把被聚合的实现并进同一分量，SCC 只会更大、不会更小（宁严不松）；
/// 这里冻结的 6 组是在该口径下实测的结果。
const sameLayerSccBaseline = <String>{
  'L3: lib/page/uni_page.dart ↔ lib/page/uni_page_components.dart',
  'L1: lib/native/rust/api/*.dart ↔ lib/native/rust/frb_generated.dart（13 文件 FRB 绑定簇）',
  'L1: lib/core/database.dart ↔ lib/core/settings.dart ↔ lib/lyric/lyric_source.dart',
  'L1: lib/core/cache.dart ↔ lib/library/audio_library.dart',
  'L2: lib/play_service/{audio_echo_log_recorder,desktop_lyric_service,equalizer_service,lyric_service,play_service,playback_service}.dart',
  'L2: lib/services/music_platform/{declarative/*,provider/online_music_header_migration,provider/online_music_probe_candidates,provider/online_music_provider_settings_controller}.dart',
};

/// 本文件冻结的 `lib/core` ↔ `lib/services` **直接 import 边**基线。
///
/// 这些是 HEAD 上**既已存在**的边，不是「正确依赖方向」的声明。方向判定由
/// [allowlistedUpwardEdges] 承担：`services → core` 8 条全部是 L2→L1 向下，合法；
/// `core → services` 3 条中 2 条 `matcher` → L2 是**同层**，1 条 `preference`
/// 向上并已在允许清单内。本测试只检测基线**增删**；任何变动都需要显式评审，
/// 不得为了「让测试变绿」而直接改这里。
const _baselineCoreToServicesEdges = <String>[
  'lib/core/matcher.dart -> lib/services/online_lyric/api/net_lyric_api.dart',
  'lib/core/matcher.dart -> lib/services/online_lyric/parsed_lyric_converter.dart',
  'lib/core/preference.dart -> lib/services/music_platform/index.dart',
];

const _baselineServicesToCoreEdges = <String>[
  'lib/services/music_platform/chksz/chksz_error.dart -> lib/core/utils.dart',
  'lib/services/music_platform/chksz/chksz_online_music_provider.dart -> lib/core/preference.dart',
  'lib/services/music_platform/provider/online_music_provider_settings.dart -> lib/core/preference.dart',
  'lib/services/music_platform/provider/online_music_provider_settings_controller.dart -> lib/core/preference.dart',
  'lib/services/music_platform/provider/online_music_provider_settings_controller.dart -> lib/core/settings.dart',
  'lib/services/online_lyric/api/net_lyric_api.dart -> lib/core/settings.dart',
  'lib/services/online_lyric/parsed_lyric_converter.dart -> lib/core/settings.dart',
  'lib/services/online_lyric/parsed_lyric_converter.dart -> lib/core/utils.dart',
];

/// 本测试的**能力边界**（不得表述为已保证比下面更多的东西）：
/// - 首个测试是**纯文本匹配**，不解析 import 图 ⇒ 传递依赖无法发现；
/// - 方向判定基于 import/export 指令词法扫描（剥离行/块注释、跳过字符串内容），
///   覆盖直接边、**传递闭包**与层商图环检测；不做类型解析，也不看运行时；
/// - `part` / `part of` 不产生边（Dart 语义上同库，层按宿主文件计）；
///   条件导入的多个候选 URI 都会被计入（宁严不松）；
/// - barrel 的 `export` 边**已**计入图，并额外约束 barrel 的层不低于其
///   re-export 目标；但 `show`/`hide` 造成的可见性收窄不做建模；
/// - `lib/main.dart` 是唯一组合根豁免；`lib/entry.dart` 不豁免，按 L3 计；
/// - `test/` 目录不在范围内（现状）。
void main() {
  test('application layers do not import provider implementation types', () {
    final violations = <String>[];
    for (final root in _applicationRoots) {
      for (final entity in Directory(root).listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        final source = entity.readAsStringSync();
        final path = entity.path.replaceAll(r'\', '/');
        final isConfigurationPanel = _configurationPanelPaths.contains(path);
        final mayUseConfigContract = _configContractConsumers.contains(path);
        final banned =
            source.contains('services/music_platform/chksz/') ||
            _implementationSymbols.hasMatch(source) ||
            (!isConfigurationPanel &&
                (source.contains('services/music_platform/provider/') ||
                    (!mayUseConfigContract &&
                        _configurationSymbols.hasMatch(source))));
        if (banned) violations.add(entity.path);
      }
    }
    expect(violations, isEmpty, reason: violations.join('\n'));
  });

  test('core/services direct import edges match the frozen baseline', () {
    final edges = <String>[];

    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final sourcePath = _normalizePath(entity.path);
      if (sourcePath == null) continue;
      edges.addAll(_crossLayerEdges(sourcePath, entity.readAsStringSync()));
    }

    final coreToServices =
        edges.where((edge) => edge.startsWith('lib/core/')).toList()..sort();
    final servicesToCore =
        edges.where((edge) => edge.startsWith('lib/services/')).toList()
          ..sort();

    expect(
      coreToServices,
      _baselineCoreToServicesEdges,
      reason:
          'lib/core → lib/services 的直接 import 边已偏离冻结基线。\n'
          '实际：$coreToServices\n'
          '若确有需要新增/删除跨层边，请先显式评审并同步更新规则文档 §6，'
          '不要仅为让测试变绿而改基线。',
    );
    expect(
      servicesToCore,
      _baselineServicesToCoreEdges,
      reason:
          'lib/services → lib/core 的直接 import 边已偏离冻结基线。\n'
          '实际：$servicesToCore\n'
          '若确有需要新增/删除跨层边，请先显式评审并同步更新规则文档 §6，'
          '不要仅为让测试变绿而改基线。',
    );
  });

  test('every lib dart file has a registered layer', () {
    final unregistered = <String>[];
    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final path = _normalizePath(entity.path);
      if (path == null) continue;
      if (_layerOf(path) == null) unregistered.add(path);
    }
    expect(
      unregistered,
      isEmpty,
      reason:
          '以下文件没有登记层归属，新增目录或文件必须先落到规则文档 §3/§4 的映射里：\n'
          '${unregistered.join('\n')}',
    );
  });

  test('layers only depend downwards (same layer allowed, count locked)', () {
    final upward = _upwardEdges(_collectGraph());

    expect(
      upward.difference(allowlistedUpwardEdges),
      isEmpty,
      reason:
          '出现未登记的向上依赖（L1→L2 / L1→L3 / L2→L3）。\n'
          '未登记：${_sorted(upward.difference(allowlistedUpwardEdges))}\n'
          '允许清单：${_sorted(allowlistedUpwardEdges)}\n'
          '处置：把违规者搬回下层，或按规则文档 §6 显式批准后写进允许清单并上调计数锁。',
    );
    expect(
      allowlistedUpwardEdges.difference(upward),
      isEmpty,
      reason:
          '允许清单里有已经不存在的边（stale）。消除后必须同时删掉清单行并下调计数锁：\n'
          '${_sorted(allowlistedUpwardEdges.difference(upward))}',
    );
    expect(
      upward.length,
      lessThanOrEqualTo(upwardEdgeBudget),
      reason:
          '向上依赖条数涨到 ${upward.length}，超过计数锁 $upwardEdgeBudget。\n'
          '存量策略是「允许清单 + 计数不得增长」，不接受放宽预算。',
    );
  });

  test('no transitive upward dependency through non-allowlisted edges', () {
    final graph = _collectGraph();
    final filtered = <String, Set<String>>{
      for (final entry in graph.edges.entries)
        entry.key: entry.value
            .where(
              (target) =>
                  !allowlistedUpwardEdges.contains('${entry.key} -> $target'),
            )
            .toSet(),
    };

    final violations = <String>[];
    for (final entry in filtered.entries) {
      final from = _layerOf(entry.key);
      if (from == null || from == layerCompositionRoot) continue;
      for (final reached in _reachable(entry.key, filtered)) {
        final to = _layerOf(reached);
        if (to == null || to == layerCompositionRoot) continue;
        if (from < to) {
          violations.add('${entry.key}(L$from) → … → $reached(L$to)');
        }
      }
    }

    expect(
      violations,
      isEmpty,
      reason:
          '存在传递向上依赖：中间层把下层文件间接抬到上层。\n'
          '${_sorted(violations)}\n'
          '⚠️ 允许清单只豁免「直接边」，不允许新增长路径。',
    );
  });

  test('layer quotient graph is acyclic', () {
    final graph = _collectGraph();
    // 只对**清掉允许清单后**的图查环：允许清单里的向上边本身就是层商图上的反向
    // 边（L1→L2 等），把它们算进来会让「有存量债务」等价于「有环」。
    // 环的定义因此是：清完允许清单后仍存在的层间循环，只能靠搬迁消除。
    final quotient = <int, Set<int>>{};
    for (final entry in graph.edges.entries) {
      final from = _layerOf(entry.key);
      if (from == null || from == layerCompositionRoot) continue;
      for (final target in entry.value) {
        if (allowlistedUpwardEdges.contains('${entry.key} -> $target')) {
          continue;
        }
        final to = _layerOf(target);
        if (to == null || to == layerCompositionRoot || to == from) continue;
        quotient.putIfAbsent(from, () => <int>{}).add(to);
      }
    }

    expect(
      _findLayerCycles(quotient),
      isEmpty,
      reason:
          '层商图出现环（已排除允许清单里的存量向上边）。\n'
          '环必须靠搬迁消除，不能靠加白名单；新增长路径也会在这里被抓住。',
    );
  });

  test('same-layer cycles are frozen at 6 SCCs (count locked)', () {
    final graph = _collectGraph();
    // 同层依赖合法（规则 L4），因此同层环不是违规，而是待收敛的耦合信号。
    // 这条用例的独立价值：层商图环检测跳过了 `to == from`，永远看不到同层环，
    // 所以同层必须单独用**文件级 SCC** 检测，否则该维度完全无守卫。
    final sameLayerDeps = <String, Set<String>>{
      for (final entry in graph.edges.entries)
        entry.key: entry.value
            .where((target) => _layerOf(target) == _layerOf(entry.key))
            .toSet(),
    };
    final sccs = _stronglyConnectedComponents(
      sameLayerDeps,
    ).where((component) => component.length > 1).toList();

    expect(
      sameLayerSccBaseline.length,
      6,
      reason: '同层 SCC 基线是 6 组；基线自身改动需与规则文档 §1.3 同步。',
    );
    expect(
      sccs.length,
      lessThanOrEqualTo(sameLayerSccBaseline.length),
      reason:
          '同层循环依赖从 ${sameLayerSccBaseline.length} 组涨到 ${sccs.length} 组，'
          '超过冻结基线。同层循环虽合法，但新增的互相咬合必须显式评审：\n'
          '${_describeSccs(sccs, _layerOf)}',
    );
  });

  test('composition root exemption is exactly lib/main.dart', () {
    // ⚠️ 这里必须与**内联字面量**比较，不能与 `compositionRootPaths` 自身比较：
    // `_layerOf` 只在 `compositionRootPaths.contains(path)` 时返回
    // `layerCompositionRoot`，两者对比是同义反复（往常量里加任何存在的文件都恒绿）。
    // 字面量是这条断言的独立 oracle。
    const expectedCompositionRoots = ['lib/main.dart'];

    expect(
      compositionRootPaths.length,
      1,
      reason:
          '组合根豁免有且只有一个（`lib/main.dart`）；当前常量含 '
          '${compositionRootPaths.length} 个：${_sorted(compositionRootPaths)}。',
    );

    final exempt = <String>[];
    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final path = _normalizePath(entity.path);
      if (path == null) continue;
      if (_layerOf(path) == layerCompositionRoot) exempt.add(path);
    }
    expect(
      exempt..sort(),
      expectedCompositionRoots,
      reason:
          '组合根豁免范围变了。豁免只给 `lib/main.dart`；`lib/entry.dart` 是待拆的'
          '混杂装配文件，按 L3 参与判定（规则文档 §7 OBS-1）。',
    );
    expect(
      compositionRootPaths.toList()..sort(),
      expectedCompositionRoots,
      reason: '`compositionRootPaths` 常量本身也只允许 `lib/main.dart`。',
    );
    expect(
      _layerOf('lib/entry.dart'),
      layerPresentation,
      reason: '`lib/entry.dart` 必须按 L3 计入方向判定，不得被当成组合根。',
    );
  });

  test('barrel layer covers every re-exported file', () {
    final graph = _collectGraph();
    final violations = <String>[];
    for (final barrel in graph.exportOnlyFiles) {
      final barrelLayer = _layerOf(barrel);
      if (barrelLayer == null || barrelLayer == layerCompositionRoot) continue;
      for (final target in graph.edges[barrel] ?? const <String>{}) {
        final targetLayer = _layerOf(target);
        if (targetLayer == null || targetLayer == layerCompositionRoot) {
          continue;
        }
        if (barrelLayer < targetLayer) {
          violations.add(
            '$barrel(L$barrelLayer) re-exports $target(L$targetLayer)',
          );
        }
      }
    }
    expect(
      violations,
      isEmpty,
      reason:
          'barrel 的层低于它 re-export 的文件：消费者经 barrel 就能拿到上层类型。\n'
          '${_sorted(violations)}',
    );
  });

  // ── fixture：词法扫描器（原有语义，保持不变）──────────────────────────────

  test('F1: multiple and comment-prefixed import directives are collected', () {
    const source = '''
/* prefix */ import 'package:pure_music/core/a.dart';
import 'package:pure_music/services/b.dart'; import 'package:pure_music/services/c.dart' as c;
''';
    expect(_crossLayerEdges('lib/core/fixture.dart', source), [
      'lib/core/fixture.dart -> lib/services/b.dart',
      'lib/core/fixture.dart -> lib/services/c.dart',
    ]);
  });

  test('F2: import-looking text in comments or strings is ignored', () {
    const source = r'''
// import 'package:pure_music/services/line_comment.dart';
/* block comment
import 'package:pure_music/services/block_comment.dart';
*/
/* prefix import 'package:pure_music/services/block_prefix.dart'; */
const note = "import 'package:pure_music/services/in_double_quote.dart';";
const rawNote = r'import "package:pure_music/services/in_raw_string.dart";';
import 'package:pure_music/services/real.dart';
''';
    expect(_crossLayerEdges('lib/core/fixture.dart', source), [
      'lib/core/fixture.dart -> lib/services/real.dart',
    ]);
  });

  test('F3: root-escaping and absolute paths are ignored', () {
    const source = '''
import '../../../../outside.dart';
import '/absolute.dart';
import 'file:///absolute.dart';
import '../../services/relative.dart';
import 'package:pure_music/services/real.dart';
''';
    expect(_crossLayerEdges('lib/core/deep/fixture.dart', source), [
      'lib/core/deep/fixture.dart -> lib/services/real.dart',
      'lib/core/deep/fixture.dart -> lib/services/relative.dart',
    ]);
  });

  // ── fixture：分层方向判定 ────────────────────────────────────────────────

  test('F4: export directives take part in the dependency graph', () {
    const source = '''
import 'package:pure_music/core/enums.dart';
export 'package:pure_music/services/music_platform/index.dart';
''';
    expect(_dependencyEdges('lib/core/index.dart', source), [
      'lib/core/index.dart -> lib/core/enums.dart',
      'lib/core/index.dart -> lib/services/music_platform/index.dart',
    ]);
  });

  test(
    'F5: layer resolution follows root, override, core list, then directory',
    () {
      expect(_layerOf('lib/main.dart'), layerCompositionRoot);
      expect(_layerOf('lib/entry.dart'), layerPresentation);
      // 逐文件覆盖优先于目录默认
      expect(
        _layerOf('lib/component/hotkey_ui_feedback.dart'),
        layerInfrastructure,
      );
      expect(
        _layerOf('lib/component/mini_now_playing.dart'),
        layerPresentation,
      );
      // core 逐文件清单优先于目录默认（core 目录默认是 L1）
      expect(_layerOf('lib/core/enums.dart'), layerBasicModel);
      expect(_layerOf('lib/core/preference.dart'), layerInfrastructure);
      expect(_layerOf('lib/core/matcher.dart'), layerDomainService);
      // 目录默认
      expect(
        _layerOf('lib/services/online_lyric/parsed_lyric_converter.dart'),
        layerDomainService,
      );
      expect(
        _layerOf('lib/native/rust/api/tag_reader.dart'),
        layerInfrastructure,
      );
      // 未登记
      expect(_layerOf('lib/unknown/whatever.dart'), isNull);
      expect(_layerOf('test/fixture.dart'), isNull);
    },
  );

  test('F6: upward edges are detected, same/downward edges are not', () {
    expect(
      _isUpward('lib/core/utils.dart', 'lib/page/home_page.dart'),
      isTrue,
      reason: 'L1 → L3 必须判为向上',
    );
    expect(
      _isUpward(
        'lib/core/preference.dart',
        'lib/services/music_platform/index.dart',
      ),
      isTrue,
      reason: 'L1 → L2 必须判为向上',
    );
    expect(
      _isUpward(
        'lib/services/online_lyric/api/net_lyric_api.dart',
        'lib/core/settings.dart',
      ),
      isFalse,
      reason: 'L2 → L1 是向下，合法',
    );
    expect(
      _isUpward(
        'lib/core/matcher.dart',
        'lib/services/online_lyric/api/net_lyric_api.dart',
      ),
      isFalse,
      reason: 'L2 → L2 同层，合法',
    );
    expect(
      _isUpward('lib/core/preference.dart', 'lib/core/utils.dart'),
      isFalse,
      reason: 'L1 → L1 同层，合法',
    );
    expect(
      _isUpward('lib/main.dart', 'lib/page/home_page.dart'),
      isFalse,
      reason: '组合根豁免',
    );
    expect(
      _isUpward('lib/unknown/a.dart', 'lib/page/home_page.dart'),
      isFalse,
      reason: '未登记层不参与判定（由覆盖率测试兜住）',
    );
  });

  test('F7: transitive reachability ignores allowlisted direct edges', () {
    const graph = <String, Set<String>>{
      'lib/core/memory_monitor.dart': {'lib/core/matcher.dart'},
      'lib/core/matcher.dart': {'lib/core/utils.dart'},
    };
    expect(_reachable('lib/core/memory_monitor.dart', graph), {
      'lib/core/matcher.dart',
      'lib/core/utils.dart',
    });

    // 允许清单只豁免直接边：移除后不得再经中间文件到达上层
    const filtered = <String, Set<String>>{
      'lib/core/memory_monitor.dart': <String>{},
      'lib/core/matcher.dart': {'lib/core/utils.dart'},
    };
    expect(_reachable('lib/core/memory_monitor.dart', filtered), isEmpty);
  });

  test('F8: layer quotient cycles are detected', () {
    expect(
      _findLayerCycles({
        layerBasicModel: {layerInfrastructure},
        layerInfrastructure: {layerBasicModel},
      }),
      isNotEmpty,
      reason: 'L0 ⇄ L1 必须判为环',
    );
    expect(
      _findLayerCycles({
        layerDomainService: {layerBasicModel, layerInfrastructure},
        layerPresentation: {
          layerBasicModel,
          layerInfrastructure,
          layerDomainService,
        },
      }),
      isEmpty,
      reason: '严格向下的层图必须判为无环',
    );
  });
}

// ═══════════════════════════════════════════════════════════════════════════
// 图收集与分层判定
// ═══════════════════════════════════════════════════════════════════════════

class _LibGraph {
  _LibGraph(this.files, this.edges, this.exportOnlyFiles);

  final List<String> files;
  final Map<String, Set<String>> edges;
  final Set<String> exportOnlyFiles;
}

/// 扫描整个 `lib/`，收集文件清单、依赖边与 barrel（只有指令、无声明）。
_LibGraph _collectGraph() {
  final files = <String>[];
  final edges = <String, Set<String>>{};
  final exportOnly = <String>{};
  for (final entity in Directory('lib').listSync(recursive: true)) {
    if (entity is! File || !entity.path.endsWith('.dart')) continue;
    final path = _normalizePath(entity.path);
    if (path == null) continue;
    files.add(path);
    final source = entity.readAsStringSync();
    edges[path] = _dependencyEdges(path, source).map(_edgeTarget).toSet();
    if (_isDirectiveOnly(source)) exportOnly.add(path);
  }
  files.sort();
  return _LibGraph(files, edges, exportOnly);
}

/// 路径 → 层号；未登记返回 `null`。
int? _layerOf(String path) {
  if (compositionRootPaths.contains(path)) return layerCompositionRoot;
  final override = fileLayerOverrides[path];
  if (override != null) return override;
  final core = coreFileLayers[path];
  if (core != null) return core;
  for (final entry in directoryLayers.entries) {
    if (path.startsWith(entry.key)) return entry.value;
  }
  return null;
}

/// `from` 是否**向上**依赖 `to`（同层、向下、任一未登记、组合根都不算向上）。
bool _isUpward(String from, String to) {
  final fromLayer = _layerOf(from);
  final toLayer = _layerOf(to);
  if (fromLayer == null || toLayer == null) return false;
  if (fromLayer == layerCompositionRoot) return false;
  if (toLayer == layerCompositionRoot) return false;
  return fromLayer < toLayer;
}

/// 全仓库的向上边集合，元素形如 `a.dart -> b.dart`。
Set<String> _upwardEdges(_LibGraph graph) {
  final result = <String>{};
  for (final entry in graph.edges.entries) {
    for (final target in entry.value) {
      if (_isUpward(entry.key, target)) {
        result.add('${entry.key} -> $target');
      }
    }
  }
  return result;
}

/// 从 `start` 出发沿 [graph] 可达的文件（不含 `start` 自身，除非有环回到自己）。
Set<String> _reachable(String start, Map<String, Set<String>> graph) {
  final seen = <String>{};
  final queue = <String>[...?graph[start]];
  while (queue.isNotEmpty) {
    final current = queue.removeLast();
    if (!seen.add(current)) continue;
    queue.addAll(graph[current] ?? const <String>{});
  }
  return seen;
}

/// 在层商图（层 → 可达层）上找环，返回可读的环路径。
List<String> _findLayerCycles(Map<int, Set<int>> quotient) {
  final cycles = <String>[];
  void visit(int layer, List<int> path) {
    final index = path.indexOf(layer);
    if (index >= 0) {
      cycles.add([...path.sublist(index), layer].map((l) => 'L$l').join(' → '));
      return;
    }
    for (final next in quotient[layer] ?? const <int>{}) {
      visit(next, [...path, layer]);
    }
  }

  for (final layer in quotient.keys) {
    visit(layer, const []);
  }
  return cycles;
}

String _edgeTarget(String edge) => edge.split(' -> ').last;

List<String> _sorted(Iterable<String> values) => values.toList()..sort();

/// 强连通分量（Kosaraju）。返回的每个分量都已排序，且整体按首元素排序。
///
/// 用于同层环检测：层商图把同层边折叠掉了，看不到 `L2 ⇄ L2` 这类环。
List<List<String>> _stronglyConnectedComponents(
  Map<String, Set<String>> graph,
) {
  final nodes = <String>{...graph.keys, for (final vs in graph.values) ...vs};
  final visited = <String>{};
  final order = <String>[];

  void firstPass(String node) {
    if (!visited.add(node)) return;
    for (final next in graph[node] ?? const <String>{}) {
      firstPass(next);
    }
    order.add(node);
  }

  for (final node in nodes) {
    firstPass(node);
  }

  final reversed = <String, Set<String>>{};
  for (final entry in graph.entries) {
    for (final target in entry.value) {
      reversed.putIfAbsent(target, () => <String>{}).add(entry.key);
    }
  }

  final assigned = <String>{};
  final components = <List<String>>[];
  void secondPass(String node, List<String> sink) {
    if (!assigned.add(node)) return;
    sink.add(node);
    for (final next in reversed[node] ?? const <String>{}) {
      secondPass(next, sink);
    }
  }

  for (final node in order.reversed) {
    if (assigned.contains(node)) continue;
    final component = <String>[];
    secondPass(node, component);
    components.add(component..sort());
  }
  components.sort((a, b) => a.first.compareTo(b.first));
  return components;
}

String _describeSccs(List<List<String>> sccs, int? Function(String) layerOf) =>
    sccs.map((c) => 'L${layerOf(c.first)}: ${c.join(' ↔ ')}').join('\n');

/// 只有 import/export 指令、没有实际声明的文件（barrel）。
bool _isDirectiveOnly(String source) {
  var sawExport = false;
  for (final line in source.split('\n')) {
    final trimmed = line.trim();
    if (trimmed.isEmpty || trimmed.startsWith('//')) continue;
    if (trimmed.startsWith('/*') || trimmed.startsWith('*')) continue;
    if (trimmed.startsWith('import ')) continue;
    if (trimmed.startsWith('export ')) {
      sawExport = true;
      continue;
    }
    // 多行指令的续行（URI、show/hide 列表、分号）
    if (trimmed.startsWith("'") || trimmed.startsWith('"')) continue;
    if (trimmed.startsWith('show ') || trimmed.startsWith('hide ')) continue;
    if (RegExp(r'^[A-Za-z_][A-Za-z0-9_]*;?$').hasMatch(trimmed)) continue;
    return false;
  }
  return sawExport;
}

// ═══════════════════════════════════════════════════════════════════════════
// 词法扫描
// ═══════════════════════════════════════════════════════════════════════════

/// 计算单个源文件与 `lib/core` / `lib/services` 之间的直接 import 边
/// （用于 core↔services 冻结基线与 fixture 单测）。
List<String> _crossLayerEdges(String sourcePath, String source) {
  final sourceIsCore = sourcePath.startsWith('lib/core/');
  final sourceIsServices = sourcePath.startsWith('lib/services/');
  if (!sourceIsCore && !sourceIsServices) return const [];

  final edges = <String>[];
  for (final uri in _importUris(source)) {
    final targetPath = _resolveImport(sourcePath, uri);
    if (targetPath == null) continue;
    final targetIsCore = targetPath.startsWith('lib/core/');
    final targetIsServices = targetPath.startsWith('lib/services/');
    if ((sourceIsCore && targetIsServices) ||
        (sourceIsServices && targetIsCore)) {
      edges.add('$sourcePath -> $targetPath');
    }
  }
  edges.sort();
  return edges;
}

/// 单个源文件的全部仓库内依赖边（`import` 与 `export` 都算，因为 `export`
/// 同样把被导出库拖进消费者的可见范围）。
List<String> _dependencyEdges(String sourcePath, String source) {
  final edges = <String>{};
  for (final uri in _directiveUris(source)) {
    final targetPath = _resolveImport(sourcePath, uri);
    if (targetPath == null || targetPath == sourcePath) continue;
    edges.add('$sourcePath -> $targetPath');
  }
  return edges.toList()..sort();
}

/// 收集全部 `import` 与 `export` 指令中的 URI 字符串（含条件导入的多候选形式）。
///
/// 先做最小词法扫描：忽略行/块注释（块注释支持嵌套），跳过字符串字面量，
/// 因此同一行多条指令与注释后的指令都能识别，而注释/字符串里的
/// “import” 文本不会被误计。不解析 `part`、插值表达式或语义。
List<String> _directiveUris(String source) =>
    _scanUris(source, const {'import', 'export'});

/// 只收集 `import` 指令的 URI（保持 core↔services 冻结基线原有语义）。
List<String> _importUris(String source) => _scanUris(source, const {'import'});

List<String> _scanUris(String source, Set<String> keywords) {
  final uris = <String>[];
  var i = 0;
  while (i < source.length) {
    final char = source[i];
    final next = i + 1 < source.length ? source[i + 1] : '';
    if (char == '/' && next == '/') {
      i = _skipLineComment(source, i + 2);
      continue;
    }
    if (char == '/' && next == '*') {
      i = _skipBlockComment(source, i);
      continue;
    }
    if (_isQuote(char)) {
      i = _scanString(source, i).end;
      continue;
    }
    if (_isIdentifierStart(char)) {
      final start = i;
      i++;
      while (i < source.length && _isIdentifierPart(source[i])) {
        i++;
      }
      if (keywords.contains(source.substring(start, i))) {
        final directive = _scanDirective(source, i);
        if (directive != null) {
          uris.addAll(directive.uris);
          i = directive.end;
        }
      }
      continue;
    }
    i++;
  }
  return uris;
}

class _DirectiveScan {
  const _DirectiveScan(this.uris, this.end);

  final List<String> uris;
  final int end;
}

class _StringScan {
  const _StringScan(this.value, this.end);

  final String value;
  final int end;
}

/// 从 `import` / `export` 关键字之后扫描到分号，收集其中的字符串字面量。
_DirectiveScan? _scanDirective(String source, int start) {
  final uris = <String>[];
  var i = start;
  while (i < source.length) {
    final char = source[i];
    final next = i + 1 < source.length ? source[i + 1] : '';
    if (char == ';') {
      return uris.isEmpty ? null : _DirectiveScan(uris, i + 1);
    }
    if (char == '/' && next == '/') {
      i = _skipLineComment(source, i + 2);
      continue;
    }
    if (char == '/' && next == '*') {
      i = _skipBlockComment(source, i);
      continue;
    }
    if (_isQuote(char)) {
      final string = _scanString(source, i);
      uris.add(string.value);
      i = string.end;
      continue;
    }
    i++;
  }
  return null;
}

/// 读取一个字符串字面量；支持 raw 前缀与三引号，普通字符串处理转义。
_StringScan _scanString(String source, int start) {
  final quote = source[start];
  final raw =
      start > 0 &&
      (source[start - 1] == 'r' || source[start - 1] == 'R') &&
      (start < 2 || !_isIdentifierPart(source[start - 2]));
  final triple =
      start + 2 < source.length &&
      source[start + 1] == quote &&
      source[start + 2] == quote;
  var i = start + (triple ? 3 : 1);
  final value = StringBuffer();

  while (i < source.length) {
    final char = source[i];
    if (!raw && char == '\\' && i + 1 < source.length) {
      value.write(source[i + 1]);
      i += 2;
      continue;
    }
    if (triple) {
      if (char == quote &&
          i + 2 < source.length &&
          source[i + 1] == quote &&
          source[i + 2] == quote) {
        return _StringScan(value.toString(), i + 3);
      }
    } else if (char == quote) {
      return _StringScan(value.toString(), i + 1);
    }
    value.write(char);
    i++;
  }
  return _StringScan(value.toString(), i);
}

int _skipLineComment(String source, int start) {
  var i = start;
  while (i < source.length && source[i] != '\n' && source[i] != '\r') {
    i++;
  }
  return i;
}

/// `start` 指向 `/*`；Dart 块注释可嵌套。
int _skipBlockComment(String source, int start) {
  var depth = 0;
  var i = start;
  while (i < source.length) {
    if (source.startsWith('/*', i)) {
      depth++;
      i += 2;
    } else if (source.startsWith('*/', i)) {
      depth--;
      i += 2;
      if (depth == 0) return i;
    } else {
      i++;
    }
  }
  return i;
}

bool _isQuote(String char) => char == "'" || char == '"';

bool _isIdentifierStart(String char) {
  final code = char.codeUnitAt(0);
  return char == '_' ||
      char == r'$' ||
      (code >= 65 && code <= 90) ||
      (code >= 97 && code <= 122);
}

bool _isIdentifierPart(String char) {
  final code = char.codeUnitAt(0);
  return _isIdentifierStart(char) || (code >= 48 && code <= 57);
}

/// 把 import URI 解析为仓库内 `lib/...` 路径；本包之外、绝对路径或越根路径
/// 返回 `null`。
String? _resolveImport(String sourcePath, String uri) {
  const packagePrefix = 'package:pure_music/';
  if (uri.startsWith(packagePrefix)) {
    return _normalizePath('lib/${uri.substring(packagePrefix.length)}');
  }
  if (uri.startsWith('dart:') || uri.startsWith('package:')) return null;
  if (uri.startsWith('/')) return null;
  final parsed = Uri.tryParse(uri);
  if (parsed == null || parsed.hasScheme) return null;
  final sourceDir = sourcePath.split('/')..removeLast();
  return _normalizePath('${sourceDir.join('/')}/$uri');
}

/// 统一为 `/` 分隔、无 `.`/`..` 的相对仓库路径；越过仓库根时返回 `null`。
String? _normalizePath(String path) {
  final parts = <String>[];
  for (final part in path.replaceAll('\\', '/').split('/')) {
    if (part.isEmpty || part == '.') continue;
    if (part == '..') {
      if (parts.isEmpty) return null;
      parts.removeLast();
      continue;
    }
    parts.add(part);
  }
  return parts.isEmpty ? null : parts.join('/');
}
