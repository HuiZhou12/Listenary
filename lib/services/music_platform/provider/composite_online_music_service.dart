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
    : capabilities = _capabilitiesFor(registry);

  /// 由**候选**推导能力集合，并在搜索上施加 **Stream 硬门槛**（D3）。
  ///
  /// 旧实现取"被选中的那一个 Provider 声明了什么"，多平台下会漏掉"这个平台其实
  /// 还有另一个可用 Provider"的情况；这里改为按 `(platform, capability)` 候选求并集。
  ///
  /// 门槛：一个平台必须**同时**有可用的 Search 与 Stream 候选，才允许作为搜索来源
  /// —— 否则会出现"搜得到但播不了"。被挡下的平台连同**原因**一起暴露，供 UI 解释
  /// （D3b:a）。
  static OnlineMusicCapabilities _capabilitiesFor(
    OnlineMusicProviderRegistry registry,
  ) {
    final search = registry.platformsFor(OnlineMusicCapability.search);
    final stream = registry.platformsFor(OnlineMusicCapability.stream);
    final searchable = {
      for (final platform in search)
        if (stream.contains(platform)) platform,
    };
    final reasons = <MusicPlatform, String>{};
    for (final platform in {...search, ...stream}) {
      if (searchable.contains(platform)) continue;
      reasons[platform] = stream.contains(platform)
          ? '缺少搜索能力，因此不会参与搜索'
          : '缺少播放解析能力，因此不会参与搜索';
    }
    return OnlineMusicCapabilities(
      searchablePlatforms: searchable,
      resolvablePlatforms: stream,
      playlistPlatforms: registry.platformsFor(OnlineMusicCapability.playlist),
      lyricPlatforms: registry.platformsFor(OnlineMusicCapability.lyric),
      unavailableSearchReasons: reasons,
    );
  }

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
    // D9 / I1：歌词必须带回来源身份（用请求里的 ref 回填，Provider 不必自己提供）。
    stamp: (lyrics, providerId) =>
        lyrics.ref == null ? lyrics.withRef(ref) : lyrics,
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
    final candidates = _streamCandidates(platform);
    if (candidates.isEmpty) throw unsupportedCapability();
    final provider = candidates.first;
    // D2:A / D10:A：Provider 报的是**内部偏好档位**，这里按该平台自己的档位声明
    // 解析成"实际传给它"的取值（含"不高于期望的最接近档位"的回落）。
    return selectPlatformQuality(
      tiers: provider.qualityTiersFor(platform),
      preference: provider.defaultQualityFor(platform),
    ).requestValue;
  }

  /// 该平台**可用的音质档位**（含平台自己的文案），供 UI 渲染选择菜单。
  ///
  /// 空列表表示该 Provider 没有声明档位（内部偏好原样透传）；UI 此时只应展示内部
  /// 偏好本身，**不要伪造平台档位名称**（补充口径④）。
  @override
  List<PlatformQualityTier> qualityTiersFor(MusicPlatform platform) {
    final candidates = _streamCandidates(platform);
    return candidates.isEmpty
        ? const []
        : candidates.first.qualityTiersFor(platform);
  }

  /// 把内部偏好解析成该平台实际使用的档位，并告知**是否发生了回落**。
  ///
  /// 用途：UI 用 `displayLabel` 展示该平台自己的档位名称；`fellBack == true` 时提示
  /// "已回落为 displayLabel"。
  @override
  PlatformQualitySelection selectQualityFor(
    MusicPlatform platform, {
    required String preference,
  }) => selectPlatformQuality(
    tiers: qualityTiersFor(platform),
    preference: preference,
  );

  List<OnlineMusicProvider> _streamCandidates(MusicPlatform platform) =>
      registry.providersFor(platform, OnlineMusicCapability.stream);

  /// 多平台聚合搜索（D6:A / D6b:a / D6c:a）。
  ///
  /// - **门槛**：只接受 [capabilities]`.searchablePlatforms` 里的平台（D3）；
  ///   被挡下的平台不会发起任何请求，也不会出现在结果的任一 map 里。
  /// - **并行**：各平台同时请求；**单平台失败不影响其它平台** —— 失败进
  ///   [AggregatedSearchResult.failures]，成功的进 `.perPlatform`。
  /// - **分页各自独立**：`limit` / `offset` 原样传给每个平台，调用方按平台分别
  ///   加载更多（D6c:a）。
  /// - **不去重**（D6b:a）：每项都保留自己的 `ref.platform` 与 `ref.trackId`。
  @override
  Future<AggregatedSearchResult> searchAggregated({
    required Iterable<MusicPlatform> platforms,
    required String keyword,
    int limit = 30,
    int offset = 0,
    required OnlineMusicCancelToken cancelToken,
  }) async {
    final requested = {
      for (final platform in platforms)
        if (capabilities.searchablePlatforms.contains(platform)) platform,
    };
    final perPlatform = <MusicPlatform, MusicSearchPage>{};
    final failures = <MusicPlatform, OnlineMusicException>{};

    await Future.wait([
      for (final platform in requested)
        _searchOnePlatform(
          platform: platform,
          keyword: keyword,
          limit: limit,
          offset: offset,
          cancelToken: cancelToken,
          perPlatform: perPlatform,
          failures: failures,
        ),
    ]);

    // 取消要如实向上传播，而不是被收进 failures 假装成"某个平台失败了"。
    if (cancelToken.isCancelled) {
      throw const OnlineMusicException(
        kind: OnlineMusicErrorKind.cancelled,
        safeMessage: '搜索已取消',
      );
    }
    return AggregatedSearchResult(perPlatform: perPlatform, failures: failures);
  }

  /// 单平台搜索；永不抛出 `OnlineMusicException`（改写进 failures），
  /// 以便 `Future.wait` 不会因为一个平台失败而丢掉其它平台的结果。
  Future<void> _searchOnePlatform({
    required MusicPlatform platform,
    required String keyword,
    required int limit,
    required int offset,
    required OnlineMusicCancelToken cancelToken,
    required Map<MusicPlatform, MusicSearchPage> perPlatform,
    required Map<MusicPlatform, OnlineMusicException> failures,
  }) async {
    try {
      perPlatform[platform] = await search(
        platform: platform,
        keyword: keyword,
        limit: limit,
        offset: offset,
        cancelToken: cancelToken,
      );
    } on OnlineMusicException catch (error) {
      failures[platform] = error;
    }
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
