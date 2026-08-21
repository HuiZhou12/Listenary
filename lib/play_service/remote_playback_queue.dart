import 'package:flutter/foundation.dart';
import 'package:pure_music/services/music_platform/models/music_models.dart';

/// 在线队列播放模式：顺序、单曲循环、随机。
enum RemotePlaybackMode { sequential, repeatOne, shuffle }

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
    Iterable<RemotePlaybackQueueItem>? originalItems,
    this.mode = RemotePlaybackMode.sequential,
  }) : items = List.unmodifiable(items),
       originalItems = List.unmodifiable(originalItems ?? items);

  const RemotePlaybackQueueSnapshot.empty()
    : items = const [],
      originalItems = const [],
      currentIndex = null,
      mode = RemotePlaybackMode.sequential;

  /// 当前实际播放顺序。
  final List<RemotePlaybackQueueItem> items;

  /// 搜索结果或在线歌单形成的用户顺序，退出随机模式时恢复。
  final List<RemotePlaybackQueueItem> originalItems;

  final int? currentIndex;
  final RemotePlaybackMode mode;

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
    // 新结果替换队列时保留当前模式（会话内）；顺序模式恢复用户顺序。
    final nextMode = value.mode == RemotePlaybackMode.shuffle
        ? RemotePlaybackMode.sequential
        : value.mode;
    value = RemotePlaybackQueueSnapshot(
      items: nextItems,
      originalItems: nextItems,
      currentIndex: currentIndex,
      mode: nextMode,
    );
  }

  void select(int index) {
    RangeError.checkValidIndex(index, value.items, 'index');
    if (value.currentIndex == index) return;
    value = RemotePlaybackQueueSnapshot(
      items: value.items,
      originalItems: value.originalItems,
      currentIndex: index,
      mode: value.mode,
    );
  }

  /// 手动排序：移动 items 并保持当前曲目身份（按 ref 重新定位 currentIndex）。
  /// 随机模式下禁用手动排序，调用方应先退出随机模式。
  void reorder(int oldIndex, int newIndex) {
    final snapshot = value;
    final items = snapshot.items;
    if (oldIndex < 0 || oldIndex >= items.length) return;
    if (newIndex < 0 || newIndex >= items.length) return;
    if (snapshot.mode == RemotePlaybackMode.shuffle) return;

    final currentRef = snapshot.currentItem?.ref;
    final nextItems = List<RemotePlaybackQueueItem>.of(items);
    final item = nextItems.removeAt(oldIndex);
    nextItems.insert(newIndex, item);

    final nextCurrent = currentRef == null
        ? null
        : nextItems.indexWhere((e) => e.ref == currentRef);
    value = RemotePlaybackQueueSnapshot(
      items: nextItems,
      originalItems: nextItems,
      currentIndex: nextCurrent == null || nextCurrent < 0 ? null : nextCurrent,
      mode: snapshot.mode,
    );
  }

  /// 循环切换模式：顺序 → 单曲循环 → 随机 → 顺序。
  void cycleMode() {
    final next = switch (value.mode) {
      RemotePlaybackMode.sequential => RemotePlaybackMode.repeatOne,
      RemotePlaybackMode.repeatOne => RemotePlaybackMode.shuffle,
      RemotePlaybackMode.shuffle => RemotePlaybackMode.sequential,
    };
    setMode(next);
  }

  void setMode(RemotePlaybackMode mode) {
    final snapshot = value;
    if (snapshot.mode == mode) return;
    final currentRef = snapshot.currentItem?.ref;
    final List<RemotePlaybackQueueItem> nextItems;
    switch (mode) {
      case RemotePlaybackMode.sequential:
        nextItems = List.of(snapshot.originalItems);
      case RemotePlaybackMode.repeatOne:
        nextItems = List.of(snapshot.items);
      case RemotePlaybackMode.shuffle:
        // 保留当前曲目，随机化其余项目。
        nextItems = List.of(snapshot.originalItems);
        final currentItem = currentRef == null
            ? null
            : nextItems.firstWhere(
                (e) => e.ref == currentRef,
                orElse: () => nextItems.first,
              );
        nextItems.remove(currentItem);
        nextItems.shuffle();
        if (currentItem != null) nextItems.insert(0, currentItem);
    }
    final nextCurrent = currentRef == null
        ? null
        : nextItems.indexWhere((e) => e.ref == currentRef);
    value = RemotePlaybackQueueSnapshot(
      items: nextItems,
      originalItems: snapshot.originalItems,
      currentIndex: nextCurrent == null || nextCurrent < 0 ? null : nextCurrent,
      mode: mode,
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
    // 同步 originalItems 中同一 ref 的元数据，避免退出随机后丢失已补全的封面/时长。
    final nextOriginal = List<RemotePlaybackQueueItem>.of(snapshot.originalItems);
    final originalIndex = nextOriginal.indexWhere((e) => e.ref == item.ref);
    if (originalIndex >= 0) {
      nextOriginal[originalIndex] = item.withMetadata(
        coverUri: nextCover,
        duration: nextDuration,
      );
    }
    value = RemotePlaybackQueueSnapshot(
      items: nextItems,
      originalItems: nextOriginal,
      currentIndex: snapshot.currentIndex,
      mode: snapshot.mode,
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
