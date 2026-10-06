import 'package:pure_music/services/music_platform/models/music_models.dart';
import 'package:pure_music/services/music_platform/online_music_error.dart';
import 'package:pure_music/services/music_platform/online_music_request.dart';
import 'package:pure_music/services/music_platform/online_music_service.dart';
import 'package:pure_music/services/music_platform/provider/online_music_capability.dart';
import 'package:pure_music/services/music_platform/provider/online_music_provider.dart';
import 'package:pure_music/services/music_platform/provider/online_music_provider_registry.dart';
import 'package:pure_music/services/music_platform/provider/online_music_route_diagnostics.dart';

/// 应用层唯一消费的在线音乐入口：把每个能力分发给 `(platform, capability)` 的候选
/// Provider。
///
/// 应用层只依赖 [OnlineMusicService]；具体是哪个 Provider 由平台感知路由决定，
/// 因此搜索、歌曲列表、歌词、播放可以各自使用不同 Provider。
///
/// **回退语义（D5:A + D15 + D16）**：候选按序尝试，只有"Provider 级故障 /
/// 缺少凭据 / 暂时没有余量"才换下一个（见 [allowsProviderFallback]）；内容语义与
/// 配置类错误一律**立即失败**，不换 Provider。回退默认**静默**（D5b:B），
/// 但每次分发都记入 [routeLog] 以便诊断。
final class CompositeOnlineMusicService implements OnlineMusicService {
  CompositeOnlineMusicService({required this.registry})
    : capabilities = OnlineMusicCapabilities(
        searchablePlatforms: registry
            .providerFor(OnlineMusicCapability.search)
            .platformsFor(OnlineMusicCapability.search),
        resolvablePlatforms: registry
            .providerFor(OnlineMusicCapability.stream)
            .platformsFor(OnlineMusicCapability.stream),
        playlistPlatforms: registry
            .providerFor(OnlineMusicCapability.playlist)
            .platformsFor(OnlineMusicCapability.playlist),
        lyricPlatforms: registry
            .providerFor(OnlineMusicCapability.lyric)
            .platformsFor(OnlineMusicCapability.lyric),
      );

  final OnlineMusicProviderRegistry registry;

  @override
  final OnlineMusicCapabilities capabilities;

  /// 路由记录上限；只保留最近若干次，避免长期占用内存。
  static const _routeLogLimit = 32;
  final List<OnlineMusicRouteRecord> _routeLog = [];

  /// 最近的路由记录（**新的在前**）。
  ///
  /// 用途：回退是静默的，但要能回答"这次到底用了哪个 Provider、试过谁、为什么换"
  /// （D5b:B）。不参与任何业务判断。
  List<OnlineMusicRouteRecord> get routeLog =>
      List.unmodifiable(_routeLog.reversed);

  OnlineMusicRouteRecord? get lastRoute =>
      _routeLog.isEmpty ? null : _routeLog.last;

  @override
  Future<MusicSearchPage> search({
    required MusicPlatform platform,
    required String keyword,
    int limit = 30,
    int offset = 0,
    required OnlineMusicCancelToken cancelToken,
  }) => _dispatch(
    platform,
    OnlineMusicCapability.search,
    (provider) => provider.search(
      platform: platform,
      keyword: keyword,
      limit: limit,
      offset: offset,
      cancelToken: cancelToken,
    ),
  );

  @override
  Future<RemotePlaylist> fetchPlaylist({
    required MusicPlatform platform,
    required String playlistId,
    required OnlineMusicCancelToken cancelToken,
  }) => _dispatch(
    platform,
    OnlineMusicCapability.playlist,
    (provider) => provider.fetchPlaylist(
      platform: platform,
      playlistId: playlistId,
      cancelToken: cancelToken,
    ),
  );

  @override
  Future<MusicLyrics> fetchLyrics(
    PlatformTrackRef ref, {
    required OnlineMusicCancelToken cancelToken,
  }) => _dispatch(
    ref.platform,
    OnlineMusicCapability.lyric,
    (provider) => provider.fetchLyrics(ref, cancelToken: cancelToken),
  );

  @override
  Future<ResolvedStream> resolve(
    PlatformTrackRef ref, {
    required String requestedQuality,
    required OnlineMusicCancelToken cancelToken,
  }) => _dispatch(
    ref.platform,
    OnlineMusicCapability.stream,
    (provider) => provider.resolve(
      ref,
      requestedQuality: requestedQuality,
      cancelToken: cancelToken,
    ),
    stamp: (stream, providerId) => stream.servedByProviderId == null
        ? stream.withServedByProvider(providerId)
        : stream,
  );

  @override
  String defaultQualityFor(MusicPlatform platform) {
    // 同步查询：没有候选即不可用；不在此处回退（无异步空间，也没有请求可失败）。
    final candidates = registry.providersFor(
      platform,
      OnlineMusicCapability.stream,
    );
    if (candidates.isEmpty) throw unsupportedCapability();
    return candidates.first.defaultQualityFor(platform);
  }

  @override
  void dispose() {
    for (final provider in registry.providers) {
      provider.dispose();
    }
  }

  /// 按候选顺序尝试；只有 [allowsProviderFallback] 认可的错误才继续下一个候选。
  ///
  /// - 候选为空 ⇒ 发请求**之前**就以 `unavailable` 失败（D14：不做平台无关回落）；
  /// - 非回退类错误 ⇒ 立即 `rethrow`，**保留原始分类与文案**（不掩盖配置错误）；
  /// - 全部候选都因可回退错误失败 ⇒ 抛出**最后一个**原始错误；
  /// - 空结果**不是错误**，原样返回，不触发回退。
  Future<T> _dispatch<T>(
    MusicPlatform platform,
    OnlineMusicCapability capability,
    Future<T> Function(OnlineMusicProvider provider) run, {
    T Function(T result, String providerId)? stamp,
  }) async {
    final candidates = registry.providersFor(platform, capability);
    if (candidates.isEmpty) throw unsupportedCapability();

    final attempts = <OnlineMusicRouteAttempt>[];
    OnlineMusicException? lastError;
    for (final provider in candidates) {
      try {
        final result = await run(provider);
        _record(platform, capability, attempts, provider.providerId);
        return stamp == null ? result : stamp(result, provider.providerId);
      } on OnlineMusicException catch (error) {
        attempts.add(
          OnlineMusicRouteAttempt(
            providerId: provider.providerId,
            kind: error.kind,
          ),
        );
        lastError = error;
        if (!allowsProviderFallback(error.kind)) {
          _record(platform, capability, attempts, null);
          rethrow;
        }
      }
    }
    _record(platform, capability, attempts, null);
    throw lastError ?? unsupportedCapability();
  }

  void _record(
    MusicPlatform platform,
    OnlineMusicCapability capability,
    List<OnlineMusicRouteAttempt> attempts,
    String? winnerProviderId,
  ) {
    _routeLog.add(
      OnlineMusicRouteRecord(
        platform: platform,
        capability: capability,
        attempts: List.unmodifiable(attempts),
        winnerProviderId: winnerProviderId,
      ),
    );
    if (_routeLog.length > _routeLogLimit) _routeLog.removeAt(0);
  }
}
