import 'package:pure_music/services/music_platform/models/music_models.dart';
import 'package:pure_music/services/music_platform/provider/online_music_capability.dart';
import 'package:pure_music/services/music_platform/provider/online_music_provider.dart';

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
  }) : _explicitCapabilityProviders = Map.unmodifiable(capabilityProviders) {
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
  late final OnlineMusicProvider _defaultProvider;
  late final Map<OnlineMusicCapability, OnlineMusicProvider> _selectedProviders;

  /// 已注册的 Provider，按注册顺序去重。
  Iterable<OnlineMusicProvider> get providers => _providers.values;

  OnlineMusicProvider get defaultProvider => _defaultProvider;

  OnlineMusicProvider providerFor(OnlineMusicCapability capability) =>
      _selectedProviders[capability]!;

  String providerIdFor(OnlineMusicCapability capability) =>
      providerFor(capability).providerId;

  /// `(platform, capability)` 的**有序候选 Provider**（D4:A）。
  ///
  /// 顺序：显式配置的能力选择（且该 Provider 确实支持该平台 + 该能力）优先，
  /// 其后按注册顺序补齐其它支持该平台 + 该能力的 Provider。
  ///
  /// 与 [providerFor] 的区别：前者是平台无关的单值 + 默认回落；这里是平台感知的候选
  /// 列表，**不含**任何默认回落。空列表是合法结果。
  List<OnlineMusicProvider> providersFor(
    MusicPlatform platform,
    OnlineMusicCapability capability,
  ) {
    final result = <OnlineMusicProvider>[];
    final explicitId = _explicitCapabilityProviders[capability];
    final explicit = explicitId == null ? null : _providers[explicitId];
    if (explicit != null && _supports(explicit, platform, capability)) {
      result.add(explicit);
    }
    for (final provider in _providers.values) {
      if (identical(provider, explicit)) continue;
      if (_supports(provider, platform, capability)) result.add(provider);
    }
    return List.unmodifiable(result);
  }

  static bool _supports(
    OnlineMusicProvider provider,
    MusicPlatform platform,
    OnlineMusicCapability capability,
  ) => provider.platformsFor(capability).contains(platform);
}
