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
  const RemoteQueuePlaybackResult({this.coverUri, this.duration});

  final Uri? coverUri;
  final Duration? duration;
}

abstract interface class RemoteQueuePlaybackMetadataGateway
    implements RemoteQueuePlaybackGateway {
  Future<RemoteQueuePlaybackResult> openWithMetadata(
    PlatformTrackRef ref, {
    required String requestedQuality,
    required OnlineMusicCancelToken cancelToken,
  });
}

final class OnlineServiceRemoteQueuePlaybackGateway
    implements RemoteQueuePlaybackMetadataGateway {
  const OnlineServiceRemoteQueuePlaybackGateway({
    required OnlineMusicService service,
    required PlaybackBackend backend,
  }) : _service = service,
       _backend = backend;

  final OnlineMusicService _service;
  final PlaybackBackend _backend;

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
  int _operation = 0;
  bool _disposed = false;

  Future<void> play(int index, {required String requestedQuality}) async {
    _throwIfDisposed();
    final snapshot = _queue.value;
    RangeError.checkValidIndex(index, snapshot.items, 'index');
    final item = snapshot.items[index];
    final operation = ++_operation;
    _activeToken?.cancel();
    final token = OnlineMusicCancelToken();
    _activeToken = token;
    _queue.select(index);

    try {
      final result = await _open(
        item.ref,
        requestedQuality: requestedQuality,
        cancelToken: token,
      );
      if (_disposed || token.isCancelled || operation != _operation) {
        throw const RemoteStreamPlaybackException(
          kind: RemoteStreamPlaybackErrorKind.cancelled,
        );
      }
      final currentItems = _queue.value.items;
      if (index >= currentItems.length || currentItems[index].ref != item.ref) {
        throw const RemoteStreamPlaybackException(
          kind: RemoteStreamPlaybackErrorKind.cancelled,
        );
      }
      _queue.enrichMetadata(
        index,
        expectedRef: item.ref,
        coverUri: result.coverUri,
        duration: result.duration,
      );
    } finally {
      if (identical(_activeToken, token)) {
        _activeToken = null;
      }
    }
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
