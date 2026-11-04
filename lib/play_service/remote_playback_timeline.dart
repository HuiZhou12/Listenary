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

typedef RemotePlaybackTimelineClock = Duration Function();

final class RemotePlaybackTimelineController
    extends ValueNotifier<RemotePlaybackTimelineSnapshot> {
  RemotePlaybackTimelineController({
    required Duration? Function() readPosition,
    this.sampleInterval = const Duration(milliseconds: 50),
    RemotePlaybackTimelineTickerFactory tickerFactory =
        _createRemotePlaybackTimelineTicker,
    RemotePlaybackTimelineClock? clock,
  }) : assert(sampleInterval > Duration.zero),
       _readPosition = readPosition,
       _tickerFactory = tickerFactory,
       _clock = clock ?? _createRemotePlaybackTimelineClock(),
       super(const RemotePlaybackTimelineSnapshot.unknown());

  /// seek 后保护窗口：窗口内与跳转方向相反的旧采样一律丢弃。
  ///
  /// 参考本地歌词的 `_pendingSeekMs` 思路：seek 之后后端位置要等下一次采样才回来，
  /// 期间 [projectedSnapshot] 会按**旧锚点**继续外推 ⇒ UI 短暂回跳到跳转前的位置。
  static const seekGuardWindow = Duration(milliseconds: 400);

  /// 认定"采样已跟上跳转目标"的容差。
  static const seekGuardTolerance = Duration(milliseconds: 120);

  final Duration? Function() _readPosition;
  final RemotePlaybackTimelineTickerFactory _tickerFactory;
  final RemotePlaybackTimelineClock _clock;
  final Duration sampleInterval;
  RemotePlaybackTimelineTicker? _ticker;
  int? _revision;
  PlaybackBackendState? _state;
  Duration? _duration;
  Duration? _positionSampleTime;
  int _tickerGeneration = 0;
  bool _disposed = false;
  Duration? _seekTarget;
  Duration? _seekGuardUntil;

  bool get isAdvancing =>
      !_disposed &&
      _state == PlaybackBackendState.playing &&
      value.hasKnownPosition;

  /// 是否处于 seek 保护窗口内（测试与 UI 诊断用）。
  bool get isSeekGuardActive {
    final until = _seekGuardUntil;
    return until != null && _clock() < until;
  }

  /// 声明"刚刚跳到 [target]"。
  ///
  /// 立刻把锚点挪到目标位置（这会消掉基于旧位置的整段外推），并在
  /// [seekGuardWindow] 内拒绝仍停留在旧位置附近的过期采样。
  void expectSeek(Duration target) {
    if (_disposed) return;
    _seekTarget = target;
    _seekGuardUntil = _clock() + seekGuardWindow;
    _publish(position: target, updateSampleTime: true);
  }

  /// 放弃 seek 期望（UI 判定跳转失败、已回滚时调用），让下一次采样立刻生效。
  void abandonSeekExpectation() {
    _seekTarget = null;
    _seekGuardUntil = null;
  }

  /// 立刻按后端真实位置重采样一次（绕开 seek 保护窗口）。
  ///
  /// 用于跳转失败的回滚：先丢弃期望，再把锚点拉回真实位置，
  /// 避免 UI 停在用户拖动出来的那个假位置上。
  void resyncNow() {
    if (_disposed) return;
    final revision = _revision;
    if (revision == null) return;
    abandonSeekExpectation();
    _sample(revision);
  }

  RemotePlaybackTimelineSnapshot get projectedSnapshot {
    final position = value.position;
    final sampleTime = _positionSampleTime;
    if (!isAdvancing || position == null || sampleTime == null) return value;
    final elapsed = _clock() - sampleTime;
    if (elapsed <= Duration.zero) return value;
    return RemotePlaybackTimelineSnapshot.normalized(
      position: position + elapsed,
      duration: value.duration,
    );
  }

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

    // 换曲（revision 变）时上一次的 seek 期望已经无意义，必须丢弃，
    // 否则新曲的位置会被旧曲的目标位置挡住。
    if (revisionChanged) abandonSeekExpectation();

    if (revisionChanged || state == PlaybackBackendState.opening) {
      _cancelTicker();
      _publish(position: Duration.zero, updateSampleTime: true);
    } else {
      _publish(position: value.position, updateSampleTime: false);
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
    _positionSampleTime = null;
    abandonSeekExpectation();
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
    if (_shouldIgnoreSampleAfterSeek(position)) return;
    _publish(position: position, updateSampleTime: true);
  }

  /// seek 保护窗口内丢弃"还没跟上跳转"的过期采样。
  ///
  /// 判据：窗口未过期，且采样点还没接近跳转目标。一旦采样跟上
  /// （落在目标容差内），立刻解除保护、恢复正常采信。
  bool _shouldIgnoreSampleAfterSeek(Duration sample) {
    final target = _seekTarget;
    final until = _seekGuardUntil;
    if (target == null || until == null) return false;
    if (_clock() >= until) {
      abandonSeekExpectation();
      return false;
    }
    if ((sample - target).abs() <= seekGuardTolerance) {
      abandonSeekExpectation();
      return false;
    }
    return true;
  }

  void _publish({required Duration? position, required bool updateSampleTime}) {
    if (updateSampleTime) _positionSampleTime = _clock();
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

RemotePlaybackTimelineClock _createRemotePlaybackTimelineClock() {
  final stopwatch = Stopwatch()..start();
  return () => stopwatch.elapsed;
}

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
