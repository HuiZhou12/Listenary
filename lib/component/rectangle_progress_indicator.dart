import 'dart:async';
import 'package:pure_music/native/bass/bass_player.dart';
import 'package:pure_music/play_service/play_service.dart';
import 'package:pure_music/play_service/playback_service.dart';
import 'package:pure_music/play_service/remote_playback_timeline.dart';
import 'package:flutter/material.dart';

class RectangleProgressIndicator extends StatefulWidget {
  const RectangleProgressIndicator({
    super.key,
    required this.size,
    required this.child,
    this.progressEnabled = true,
    this.remoteTimeline,
    this.remoteTimelineAdvancing = false,
  }) : assert(remoteTimeline != null || !remoteTimelineAdvancing);

  final Size size;
  final Widget child;
  final bool progressEnabled;
  final RemotePlaybackTimelineController? remoteTimeline;
  final bool remoteTimelineAdvancing;

  @override
  State<RectangleProgressIndicator> createState() =>
      _RectangleProgressIndicatorState();
}

class _RectangleProgressIndicatorState
    extends State<RectangleProgressIndicator> {
  PlaybackService? _playbackService;
  Timer? _progressTimer;
  final Stopwatch _clock = Stopwatch()..start();
  int _lastNativeSyncMs = 0;
  double _syncedPosition = 0.0;
  double _syncedLength = 1.0;
  static const _nativeSyncInterval = Duration(seconds: 1);

  /// position / length, [0, 1]
  final progress = ValueNotifier<double>(0);

  PlaybackService get _localPlaybackService =>
      _playbackService ??= PlayService.instance.playbackService;

  @override
  void initState() {
    super.initState();
    _bindProgressSource();
    _syncTimer();
  }

  void _bindProgressSource() {
    final remoteTimeline = widget.remoteTimeline;
    if (remoteTimeline != null) {
      remoteTimeline.addListener(_syncTimer);
      return;
    }
    final playbackService = _localPlaybackService;
    playbackService.playerStateNotifier.addListener(_syncTimer);
    playbackService.nowPlayingNotifier.addListener(_syncNativeProgress);
  }

  void _unbindProgressSource(RectangleProgressIndicator source) {
    final remoteTimeline = source.remoteTimeline;
    if (remoteTimeline != null) {
      remoteTimeline.removeListener(_syncTimer);
      return;
    }
    final playbackService = _playbackService;
    playbackService?.playerStateNotifier.removeListener(_syncTimer);
    playbackService?.nowPlayingNotifier.removeListener(_syncNativeProgress);
  }

  void _syncNativeProgress() {
    if (!widget.progressEnabled) {
      progress.value = 0;
      return;
    }
    final remoteTimeline = widget.remoteTimeline;
    if (remoteTimeline != null) {
      progress.value = remoteTimeline.projectedSnapshot.progress ?? 0;
      return;
    }
    final playbackService = _localPlaybackService;
    _syncedLength = playbackService.length;
    _syncedPosition = playbackService.position;
    _lastNativeSyncMs = _clock.elapsedMilliseconds;
    _emitProgressFromLocal();
  }

  void _emitProgressFromLocal() {
    final elapsedMs = _clock.elapsedMilliseconds - _lastNativeSyncMs;
    final isPlaying =
        _localPlaybackService.playerStateNotifier.value == PlayerState.playing;
    final position = isPlaying
        ? _syncedPosition + elapsedMs / 1000.0
        : _syncedPosition;
    progress.value = _syncedLength > 0
        ? (position / _syncedLength).clamp(0.0, 1.0)
        : 0;
  }

  void _syncTimer() {
    if (!widget.progressEnabled) {
      _progressTimer?.cancel();
      _progressTimer = null;
      progress.value = 0;
      return;
    }
    _syncNativeProgress();
    final isPlaying = widget.remoteTimeline != null
        ? widget.remoteTimelineAdvancing
        : _localPlaybackService.playerStateNotifier.value ==
              PlayerState.playing;
    if (!isPlaying) {
      _progressTimer?.cancel();
      _progressTimer = null;
      return;
    }
    _progressTimer ??= Timer.periodic(const Duration(milliseconds: 200), (_) {
      if (widget.remoteTimeline != null) {
        _syncNativeProgress();
        return;
      }
      final elapsedSinceNative = _clock.elapsedMilliseconds - _lastNativeSyncMs;
      if (elapsedSinceNative >= _nativeSyncInterval.inMilliseconds) {
        _syncNativeProgress();
      } else {
        _emitProgressFromLocal();
      }
    });
  }

  @override
  void didUpdateWidget(RectangleProgressIndicator oldWidget) {
    super.didUpdateWidget(oldWidget);
    final sourceChanged = !identical(
      oldWidget.remoteTimeline,
      widget.remoteTimeline,
    );
    if (sourceChanged) {
      _unbindProgressSource(oldWidget);
      _bindProgressSource();
    }
    if (sourceChanged ||
        oldWidget.progressEnabled != widget.progressEnabled ||
        oldWidget.remoteTimelineAdvancing != widget.remoteTimelineAdvancing) {
      _syncTimer();
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return CustomPaint(
      size: widget.size,
      painter: RectangleProgressPainter(progress: progress, scheme: scheme),
      child: widget.child,
    );
  }

  @override
  void dispose() {
    _unbindProgressSource(widget);
    _progressTimer?.cancel();
    progress.dispose();
    super.dispose();
  }
}

class RectangleProgressPainter extends CustomPainter {
  /// position / length, [0, 1]
  final ValueNotifier<double> progress;

  final ColorScheme scheme;
  final Paint _progressPainter = Paint();
  final Paint _trackPainter = Paint();

  RectangleProgressPainter({required this.progress, required this.scheme})
    : super(repaint: progress);

  @override
  void paint(Canvas canvas, Size size) {
    _progressPainter.color = scheme.secondaryContainer;
    _trackPainter.color = scheme.surfaceContainer;

    /// 进度条背景
    canvas.drawRect(
      Rect.fromLTWH(0.0, 0.0, size.width, size.height),
      _trackPainter,
    );

    /// 进度
    if (!progress.value.isNaN && !progress.value.isInfinite) {
      canvas.drawRect(
        Rect.fromLTWH(0.0, 0.0, size.width * progress.value, size.height),
        _progressPainter,
      );
    }
  }

  @override
  bool shouldRepaint(RectangleProgressPainter oldDelegate) => false;

  @override
  bool shouldRebuildSemantics(RectangleProgressPainter oldDelegate) => false;
}
