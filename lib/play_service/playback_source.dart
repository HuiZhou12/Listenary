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

/// 后端拒绝进度跳转（音源不支持、流尚未下载到该位置、或当前状态不可跳转）。
///
/// **只向上层暴露这一种类型**：驱动层抛出的 [FormatException] 等细节
/// （可能带流地址/签名线索）一律在 backend 边界收敛掉。
final class PlaybackBackendSeekException implements Exception {
  const PlaybackBackendSeekException();

  @override
  String toString() => 'PlaybackBackendSeekException';
}

abstract interface class ControllablePlaybackBackend
    implements PlaybackBackend {
  Future<void> pause();

  Future<void> resume();
}

/// 可跳转进度的后端；远程流后端也实现它。
abstract interface class SeekablePlaybackBackend implements PlaybackBackend {
  /// 跳到 [position]。失败时抛 [PlaybackBackendSeekException]，不中断当前流。
  Future<void> seek(Duration position);
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
