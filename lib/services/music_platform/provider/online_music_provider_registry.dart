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

/// 由配置层提供的**身份版**「显式候选」查询（2.2 / G5）。
///
/// 只在装配层能提供它时使用（`OnlineMusicSettings.explicitCandidateIdsForIdentity`）；
/// 这样两个自定义平台可以分别指定候选，而内置平台的语义与
/// [OnlineMusicExplicitCandidates] 完全一致。
typedef OnlineMusicExplicitCandidatesForIdentity =
    List<String> Function(
      PlatformIdentity identity,
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
    OnlineMusicExplicitCandidatesForIdentity? explicitCandidatesForIdentity,
    Iterable<PlatformIdentity> enabledPlatforms = const {},
    Map<String, PlatformIdentity> providerIdentities = const {},
  }) : _explicitCapabilityProviders = Map.unmodifiable(capabilityProviders),
       _identities = Map.unmodifiable(providerIdentities),
       _explicitCandidates = explicitCandidates,
       _explicitCandidatesForIdentity = explicitCandidatesForIdentity,
       _enabledPlatforms = Set.unmodifiable({
         for (final identity in enabledPlatforms) identity.normalized,
       }) {
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
  final OnlineMusicExplicitCandidatesForIdentity?
  _explicitCandidatesForIdentity;

  /// 已**启用**的平台**身份**集合；**空集 = 全部启用**
  /// （与 `OnlineMusicSettings.enabledPlatforms` 同义 —— P-55：这里以前也写成"被停用"，
  /// 与字段语义相反，见那边的详细说明）。
  ///
  /// 2.2 / G5（G7 修复）：元素是**平台身份**而不是枚举 —— 以前只录内置平台枚举，
  /// 而自定义身份的判定要求"该平台在启用集合内"，于是**只要用户停用过任一内置平台，
  /// 所有自定义平台的候选就恒为空**（调用报 `unavailable`，界面看不出真实原因）。
  /// 现在按身份判定：自定义平台有自己的 `custom:<稳定 ID>` 项，不再被内置平台的停用牵连。
  final Set<PlatformIdentity> _enabledPlatforms;

  /// F5-P-39（P2）：`providerId → 平台身份`。由装配层从各条目的
  /// `OnlineMusicProviderDefinition.identity` 派生（**配置是唯一事实源**）。
  ///
  /// 为什么需要注入而不是加接口：运行期 `OnlineMusicProvider` 只暴露 `providerId`，
  /// 若给它加身份访问器会波及**全部实现与测试替身**（F4 教训：`implements` 不继承实现）。
  final Map<String, PlatformIdentity> _identities;
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
  /// F5-P-39（P2）：按**平台身份**取候选 —— 平台级路由/聚合/日志都必须用它，
  /// 否则所有自定义平台共享 `MusicPlatform.custom` 会互相串台。
  ///
  /// - 身份**无效**（自定义平台缺稳定 ID）⇒ 返回空（**fail-closed**，不路由）；
  /// - **停用判定按身份**（2.2 / G5 / G7）：显示停用的内置平台不影响任何自定义平台的候选；
  /// - 内置平台 ⇒ 与身份化之前逐项等价（走同一显式候选与隐式推导）；
  /// - 自定义平台 ⇒ 在 `_supports` 基础上要求该 provider 的注入身份**等于**本身份。
  List<OnlineMusicProvider> providersForIdentity(
    PlatformIdentity identity,
    OnlineMusicCapability capability,
  ) {
    if (!identity.isValid) return const [];
    final normalized = identity.normalized;
    if (_enabledPlatforms.isNotEmpty &&
        !_enabledPlatforms.contains(normalized)) {
      return const [];
    }
    final explicitIds = _explicitIdsForIdentity(normalized, capability);
    bool matches(OnlineMusicProvider provider) =>
        _supports(provider, normalized.platform, capability) &&
        (!normalized.isCustom ||
            _identities[provider.providerId]?.normalized == normalized);
    if (explicitIds.isNotEmpty) {
      final explicit = <OnlineMusicProvider>[];
      for (final id in explicitIds) {
        final provider = _providers[id];
        if (provider == null || explicit.contains(provider)) continue;
        if (matches(provider)) explicit.add(provider);
      }
      return List.unmodifiable(explicit);
    }
    return List.unmodifiable([
      for (final provider in _providers.values)
        if (matches(provider)) provider,
    ]);
  }

  /// P-63: identities of providers supporting the capability (availability judgement source).
  Set<PlatformIdentity> identitiesFor(OnlineMusicCapability capability) {
    final result = <PlatformIdentity>{};
    for (final provider in _providers.values) {
      final platforms = provider.platformsFor(capability);
      if (platforms.isEmpty) continue;
      final identity = _identities[provider.providerId];
      // 自定义 provider 必须在启用集合内（与 `providersForIdentity` 同一判据）。
      if (identity != null &&
          _enabledPlatforms.isNotEmpty &&
          !_enabledPlatforms.contains(identity.normalized)) {
        continue;
      }
      result.add(identity ?? PlatformIdentity.builtin(platforms.first));
    }
    return Set.unmodifiable(result);
  }

  /// 该能力下**按平台身份**的可用集合（含内置平台身份）。
  ///
  /// 与 [identitiesFor] 的差别：过滤掉**候选为空**的身份（例如显式候选全部失效、
  /// 或该自定义平台下没有支持此能力的条目），因此界面据此回答"谁真的能搜"。
  Set<PlatformIdentity> candidatesIdentitiesFor(
    OnlineMusicCapability capability,
  ) => {
    for (final identity in identitiesFor(capability))
      if (providersForIdentity(identity, capability).isNotEmpty) identity,
  };

  /// 内置平台版候选（既有调用点保持不变）。
  List<OnlineMusicProvider> providersFor(
    MusicPlatform platform,
    OnlineMusicCapability capability,
  ) {
    // `custom` 是**枚举级**查询（能力集合/门槛用：两个自定义平台共用一个枚举键）。
    // 逐个身份判定启用状态：任一自定义平台启用即可，不让内置平台的停用牵连它（G7）。
    if (platform == MusicPlatform.custom) {
      return List.unmodifiable([
        for (final provider in _providers.values)
          if (_providerIdentityEnabled(provider) &&
              _supports(provider, platform, capability))
            provider,
      ]);
    }
    return providersForIdentity(PlatformIdentity.builtin(platform), capability);
  }

  /// 该 provider 的身份当前是否启用（空集 = 全部启用；身份未知 ⇒ 安全方向为不启用）。
  bool _providerIdentityEnabled(OnlineMusicProvider provider) {
    if (_enabledPlatforms.isEmpty) return true;
    final identity = _identities[provider.providerId];
    if (identity == null) return false;
    return _enabledPlatforms.contains(identity.normalized);
  }

  /// 显式候选 id：配置层提供了 [OnlineMusicExplicitCandidatesForIdentity] /
  /// [OnlineMusicExplicitCandidates] 就用它，否则退回旧的**平台无关单值**选择。
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
  List<String> _explicitIdsForIdentity(
    PlatformIdentity identity,
    OnlineMusicCapability capability,
  ) {
    final identityResolver = _explicitCandidatesForIdentity;
    if (identityResolver != null) {
      return identityResolver(identity, capability);
    }
    final resolver = _explicitCandidates;
    if (resolver != null) return resolver(identity.platform, capability);
    final legacyId = _explicitCapabilityProviders[capability];
    if (legacyId == null) return const [];
    final provider = _providers[legacyId];
    if (provider == null ||
        !_supports(provider, identity.platform, capability)) {
      return const [];
    }
    if (identity.isCustom &&
        _identities[legacyId]?.normalized != identity.normalized) {
      return const [];
    }
    return [legacyId];
  }

  /// 某能力在**所有平台**上的可用集合，按候选推导（多 Provider 取并集）。
  ///
  /// 与旧的「看被选中的那一个 Provider 声明了什么」不同：这里回答的是
  /// "这个平台到底有没有能用的 Provider"，这正是平台门槛（D3）需要的依据。
  Set<MusicPlatform> platformsFor(OnlineMusicCapability capability) => {
    // ⚠️ 这里**必须**用 `MusicPlatform.values`（含 `custom`）：能力集合是**路由/门槛**依据，
    // 不是界面枚举。若排除 `custom`，自定义平台会在聚合门槛处被丢掉（provider 一个请求都收不到）。
    // 自定义平台之间的区分由 `providersForIdentity`（稳定 ID）负责，不靠这里。
    for (final platform in MusicPlatform.values)
      if (providersFor(platform, capability).isNotEmpty) platform,
  };

  static bool _supports(
    OnlineMusicProvider provider,
    MusicPlatform platform,
    OnlineMusicCapability capability,
  ) => provider.platformsFor(capability).contains(platform);
}
