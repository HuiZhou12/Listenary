import 'package:flutter/foundation.dart';

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
