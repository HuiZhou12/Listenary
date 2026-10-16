/// 探测候选的**来源策略**（D-F3-1 / D-F3-5）。
///
/// 为什么单独一个文件：策略是"**谁**该被探测"的判定，探测本身（`provider_probe.dart`）
/// 只负责"按给定顺序各试一次并说清结论"。把两者分开，才能对策略单独下断言
/// （尤其是"条目有绑定就**不得**退回模板"这条 D-F3-1 第 4 条）。
library;

// `probeCapableCapabilities`（哪些能力可作服务级探针）定义在**声明式层**：
// 它是探测自身的契约，放在这里会形成 provider→declarative→provider 的循环依赖。
import 'package:pure_music/services/music_platform/declarative/declarative_probe_contract.dart';
import 'package:pure_music/services/music_platform/declarative/provider_probe.dart';
import 'package:pure_music/services/music_platform/declarative/provider_templates.dart';
import 'package:pure_music/services/music_platform/provider/online_music_binding.dart';
import 'package:pure_music/services/music_platform/provider/online_music_capability.dart';
import 'package:pure_music/services/music_platform/provider/online_music_provider_settings.dart';

/// 给该条目构造**探测候选**（列表顺序 = 执行顺序）。
///
/// D-F3-1 的四条：
/// 1. **优先**条目自身**实际存在**的声明式绑定；先 search，没有 search 再看下一个
///    可探测能力（D-F3-5 第 1/2 条）；
/// 2. 只有该条目**完全没有**声明式绑定时，才用兼容模板（D-F3-1 第 2 条），
///    并在候选里如实标注来源（第 3 条）；
/// 3. 条目**有**绑定（哪怕写坏了、哪怕不是可探测的能力）时**绝不**退回模板 ——
///    用模板的成功掩盖用户配置的问题正是 D-F3-1 第 4 条禁止的；
/// 4. 不做开放式扫描、不引入插件/动态发现（模板仍是编译期闭集）。
List<ProviderProbeCandidate> probeCandidatesFor(
  OnlineMusicProviderDefinition definition, {
  List<OnlineMusicProviderTemplate>? templates,
}) {
  final userCandidates = <ProviderProbeCandidate>[
    for (final capability in probeCapableCapabilities)
      if (definition.bindingFor(capability)
          case final OnlineMusicDeclarativeCapabilityBinding binding)
        ProviderProbeCandidate(
          id: 'user:${capability.name}',
          label: '条目自身配置',
          binding: binding,
          capability: capability,
          source: ProviderProbeCandidateSource.userConfig,
        ),
  ];
  if (userCandidates.isNotEmpty) return List.unmodifiable(userCandidates);

  // 条目**已经**配了绑定（只是这些能力不适合服务级探测）⇒ 也不退回模板。
  if (_hasAnyDeclarativeBinding(definition)) return const [];

  return List.unmodifiable([
    for (final template in templates ?? onlineMusicProviderTemplates())
      ProviderProbeCandidate.fromTemplate(template),
  ]);
}

/// 该条目是否**已经**有任何声明式绑定（用于"绝不退回模板"这条边界）。
bool hasAnyDeclarativeBinding(OnlineMusicProviderDefinition definition) =>
    _hasAnyDeclarativeBinding(definition);

bool _hasAnyDeclarativeBinding(OnlineMusicProviderDefinition definition) => [
  for (final capability in OnlineMusicCapability.values)
    definition.bindingFor(capability),
].any((binding) => binding is OnlineMusicDeclarativeCapabilityBinding);

/// 没有候选时**如实**说明原因（不要把"该条目配的能力不适合服务级探测"
/// 说成"该条目没有绑定"，也不要说成"候选都没通过"）。
String noProbeCandidateReason(OnlineMusicProviderDefinition definition) =>
    _hasAnyDeclarativeBinding(definition)
    ? '该条目已配置的绑定都不适合服务级探测（探测只验不需要实体 ID 就能独立执行的能力，'
          '如搜索 / 新歌 / 歌单列表 / 歌单分类 / 榜单）：请用「试跑」逐能力验证'
          '（需要曲目或歌单 ID 的能力只能试跑，探测不会伪造 ID）'
    : '没有可执行的探测候选（该条目没有声明式绑定，也没有可用的兼容模板）';
