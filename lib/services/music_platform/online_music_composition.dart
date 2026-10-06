import 'package:dio/dio.dart';
import 'package:pure_music/services/music_platform/chksz/chksz_credential_access.dart';
import 'package:pure_music/services/music_platform/chksz/chksz_online_music_provider.dart';
import 'package:pure_music/services/music_platform/chksz/chksz_provider_config.dart';
import 'package:pure_music/services/music_platform/chksz/chksz_runtime_factory.dart';
import 'package:pure_music/services/music_platform/declarative/declarative_http_transport.dart';
import 'package:pure_music/services/music_platform/declarative/declarative_music_provider.dart';
import 'package:pure_music/services/music_platform/models/music_models.dart';
import 'package:pure_music/services/music_platform/online_music_credentials.dart';
import 'package:pure_music/services/music_platform/online_music_request.dart';
import 'package:pure_music/services/music_platform/online_music_service.dart';
import 'package:pure_music/services/music_platform/provider/composite_online_music_service.dart';
import 'package:pure_music/services/music_platform/provider/online_music_binding.dart';
import 'package:pure_music/services/music_platform/provider/online_music_capability.dart';
import 'package:pure_music/services/music_platform/provider/online_music_provider.dart';
import 'package:pure_music/services/music_platform/provider/online_music_provider_auth.dart';
import 'package:pure_music/services/music_platform/provider/online_music_quality_tiers.dart';
import 'package:pure_music/services/music_platform/provider/online_music_provider_registry.dart';
import 'package:pure_music/services/music_platform/provider/online_music_provider_settings.dart';

/// 组合结果：应用层用的 service，以及**每个条目各自**的凭据入口。
final class OnlineMusicComposition {
  OnlineMusicComposition({
    required this.service,
    required Iterable<OnlineMusicProvider> providers,
    required Map<String, OnlineMusicCredentialController> credentialControllers,
  }) : credentialControllers = Map.unmodifiable(credentialControllers);

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
typedef OnlineMusicDioFactory =
    Dio Function(OnlineMusicProviderDefinition definition);

/// 按配置装配在线音乐 Provider，并把每个能力接到被选中的实现。
///
/// 分派点是 §5.6：`builtin` 走代码实现（ChkSz），`http` 走声明式引擎，
/// 缺失/`unsupported` 则该能力不被注册 → 上层报 `unavailable`。
OnlineMusicComposition createOnlineMusicComposition({
  OnlineMusicSettings settings = OnlineMusicSettings.defaults,
  required bool portableBuild,
  OnlineMusicDioFactory? dioFactory,
  ChkszCredentialAccess? credentialAccess,
}) {
  final access =
      credentialAccess ?? ChkszCredentialAccess(portableBuild: portableBuild);
  final providers = <OnlineMusicProvider>[];
  final credentialControllers = <String, OnlineMusicCredentialController>{};

  for (final definition in settings.providers) {
    final delegates = <OnlineMusicCapability, OnlineMusicProvider>{};
    ChkszOnlineMusicProvider? builtin;
    DeclarativeMusicProvider? declarative;
    final declarativeBindings =
        <OnlineMusicCapability, OnlineMusicDeclarativeCapabilityBinding>{};

    for (final capability in OnlineMusicCapability.values) {
      switch (definition.bindingFor(capability)) {
        case OnlineMusicUnsupportedCapabilityBinding():
          break;
        case OnlineMusicBuiltinCapabilityBinding():
          builtin ??= ChkszOnlineMusicProvider(
            runtime: createChkszRuntime(
              credentialProvider: definition.requiresCredential
                  ? access.providerFor(
                      definition.credentialReference ?? definition.id,
                    )
                  : null,
              config: chkszProviderConfigFor(definition),
              authResolver: definition.authFor,
              dio: dioFactory?.call(definition),
            ),
            providerId: definition.id,
          );
          delegates[capability] = builtin;
        case final OnlineMusicDeclarativeCapabilityBinding binding:
          declarativeBindings[capability] = binding;
      }
    }

    if (declarativeBindings.isNotEmpty) {
      final ownedDio =
          dioFactory?.call(definition) ??
          Dio(
            BaseOptions(
              baseUrl: definition.baseUrl,
              connectTimeout: definition.connectTimeout,
              sendTimeout: definition.sendTimeout,
              receiveTimeout: definition.receiveTimeout,
            ),
          );
      declarative = DeclarativeMusicProvider(
        providerId: definition.id,
        bindings: declarativeBindings,
        transport: DioDeclarativeHttpTransport(dio: ownedDio),
        credentials: access,
        credentialReference: definition.requiresCredential
            ? definition.credentialReference
            : null,
        contentPlatform: definition.contentPlatform,
        disposeTransport: () => ownedDio.close(force: true),
      );
      for (final capability in declarativeBindings.keys) {
        delegates[capability] = declarative;
      }
    }

    providers.add(
      _ConfiguredMusicProvider(
        providerId: definition.id,
        delegates: delegates,
        delegateDisposables: {
          builtin,
          declarative,
        }.whereType<OnlineMusicProvider>(),
      ),
    );

    credentialControllers[definition.id] =
        builtin ??
        _ReferenceCredentialController(
          reference:
              definition.credentialReference ??
              deriveOnlineMusicCredentialReference(definition.id),
          access: access,
        );
  }

  final registry = OnlineMusicProviderRegistry(
    providers: providers,
    defaultProviderId: settings.defaultProviderId,
    capabilityProviders: settings.capabilityProviders,
    // 平台感知路由（D4:A / D14）：候选由配置层的 (platform, capability) 查询决定，
    // 其中已包含旧单值映射的回落语义；不再使用平台无关的 defaultProvider 做路由。
    explicitCandidates: settings.explicitCandidateIdsFor,
  );

  return OnlineMusicComposition(
    service: CompositeOnlineMusicService(registry: registry),
    providers: providers,
    credentialControllers: credentialControllers,
  );
}

/// 一个条目对外就是一个 Provider：内部按能力把调用分派给内置实现或声明式引擎。
final class _ConfiguredMusicProvider implements OnlineMusicProvider {
  _ConfiguredMusicProvider({
    required this.providerId,
    required Map<OnlineMusicCapability, OnlineMusicProvider> delegates,
    required Iterable<OnlineMusicProvider> delegateDisposables,
  }) : _delegates = Map.unmodifiable(delegates),
       _delegateDisposables = List.unmodifiable(delegateDisposables);

  @override
  final String providerId;

  final Map<OnlineMusicCapability, OnlineMusicProvider> _delegates;
  final List<OnlineMusicProvider> _delegateDisposables;

  @override
  Set<MusicPlatform> platformsFor(OnlineMusicCapability capability) =>
      _delegates[capability]?.platformsFor(capability) ?? const {};

  @override
  OnlineMusicProviderAuth authFor(OnlineMusicCapability capability) =>
      _delegates[capability]?.authFor(capability) ?? const OnlineMusicNoAuth();

  OnlineMusicProvider? _delegate(OnlineMusicCapability capability) =>
      _delegates[capability];

  @override
  Future<MusicSearchPage> search({
    required MusicPlatform platform,
    required String keyword,
    int limit = 30,
    int offset = 0,
    required OnlineMusicCancelToken cancelToken,
  }) {
    final delegate = _delegate(OnlineMusicCapability.search);
    if (delegate == null) return Future.error(unsupportedCapability());
    return delegate.search(
      platform: platform,
      keyword: keyword,
      limit: limit,
      offset: offset,
      cancelToken: cancelToken,
    );
  }

  @override
  Future<RemotePlaylist> fetchPlaylist({
    required MusicPlatform platform,
    required String playlistId,
    required OnlineMusicCancelToken cancelToken,
  }) {
    final delegate = _delegate(OnlineMusicCapability.playlist);
    if (delegate == null) return Future.error(unsupportedCapability());
    return delegate.fetchPlaylist(
      platform: platform,
      playlistId: playlistId,
      cancelToken: cancelToken,
    );
  }

  @override
  Future<MusicLyrics> fetchLyrics(
    PlatformTrackRef ref, {
    required OnlineMusicCancelToken cancelToken,
  }) {
    final delegate = _delegate(OnlineMusicCapability.lyric);
    if (delegate == null) return Future.error(unsupportedCapability());
    return delegate.fetchLyrics(ref, cancelToken: cancelToken);
  }

  @override
  Future<ResolvedStream> resolve(
    PlatformTrackRef ref, {
    required String requestedQuality,
    required OnlineMusicCancelToken cancelToken,
  }) {
    final delegate = _delegate(OnlineMusicCapability.stream);
    if (delegate == null) return Future.error(unsupportedCapability());
    return delegate.resolve(
      ref,
      requestedQuality: requestedQuality,
      cancelToken: cancelToken,
    );
  }

  @override
  String defaultQualityFor(MusicPlatform platform) =>
      _delegate(OnlineMusicCapability.stream)?.defaultQualityFor(platform) ??
      MusicQuality.lossless.level;

  /// 档位声明同样委托给**播放解析**能力的那个 delegate —— 档位是"该平台怎么播"
  /// 的一部分，和数据能力（搜索/歌单）无关。
  @override
  List<PlatformQualityTier> qualityTiersFor(MusicPlatform platform) =>
      _delegate(OnlineMusicCapability.stream)?.qualityTiersFor(platform) ??
      const [];

  @override
  void dispose() {
    for (final delegate in _delegateDisposables) {
      delegate.dispose();
    }
  }
}

/// 声明式条目没有 ChkSz runtime，但设置页仍要能配置它的 Key：
/// 这里按引用把它适配成凭据入口。
final class _ReferenceCredentialController
    implements OnlineMusicCredentialController {
  _ReferenceCredentialController({
    required this.reference,
    required this.access,
  });

  final String reference;
  final ChkszCredentialAccess access;

  @override
  String get credentialDisplayName => access.credentialDisplayName;

  @override
  String get inputHint => access.inputHint;

  @override
  bool isCredentialFormatValid(String value) => access.isValidFormat(value);

  @override
  Future<bool> isConfigured() => access.isConfigured(reference);

  @override
  Future<void> saveCredential(String value) => access.save(reference, value);

  @override
  Future<void> clearCredential() => access.clear(reference);
}
