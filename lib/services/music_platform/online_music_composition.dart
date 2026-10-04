import 'package:pure_music/services/music_platform/chksz/chksz_credential_provider_factory.dart';
import 'package:pure_music/services/music_platform/chksz/chksz_online_music_provider.dart';
import 'package:pure_music/services/music_platform/chksz/chksz_provider_config.dart';
import 'package:pure_music/services/music_platform/chksz/chksz_runtime_factory.dart';
import 'package:pure_music/services/music_platform/online_music_credentials.dart';
import 'package:pure_music/services/music_platform/online_music_service.dart';
import 'package:pure_music/services/music_platform/provider/composite_online_music_service.dart';
import 'package:pure_music/services/music_platform/provider/online_music_provider_registry.dart';
import 'package:pure_music/services/music_platform/provider/online_music_provider_settings.dart';

/// 组合结果：应用层用的service，以及设置页用的凭据入口。
final class OnlineMusicComposition {
  const OnlineMusicComposition({
    required this.service,
    required this.credentials,
  });

  final OnlineMusicService service;
  final OnlineMusicCredentialController credentials;
}

/// 按配置装配在线音乐 Provider，并把每个能力接到被选中的 Provider。
///
/// 每个配置条目独立拥有自己的连接、认证与取消/配额状态；条目之间不共享凭据。
OnlineMusicComposition createOnlineMusicComposition({
  OnlineMusicSettings settings = OnlineMusicSettings.defaults,
  required bool portableBuild,
}) {
  final definitions = {
    for (final definition in settings.providers) definition.id: definition,
  };
  final providers = <ChkszOnlineMusicProvider>[];
  for (final definition in settings.providers) {
    final reference = definition.credentialReference;
    final runtime = createChkszRuntime(
      credentialProvider: reference == null
          ? null
          : createChkszCredentialProvider(
              portableBuild: portableBuild,
              credentialReference: reference,
            ),
      config: ChkszProviderConfig(
        baseUrl: definition.baseUrl,
        connectTimeout: definition.connectTimeout,
        sendTimeout: definition.sendTimeout,
        receiveTimeout: definition.receiveTimeout,
      ),
      authResolver: definition.authFor,
    );
    providers.add(
      ChkszOnlineMusicProvider(runtime: runtime, providerId: definition.id),
    );
  }

  final registry = OnlineMusicProviderRegistry(
    providers: providers,
    defaultProviderId: settings.defaultProviderId,
    capabilityProviders: settings.capabilityProviders,
  );

  return OnlineMusicComposition(
    service: CompositeOnlineMusicService(registry: registry),
    credentials: _credentialOwner(providers, definitions, registry),
  );
}

/// 设置页只管理一个 Provider 的凭据：优先默认 Provider，
/// 若它不需要凭据，则退到第一个需要凭据的条目；都不需要时仍用默认 Provider。
ChkszOnlineMusicProvider _credentialOwner(
  List<ChkszOnlineMusicProvider> providers,
  Map<String, OnlineMusicProviderDefinition> definitions,
  OnlineMusicProviderRegistry registry,
) {
  final defaultId = registry.defaultProvider.providerId;
  final owner = providers.firstWhere(
    (provider) => provider.providerId == defaultId,
  );
  if (definitions[owner.providerId]?.requiresCredential ?? false) return owner;
  for (final provider in providers) {
    if (definitions[provider.providerId]?.requiresCredential ?? false) {
      return provider;
    }
  }
  return owner;
}
