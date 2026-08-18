import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/native/bass/bass_player.dart';
import 'package:pure_music/play_service/bass_url_playback_backend.dart';
import 'package:pure_music/play_service/playback_source.dart';
import 'package:pure_music/services/music_platform/models/music_models.dart';

void main() {
  late _FakeBassUrlPlaybackDriver driver;
  late BassUrlPlaybackBackend backend;
  late List<PlaybackBackendState> states;
  late StreamSubscription<PlaybackBackendState> subscription;

  setUp(() {
    driver = _FakeBassUrlPlaybackDriver();
    backend = BassUrlPlaybackBackend(driver: driver);
    states = [];
    subscription = backend.stateStream.listen(states.add);
  });

  tearDown(() async {
    await subscription.cancel();
    await backend.dispose();
  });

  test('rejects local playback sources', () async {
    await expectLater(
      backend.open(const LocalPlaybackSource(path: 'local.mp3')),
      throwsA(
        isA<PlaybackBackendOpenException>().having(
          (error) => error.kind,
          'kind',
          PlaybackBackendOpenFailure.unavailable,
        ),
      ),
    );

    expect(driver.openedUris, isEmpty);
  });

  test('opens a URL and maps driver states', () async {
    driver.state = PlayerState.playing;

    await backend.open(_remoteSource());
    driver.emit(PlayerState.pausedDevice);
    driver.emit(PlayerState.stalled);
    driver.emit(PlayerState.completed);
    await pumpEventQueue();

    expect(driver.openedUris, hasLength(1));
    expect(states, [
      PlaybackBackendState.opening,
      PlaybackBackendState.playing,
      PlaybackBackendState.paused,
      PlaybackBackendState.stalled,
      PlaybackBackendState.completed,
    ]);
  });

  test('exposes the remote driver spectrum without copying it', () async {
    final frames = <Float32List>[];
    final spectrumSubscription = backend.spectrumStream.listen(frames.add);
    final frame = Float32List.fromList([0.1, 0.2, 0.3, 0.4]);

    driver.emitSpectrum(frame);
    await pumpEventQueue();

    expect(frames, hasLength(1));
    expect(frames.single, same(frame));
    await spectrumSubscription.cancel();
  });

  test('routes clamped volume to the remote driver', () {
    backend.setVolume(1.5);
    backend.setVolume(-0.5);

    expect(driver.volumeValues, [1.0, 0.0]);
  });

  test('pauses and resumes the current URL without reopening it', () async {
    driver.state = PlayerState.playing;

    await backend.open(_remoteSource());
    await backend.pause();
    await backend.resume();
    await pumpEventQueue();

    expect(driver.openedUris, hasLength(1));
    expect(driver.pauseCount, 1);
    expect(driver.resumeCount, 1);
    expect(states, [
      PlaybackBackendState.opening,
      PlaybackBackendState.playing,
      PlaybackBackendState.paused,
      PlaybackBackendState.playing,
    ]);
  });

  test('controls are safe no-ops without an applicable remote state', () async {
    await backend.pause();
    await backend.resume();

    driver.state = PlayerState.playing;
    await backend.open(_remoteSource());
    await backend.pause();
    await backend.pause();
    await backend.resume();
    await backend.resume();

    expect(driver.pauseCount, 1);
    expect(driver.resumeCount, 1);
  });

  test('reads one position snapshot only from readable states', () async {
    expect(backend.readPosition(), isNull);
    expect(driver.positionReadCount, 0);

    driver.state = PlayerState.playing;
    driver.positionSeconds = 12.345;
    await backend.open(_remoteSource());

    expect(backend.readPosition(), const Duration(milliseconds: 12345));
    expect(driver.positionReadCount, 1);

    driver.emit(PlayerState.paused);
    await pumpEventQueue();
    expect(backend.readPosition(), const Duration(milliseconds: 12345));

    driver.emit(PlayerState.stalled);
    await pumpEventQueue();
    expect(backend.readPosition(), const Duration(milliseconds: 12345));

    driver.emit(PlayerState.completed);
    await pumpEventQueue();
    expect(backend.readPosition(), const Duration(milliseconds: 12345));
    expect(driver.positionReadCount, 4);

    await backend.stop();
    expect(backend.readPosition(), isNull);
    expect(driver.positionReadCount, 4);
  });

  test('reads the opened remote stream duration safely', () async {
    expect(backend.readDuration(), isNull);
    expect(driver.durationReadCount, 0);

    driver.state = PlayerState.playing;
    driver.durationSeconds = 185.25;
    await backend.open(_remoteSource());

    expect(backend.readDuration(), const Duration(milliseconds: 185250));
    expect(driver.durationReadCount, 1);

    for (final value in [double.nan, double.infinity, 0.0, -1.0]) {
      driver.durationSeconds = value;
      expect(backend.readDuration(), isNull);
    }
    driver.durationError = StateError('native duration failed');
    expect(backend.readDuration(), isNull);

    await backend.stop();
    expect(backend.readDuration(), isNull);
  });

  test(
    'position read degrades invalid values and driver errors to unknown',
    () async {
      driver.state = PlayerState.playing;
      await backend.open(_remoteSource());

      for (final value in [double.nan, double.infinity, -1.0]) {
        driver.positionSeconds = value;
        expect(backend.readPosition(), isNull);
      }

      driver.positionError = StateError('native position failed');
      expect(backend.readPosition(), isNull);
    },
  );

  test('opening and failed states do not access the position reader', () async {
    final pendingOpen = Completer<void>();
    driver.pendingOpens.add(pendingOpen.future);
    final openFuture = backend.open(_remoteSource());
    await pumpEventQueue();

    expect(backend.readPosition(), isNull);
    expect(driver.positionReadCount, 0);

    driver.openError = StateError('open failed');
    pendingOpen.complete();
    await expectLater(openFuture, throwsA(isA<PlaybackBackendOpenException>()));
    expect(backend.readPosition(), isNull);
    expect(driver.positionReadCount, 0);
  });

  test('control failures expose only a safe exception', () async {
    driver.state = PlayerState.playing;
    await backend.open(_remoteSource());
    driver.pauseError = StateError('signed request failed');

    Object? error;
    try {
      await backend.pause();
    } catch (caught) {
      error = caught;
    }

    expect(error, isA<PlaybackBackendControlException>());
    expect(error.toString(), isNot(contains('secret-signature')));
    expect(states.last, PlaybackBackendState.playing);
  });

  test('stop prevents a stale open from becoming playing', () async {
    final pendingOpen = Completer<void>();
    driver.pendingOpens.add(pendingOpen.future);

    final openFuture = backend.open(_remoteSource());
    await pumpEventQueue();
    await backend.stop();
    driver.state = PlayerState.playing;
    pendingOpen.complete();
    await openFuture;
    await pumpEventQueue();

    expect(states, contains(PlaybackBackendState.opening));
    expect(states.last, PlaybackBackendState.stopped);
    expect(states, isNot(contains(PlaybackBackendState.playing)));
    expect(driver.stopCount, greaterThanOrEqualTo(2));
  });

  test('a newer open supersedes an older pending open', () async {
    final firstOpen = Completer<void>();
    driver.pendingOpens.add(firstOpen.future);
    driver.pendingOpens.add(Future<void>.value());

    final oldFuture = backend.open(_remoteSource(trackId: 'old'));
    await pumpEventQueue();
    final newFuture = backend.open(_remoteSource(trackId: 'new'));
    firstOpen.complete();
    await Future.wait([oldFuture, newFuture]);
    await pumpEventQueue();

    expect(driver.openedUris, hasLength(2));
    expect(states.last, PlaybackBackendState.playing);
    expect(driver.stopCount, 1);
  });

  test('open failure exposes only a safe backend exception', () async {
    driver.openError = StateError('signed request failed');

    Object? error;
    try {
      await backend.open(_remoteSource());
    } catch (caught) {
      error = caught;
    }

    expect(error, isA<PlaybackBackendOpenException>());
    expect(error.toString(), isNot(contains('secret-signature')));
    expect(states, contains(PlaybackBackendState.failed));
  });

  test('dispose is idempotent', () async {
    await backend.dispose();
    await backend.dispose();

    expect(driver.disposeCount, 1);
  });
}

RemotePlaybackSource _remoteSource({String trackId = 'track-1'}) {
  final now = DateTime.now();
  return RemotePlaybackSource(
    stream: ResolvedStream(
      ref: PlatformTrackRef(platform: MusicPlatform.netease, trackId: trackId),
      uri: Uri.parse('https://media.invalid/audio?signature=secret-signature'),
      requestedQuality: 'standard',
      resolvedAt: now,
      expiresAt: now.add(const Duration(minutes: 5)),
    ),
  );
}

final class _FakeBassUrlPlaybackDriver implements BassUrlPlaybackDriver {
  final _states = StreamController<PlayerState>.broadcast();
  final _spectrum = StreamController<Float32List>.broadcast();
  final openedUris = <Uri>[];
  @override
  PlayerState state = PlayerState.stopped;
  final pendingOpens = <Future<void>>[];
  Object? openError;
  Object? pauseError;
  Object? resumeError;
  int pauseCount = 0;
  int resumeCount = 0;
  int stopCount = 0;
  int disposeCount = 0;
  double? positionSeconds;
  Object? positionError;
  int positionReadCount = 0;
  double? durationSeconds;
  Object? durationError;
  int durationReadCount = 0;
  final volumeValues = <double>[];

  @override
  Stream<PlayerState> get stateStream => _states.stream;

  @override
  Stream<Float32List> get spectrumStream => _spectrum.stream;

  @override
  double? readPositionSeconds() {
    positionReadCount++;
    final error = positionError;
    if (error != null) throw error;
    return positionSeconds;
  }

  @override
  double? readDurationSeconds() {
    durationReadCount++;
    final error = durationError;
    if (error != null) throw error;
    return durationSeconds;
  }

  @override
  void setVolume(double volume) {
    volumeValues.add(volume);
  }

  void emit(PlayerState value) {
    state = value;
    _states.add(value);
  }

  void emitSpectrum(Float32List value) {
    _spectrum.add(value);
  }

  @override
  Future<void> open(Uri uri) async {
    openedUris.add(uri);
    if (pendingOpens.isNotEmpty) await pendingOpens.removeAt(0);
    final error = openError;
    if (error != null) throw error;
    state = PlayerState.playing;
  }

  @override
  Future<void> pause() async {
    pauseCount++;
    final error = pauseError;
    if (error != null) throw error;
    emit(PlayerState.paused);
  }

  @override
  Future<void> resume() async {
    resumeCount++;
    final error = resumeError;
    if (error != null) throw error;
    emit(PlayerState.playing);
  }

  @override
  Future<void> stop() async {
    stopCount++;
    state = PlayerState.stopped;
  }

  @override
  Future<void> dispose() async {
    disposeCount++;
    await _states.close();
    await _spectrum.close();
  }
}
