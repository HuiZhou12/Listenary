import 'package:flutter/foundation.dart';
import 'package:pure_music/services/music_platform/models/music_models.dart';

@immutable
final class RemotePlaybackQueueItem {
  RemotePlaybackQueueItem({
    required this.ref,
    required this.title,
    required Iterable<String> artists,
    this.album = '',
    this.duration = Duration.zero,
  }) : artists = List.unmodifiable(artists);

  factory RemotePlaybackQueueItem.fromTrack(MusicTrack track) {
    return RemotePlaybackQueueItem(
      ref: track.ref,
      title: track.title,
      artists: track.artists,
      album: track.album,
      duration: track.duration,
    );
  }

  final PlatformTrackRef ref;
  final String title;
  final List<String> artists;
  final String album;
  final Duration duration;

  String get artistDisplay => artists.join('、');
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
