import 'dart:async';

import 'package:pure_music/core/utils.dart';
import 'package:pure_music/play_service/playback_source.dart';
import 'package:pure_music/play_service/remote_playback_queue.dart';
import 'package:pure_music/play_service/remote_playback_session_controller.dart';
import 'package:pure_music/play_service/remote_playback_timeline.dart';
import 'package:pure_music/services/music_platform/models/music_models.dart';
import 'package:pure_music/services/music_platform/online_library/online_history_controller.dart';

enum OnlineHistoryProjectionFailure { playbackStarted, metadata, playCount }

final class OnlineHistoryProjectionBinding {
  OnlineHistoryProjectionBinding({
    required RemotePlaybackQueue queue,
    required RemotePlaybackSessionController sessionController,
    required RemotePlaybackTimelineController timelineController,
    required OnlineHistoryController historyController,
    void Function(OnlineHistoryProjectionFailure failure)? onFailure,
  }) : _queue = queue,
       _sessionController = sessionController,
       _timelineController = timelineController,
       _historyController = historyController,
       _onFailure = onFailure ?? _logFailure,
       _controlState = sessionController.controlState {
    _queue.addListener(_synchronize);
    _timelineController.addListener(_onTimelineChanged);
    _controlSubscription = sessionController.controlStateStream.listen(
      _onControlStateChanged,
    );
    _synchronize();
  }

  final RemotePlaybackQueue _queue;
  final RemotePlaybackSessionController _sessionController;
  final RemotePlaybackTimelineController _timelineController;
  final OnlineHistoryController _historyController;
  final void Function(OnlineHistoryProjectionFailure failure) _onFailure;
  late final StreamSubscription<RemotePlaybackControlSnapshot>
  _controlSubscription;
  RemotePlaybackControlSnapshot _controlState;
  RemotePlaybackQueueItem? _item;
  int? _revision;
  Duration? _lastPosition;
  Duration _accumulated = Duration.zero;
  bool _startAttempted = false;
  bool _historyRecorded = false;
  Duration _persistedDuration = Duration.zero;
  Uri? _persistedCoverUri;
  bool _metadataUpdateInFlight = false;
  bool _countAttempted = false;
  bool _disposed = false;

  void _onControlStateChanged(RemotePlaybackControlSnapshot state) {
    if (_disposed) return;
    _controlState = state;
    _synchronize();
  }

  void _synchronize() {
    if (_disposed) return;
    final item = _queue.value.currentItem;
    if (!_controlState.isActive || item == null) {
      _reset();
      return;
    }

    final revision = _sessionController.playbackRevision;
    if (_revision != revision || _item?.ref != item.ref) {
      _beginSession(revision, item);
    } else {
      _item = item;
      _persistEnrichedMetadataIfNeeded();
    }

    if (_controlState.state == PlaybackBackendState.playing) {
      _recordPlaybackStarted();
    } else {
      _lastPosition = _timelineController.value.position;
    }
  }

  void _beginSession(int revision, RemotePlaybackQueueItem item) {
    _revision = revision;
    _item = item;
    _lastPosition = _timelineController.value.position;
    _accumulated = Duration.zero;
    _startAttempted = false;
    _historyRecorded = false;
    _persistedDuration = Duration.zero;
    _persistedCoverUri = null;
    _metadataUpdateInFlight = false;
    _countAttempted = false;
  }

  void _recordPlaybackStarted() {
    if (_startAttempted) return;
    final item = _item;
    final revision = _revision;
    if (item == null || revision == null) return;
    _startAttempted = true;
    unawaited(_persistPlaybackStarted(revision, item));
  }

  Future<void> _persistPlaybackStarted(
    int revision,
    RemotePlaybackQueueItem item,
  ) async {
    try {
      await _historyController.recordPlaybackStarted(
        _trackFromQueueItem(item),
        lastQuality: _sessionController.requestedQuality,
      );
      if (!_disposed && _revision == revision && _item?.ref == item.ref) {
        _historyRecorded = true;
        _persistedDuration = item.duration;
        _persistedCoverUri = item.coverUri;
        _persistEnrichedMetadataIfNeeded();
      }
    } catch (_) {
      if (!_disposed) {
        _onFailure(OnlineHistoryProjectionFailure.playbackStarted);
      }
    }
  }

  void _persistEnrichedMetadataIfNeeded() {
    if (!_historyRecorded || _metadataUpdateInFlight) return;
    final item = _item;
    final revision = _revision;
    if (item == null || revision == null) return;
    final hasNewDuration = item.duration > _persistedDuration;
    final hasNewCover =
        !_isRenderableHttpsUri(_persistedCoverUri) &&
        _isRenderableHttpsUri(item.coverUri);
    if (!hasNewDuration && !hasNewCover) return;
    _metadataUpdateInFlight = true;
    _persistedDuration = item.duration;
    _persistedCoverUri = item.coverUri;
    unawaited(_persistEnrichedMetadata(revision, item));
  }

  Future<void> _persistEnrichedMetadata(
    int revision,
    RemotePlaybackQueueItem item,
  ) async {
    try {
      await _historyController.updateTrackMetadata(
        _trackFromQueueItem(item),
        lastQuality: _sessionController.requestedQuality,
      );
    } catch (_) {
      if (!_disposed && _revision == revision && _item?.ref == item.ref) {
        _onFailure(OnlineHistoryProjectionFailure.metadata);
      }
    } finally {
      if (!_disposed && _revision == revision && _item?.ref == item.ref) {
        _metadataUpdateInFlight = false;
        _persistEnrichedMetadataIfNeeded();
      }
    }
  }

  void _onTimelineChanged() {
    if (_disposed) return;
    _synchronize();
    final position = _timelineController.value.position;
    if (_controlState.state != PlaybackBackendState.playing ||
        !_historyRecorded ||
        _countAttempted ||
        position == null) {
      _lastPosition = position;
      return;
    }

    final threshold = _listenThreshold(_item?.duration ?? Duration.zero);
    if (threshold <= Duration.zero) return;
    final previous = _lastPosition;
    _lastPosition = position;
    if (previous == null) return;
    final delta = position - previous;
    if (delta <= Duration.zero || delta > const Duration(seconds: 2)) return;

    _accumulated += delta;
    if (_accumulated < threshold) return;
    _countAttempted = true;
    final revision = _revision;
    final item = _item;
    if (revision == null || item == null) return;
    unawaited(_persistPlayCount(revision, item.ref));
  }

  Future<void> _persistPlayCount(int revision, PlatformTrackRef ref) async {
    try {
      if (!await _historyController.incrementPlayCount(ref) &&
          !_disposed &&
          _revision == revision) {
        _onFailure(OnlineHistoryProjectionFailure.playCount);
      }
    } catch (_) {
      if (!_disposed && _revision == revision) {
        _onFailure(OnlineHistoryProjectionFailure.playCount);
      }
    }
  }

  void _reset() {
    _revision = null;
    _item = null;
    _lastPosition = null;
    _accumulated = Duration.zero;
    _startAttempted = false;
    _historyRecorded = false;
    _persistedDuration = Duration.zero;
    _persistedCoverUri = null;
    _metadataUpdateInFlight = false;
    _countAttempted = false;
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _queue.removeListener(_synchronize);
    _timelineController.removeListener(_onTimelineChanged);
    await _controlSubscription.cancel();
    _reset();
  }
}

MusicTrack _trackFromQueueItem(RemotePlaybackQueueItem item) => MusicTrack(
  ref: item.ref,
  title: item.title,
  artists: item.artists,
  album: item.album,
  coverUri: item.coverUri,
  duration: item.duration,
  availability: TrackAvailability.playable,
);

bool _isRenderableHttpsUri(Uri? uri) =>
    uri != null && uri.scheme == 'https' && uri.host.isNotEmpty;

Duration _listenThreshold(Duration duration) {
  if (duration <= Duration.zero) return Duration.zero;
  final ninetyPercent = Duration(
    microseconds: duration.inMicroseconds * 9 ~/ 10,
  );
  const maximum = Duration(seconds: 60);
  return ninetyPercent < maximum ? ninetyPercent : maximum;
}

void _logFailure(OnlineHistoryProjectionFailure failure) {
  logger.w('[online history] ${failure.name} failed');
}
