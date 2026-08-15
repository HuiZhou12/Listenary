import 'package:pure_music/play_service/playback_source.dart';
import 'package:pure_music/play_service/remote_playback_queue.dart';
import 'package:pure_music/services/music_platform/chksz/chksz_request.dart';
import 'package:pure_music/services/music_platform/chksz/chksz_runtime.dart';
import 'package:pure_music/services/music_platform/chksz/remote_stream_coordinator.dart';
import 'package:pure_music/services/music_platform/models/music_models.dart';

abstract interface class RemoteQueuePlaybackGateway {
  Future<void> open(
    PlatformTrackRef ref, {
    required String requestedQuality,
    required ChkszCancelToken cancelToken,
  });
}

final class ChkszRemoteQueuePlaybackGateway
    implements RemoteQueuePlaybackGateway {
  const ChkszRemoteQueuePlaybackGateway({
    required ChkszRuntime runtime,
    required PlaybackBackend backend,
  }) : _runtime = runtime,
       _backend = backend;

  final ChkszRuntime _runtime;
  final PlaybackBackend _backend;

  @override
  Future<void> open(
    PlatformTrackRef ref, {
    required String requestedQuality,
    required ChkszCancelToken cancelToken,
  }) async {
    await _runtime.resolveAndOpenNetease(
      ref,
      requestedQuality: requestedQuality,
      backend: _backend,
      cancelToken: cancelToken,
    );
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
  ChkszCancelToken? _activeToken;
  int _operation = 0;
  bool _disposed = false;

  Future<void> play(int index, {required String requestedQuality}) async {
    _throwIfDisposed();
    final snapshot = _queue.value;
    RangeError.checkValidIndex(index, snapshot.items, 'index');
    final item = snapshot.items[index];
    final operation = ++_operation;
    _activeToken?.cancel();
    final token = ChkszCancelToken();
    _activeToken = token;

    try {
      await _gateway.open(
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
      _queue.select(index);
    } finally {
      if (identical(_activeToken, token)) {
        _activeToken = null;
      }
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _operation++;
    _activeToken?.cancel();
    _activeToken = null;
  }

  void _throwIfDisposed() {
    if (_disposed) {
      throw StateError('RemotePlaybackQueueController has been disposed');
    }
  }
}
