import 'package:pure_music/play_service/playback_source.dart';
import 'package:pure_music/services/music_platform/models/music_models.dart';
import 'package:pure_music/services/music_platform/online_music_request.dart';

typedef RemoteStreamResolver =
    Future<ResolvedStream> Function(
      PlatformTrackRef ref, {
      required String requestedQuality,
      required OnlineMusicCancelToken cancelToken,
    });
typedef RemoteStreamClock = DateTime Function();

enum RemoteStreamPlaybackErrorKind {
  cancelled,
  invalidStream,
  expired,
  openFailed,
}

final class RemoteStreamPlaybackException implements Exception {
  const RemoteStreamPlaybackException({required this.kind});

  final RemoteStreamPlaybackErrorKind kind;

  String get safeMessage => switch (kind) {
    RemoteStreamPlaybackErrorKind.cancelled => '播放请求已取消',
    RemoteStreamPlaybackErrorKind.invalidStream => '音乐服务返回了无效播放地址',
    RemoteStreamPlaybackErrorKind.expired => '播放地址已过期，请重试',
    RemoteStreamPlaybackErrorKind.openFailed => '无法打开远程音频流',
  };

  @override
  String toString() => 'RemoteStreamPlaybackException(${kind.name})';
}

final class RemoteStreamCoordinator {
  RemoteStreamCoordinator({
    required RemoteStreamResolver resolver,
    required PlaybackBackend backend,
    RemoteStreamClock? clock,
  }) : _resolver = resolver,
       _backend = backend,
       _clock = clock ?? DateTime.now;

  final RemoteStreamResolver _resolver;
  final PlaybackBackend _backend;
  final RemoteStreamClock _clock;

  Future<ResolvedStream> resolveAndOpen(
    PlatformTrackRef ref, {
    required String requestedQuality,
    OnlineMusicCancelToken? cancelToken,
  }) async {
    final token = cancelToken ?? OnlineMusicCancelToken();
    for (var attempt = 0; attempt < 2; attempt++) {
      _throwIfCancelled(token);
      final stream = await _resolver(
        ref,
        requestedQuality: requestedQuality,
        cancelToken: token,
      );
      _throwIfCancelled(token);
      _validate(stream, ref);

      if (stream.isExpiredAt(_clock())) {
        if (attempt == 0) continue;
        throw const RemoteStreamPlaybackException(
          kind: RemoteStreamPlaybackErrorKind.expired,
        );
      }

      try {
        await _backend.open(RemotePlaybackSource(stream: stream));
        if (token.isCancelled) {
          await _stopSafely();
          _throwIfCancelled(token);
        }
        return stream;
      } on PlaybackBackendOpenException catch (error) {
        await _stopSafely();
        if (error.kind == PlaybackBackendOpenFailure.expired && attempt == 0) {
          continue;
        }
        throw RemoteStreamPlaybackException(
          kind: error.kind == PlaybackBackendOpenFailure.expired
              ? RemoteStreamPlaybackErrorKind.expired
              : RemoteStreamPlaybackErrorKind.openFailed,
        );
      } on RemoteStreamPlaybackException {
        rethrow;
      } catch (_) {
        await _stopSafely();
        throw const RemoteStreamPlaybackException(
          kind: RemoteStreamPlaybackErrorKind.openFailed,
        );
      }
    }
    throw StateError('Unreachable remote stream retry state');
  }

  void _validate(ResolvedStream stream, PlatformTrackRef expectedRef) {
    if (stream.ref != expectedRef ||
        !stream.uri.hasScheme ||
        stream.uri.host.isEmpty) {
      throw const RemoteStreamPlaybackException(
        kind: RemoteStreamPlaybackErrorKind.invalidStream,
      );
    }
  }

  void _throwIfCancelled(OnlineMusicCancelToken token) {
    if (token.isCancelled) {
      throw const RemoteStreamPlaybackException(
        kind: RemoteStreamPlaybackErrorKind.cancelled,
      );
    }
  }

  Future<void> _stopSafely() async {
    try {
      await _backend.stop();
    } catch (_) {}
  }
}
