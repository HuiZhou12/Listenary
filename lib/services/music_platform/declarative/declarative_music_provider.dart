/// 声明式能力在运行时的执行者：一个 Provider 上「由配置驱动」的那部分能力。
///
/// 它把 [buildDeclarativeRequest] → 传输 → [declarativeResponseIsSuccess] → 映射
/// 串成一次调用，并把所有失败归一成既有跨层契约 [OnlineMusicException]。
/// 未在本 Provider 上配置的能力一律报 `unavailable`，绝不伪装成支持。
library;

import 'dart:async';

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
import 'package:pure_music/services/music_platform/provider/online_music_response_spec.dart';

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

    /// F5-P-39（P3）：稳定平台 ID，透传给摘要/搜索页（界面按身份显示名字）。
    this.platformId,

    /// F4-S4（P-13 / D10b:a）：Provider **静态声明**的档位表（内部级别 → 平台取值 + 展示名）。
    /// 缺省空 = 不声明档位 ⇒ 与修复前完全一致。
    this.qualityTiers = const [],
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
  final String? platformId;

  /// F4-S4：静态声明的档位表；空表表示"不声明"。
  final List<PlatformQualityTier> qualityTiers;

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
    _ensurePaginationSupported(binding);
    return _run(
      binding: binding,
      cancelToken: cancelToken,
      inputs: DeclarativeInputs(
        keyword: keyword,
        limit: limit,
        offset: offset,
        // F4-S3（P-11）：页码**由 offset/limit 派生**（以前恒 1 ⇒ 任何按 `page` 取值的绑定
        // 都会永远请求第一页）。`limit <= 0` 时按第一页处理。
        page: limit > 0 ? (offset ~/ limit) + 1 : 1,
      ),
      map: (body) => mapDeclarativeSearchResponse(
        spec: binding.response,
        body: body,
        platform: contentPlatform,
        platformId: platformId,
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
        platformId: platformId,
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
        platformId: platformId,
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
        platformId: platformId,
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
    final binding = _requireBinding(OnlineMusicCapability.chartList, platform);
    return _run(
      binding: binding,
      cancelToken: cancelToken,
      inputs: DeclarativeInputs(limit: limit, offset: offset, page: 1),
      // 榜单索引与歌单集合同构，共用同一个映射（见映射函数的说明）。
      map: (body) => mapDeclarativePlaylistCollectionResponse(
        spec: binding.response,
        body: body,
        platform: platform,
        platformId: platformId,
      ),
    );
  }

  @override
  Future<List<OnlineAlbumSummary>> searchAlbums({
    required MusicPlatform platform,
    required String keyword,
    int limit = 30,
    int offset = 0,
    required OnlineMusicCancelToken cancelToken,
  }) async {
    final binding = _requireBinding(
      OnlineMusicCapability.searchAlbums,
      platform,
    );
    return _run(
      binding: binding,
      cancelToken: cancelToken,
      inputs: DeclarativeInputs(
        keyword: keyword,
        limit: limit,
        offset: offset,
        page: 1,
      ),
      map: (body) => mapDeclarativeAlbumListResponse(
        spec: binding.response,
        body: body,
        platform: platform,
        platformId: platformId,
      ),
    );
  }

  @override
  Future<List<OnlineAlbumSummary>> fetchNewAlbums({
    required MusicPlatform platform,
    int limit = 30,
    int offset = 0,
    required OnlineMusicCancelToken cancelToken,
  }) async {
    final binding = _requireBinding(OnlineMusicCapability.newAlbums, platform);
    return _run(
      binding: binding,
      cancelToken: cancelToken,
      inputs: DeclarativeInputs(limit: limit, offset: offset, page: 1),
      map: (body) => mapDeclarativeAlbumListResponse(
        spec: binding.response,
        body: body,
        platform: platform,
        platformId: platformId,
      ),
    );
  }

  @override
  Future<List<MusicTrack>> fetchArtistSongs({
    required MusicPlatform platform,
    required String artistId,
    int limit = 30,
    int offset = 0,
    required OnlineMusicCancelToken cancelToken,
  }) async {
    final binding = _requireBinding(OnlineMusicCapability.artistSongs, platform);
    return _run(
      binding: binding,
      cancelToken: cancelToken,
      inputs: DeclarativeInputs(
        artistId: artistId,
        limit: limit,
        offset: offset,
        page: 1,
      ),
      // 与搜索/新歌同构（都是曲目数组）⇒ **共用同一个映射** ✓。
      map: (body) => mapDeclarativeSearchResponse(
        spec: binding.response,
        body: body,
        platform: platform,
        platformId: platformId,
        limit: limit,
        offset: offset,
      ).items,
    );
  }

  @override
  Future<List<OnlineAlbumSummary>> fetchArtistAlbums({
    required MusicPlatform platform,
    required String artistId,
    int limit = 30,
    int offset = 0,
    required OnlineMusicCancelToken cancelToken,
  }) async {
    final binding = _requireBinding(
      OnlineMusicCapability.artistAlbums,
      platform,
    );
    return _run(
      binding: binding,
      cancelToken: cancelToken,
      inputs: DeclarativeInputs(
        artistId: artistId,
        limit: limit,
        offset: offset,
        page: 1,
      ),
      map: (body) => mapDeclarativeAlbumListResponse(
        spec: binding.response,
        body: body,
        platform: platform,
        platformId: platformId,
      ),
    );
  }

  @override
  Future<OnlineAlbum> fetchAlbum({
    required MusicPlatform platform,
    required String albumId,
    required OnlineMusicCancelToken cancelToken,
  }) async {
    final binding = _requireBinding(OnlineMusicCapability.album, platform);
    return _run(
      binding: binding,
      cancelToken: cancelToken,
      // 专辑 id 是**唯一输入**（在请求里）；它会回填到结果的身份上 ✓。
      inputs: DeclarativeInputs(albumId: albumId, page: 1),
      map: (body) => mapDeclarativeAlbumResponse(
        spec: binding.response,
        body: body,
        platform: platform,
        platformId: platformId,
        requestedAlbumId: albumId,
      ),
    );
  }

  @override
  Future<OnlineArtist> fetchArtist({
    required MusicPlatform platform,
    required String artistId,
    required OnlineMusicCancelToken cancelToken,
  }) async {
    final binding = _requireBinding(OnlineMusicCapability.artist, platform);
    return _run(
      binding: binding,
      cancelToken: cancelToken,
      // 艺人 id 是**唯一输入**（在请求里）；它会回填到结果的身份上 ✓。
      inputs: DeclarativeInputs(artistId: artistId, page: 1),
      map: (body) => mapDeclarativeArtistResponse(
        spec: binding.response,
        body: body,
        platform: platform,
        platformId: platformId,
        requestedArtistId: artistId,
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
        platformId: platformId,
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
  List<PlatformQualityTier> qualityTiersFor(MusicPlatform platform) =>
      // F4-S4（P-13）：声明式 Provider 的档位由**配置**给出（以前恒空、只能写代码）。
      qualityTiers;

  @override
  void dispose() => _disposeTransport?.call();

  /// F4-S3（P-11）：**游标分页暂不支持** —— 服务层契约里没有"上一页游标"的位置
  /// （`search` 只有 `offset` / `limit`），运行期无法把映射出的 `nextCursor` 传回请求。
  ///
  /// 按 D4「不支持的必须明确报出、不得静默」：这里**明确失败**，而不是静默发出一个
  /// 不带游标的请求、把第二页当成第一页（那会让"加载更多"永远返回同一批结果）。
  void _ensurePaginationSupported(
    OnlineMusicDeclarativeCapabilityBinding binding,
  ) {
    if (binding.response.pagination.kind == OnlineMusicPaginationKind.cursor) {
      throw const OnlineMusicException(
        kind: OnlineMusicErrorKind.badRequest,
        safeMessage:
            '该能力声明了游标分页，但当前版本无法把游标传回请求（服务层只支持 offset/limit）：'
            '请改用 offset/limit 或 pageSize 分页',
      );
    }
  }

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
    // 允许**异步**映射：歌词需要把 LRC 解析成 `parsed`（与内置路径同一个解析器）。
    required FutureOr<T> Function(Object? body) map,
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
      return await map(response.data);
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
          // F4-S1：参数绑定自身不成立（来源与固定值同给 / 都没有）⇒ **配置错误**，
          // 与敏感头明文同理：**不能**归成 notConfigured，否则路由会把它当成
          // "换个 Provider 试试"，把真正该修的配置问题盖掉。
          DeclarativeRequestErrorKind.invalidParameterBinding =>
            OnlineMusicErrorKind.badRequest,
          // F4-S8（P-65 认证冲突 / 非 ASCII 头值）：都是**配置**问题（要用户去改配置）
          // ⇒ badRequest；同上**不能**归成 notConfigured。
          DeclarativeRequestErrorKind.authParameterConflict =>
            OnlineMusicErrorKind.badRequest,
          DeclarativeRequestErrorKind.invalidHeaderValue =>
            OnlineMusicErrorKind.badRequest,
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
