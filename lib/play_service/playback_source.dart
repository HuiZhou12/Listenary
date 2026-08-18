import 'dart:async';
import 'dart:typed_data';

import 'package:pure_music/services/music_platform/models/music_models.dart';

sealed class PlaybackSource {
  const PlaybackSource();
}

final class LocalPlaybackSource extends PlaybackSource {
  const LocalPlaybackSource({required this.path});

  final String path;
}

final class RemotePlaybackSource extends PlaybackSource {
  const RemotePlaybackSource({required this.stream});

  final ResolvedStream stream;

  Uri get uri => stream.uri;

  bool isExpiredAt(DateTime time) => stream.isExpiredAt(time);
}

enum PlaybackBackendState {
  stopped,
  opening,
  playing,
  paused,
  stalled,
  completed,
  failed,
}

enum PlaybackBackendOpenFailure { expired, unavailable }

final class PlaybackBackendOpenException implements Exception {
  const PlaybackBackendOpenException({required this.kind});

  final PlaybackBackendOpenFailure kind;

  @override
  String toString() => 'PlaybackBackendOpenException(${kind.name})';
}

abstract interface class PlaybackBackend {
  Stream<PlaybackBackendState> get stateStream;

  Future<void> open(PlaybackSource source);

  Future<void> stop();

  Future<void> dispose();
}

final class PlaybackBackendControlException implements Exception {
  const PlaybackBackendControlException();

  @override
  String toString() => 'PlaybackBackendControlException';
}

abstract interface class ControllablePlaybackBackend
    implements PlaybackBackend {
  Future<void> pause();

  Future<void> resume();
}

abstract interface class PositionReadablePlaybackBackend
    implements PlaybackBackend {
  Duration? readPosition();
}

abstract interface class DurationReadablePlaybackBackend
    implements PlaybackBackend {
  Duration? readDuration();
}

abstract interface class SpectrumReadablePlaybackBackend
    implements PlaybackBackend {
  Stream<Float32List> get spectrumStream;
}

abstract interface class VolumeControllablePlaybackBackend
    implements PlaybackBackend {
  void setVolume(double volume);
}
