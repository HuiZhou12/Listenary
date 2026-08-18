import 'package:flutter/foundation.dart';
import 'package:pure_music/services/music_platform/models/music_models.dart';

@immutable
final class RemotePlaybackQueueItem {
  RemotePlaybackQueueItem({
    required this.ref,
    required this.title,
    required Iterable<String> artists,
    this.album = '',
    this.coverUri,
    this.duration = Duration.zero,
  }) : artists = List.unmodifiable(artists);

  factory RemotePlaybackQueueItem.fromTrack(MusicTrack track) {
    return RemotePlaybackQueueItem(
      ref: track.ref,
      title: track.title,
      artists: track.artists,
      album: track.album,
      coverUri: track.coverUri,
      duration: track.duration,
    );
  }

  final PlatformTrackRef ref;
  final String title;
  final List<String> artists;
  final String album;
  final Uri? coverUri;
  final Duration duration;

  String get artistDisplay => artists.join('、');

  RemotePlaybackQueueItem withCoverUri(Uri value) {
    return withMetadata(coverUri: value);
  }

  RemotePlaybackQueueItem withMetadata({Uri? coverUri, Duration? duration}) {
    return RemotePlaybackQueueItem(
      ref: ref,
      title: title,
      artists: artists,
      album: album,
      coverUri: coverUri ?? this.coverUri,
      duration: duration ?? this.duration,
    );
  }
}

@immutable
final class RemotePlaybackQueueSnapshot {
  RemotePlaybackQueueSnapshot({
    required Iterable<RemotePlaybackQueueItem> items,
    required this.currentIndex,
  }) : items = List.unmodifiable(items);

  const RemotePlaybackQueueSnapshot.empty()
    : items = const [],
      currentIndex = null;

  final List<RemotePlaybackQueueItem> items;
  final int? currentIndex;

  RemotePlaybackQueueItem? get currentItem {
    final index = currentIndex;
    return index == null ? null : items[index];
  }

  bool get isEmpty => items.isEmpty;
}

final class RemotePlaybackQueue
    extends ValueNotifier<RemotePlaybackQueueSnapshot> {
  RemotePlaybackQueue() : super(const RemotePlaybackQueueSnapshot.empty());

  void replace(Iterable<RemotePlaybackQueueItem> items, {int? currentIndex}) {
    final nextItems = List<RemotePlaybackQueueItem>.unmodifiable(items);
    if (nextItems.isEmpty) {
      throw ArgumentError.value(items, 'items', 'must not be empty');
    }
    if (currentIndex != null) {
      RangeError.checkValidIndex(currentIndex, nextItems, 'currentIndex');
    }
    value = RemotePlaybackQueueSnapshot(
      items: nextItems,
      currentIndex: currentIndex,
    );
  }

  void select(int index) {
    RangeError.checkValidIndex(index, value.items, 'index');
    if (value.currentIndex == index) return;
    value = RemotePlaybackQueueSnapshot(
      items: value.items,
      currentIndex: index,
    );
  }

  bool enrichCover(
    int index, {
    required PlatformTrackRef expectedRef,
    required Uri coverUri,
  }) {
    return enrichMetadata(index, expectedRef: expectedRef, coverUri: coverUri);
  }

  bool enrichDuration(
    int index, {
    required PlatformTrackRef expectedRef,
    required Duration duration,
  }) {
    return enrichMetadata(index, expectedRef: expectedRef, duration: duration);
  }

  bool enrichMetadata(
    int index, {
    required PlatformTrackRef expectedRef,
    Uri? coverUri,
    Duration? duration,
  }) {
    final snapshot = value;
    if (index < 0 || index >= snapshot.items.length) return false;
    final item = snapshot.items[index];
    if (item.ref != expectedRef) return false;
    final nextCover =
        !_isRenderableHttpsUri(item.coverUri) && _isRenderableHttpsUri(coverUri)
        ? coverUri
        : null;
    final nextDuration =
        item.duration <= Duration.zero &&
            duration != null &&
            duration > Duration.zero
        ? duration
        : null;
    if (nextCover == null && nextDuration == null) return false;
    final nextItems = List<RemotePlaybackQueueItem>.of(snapshot.items);
    nextItems[index] = item.withMetadata(
      coverUri: nextCover,
      duration: nextDuration,
    );
    value = RemotePlaybackQueueSnapshot(
      items: nextItems,
      currentIndex: snapshot.currentIndex,
    );
    return true;
  }

  void clear() {
    if (value.isEmpty) return;
    value = const RemotePlaybackQueueSnapshot.empty();
  }

  @override
  void dispose() {
    clear();
    super.dispose();
  }
}

bool _isRenderableHttpsUri(Uri? uri) =>
    uri != null && uri.scheme == 'https' && uri.host.isNotEmpty;
