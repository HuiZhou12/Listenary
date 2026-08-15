import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/play_service/playback_source.dart';
import 'package:pure_music/services/music_platform/models/music_models.dart';

void main() {
  const ref = PlatformTrackRef(
    platform: MusicPlatform.netease,
    trackId: 'track-1',
  );
  final resolvedAt = DateTime.utc(2026, 8, 14, 12);

  test('local source keeps the local path only', () {
    const source = LocalPlaybackSource(path: r'C:\Music\song.mp3');

    expect(source.path, r'C:\Music\song.mp3');
    expect(source, isA<PlaybackSource>());
  });

  test('remote source exposes resolved stream without a path', () {
    final source = RemotePlaybackSource(
      stream: ResolvedStream(
        ref: ref,
        uri: Uri.parse('https://media.invalid/stream'),
        requestedQuality: 'standard',
        resolvedAt: resolvedAt,
        expiresAt: resolvedAt.add(const Duration(minutes: 1)),
      ),
    );

    expect(source.uri, Uri.parse('https://media.invalid/stream'));
    expect(source.isExpiredAt(resolvedAt), isFalse);
    expect(
      source.isExpiredAt(resolvedAt.add(const Duration(minutes: 1))),
      isTrue,
    );
    expect(source, isA<PlaybackSource>());
  });

  test('backend contract supports state and lifecycle operations', () async {
    final backend = _FakePlaybackBackend();
    final states = <PlaybackBackendState>[];
    final subscription = backend.stateStream.listen(states.add);
    const source = LocalPlaybackSource(path: r'C:\Music\song.mp3');

    await backend.open(source);
    await backend.stop();
    await backend.dispose();
    await subscription.cancel();

    expect(backend.opened, [source]);
    expect(backend.operations, ['open', 'stop', 'dispose']);
    expect(states, [
      PlaybackBackendState.opening,
      PlaybackBackendState.playing,
    ]);
    expect(backend, isNot(isA<ControllablePlaybackBackend>()));
  });
}

final class _FakePlaybackBackend implements PlaybackBackend {
  final _stateController = StreamController<PlaybackBackendState>.broadcast();
  final List<PlaybackSource> opened = [];
  final List<String> operations = [];

  @override
  Stream<PlaybackBackendState> get stateStream => _stateController.stream;

  @override
  Future<void> open(PlaybackSource source) async {
    operations.add('open');
    opened.add(source);
    _stateController.add(PlaybackBackendState.opening);
    _stateController.add(PlaybackBackendState.playing);
  }

  @override
  Future<void> stop() async {
    operations.add('stop');
  }

  @override
  Future<void> dispose() async {
    operations.add('dispose');
    await _stateController.close();
  }
}
