import 'package:dio/dio.dart';
import 'package:pure_music/services/music_platform/chksz/chksz_credential_provider_factory.dart';
import 'package:pure_music/services/music_platform/chksz/chksz_online_music_provider.dart';
import 'package:pure_music/services/music_platform/chksz/chksz_provider_config.dart';
import 'package:pure_music/services/music_platform/chksz/chksz_runtime_factory.dart';
import 'package:pure_music/services/music_platform/online_music_credentials.dart';
import 'package:pure_music/services/music_platform/online_music_service.dart';
import 'package:pure_music/services/music_platform/provider/composite_online_music_service.dart';
import 'package:pure_music/services/music_platform/provider/online_music_provider_registry.dart';
import 'package:pure_music/services/music_platform/provider/online_music_provider_settings.dart';

/// 组合结果：应用层用的 service，以及**每个条目各自**的凭据入口。
///
/// 设置页对已在运行的条目走这里的凭据入口（保留「更换 Key 会取消在途请求并清空配额」的语义）；
/// 对新增、尚未组装的条目则走设置控制器里的按引用访问。
final class OnlineMusicComposition {
  OnlineMusicComposition({
    required this.service,
    required Iterable<ChkszOnlineMusicProvider> providers,
  }) : credentialControllers = Map.unmodifiable({
         for (final provider in providers) provider.providerId: provider,
       });

  final OnlineMusicService service;
  final Map<String, OnlineMusicCredentialController> credentialControllers;
}

/// 为一个配置条目建立 ChkSz 连接配置。
ChkszProviderConfig chkszProviderConfigFor(
  OnlineMusicProviderDefinition definition,
) => ChkszProviderConfig(
  baseUrl: definition.baseUrl,
  connectTimeout: definition.connectTimeout,
  sendTimeout: definition.sendTimeout,
  receiveTimeout: definition.receiveTimeout,
);

/// 可注入的 Dio 出口；按条目提供，便于为每个条目绑定自己的连接。
typedef OnlineMusicDioFactory = Dio Function(
  OnlineMusicProviderDefinition definition,
);

/// 按配置装配在线音乐 Provider，并把每个能力接到被选中的 Provider。
///
/// 每个配置条目独立拥有自己的连接、认证与取消/配额状态；条目之间不共享凭据。
OnlineMusicComposition createOnlineMusicComposition({
  OnlineMusicSettings settings = OnlineMusicSettings.defaults,
  required bool portableBuild,
  OnlineMusicDioFactory? dioFactory,
}) {
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
      config: chkszProviderConfigFor(definition),
      authResolver: definition.authFor,
      dio: dioFactory?.call(definition),
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
    providers: providers,
  );
}
