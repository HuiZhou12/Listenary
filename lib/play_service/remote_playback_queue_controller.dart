import 'package:pure_music/play_service/playback_source.dart';
import 'package:pure_music/play_service/remote_playback_queue.dart';
import 'package:pure_music/services/music_platform/models/music_models.dart';
import 'package:pure_music/services/music_platform/online_music_request.dart';
import 'package:pure_music/services/music_platform/online_music_service.dart';
import 'package:pure_music/services/music_platform/remote_stream_coordinator.dart';

abstract interface class RemoteQueuePlaybackGateway {
  Future<void> open(
    PlatformTrackRef ref, {
    required String requestedQuality,
    required OnlineMusicCancelToken cancelToken,
  });
}

final class RemoteQueuePlaybackResult {
  const RemoteQueuePlaybackResult({
    this.coverUri,
    this.duration,
    this.actualQuality,
  });

  final Uri? coverUri;
  final Duration? duration;

  /// The platform-reported level, never inferred from the request.
  final String? actualQuality;
}

abstract interface class RemoteQueuePlaybackMetadataGateway
    implements RemoteQueuePlaybackGateway {
  Future<RemoteQueuePlaybackResult> openWithMetadata(
    PlatformTrackRef ref, {
    required String requestedQuality,
    required OnlineMusicCancelToken cancelToken,
  });
}

/// 能查到**平台档位声明**的播放网关（D2:A / D10:A）。
///
/// 降级链必须按平台自己声明的档位走，而不是按内部枚举下标 —— 后者等于把网易云的
/// 档位语义强加到别的平台（Spec §19.7 缺陷 B）。网关不实现这个接口时
/// （既有测试替身、没有档位声明的平台），控制器保持引入档位模型之前的行为。
abstract interface class RemoteQueuePlaybackQualityGateway
    implements RemoteQueuePlaybackGateway {
  List<PlatformQualityTier> qualityTiersFor(MusicPlatform platform);
}

final class OnlineServiceRemoteQueuePlaybackGateway
    implements
        RemoteQueuePlaybackMetadataGateway,
        RemoteQueuePlaybackQualityGateway {
  const OnlineServiceRemoteQueuePlaybackGateway({
    required OnlineMusicService service,
    required PlaybackBackend backend,
  }) : _service = service,
       _backend = backend;

  final OnlineMusicService _service;
  final PlaybackBackend _backend;

  @override
  List<PlatformQualityTier> qualityTiersFor(MusicPlatform platform) =>
      _service.qualityTiersFor(platform);

  @override
  Future<void> open(
    PlatformTrackRef ref, {
    required String requestedQuality,
    required OnlineMusicCancelToken cancelToken,
  }) async {
    await openWithMetadata(
      ref,
      requestedQuality: requestedQuality,
      cancelToken: cancelToken,
    );
  }

  @override
  Future<RemoteQueuePlaybackResult> openWithMetadata(
    PlatformTrackRef ref, {
    required String requestedQuality,
    required OnlineMusicCancelToken cancelToken,
  }) async {
    final stream =
        await RemoteStreamCoordinator(
          resolver: _service.resolve,
          backend: _backend,
        ).resolveAndOpen(
          ref,
          requestedQuality: requestedQuality,
          cancelToken: cancelToken,
        );
    return RemoteQueuePlaybackResult(
      coverUri: stream.coverUri,
      duration: _readDuration(),
      actualQuality: stream.actualQuality,
    );
  }

  Duration? _readDuration() {
    final backend = _backend;
    if (backend is! DurationReadablePlaybackBackend) return null;
    try {
      return backend.readDuration();
    } catch (_) {
      return null;
    }
  }
}

final class RemotePlaybackQueueController {
  RemotePlaybackQueueController({
    required RemotePlaybackQueue queue,
    required RemoteQueuePlaybackGateway gateway,
  }) : _queue = queue,
       _gateway = gateway;

  final RemotePlaybackQueue _queue;
  final RemoteQueuePlaybackGateway _gateway;
  OnlineMusicCancelToken? _activeToken;
  String? _lastActualQuality;
  int _operation = 0;
  bool _disposed = false;

  String? get lastActualQuality => _lastActualQuality;

  Future<String?> play(
    int index, {
    required String requestedQuality,
    String? fallbackQuality,
  }) async {
    _throwIfDisposed();
    final snapshot = _queue.value;
    RangeError.checkValidIndex(index, snapshot.items, 'index');
    final item = snapshot.items[index];
    final operation = ++_operation;
    _activeToken?.cancel();
    final token = OnlineMusicCancelToken();
    _activeToken = token;
    _queue.select(index);

    final qualities = _qualityFallbackChain(
      requestedQuality,
      platform: item.ref.platform,
      fallbackQuality: fallbackQuality,
    );
    Object? lastError;
    try {
      for (final quality in qualities) {
        if (token.isCancelled) {
          throw const RemoteStreamPlaybackException(
            kind: RemoteStreamPlaybackErrorKind.cancelled,
          );
        }
        try {
          final result = await _open(
            item.ref,
            requestedQuality: quality,
            cancelToken: token,
          );
          if (_disposed || token.isCancelled || operation != _operation) {
            throw const RemoteStreamPlaybackException(
              kind: RemoteStreamPlaybackErrorKind.cancelled,
            );
          }
          final currentItems = _queue.value.items;
          if (index >= currentItems.length ||
              currentItems[index].ref != item.ref) {
            throw const RemoteStreamPlaybackException(
              kind: RemoteStreamPlaybackErrorKind.cancelled,
            );
          }
          // 解析成功即认为可播放：平台可能返回低于请求的档位（甚至未知档位字符串），
          // 此时直接采用平台返回的真实 `level`，由上层负责提示降权；
          // 不能因为「低于请求」继续向下重试，否则会出现请求风暴或误判为失败。
          _queue.enrichMetadata(
            index,
            expectedRef: item.ref,
            coverUri: result.coverUri,
            duration: result.duration,
          );
          _lastActualQuality = result.actualQuality ?? quality;
          return _lastActualQuality;
        } catch (error) {
          if (error is RemoteStreamPlaybackException &&
              error.kind == RemoteStreamPlaybackErrorKind.cancelled) {
            rethrow;
          }
          lastError = error;
        }
      }
      if (lastError != null) throw lastError;
      throw StateError('No playable quality available');
    } finally {
      if (identical(_activeToken, token)) {
        _activeToken = null;
      }
    }
  }

  /// 降级链：从期望档一路降到下限（下限可能是上一首平台实际返回的档位）。
  ///
  /// 有平台档位声明时**按该平台的档位**生成（内部枚举只是我们的抽象，平台真实档位
  /// 可能少一档、顺序不同）；没有声明时保持引入档位模型之前的行为。
  List<String> _qualityFallbackChain(
    String requestedQuality, {
    required MusicPlatform platform,
    String? fallbackQuality,
  }) {
    final gateway = _gateway;
    List<PlatformQualityTier> tiers = const [];
    if (gateway is RemoteQueuePlaybackQualityGateway) {
      tiers = gateway.qualityTiersFor(platform);
    }
    final platformChain = platformQualityFallbackChain(
      tiers: tiers,
      requestedQuality: requestedQuality,
      fallbackQuality: fallbackQuality,
    );
    if (platformChain != null) return platformChain;

    final requestedIndex = MusicQuality.values.indexWhere(
      (quality) => quality.level == requestedQuality,
    );
    if (requestedIndex < 0) return [requestedQuality];
    final fallbackIndex = fallbackQuality == null
        ? -1
        : MusicQuality.values.indexWhere(
            (quality) => quality.level == fallbackQuality,
          );
    final lowestIndex = fallbackIndex < 0
        ? 0
        : fallbackIndex < requestedIndex
        ? fallbackIndex
        : 0;
    return [
      for (var index = requestedIndex; index >= lowestIndex; index--)
        MusicQuality.values[index].level,
    ];
  }

  Future<RemoteQueuePlaybackResult> _open(
    PlatformTrackRef ref, {
    required String requestedQuality,
    required OnlineMusicCancelToken cancelToken,
  }) async {
    final gateway = _gateway;
    if (gateway is RemoteQueuePlaybackMetadataGateway) {
      return gateway.openWithMetadata(
        ref,
        requestedQuality: requestedQuality,
        cancelToken: cancelToken,
      );
    }
    await gateway.open(
      ref,
      requestedQuality: requestedQuality,
      cancelToken: cancelToken,
    );
    return const RemoteQueuePlaybackResult();
  }

  void cancel() {
    if (_disposed) return;
    _operation++;
    _activeToken?.cancel();
    _activeToken = null;
  }

  void dispose() {
    if (_disposed) return;
    cancel();
    _disposed = true;
  }

  void _throwIfDisposed() {
    if (_disposed) {
      throw StateError('RemotePlaybackQueueController has been disposed');
    }
  }
}
