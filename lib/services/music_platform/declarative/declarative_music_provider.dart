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
    final binding = _requireBinding(
      OnlineMusicCapability.stream,
      ref.platform,
    );
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
  }) async => throw unsupportedCapability();

  @override
  Future<MusicLyrics> fetchLyrics(
    PlatformTrackRef ref, {
    required OnlineMusicCancelToken cancelToken,
  }) async => throw unsupportedCapability();

  @override
  String defaultQualityFor(MusicPlatform platform) => MusicQuality.lossless.level;

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
      final request = buildDeclarativeRequest(
        spec: binding.request,
        inputs: inputs,
        credential: credential,
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
        throw OnlineMusicException(
          kind: _errorKindForStatus(response.statusCode),
          safeMessage: _safeMessageForStatus(response.statusCode),
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
        },
        safeMessage: error.safeMessage,
      );
    } on DeclarativeMappingException {
      throw const OnlineMusicException(
        kind: OnlineMusicErrorKind.invalidResponse,
        safeMessage: '音乐服务返回了无法识别的数据',
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

  OnlineMusicErrorKind _errorKindForStatus(int statusCode) =>
      switch (statusCode) {
        400 => OnlineMusicErrorKind.badRequest,
        401 => OnlineMusicErrorKind.notConfigured,
        402 => OnlineMusicErrorKind.quotaExhausted,
        403 => OnlineMusicErrorKind.forbidden,
        404 => OnlineMusicErrorKind.notFound,
        429 => OnlineMusicErrorKind.rateLimited,
        >= 500 => OnlineMusicErrorKind.unavailable,
        _ => OnlineMusicErrorKind.businessFailure,
      };

  String _safeMessageForStatus(int statusCode) => switch (statusCode) {
    400 => '音乐服务拒绝了该请求',
    401 => '请先配置有效凭据',
    403 => '音乐服务拒绝访问',
    404 => '音乐服务没有该接口',
    429 => '请求过于频繁，请稍后再试',
    >= 500 => '音乐服务暂时不可用',
    _ => '音乐服务请求失败',
  };

  @override
  String toString() =>
      'DeclarativeMusicProvider($providerId, ${_bindings.length} capabilities)';
}
