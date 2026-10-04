import 'package:pure_music/services/music_platform/provider/online_music_capability.dart';
import 'package:pure_music/services/music_platform/provider/online_music_provider.dart';

/// 能力 → Provider 的解析结果。
///
/// 选择只决定「用哪个 Provider 的哪个能力」；某个能力指向未注册的 Provider、
/// 或配置缺失时，该能力回落默认 Provider，不会把非法值交给调用方。
final class OnlineMusicProviderRegistry {
  OnlineMusicProviderRegistry({
    required Iterable<OnlineMusicProvider> providers,
    String? defaultProviderId,
    Map<OnlineMusicCapability, String> capabilityProviders = const {},
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
  late final OnlineMusicProvider _defaultProvider;
  late final Map<OnlineMusicCapability, OnlineMusicProvider> _selectedProviders;

  /// 已注册的 Provider，按注册顺序去重。
  Iterable<OnlineMusicProvider> get providers => _providers.values;

  OnlineMusicProvider get defaultProvider => _defaultProvider;

  bool isRegistered(String providerId) => _providers.containsKey(providerId);

  OnlineMusicProvider providerFor(OnlineMusicCapability capability) =>
      _selectedProviders[capability]!;

  String providerIdFor(OnlineMusicCapability capability) =>
      providerFor(capability).providerId;
}
