import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/native/rust/api/smtc_flutter.dart';
import 'package:pure_music/play_service/active_playback_session.dart';
import 'package:pure_music/play_service/local_smtc_input.dart';
import 'package:pure_music/play_service/local_smtc_publisher.dart';

void main() {
  test('slot accepts an initial publisher and idempotent rebinding', () {
    final first = _FakePublisher();
    final second = _FakePublisher();
    final slot = LocalSmtcPublisherSlot(first);

    expect(slot.publisher, same(first));
    slot.bind(first);
    expect(slot.publisher, same(first));
    slot.bind(second);
    expect(slot.publisher, same(second));
  });

  test('stale clear cannot remove a replacement publisher', () {
    final first = _FakePublisher();
    final second = _FakePublisher();
    final slot = LocalSmtcPublisherSlot(first);

    slot.bind(second);
    slot.clear(first);
    expect(slot.publisher, same(second));
    slot.clear(second);
    expect(slot.publisher, isNull);
    slot.clear(second);
    expect(slot.publisher, isNull);
  });

  test('slot does not own or dispose the publisher', () {
    final publisher = _FakePublisher();
    final slot = LocalSmtcPublisherSlot(publisher);

    slot.clear(publisher);

    expect(publisher.disposeCalls, 0);
  });

  test('active-session adapter publishes only for a local snapshot', () async {
    var snapshot = _snapshot(ActivePlaybackSessionSource.local);
    final calls = <ActivePlaybackSessionSnapshot>[];
    final adapter = ActiveSessionLocalSmtcPublisher(
      readSnapshot: () => snapshot,
      publishActiveSession: (value, {localInput}) async {
        calls.add(value);
        expect(localInput, same(_input));
      },
      publishActiveSessionPosition: (value, positionMs) async {},
    );

    await adapter.publish(_input);
    snapshot = _snapshot(ActivePlaybackSessionSource.remote);
    await adapter.publish(_input);
    snapshot = ActivePlaybackSessionSnapshot.inactive(revision: 3);
    await adapter.publish(_input);

    expect(calls, hasLength(1));
    expect(calls.single.source, ActivePlaybackSessionSource.local);
  });
}

final class _FakePublisher implements LocalSmtcPublisher {
  int disposeCalls = 0;

  @override
  Future<void> publish(LocalSmtcInput input) async {}

  @override
  Future<void> publishPosition(int positionMs) async {}

  @override
  Future<void> clearDisplay() async {}
}

const _input = LocalSmtcInput(
  title: 'Title',
  artist: 'Artist',
  album: 'Album',
  durationMs: 1000,
  path: r'C:\Music\song.mp3',
  state: SMTCState.playing,
  positionMs: 100,
);

ActivePlaybackSessionSnapshot _snapshot(ActivePlaybackSessionSource source) =>
    ActivePlaybackSessionSnapshot.active(
      revision: source == ActivePlaybackSessionSource.local ? 1 : 2,
      source: source,
      queue: const [
        ActivePlaybackSessionItem(title: 'Title', artist: 'Artist'),
      ],
      currentIndex: 0,
      state: ActivePlaybackSessionState.playing,
      controlInFlight: false,
      capabilities: ActivePlaybackSessionCapabilities.none,
    );
