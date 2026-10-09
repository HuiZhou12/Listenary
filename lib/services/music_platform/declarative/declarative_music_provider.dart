/// 声明式能力在运行时的执行者：一个 Provider 上「由配置驱动」的那部分能力。
///
/// 它把 [buildDeclarativeRequest] → 传输 → [declarativeResponseIsSuccess] → 映射
/// 串成一次调用，并把所有失败归一成既有跨层契约 [OnlineMusicException]。
/// 未在本 Provider 上配置的能力一律报 `unavailable`，绝不伪装成支持。
library;

import 'package:dio/dio.dart';
import 'package:pure_music/services/music_platform/declarative/declarative_errors.dart';
import 'package:pure_music/services/music_platform/declarative/declarative_http_transport.dart';
import 'package:pure_music/services/music_platform/declarative/declarative_request_builder.dart';
import 'package:pure_music/services/music_platform/declarative/declarative_response_mapper.dart';
import 'package:pure_music/services/music_platform/models/music_models.dart';
import 'package:pure_music/services/music_platform/online_music_error.dart';
import 'package:pure_music/services/music_platform/online_music_request.dart';
import 'package:pure_music/services/music_platform/provider/online_music_binding.dart';
import 'package:pure_music/services/music_platform/provider/online_music_capability.dart';
import 'package:pure_music/services/music_platform/provider/online_music_provider.dart';
import 'package:pure_music/services/music_platform/provider/online_music_provider_auth.dart';
import 'package:pure_music/services/music_platform/provider/online_music_quality_tiers.dart';
import 'package:pure_music/services/music_platform/provider/online_music_provider_credentials.dart';
import 'package:pure_music/services/music_platform/provider/online_music_request_spec.dart';

typedef DeclarativeTransportDispose = void Function();

final class DeclarativeMusicProvider implements OnlineMusicProvider {
  DeclarativeMusicProvider({
    required this.providerId,
    required Map<OnlineMusicCapability, OnlineMusicDeclarativeCapabilityBinding>
    bindings,
    required DeclarativeHttpTransport transport,
    required OnlineMusicCredentialReader credentials,
    this.credentialReference,
    this.contentPlatform = MusicPlatform.netease,
    DeclarativeTransportDispose? disposeTransport,
    DateTime Function()? clock,
  }) : _bindings = Map.unmodifiable(bindings),
       _transport = transport,
       _credentials = credentials,
       _disposeTransport = disposeTransport,
       _clock = clock ?? DateTime.now;

  @override
  final String providerId;

  final Map<OnlineMusicCapability, OnlineMusicDeclarativeCapabilityBinding>
  _bindings;
  final DeclarativeHttpTransport _transport;
  final OnlineMusicCredentialReader _credentials;
  final String? credentialReference;
  final MusicPlatform contentPlatform;
  final DeclarativeTransportDispose? _disposeTransport;
  final DateTime Function() _clock;

  @override
  Set<MusicPlatform> platformsFor(OnlineMusicCapability capability) =>
      _bindings.containsKey(capability) ? {contentPlatform} : const {};

  /// 认证细节在每个能力自己的请求声明里；这里统一报告"无额外要求"，
  /// 因为凭据是由声明式引擎自己按 `AuthPlacement` 注入的。
  @override
  OnlineMusicProviderAuth authFor(OnlineMusicCapability capability) =>
      const OnlineMusicNoAuth();

  @override
  Future<MusicSearchPage> search({
    required MusicPlatform platform,
    required String keyword,
    int limit = 30,
    int offset = 0,
    required OnlineMusicCancelToken cancelToken,
  }) async {
    final binding = _requireBinding(OnlineMusicCapability.search, platform);
    return _run(
      binding: binding,
      cancelToken: cancelToken,
      inputs: DeclarativeInputs(
        keyword: keyword,
        limit: limit,
        offset: offset,
        page: 1,
      ),
      map: (body) => mapDeclarativeSearchResponse(
        spec: binding.response,
        body: body,
        platform: contentPlatform,
        limit: limit,
        offset: offset,
      ),
    );
  }

  @override
  Future<ResolvedStream> resolve(
    PlatformTrackRef ref, {
    required String requestedQuality,
    required OnlineMusicCancelToken cancelToken,
  }) async {
    final binding = _requireBinding(OnlineMusicCapability.stream, ref.platform);
    return _run(
      binding: binding,
      cancelToken: cancelToken,
      inputs: DeclarativeInputs(
        trackId: ref.trackId,
        quality: requestedQuality,
      ),
      map: (body) => mapDeclarativeResolveResponse(
        spec: binding.response,
        body: body,
        expectedRef: ref,
        requestedQuality: requestedQuality,
        resolvedAt: _clock(),
      ),
    );
  }

  @override
  Future<RemotePlaylist> fetchPlaylist({
    required MusicPlatform platform,
    required String playlistId,
    required OnlineMusicCancelToken cancelToken,
  }) async {
    final binding = _requireBinding(OnlineMusicCapability.playlist, platform);
    return _run(
      binding: binding,
      cancelToken: cancelToken,
      inputs: DeclarativeInputs(playlistId: playlistId),
      map: (body) => mapDeclarativePlaylistResponse(
        spec: binding.response,
        body: body,
        platform: contentPlatform,
        requestedPlaylistId: playlistId,
      ),
    );
  }

  @override
  Future<MusicLyrics> fetchLyrics(
    PlatformTrackRef ref, {
    required OnlineMusicCancelToken cancelToken,
  }) async {
    final binding = _requireBinding(OnlineMusicCapability.lyric, ref.platform);
    return _run(
      binding: binding,
      cancelToken: cancelToken,
      inputs: DeclarativeInputs(trackId: ref.trackId),
      map: (body) => mapDeclarativeLyricsResponse(
        spec: binding.response,
        body: body,
        ref: ref,
      ),
    );
  }

  @override
  Future<List<RemotePlaylistSummary>> fetchPlaylistCollection({
    required MusicPlatform platform,
    int limit = 30,
    int offset = 0,
    String? categoryId,
    required OnlineMusicCancelToken cancelToken,
  }) async {
    final binding = _requireBinding(
      OnlineMusicCapability.playlistCollection,
      platform,
    );
    return _run(
      binding: binding,
      cancelToken: cancelToken,
      inputs: DeclarativeInputs(
        limit: limit,
        offset: offset,
        page: 1,
        // 不给分类时它是 null：绑定里若把 `cat` 声明为 required，请求层会明确报
        // "缺少必填输入"，而不是悄悄发出一个没有分类的请求。
        categoryId: categoryId,
      ),
      map: (body) => mapDeclarativePlaylistCollectionResponse(
        spec: binding.response,
        body: body,
        platform: platform,
      ),
    );
  }

  @override
  Future<List<RemotePlaylistCategory>> fetchPlaylistCategories({
    required MusicPlatform platform,
    int limit = 30,
    int offset = 0,
    required OnlineMusicCancelToken cancelToken,
  }) async {
    final binding = _requireBinding(
      OnlineMusicCapability.playlistCategories,
      platform,
    );
    return _run(
      binding: binding,
      cancelToken: cancelToken,
      inputs: DeclarativeInputs(limit: limit, offset: offset, page: 1),
      map: (body) => mapDeclarativePlaylistCategoriesResponse(
        spec: binding.response,
        body: body,
        platform: platform,
      ),
    );
  }

  @override
  Future<List<RemotePlaylistSummary>> fetchChartList({
    required MusicPlatform platform,
    int limit = 30,
    int offset = 0,
    required OnlineMusicCancelToken cancelToken,
  }) async {
    final binding = _requireBinding(
      OnlineMusicCapability.chartList,
      platform,
    );
    return _run(
      binding: binding,
      cancelToken: cancelToken,
      inputs: DeclarativeInputs(limit: limit, offset: offset, page: 1),
      // 榜单索引与歌单集合同构，共用同一个映射（见映射函数的说明）。
      map: (body) => mapDeclarativePlaylistCollectionResponse(
        spec: binding.response,
        body: body,
        platform: platform,
      ),
    );
  }

  @override
  Future<List<MusicTrack>> fetchNewSongs({
    required MusicPlatform platform,
    int limit = 30,
    int offset = 0,
    required OnlineMusicCancelToken cancelToken,
  }) async {
    final binding = _requireBinding(OnlineMusicCapability.newSongs, platform);
    return _run(
      binding: binding,
      cancelToken: cancelToken,
      inputs: DeclarativeInputs(limit: limit, offset: offset, page: 1),
      // 新歌与搜索同构（都是曲目数组），因此**共用同一个映射**，只取其中的曲目部分。
      map: (body) => mapDeclarativeSearchResponse(
        spec: binding.response,
        body: body,
        platform: platform,
        limit: limit,
        offset: offset,
      ).items,
    );
  }

  @override
  String defaultQualityFor(MusicPlatform platform) =>
      MusicQuality.lossless.level;

  /// 声明式 Provider **不声明档位**：它的 `quality` 参数含义由用户自己的接口决定
  /// （可能是 `level`，也可能是 `sq` 这种平台专有取值），程序无从推断。
  /// 留空即"原样透传内部偏好"，与引入档位模型之前的行为完全一致。
  @override
  List<PlatformQualityTier> qualityTiersFor(MusicPlatform platform) => const [];

  @override
  void dispose() => _disposeTransport?.call();

  OnlineMusicDeclarativeCapabilityBinding _requireBinding(
    OnlineMusicCapability capability,
    MusicPlatform platform,
  ) {
    final binding = _bindings[capability];
    if (binding == null || platform != contentPlatform) {
      throw unsupportedCapability();
    }
    return binding;
  }

  Future<T> _run<T>({
    required OnlineMusicDeclarativeCapabilityBinding binding,
    required OnlineMusicCancelToken cancelToken,
    required DeclarativeInputs inputs,
    required T Function(Object? body) map,
  }) async {
    if (cancelToken.isCancelled) {
      throw const OnlineMusicException(
        kind: OnlineMusicErrorKind.cancelled,
        safeMessage: '播放请求已取消',
      );
    }
    try {
      final credential = await _readCredential(binding);
      if (cancelToken.isCancelled) {
        throw const OnlineMusicException(
          kind: OnlineMusicErrorKind.cancelled,
          safeMessage: '播放请求已取消',
        );
      }
      // P-54：条目级「不需要 Key」与能力级「声明了认证」矛盾时，**换 Provider 也没用**
      // ⇒ 归配置错误（`badRequest`，禁止回退），而不是"凭据还没配"那种可回退的
      // `notConfigured`（后者换一个是合理出路，前者只会把配置错误掩盖掉）。
      final authIssue = declarativeAuthConfigIssue(
        auth: binding.request.auth,
        hasCredentialReference: credentialReference != null,
      );
      if (authIssue != null) {
        throw OnlineMusicException(
          kind: OnlineMusicErrorKind.badRequest,
          safeMessage: authIssue,
        );
      }
      final request = buildDeclarativeRequest(
        spec: binding.request,
        inputs: inputs,
        credential: credential,
        headerCredentials: await readHeaderCredentialValues(
          spec: binding.request,
          reader: _credentials,
        ),
      );
      final response = await _transport.send(request, cancelToken: cancelToken);
      if (cancelToken.isCancelled) {
        throw const OnlineMusicException(
          kind: OnlineMusicErrorKind.cancelled,
          safeMessage: '播放请求已取消',
        );
      }
      if (!declarativeResponseIsSuccess(
        spec: binding.response.success,
        statusCode: response.statusCode,
        body: response.data,
      )) {
        // P-16：分类**统一**由 `classifyHttpStatus` 决定（单一事实源）。
        // 声明式 Provider 的路径由**用户配置** ⇒ 这里的 404 与"响应不是可读 JSON"
        // 都属于「接口定义对不上服务端」（Spec §6.5），该规则已内建在那张表里。
        final kind = classifyHttpStatus(
          response.statusCode,
          origin: OnlineMusicErrorOrigin.declarative,
          readableJson: _isReadableJson(response.data),
        );
        throw OnlineMusicException(
          kind: kind,
          safeMessage: _safeMessageForKind(kind, response.statusCode),
        );
      }
      return map(response.data);
    } on OnlineMusicException {
      rethrow;
    } on DeclarativeRequestException catch (error) {
      throw OnlineMusicException(
        kind: switch (error.kind) {
          DeclarativeRequestErrorKind.missingCredential =>
            OnlineMusicErrorKind.notConfigured,
          DeclarativeRequestErrorKind.missingRequiredInput =>
            OnlineMusicErrorKind.badRequest,
          // F0：敏感头**仍是明文** ⇒ 配置错误（要用户去改配置），因此**不是**
          // notConfigured —— 后者会被路由当成"换个 Provider 试试"，把真正该修的错误盖掉。
          DeclarativeRequestErrorKind.sensitiveHeaderPlaintext =>
            OnlineMusicErrorKind.badRequest,
          // 声明了引用但没有可用凭据 ⇒ 与"没配凭据"同类（换 Provider 是合理出路）。
          DeclarativeRequestErrorKind.sensitiveHeaderCredentialMissing =>
            OnlineMusicErrorKind.notConfigured,
        },
        safeMessage: error.safeMessage,
      );
    } on DeclarativeMappingException catch (error) {
      // 响应能取到、成功判定也过了，但按当前字段映射读不出领域对象 ⇒ 接口定义不匹配。
      throw OnlineMusicException(
        kind: OnlineMusicErrorKind.endpointMismatch,
        safeMessage: '当前接口定义无法匹配响应：${error.reason}',
      );
    } on DioException catch (error) {
      if (CancelToken.isCancel(error)) {
        throw const OnlineMusicException(
          kind: OnlineMusicErrorKind.cancelled,
          safeMessage: '播放请求已取消',
        );
      }
      throw const OnlineMusicException(
        kind: OnlineMusicErrorKind.network,
        safeMessage: '在线音乐网络请求失败',
      );
    } catch (_) {
      throw const OnlineMusicException(
        kind: OnlineMusicErrorKind.unknown,
        safeMessage: '音乐服务请求失败',
      );
    }
  }

  Future<String?> _readCredential(
    OnlineMusicDeclarativeCapabilityBinding binding,
  ) async {
    final reference = credentialReference;
    if (reference == null) return null;
    if (binding.request.auth is OnlineMusicNoAuthPlacement) return null;
    return _credentials.readCredential(reference);
  }

  /// 响应是否是可读 JSON（对象 / 数组）。
  ///
  /// 不是的话说明接口定义与响应结构对不上（D15），而不是业务层说"没有这条数据"。
  static bool _isReadableJson(Object? data) => data is Map || data is List;

  /// 分类之后**给用户看的那句话**。
  ///
  /// P-16：**分类**只有一处（`classifyHttpStatus`），这里只负责措辞 ——
  /// 声明式的 404/不可读响应统一说"接口定义无法匹配响应"，其余按分类取词，
  /// 并在句末带上原始状态码（用户拿它去比对服务端日志）。
  String _safeMessageForKind(OnlineMusicErrorKind kind, int statusCode) {
    if (kind == OnlineMusicErrorKind.endpointMismatch) {
      return '当前接口定义无法匹配响应：请检查服务地址与请求路径（HTTP $statusCode）';
    }
    final base = switch (kind) {
      OnlineMusicErrorKind.badRequest => '音乐服务拒绝了该请求',
      OnlineMusicErrorKind.notConfigured => '请先配置有效凭据',
      OnlineMusicErrorKind.forbidden => '音乐服务拒绝访问',
      OnlineMusicErrorKind.rateLimited => '请求过于频繁，请稍后再试',
      OnlineMusicErrorKind.unavailable => '音乐服务暂时不可用',
      _ => '音乐服务请求失败',
    };
    return '$base（HTTP $statusCode）';
  }

  @override
  String toString() =>
      'DeclarativeMusicProvider($providerId, ${_bindings.length} capabilities)';
}
