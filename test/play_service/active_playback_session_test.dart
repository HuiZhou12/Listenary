import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/play_service/active_playback_session.dart';

void main() {
  test('starts inactive without queue or controls', () {
    final session = ActivePlaybackSession();
    addTearDown(session.dispose);

    expect(session.value.source, ActivePlaybackSessionSource.inactive);
    expect(session.value.isActive, isFalse);
    expect(session.value.queue, isEmpty);
    expect(session.value.currentItem, isNull);
    expect(session.value.capabilities, ActivePlaybackSessionCapabilities.none);
  });

  test('copies queue input and exposes an immutable snapshot', () {
    final session = ActivePlaybackSession();
    addTearDown(session.dispose);
    final input = [_item('Local 1')];

    session.switchTo(
      source: ActivePlaybackSessionSource.local,
      queue: input,
      currentIndex: 0,
      state: ActivePlaybackSessionState.playing,
      controlInFlight: false,
      capabilities: _localCapabilities,
    );
    input.add(_item('Local 2'));

    expect(session.value.queue, [_item('Local 1')]);
    expect(session.value.currentItem, _item('Local 1'));
    expect(
      () => session.value.queue.add(_item('Local 3')),
      throwsUnsupportedError,
    );
  });

  test('media metadata participates in item value identity', () {
    final coverUri = Uri.parse('https://cover.invalid/remote');
    final item = ActivePlaybackSessionItem(
      title: 'Remote',
      artist: 'Artist',
      album: 'Album',
      coverUri: coverUri,
      duration: const Duration(minutes: 3),
    );

    expect(item.coverUri, coverUri);
    expect(item.duration, const Duration(minutes: 3));
    expect(
      item,
      ActivePlaybackSessionItem(
        title: 'Remote',
        artist: 'Artist',
        album: 'Album',
        coverUri: Uri.parse('https://cover.invalid/remote'),
        duration: const Duration(minutes: 3),
      ),
    );
    expect(
      item,
      isNot(
        const ActivePlaybackSessionItem(
          title: 'Remote',
          artist: 'Artist',
          album: 'Album',
        ),
      ),
    );
    expect(item.toString(), isNot(contains('cover.invalid')));
  });

  test('remote switch rejects updates from the previous local lease', () {
    final session = ActivePlaybackSession();
    addTearDown(session.dispose);
    final localLease = session.switchTo(
      source: ActivePlaybackSessionSource.local,
      queue: [_item('Local')],
      currentIndex: 0,
      state: ActivePlaybackSessionState.paused,
      controlInFlight: false,
      capabilities: _localCapabilities,
    );

    final remoteLease = session.switchTo(
      source: ActivePlaybackSessionSource.remote,
      queue: [_item('Remote')],
      currentIndex: null,
      state: ActivePlaybackSessionState.opening,
      controlInFlight: false,
      capabilities: ActivePlaybackSessionCapabilities.none,
    );

    expect(
      session.publish(
        localLease,
        queue: [_item('Local stale')],
        currentIndex: 0,
        state: ActivePlaybackSessionState.playing,
        controlInFlight: false,
        capabilities: _localCapabilities,
      ),
      isFalse,
    );
    expect(session.value.source, ActivePlaybackSessionSource.remote);
    expect(session.value.queue, [_item('Remote')]);
    expect(session.value.currentItem, isNull);
    expect(remoteLease.revision, greaterThan(localLease.revision));
  });

  test('local handoff rejects stale remote events', () {
    final session = ActivePlaybackSession();
    addTearDown(session.dispose);
    final remoteLease = session.switchTo(
      source: ActivePlaybackSessionSource.remote,
      queue: [_item('Remote')],
      currentIndex: 0,
      state: ActivePlaybackSessionState.playing,
      controlInFlight: false,
      capabilities: _remoteCapabilities,
    );

    final localLease = session.switchTo(
      source: ActivePlaybackSessionSource.local,
      queue: [_item('Local')],
      currentIndex: 0,
      state: ActivePlaybackSessionState.paused,
      controlInFlight: false,
      capabilities: _localCapabilities,
    );

    expect(
      session.publish(
        remoteLease,
        queue: [_item('Remote stale')],
        currentIndex: 0,
        state: ActivePlaybackSessionState.completed,
        controlInFlight: false,
        capabilities: ActivePlaybackSessionCapabilities.none,
      ),
      isFalse,
    );
    expect(session.value.source, ActivePlaybackSessionSource.local);
    expect(session.value.currentItem, _item('Local'));
    expect(session.release(remoteLease), isFalse);
    expect(session.release(localLease), isTrue);
    expect(session.value.source, ActivePlaybackSessionSource.inactive);
  });

  test('equal updates do not publish duplicate snapshots', () {
    final session = ActivePlaybackSession();
    addTearDown(session.dispose);
    var notifications = 0;
    session.addListener(() => notifications++);
    final queue = [_item('Remote')];
    final lease = session.switchTo(
      source: ActivePlaybackSessionSource.remote,
      queue: queue,
      currentIndex: 0,
      state: ActivePlaybackSessionState.playing,
      controlInFlight: false,
      capabilities: _remoteCapabilities,
    );

    expect(
      session.publish(
        lease,
        queue: List.of(queue),
        currentIndex: 0,
        state: ActivePlaybackSessionState.playing,
        controlInFlight: false,
        capabilities: _remoteCapabilities,
      ),
      isFalse,
    );
    expect(notifications, 1);

    expect(
      session.publish(
        lease,
        queue: queue,
        currentIndex: 0,
        state: ActivePlaybackSessionState.paused,
        controlInFlight: false,
        capabilities: _remoteCapabilities,
      ),
      isTrue,
    );
    expect(notifications, 2);
  });

  test('invalid current indexes do not replace the current snapshot', () {
    final session = ActivePlaybackSession();
    addTearDown(session.dispose);
    final lease = session.switchTo(
      source: ActivePlaybackSessionSource.remote,
      queue: [_item('Remote')],
      currentIndex: null,
      state: ActivePlaybackSessionState.opening,
      controlInFlight: false,
      capabilities: ActivePlaybackSessionCapabilities.none,
    );
    final before = session.value;

    expect(
      () => session.publish(
        lease,
        queue: [_item('Remote')],
        currentIndex: 1,
        state: ActivePlaybackSessionState.playing,
        controlInFlight: false,
        capabilities: _remoteCapabilities,
      ),
      throwsRangeError,
    );
    expect(session.value, same(before));
  });

  group('来源标记（sourceLabel，Spec §20.2 的既定扩展路径）', () {
    test('默认是 null：本地曲目不填它，因此本地语义不受影响', () {
      expect(_item('Local').sourceLabel, isNull);
    });

    test('★ 相等性把 sourceLabel 算进去（否则只改来源的队列更新会被漏掉）', () {
      const netease = ActivePlaybackSessionItem(
        title: 'Same',
        artist: 'Same artist',
        sourceLabel: '网易云',
      );
      const qq = ActivePlaybackSessionItem(
        title: 'Same',
        artist: 'Same artist',
        sourceLabel: 'QQ音乐',
      );
      const none = ActivePlaybackSessionItem(
        title: 'Same',
        artist: 'Same artist',
      );

      expect(netease, isNot(qq));
      expect(netease, isNot(none));
      expect(netease.hashCode, isNot(qq.hashCode));
      // 同值仍然相等。
      expect(
        netease,
        const ActivePlaybackSessionItem(
          title: 'Same',
          artist: 'Same artist',
          sourceLabel: '网易云',
        ),
      );
    });
  });
}

const _localCapabilities = ActivePlaybackSessionCapabilities(
  canPlay: true,
  canPause: true,
  canPrevious: true,
  canNext: true,
  canSeek: true,
);

const _remoteCapabilities = ActivePlaybackSessionCapabilities(
  canPlay: true,
  canPause: true,
  canPrevious: true,
  canNext: true,
  canSeek: false,
);

ActivePlaybackSessionItem _item(String title) => ActivePlaybackSessionItem(
  title: title,
  artist: '$title Artist',
  album: '$title Album',
);
