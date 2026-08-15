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
}

RemotePlaybackQueueItem _item(String trackId) {
  return RemotePlaybackQueueItem(
    ref: PlatformTrackRef(platform: MusicPlatform.netease, trackId: trackId),
    title: 'Track $trackId',
    artists: const ['Artist'],
  );
}
