import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/play_service/remote_playback_queue.dart';
import 'package:pure_music/services/music_platform/models/music_models.dart';

void main() {
  test('builds safe queue items from music tracks', () {
    final item = RemotePlaybackQueueItem.fromTrack(
      MusicTrack(
        ref: const PlatformTrackRef(
          platform: MusicPlatform.netease,
          trackId: 'track-1',
        ),
        title: 'Title',
        artists: const ['Artist A', 'Artist B'],
        album: 'Album',
        duration: const Duration(minutes: 3),
        coverUri: Uri.parse('https://cover.invalid/image'),
      ),
    );

    expect(item.ref.trackId, 'track-1');
    expect(item.artistDisplay, 'Artist A、Artist B');
    expect(item.album, 'Album');
    expect(item.coverUri, Uri.parse('https://cover.invalid/image'));
    expect(item.duration, const Duration(minutes: 3));
    expect(item.toString(), isNot(contains('cover.invalid')));
  });

  test('replaces the queue with an immutable snapshot', () {
    final queue = RemotePlaybackQueue();
    final input = [_item('1'), _item('2')];

    queue.replace(input, currentIndex: 1);
    input.clear();

    expect(queue.value.items.map((item) => item.ref.trackId), ['1', '2']);
    expect(queue.value.currentItem?.ref.trackId, '2');
    expect(() => queue.value.items.add(_item('3')), throwsUnsupportedError);
    queue.dispose();
  });

  test('select validates the index and publishes a new snapshot', () {
    final queue = RemotePlaybackQueue();
    queue.replace([_item('1'), _item('2')], currentIndex: 0);
    final previous = queue.value;

    queue.select(1);

    expect(queue.value, isNot(same(previous)));
    expect(queue.value.currentItem?.ref.trackId, '2');
    expect(() => queue.select(2), throwsRangeError);
    queue.dispose();
  });

  test('enriches only a matching item without a usable HTTPS cover', () {
    final queue = RemotePlaybackQueue();
    final ref = _item('1').ref;
    queue.replace([
      RemotePlaybackQueueItem(
        ref: ref,
        title: 'Track 1',
        artists: const ['Artist'],
        coverUri: Uri.parse('http://cover.invalid/search'),
      ),
      _item('2'),
    ], currentIndex: 0);

    expect(
      queue.enrichCover(
        0,
        expectedRef: ref,
        coverUri: Uri.parse('https://cover.invalid/resolved'),
      ),
      isTrue,
    );
    expect(
      queue.value.currentItem?.coverUri,
      Uri.parse('https://cover.invalid/resolved'),
    );
    expect(queue.value.currentIndex, 0);
    queue.dispose();
  });

  test('rejects unsafe, stale, and unnecessary cover enrichment', () {
    final queue = RemotePlaybackQueue();
    final ref = _item('1').ref;
    final existing = Uri.parse('https://cover.invalid/search');
    queue.replace([
      RemotePlaybackQueueItem(
        ref: ref,
        title: 'Track 1',
        artists: const ['Artist'],
        coverUri: existing,
      ),
    ], currentIndex: 0);

    expect(
      queue.enrichCover(
        0,
        expectedRef: ref,
        coverUri: Uri.parse('https://cover.invalid/resolved'),
      ),
      isFalse,
    );
    expect(
      queue.enrichCover(
        0,
        expectedRef: _item('2').ref,
        coverUri: Uri.parse('https://cover.invalid/resolved'),
      ),
      isFalse,
    );
    expect(
      queue.enrichCover(
        1,
        expectedRef: ref,
        coverUri: Uri.parse('https://cover.invalid/resolved'),
      ),
      isFalse,
    );
    expect(
      queue.enrichCover(
        0,
        expectedRef: ref,
        coverUri: Uri.parse('http://cover.invalid/resolved'),
      ),
      isFalse,
    );
    expect(queue.value.currentItem?.coverUri, existing);
    queue.dispose();
  });

  test('enriches only a matching item with missing duration', () {
    final queue = RemotePlaybackQueue();
    final ref = _item('1').ref;
    queue.replace([_item('1')], currentIndex: 0);

    expect(
      queue.enrichDuration(
        0,
        expectedRef: ref,
        duration: const Duration(minutes: 3),
      ),
      isTrue,
    );
    expect(queue.value.currentItem?.duration, const Duration(minutes: 3));
    expect(
      queue.enrichDuration(
        0,
        expectedRef: ref,
        duration: const Duration(minutes: 4),
      ),
      isFalse,
    );
    expect(
      queue.enrichDuration(
        0,
        expectedRef: _item('2').ref,
        duration: const Duration(minutes: 4),
      ),
      isFalse,
    );
    expect(queue.value.currentItem?.duration, const Duration(minutes: 3));
    queue.dispose();
  });

  test('replace rejects empty queues and invalid indexes', () {
    final queue = RemotePlaybackQueue();

    expect(() => queue.replace(const [], currentIndex: 0), throwsArgumentError);
    expect(
      () => queue.replace([_item('1')], currentIndex: 1),
      throwsRangeError,
    );
    expect(queue.value.isEmpty, isTrue);
    queue.dispose();
  });

  test('replace can publish a queue before playback selects an item', () {
    final queue = RemotePlaybackQueue();

    queue.replace([_item('1'), _item('2')]);

    expect(queue.value.items, hasLength(2));
    expect(queue.value.currentIndex, isNull);
    expect(queue.value.currentItem, isNull);
    queue.dispose();
  });

  test('clear and dispose release all queue items', () {
    final queue = RemotePlaybackQueue();
    queue.replace([_item('1')], currentIndex: 0);

    queue.clear();

    expect(queue.value.items, isEmpty);
    expect(queue.value.currentIndex, isNull);
    queue.replace([_item('2')], currentIndex: 0);
    queue.dispose();
    expect(queue.value.items, isEmpty);
  });

  test('reorder moves items and keeps the current track identity', () {
    final queue = RemotePlaybackQueue();
    queue.replace([_item('1'), _item('2'), _item('3')], currentIndex: 1);

    // 把当前曲目 '2' 从 index 1 移到末尾。
    queue.reorder(1, 2);

    expect(queue.value.items.map((e) => e.ref.trackId), ['1', '3', '2']);
    expect(queue.value.currentIndex, 2);
    expect(queue.value.currentItem!.ref.trackId, '2');
    expect(queue.value.originalItems.map((e) => e.ref.trackId), ['1', '3', '2']);
  });

  test('reorder is disabled in shuffle mode', () {
    final queue = RemotePlaybackQueue();
    queue.replace([_item('1'), _item('2'), _item('3')], currentIndex: 0);
    queue.setMode(RemotePlaybackMode.shuffle);

    final before = queue.value.items;
    queue.reorder(0, 1);
    expect(queue.value.items, before);
  });

  test('cycle mode rotates sequential -> repeatOne -> shuffle -> sequential', () {
    final queue = RemotePlaybackQueue();
    queue.replace([_item('1'), _item('2'), _item('3')], currentIndex: 0);

    expect(queue.value.mode, RemotePlaybackMode.sequential);
    queue.cycleMode();
    expect(queue.value.mode, RemotePlaybackMode.repeatOne);
    queue.cycleMode();
    expect(queue.value.mode, RemotePlaybackMode.shuffle);
    queue.cycleMode();
    expect(queue.value.mode, RemotePlaybackMode.sequential);
  });

  test('shuffle keeps the current track and restores original order on exit', () {
    final queue = RemotePlaybackQueue();
    queue.replace([_item('1'), _item('2'), _item('3')], currentIndex: 1);

    queue.setMode(RemotePlaybackMode.shuffle);
    // 当前曲目 '2' 保留在首位，其余随机化但数量不变。
    expect(queue.value.items, hasLength(3));
    expect(queue.value.items.first.ref.trackId, '2');
    expect(queue.value.currentItem!.ref.trackId, '2');
    expect(queue.value.originalItems.map((e) => e.ref.trackId), ['1', '2', '3']);

    queue.setMode(RemotePlaybackMode.sequential);
    expect(queue.value.items.map((e) => e.ref.trackId), ['1', '2', '3']);
    expect(queue.value.currentIndex, 1);
    expect(queue.value.currentItem!.ref.trackId, '2');
  });

  test('replace keeps the current mode within a session', () {
    final queue = RemotePlaybackQueue();
    queue.replace([_item('1'), _item('2')], currentIndex: 0);
    queue.setMode(RemotePlaybackMode.repeatOne);

    queue.replace([_item('3'), _item('4')], currentIndex: 0);
    expect(queue.value.mode, RemotePlaybackMode.repeatOne);
    expect(queue.value.originalItems.map((e) => e.ref.trackId), ['3', '4']);
  });

  test('replace resets shuffle to sequential for the new queue', () {
    final queue = RemotePlaybackQueue();
    queue.replace([_item('1'), _item('2')], currentIndex: 0);
    queue.setMode(RemotePlaybackMode.shuffle);

    queue.replace([_item('3'), _item('4')], currentIndex: 0);
    expect(queue.value.mode, RemotePlaybackMode.sequential);
  });
}

RemotePlaybackQueueItem _item(String trackId) {
  return RemotePlaybackQueueItem(
    ref: PlatformTrackRef(platform: MusicPlatform.netease, trackId: trackId),
    title: 'Track $trackId',
    artists: const ['Artist'],
  );
}
