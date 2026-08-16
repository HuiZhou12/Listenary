import 'package:flutter_test/flutter_test.dart';
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
}

final class _FakePublisher implements LocalSmtcPublisher {
  int disposeCalls = 0;

  @override
  Future<void> publish(
    ActivePlaybackSessionSnapshot snapshot, {
    LocalSmtcInput? localInput,
  }) async {}
}
