import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:pure_music/play_service/playback_source.dart';

@immutable
final class RemotePlaybackTimelineSnapshot {
  const RemotePlaybackTimelineSnapshot.unknown()
    : position = null,
      duration = null;

  factory RemotePlaybackTimelineSnapshot.normalized({
    required Duration? position,
    required Duration? duration,
  }) {
    var normalizedPosition = position?.isNegative == false ? position : null;
    final normalizedDuration = duration != null && duration > Duration.zero
        ? duration
        : null;
    if (normalizedPosition != null &&
        normalizedDuration != null &&
        normalizedPosition > normalizedDuration) {
      normalizedPosition = normalizedDuration;
    }
    return RemotePlaybackTimelineSnapshot._(
      position: normalizedPosition,
      duration: normalizedDuration,
    );
  }

  const RemotePlaybackTimelineSnapshot._({
    required this.position,
    required this.duration,
  });

  final Duration? position;
  final Duration? duration;

  bool get hasKnownPosition => position != null;
  bool get hasKnownDuration => duration != null;

  double? get progress {
    final currentPosition = position;
    final currentDuration = duration;
    if (currentPosition == null || currentDuration == null) return null;
    return currentPosition.inMicroseconds / currentDuration.inMicroseconds;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is RemotePlaybackTimelineSnapshot &&
          position == other.position &&
          duration == other.duration;

  @override
  int get hashCode => Object.hash(position, duration);
}

abstract interface class RemotePlaybackTimelineTicker {
  void cancel();
}

typedef RemotePlaybackTimelineTickerFactory =
    RemotePlaybackTimelineTicker Function(
      Duration interval,
      void Function() callback,
    );

final class RemotePlaybackTimelineController
    extends ValueNotifier<RemotePlaybackTimelineSnapshot> {
  RemotePlaybackTimelineController({
    required Duration? Function() readPosition,
    this.sampleInterval = const Duration(seconds: 1),
    RemotePlaybackTimelineTickerFactory tickerFactory =
        _createRemotePlaybackTimelineTicker,
  }) : assert(sampleInterval > Duration.zero),
       _readPosition = readPosition,
       _tickerFactory = tickerFactory,
       super(const RemotePlaybackTimelineSnapshot.unknown());

  final Duration? Function() _readPosition;
  final RemotePlaybackTimelineTickerFactory _tickerFactory;
  final Duration sampleInterval;
  RemotePlaybackTimelineTicker? _ticker;
  int? _revision;
  PlaybackBackendState? _state;
  Duration? _duration;
  int _tickerGeneration = 0;
  bool _disposed = false;

  void synchronize({
    required int revision,
    required PlaybackBackendState? state,
    required Duration duration,
  }) {
    if (_disposed) return;
    if (state == null) {
      _clear();
      return;
    }

    final revisionChanged = revision != _revision;
    final stateChanged = state != _state;
    _revision = revision;
    _state = state;
    _duration = duration > Duration.zero ? duration : null;

    if (revisionChanged || state == PlaybackBackendState.opening) {
      _cancelTicker();
      _publish(position: Duration.zero);
    } else {
      _publish(position: value.position);
    }

    if (!revisionChanged && !stateChanged) return;
    switch (state) {
      case PlaybackBackendState.playing:
        _sample(revision);
        _startTicker(revision);
      case PlaybackBackendState.paused:
      case PlaybackBackendState.stalled:
      case PlaybackBackendState.completed:
        _cancelTicker();
        _sample(revision);
      case PlaybackBackendState.stopped:
      case PlaybackBackendState.failed:
        _cancelTicker();
      case PlaybackBackendState.opening:
        break;
    }
  }

  void clear() {
    if (_disposed) return;
    _clear();
  }

  void _clear() {
    _cancelTicker();
    _revision = null;
    _state = null;
    _duration = null;
    _setValue(const RemotePlaybackTimelineSnapshot.unknown());
  }

  void _startTicker(int revision) {
    if (_ticker != null || _disposed) return;
    final generation = ++_tickerGeneration;
    _ticker = _tickerFactory(sampleInterval, () {
      if (_disposed ||
          generation != _tickerGeneration ||
          revision != _revision ||
          _state != PlaybackBackendState.playing) {
        return;
      }
      _sample(revision);
    });
  }

  void _cancelTicker() {
    _tickerGeneration++;
    _ticker?.cancel();
    _ticker = null;
  }

  void _sample(int revision) {
    if (_disposed || revision != _revision) return;
    Duration? position;
    try {
      position = _readPosition();
    } catch (_) {
      return;
    }
    if (position == null || position.isNegative) return;
    _publish(position: position);
  }

  void _publish({required Duration? position}) {
    _setValue(
      RemotePlaybackTimelineSnapshot.normalized(
        position: position,
        duration: _duration,
      ),
    );
  }

  void _setValue(RemotePlaybackTimelineSnapshot next) {
    if (next != value) value = next;
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _cancelTicker();
    super.dispose();
  }
}

RemotePlaybackTimelineTicker _createRemotePlaybackTimelineTicker(
  Duration interval,
  void Function() callback,
) => _TimerRemotePlaybackTimelineTicker(interval, callback);

final class _TimerRemotePlaybackTimelineTicker
    implements RemotePlaybackTimelineTicker {
  _TimerRemotePlaybackTimelineTicker(
    Duration interval,
    void Function() callback,
  ) : _timer = Timer.periodic(interval, (_) => callback());

  final Timer _timer;

  @override
  void cancel() => _timer.cancel();
}
