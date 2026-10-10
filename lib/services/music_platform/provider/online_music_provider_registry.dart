import 'package:pure_music/services/music_platform/models/music_models.dart';
import 'package:pure_music/services/music_platform/provider/online_music_capability.dart';
import 'package:pure_music/services/music_platform/provider/online_music_provider.dart';

/// 由配置层提供的「显式候选」查询（D4:A）：`(platform, capability) → 有序 providerId`。
///
/// 提供它时，平台感知解析只用它（它已包含旧单值映射的回落语义，见
/// `OnlineMusicSettings.explicitCandidateIdsFor`）；不提供时退回旧行为。
typedef OnlineMusicExplicitCandidates =
    List<String> Function(
      MusicPlatform platform,
      OnlineMusicCapability capability,
    );

/// 能力 → Provider 的解析结果。
///
/// 两条解析路径刻意分开：
/// - [providerFor]／[providerIdFor]：**平台无关的单值**，保留旧语义（缺失或指向未注册
///   Provider 时回落默认 Provider），只用于兼容既有调用方与旧界面；
/// - [providersFor]：按 `(platform, capability)` 返回**有序候选**（D4:A），
///   并且**不做**任何平台无关的默认回落（D14）——空列表是合法结果，表示"该平台此能力
///   不可用"，由调用方报 `unavailable`。
final class OnlineMusicProviderRegistry {
  OnlineMusicProviderRegistry({
    required Iterable<OnlineMusicProvider> providers,
    String? defaultProviderId,
    Map<OnlineMusicCapability, String> capabilityProviders = const {},
    OnlineMusicExplicitCandidates? explicitCandidates,
    Iterable<MusicPlatform> enabledPlatforms = const {},
  }) : _explicitCapabilityProviders = Map.unmodifiable(capabilityProviders),
       _explicitCandidates = explicitCandidates,
       _enabledPlatforms = Set.unmodifiable(enabledPlatforms) {
    for (final provider in providers) {
      _providers.putIfAbsent(provider.providerId, () => provider);
    }
    if (_providers.isEmpty) {
      throw ArgumentError.value(
        providers,
        'providers',
        'At least one online music provider is required',
      );
    }
    final requestedDefault = defaultProviderId;
    _defaultProvider =
        (requestedDefault == null ? null : _providers[requestedDefault]) ??
        _providers.values.first;
    _selectedProviders = {
      for (final capability in OnlineMusicCapability.values)
        capability:
            _providers[capabilityProviders[capability]] ?? _defaultProvider,
    };
  }

  final Map<String, OnlineMusicProvider> _providers = {};
  final Map<OnlineMusicCapability, String> _explicitCapabilityProviders;
  final OnlineMusicExplicitCandidates? _explicitCandidates;

  /// 已**启用**的平台集合；**空集 = 全部启用**
  /// （与 `OnlineMusicSettings.enabledPlatforms` 同义 —— P-55：这里以前也写成"被停用"，
  /// 与字段语义相反，见那边的详细说明）。
  final Set<MusicPlatform> _enabledPlatforms;
  late final OnlineMusicProvider _defaultProvider;
  late final Map<OnlineMusicCapability, OnlineMusicProvider> _selectedProviders;

  /// 已注册的 Provider，按注册顺序去重。
  Iterable<OnlineMusicProvider> get providers => _providers.values;

  OnlineMusicProvider get defaultProvider => _defaultProvider;

  OnlineMusicProvider providerFor(OnlineMusicCapability capability) =>
      _selectedProviders[capability]!;

  String providerIdFor(OnlineMusicCapability capability) =>
      providerFor(capability).providerId;

  /// `(platform, capability)` 的**有序候选 Provider**（D4:A + D17:b）。
  ///
  /// 两条分支互斥：
  /// - **有显式候选**（用户给这个 `(platform, capability)` 指定过条目）⇒ 候选 =
  ///   **仅**这些条目中已注册且支持该平台 + 该能力的那些。**不再**按注册顺序补齐其它
  ///   条目：用户明确指派过的组合，不允许被"系统自己找的"隐式条目救场
  ///   （D17:b —— 避免"我为搜索指定的服务缺 Key 时被静默换成另一个我从未指派过的条目"）。
  ///   显式 id 全部被过滤掉时结果是空列表，该组合即 `unavailable`（§5.2）。
  /// - **没有显式候选** ⇒ 候选 = 按注册顺序推导的隐式条目（与引入 D17 之前一致），
  ///   此时回退仍在这些隐式条目之间按 §6.3 的 fail-closed 表进行（用户没有表达偏好，
  ///   故不存在"违背显式指定"的问题）。
  ///
  /// 与 [providerFor] 的区别：前者是平台无关的单值 + 默认回落；这里是平台感知的候选
  /// 列表，**不含**任何默认回落。空列表是合法结果。
  List<OnlineMusicProvider> providersFor(
    MusicPlatform platform,
    OnlineMusicCapability capability,
  ) {
    // 被用户停用的平台：候选一律按"空"处理 ⇒ 该平台的所有能力报 `unavailable`，
    // 并且它不会出现在 `platformsFor` 推导出的能力集合里（含 searchablePlatforms，D8:A）。
    if (_enabledPlatforms.isNotEmpty && !_enabledPlatforms.contains(platform)) {
      return const [];
    }
    final explicitIds = _explicitIdsFor(platform, capability);
    if (explicitIds.isNotEmpty) {
      final explicit = <OnlineMusicProvider>[];
      for (final id in explicitIds) {
        final provider = _providers[id];
        if (provider == null || explicit.contains(provider)) continue;
        if (_supports(provider, platform, capability)) explicit.add(provider);
      }
      return List.unmodifiable(explicit);
    }
    return List.unmodifiable([
      for (final provider in _providers.values)
        if (_supports(provider, platform, capability)) provider,
    ]);
  }

  /// 显式候选 id：配置层提供了 [OnlineMusicExplicitCandidates] 就用它，
  /// 否则退回旧的**平台无关单值**选择。
  ///
  /// 旧单值映射（`capabilities{cap → providerId}`）本身不含平台信息，D13:A 把它解释为
  /// "该 Provider **自己那个平台**上的候选"。因此它只有在这个 Provider 确实支持
  /// `(platform, capability)` 时才算一个显式候选；否则该组合视作**没有**显式候选，
  /// 继续按注册顺序推导隐式条目。
  ///
  /// ⚠️ 判据用的是 [_supports]（**运行期**那条规则，即 `platformsFor`），
  /// 与配置层 `explicitCandidateIdsFor` 现在的判据**同源**（F2-P59 把配置层从
  /// `contentPlatform` 改成运行期规则后，两边才真正一致 —— 以前注释里写"一致"，
  /// 实际是两套标准）。
  List<String> _explicitIdsFor(
    MusicPlatform platform,
    OnlineMusicCapability capability,
  ) {
    final resolver = _explicitCandidates;
    if (resolver != null) return resolver(platform, capability);
    final legacyId = _explicitCapabilityProviders[capability];
    if (legacyId == null) return const [];
    final provider = _providers[legacyId];
    if (provider == null || !_supports(provider, platform, capability)) {
      return const [];
    }
    return [legacyId];
  }

  /// 某能力在**所有平台**上的可用集合，按候选推导（多 Provider 取并集）。
  ///
  /// 与旧的「看被选中的那一个 Provider 声明了什么」不同：这里回答的是
  /// "这个平台到底有没有能用的 Provider"，这正是平台门槛（D3）需要的依据。
  Set<MusicPlatform> platformsFor(OnlineMusicCapability capability) => {
    for (final platform in builtinMusicPlatforms)
      if (providersFor(platform, capability).isNotEmpty) platform,
  };

  static bool _supports(
    OnlineMusicProvider provider,
    MusicPlatform platform,
    OnlineMusicCapability capability,
  ) => provider.platformsFor(capability).contains(platform);
}
