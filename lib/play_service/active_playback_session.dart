import 'package:flutter/foundation.dart';

enum ActivePlaybackSessionSource { inactive, local, remote }

enum ActivePlaybackSessionState {
  stopped,
  opening,
  playing,
  paused,
  stalled,
  completed,
  failed,
}

@immutable
final class ActivePlaybackSessionItem {
  const ActivePlaybackSessionItem({
    required this.title,
    required this.artist,
    this.album = '',
    this.coverUri,
    this.duration = Duration.zero,
  });

  final String title;
  final String artist;
  final String album;
  final Uri? coverUri;
  final Duration duration;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ActivePlaybackSessionItem &&
          title == other.title &&
          artist == other.artist &&
          album == other.album &&
          coverUri == other.coverUri &&
          duration == other.duration;

  @override
  int get hashCode => Object.hash(title, artist, album, coverUri, duration);
}

@immutable
final class ActivePlaybackSessionCapabilities {
  const ActivePlaybackSessionCapabilities({
    required this.canPlay,
    required this.canPause,
    required this.canPrevious,
    required this.canNext,
    required this.canSeek,
  });

  static const none = ActivePlaybackSessionCapabilities(
    canPlay: false,
    canPause: false,
    canPrevious: false,
    canNext: false,
    canSeek: false,
  );

  final bool canPlay;
  final bool canPause;
  final bool canPrevious;
  final bool canNext;
  final bool canSeek;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ActivePlaybackSessionCapabilities &&
          canPlay == other.canPlay &&
          canPause == other.canPause &&
          canPrevious == other.canPrevious &&
          canNext == other.canNext &&
          canSeek == other.canSeek;

  @override
  int get hashCode => Object.hash(
    canPlay,
    canPause,
    canPrevious,
    canNext,
    canSeek,
  );
}

@immutable
final class ActivePlaybackSessionSnapshot {
  ActivePlaybackSessionSnapshot._({
    required this.revision,
    required this.source,
    required Iterable<ActivePlaybackSessionItem> queue,
    required this.currentIndex,
    required this.state,
    required this.controlInFlight,
    required this.capabilities,
  }) : queue = List.unmodifiable(queue) {
    if (source == ActivePlaybackSessionSource.inactive) {
      if (this.queue.isNotEmpty || currentIndex != null) {
        throw ArgumentError('An inactive session cannot expose a queue');
      }
      return;
    }
    if (currentIndex != null) {
      RangeError.checkValidIndex(currentIndex!, this.queue, 'currentIndex');
    }
  }

  factory ActivePlaybackSessionSnapshot.inactive({required int revision}) =>
      ActivePlaybackSessionSnapshot._(
        revision: revision,
        source: ActivePlaybackSessionSource.inactive,
        queue: const [],
        currentIndex: null,
        state: ActivePlaybackSessionState.stopped,
        controlInFlight: false,
        capabilities: ActivePlaybackSessionCapabilities.none,
      );

  factory ActivePlaybackSessionSnapshot.active({
    required int revision,
    required ActivePlaybackSessionSource source,
    required Iterable<ActivePlaybackSessionItem> queue,
    required int? currentIndex,
    required ActivePlaybackSessionState state,
    required bool controlInFlight,
    required ActivePlaybackSessionCapabilities capabilities,
  }) {
    if (source == ActivePlaybackSessionSource.inactive) {
      throw ArgumentError.value(source, 'source', 'must be local or remote');
    }
    return ActivePlaybackSessionSnapshot._(
      revision: revision,
      source: source,
      queue: queue,
      currentIndex: currentIndex,
      state: state,
      controlInFlight: controlInFlight,
      capabilities: capabilities,
    );
  }

  final int revision;
  final ActivePlaybackSessionSource source;
  final List<ActivePlaybackSessionItem> queue;
  final int? currentIndex;
  final ActivePlaybackSessionState state;
  final bool controlInFlight;
  final ActivePlaybackSessionCapabilities capabilities;

  bool get isActive => source != ActivePlaybackSessionSource.inactive;

  ActivePlaybackSessionItem? get currentItem {
    final index = currentIndex;
    return index == null ? null : queue[index];
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ActivePlaybackSessionSnapshot &&
          revision == other.revision &&
          source == other.source &&
          listEquals(queue, other.queue) &&
          currentIndex == other.currentIndex &&
          state == other.state &&
          controlInFlight == other.controlInFlight &&
          capabilities == other.capabilities;

  @override
  int get hashCode => Object.hash(
    revision,
    source,
    Object.hashAll(queue),
    currentIndex,
    state,
    controlInFlight,
    capabilities,
  );
}

@immutable
final class ActivePlaybackSessionLease {
  const ActivePlaybackSessionLease._({
    required this.revision,
    required this.source,
  });

  final int revision;
  final ActivePlaybackSessionSource source;
}

final class ActivePlaybackSession
    extends ValueNotifier<ActivePlaybackSessionSnapshot> {
  ActivePlaybackSession()
    : super(ActivePlaybackSessionSnapshot.inactive(revision: 0));

  int _revision = 0;
  ActivePlaybackSessionLease? _currentLease;
  bool _disposed = false;

  ActivePlaybackSessionLease switchTo({
    required ActivePlaybackSessionSource source,
    required Iterable<ActivePlaybackSessionItem> queue,
    required int? currentIndex,
    required ActivePlaybackSessionState state,
    required bool controlInFlight,
    required ActivePlaybackSessionCapabilities capabilities,
  }) {
    _throwIfDisposed();
    if (source == ActivePlaybackSessionSource.inactive) {
      throw ArgumentError.value(source, 'source', 'must be local or remote');
    }
    final lease = ActivePlaybackSessionLease._(
      revision: ++_revision,
      source: source,
    );
    final snapshot = _snapshotFor(
      lease,
      queue: queue,
      currentIndex: currentIndex,
      state: state,
      controlInFlight: controlInFlight,
      capabilities: capabilities,
    );
    _currentLease = lease;
    value = snapshot;
    return lease;
  }

  bool publish(
    ActivePlaybackSessionLease lease, {
    required Iterable<ActivePlaybackSessionItem> queue,
    required int? currentIndex,
    required ActivePlaybackSessionState state,
    required bool controlInFlight,
    required ActivePlaybackSessionCapabilities capabilities,
  }) {
    if (_disposed || !identical(_currentLease, lease)) return false;
    final snapshot = _snapshotFor(
      lease,
      queue: queue,
      currentIndex: currentIndex,
      state: state,
      controlInFlight: controlInFlight,
      capabilities: capabilities,
    );
    if (value == snapshot) return false;
    value = snapshot;
    return true;
  }

  bool release(ActivePlaybackSessionLease lease) {
    if (_disposed || !identical(_currentLease, lease)) return false;
    _currentLease = null;
    value = ActivePlaybackSessionSnapshot.inactive(revision: ++_revision);
    return true;
  }

  ActivePlaybackSessionSnapshot _snapshotFor(
    ActivePlaybackSessionLease lease, {
    required Iterable<ActivePlaybackSessionItem> queue,
    required int? currentIndex,
    required ActivePlaybackSessionState state,
    required bool controlInFlight,
    required ActivePlaybackSessionCapabilities capabilities,
  }) => ActivePlaybackSessionSnapshot.active(
    revision: lease.revision,
    source: lease.source,
    queue: queue,
    currentIndex: currentIndex,
    state: state,
    controlInFlight: controlInFlight,
    capabilities: capabilities,
  );

  void _throwIfDisposed() {
    if (_disposed) {
      throw StateError('ActivePlaybackSession has been disposed');
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _currentLease = null;
    _revision++;
    super.dispose();
  }
}
