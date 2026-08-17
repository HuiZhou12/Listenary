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
    return RemotePlaybackQueueItem(
      ref: ref,
      title: title,
      artists: artists,
      album: album,
      coverUri: value,
      duration: duration,
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
    final snapshot = value;
    if (index < 0 || index >= snapshot.items.length) return false;
    final item = snapshot.items[index];
    if (item.ref != expectedRef ||
        _isRenderableHttpsUri(item.coverUri) ||
        !_isRenderableHttpsUri(coverUri)) {
      return false;
    }
    final nextItems = List<RemotePlaybackQueueItem>.of(snapshot.items);
    nextItems[index] = item.withCoverUri(coverUri);
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
