import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/native/rust/api/smtc_flutter.dart';
import 'package:pure_music/play_service/local_smtc_input.dart';
import 'package:pure_music/play_service/local_smtc_publisher.dart';

void main() {
  test('publisher slot forwards complete local metadata and state', () async {
    final publisher = _RecordingPublisher();
    final slot = LocalSmtcPublisherSlot(publisher);
    const input = LocalSmtcInput(
      title: 'Title',
      artist: 'Artist',
      album: 'Album',
      durationMs: 180000,
      path: r'C:\Music\title.flac',
      state: SMTCState.paused,
      positionMs: 4200,
    );

    await slot.publish(input);

    expect(publisher.inputs, [input]);
  });

  test('empty publisher slot safely consumes local state events', () async {
    final slot = LocalSmtcPublisherSlot();

    await slot.publish(
      const LocalSmtcInput(
        title: 'Title',
        artist: 'Artist',
        album: 'Album',
        durationMs: 1000,
        path: r'C:\Music\title.mp3',
        state: SMTCState.playing,
        positionMs: 0,
      ),
    );
  });
}

final class _RecordingPublisher implements LocalSmtcPublisher {
  final inputs = <LocalSmtcInput>[];

  @override
  Future<void> publish(LocalSmtcInput input) async {
    inputs.add(input);
  }

  @override
  Future<void> publishPosition(int positionMs) async {}

  @override
  Future<void> clearDisplay() async {}
}
