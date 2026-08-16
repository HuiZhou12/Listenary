import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/play_service/active_playback_session.dart';
import 'package:pure_music/play_service/local_smtc_publisher.dart';

void main() {
  test(
    'local position and inactive clear are routed through the publisher',
    () async {
      var snapshot = _snapshot(ActivePlaybackSessionSource.local);
      final positions = <int>[];
      final clears = <ActivePlaybackSessionSnapshot>[];
      final publisher = ActiveSessionLocalSmtcPublisher(
        readSnapshot: () => snapshot,
        publishActiveSession: (value, {localInput}) async {
          if (value.source == ActivePlaybackSessionSource.inactive) {
            clears.add(value);
          }
        },
        publishActiveSessionPosition: (value, positionMs) async {
          positions.add(positionMs);
        },
      );

      await publisher.publishPosition(12000);
      snapshot = ActivePlaybackSessionSnapshot.inactive(revision: 2);
      await publisher.clearDisplay();

      expect(positions, [12000]);
      expect(clears, hasLength(1));
    },
  );

  test('remote session suppresses local position and clear requests', () async {
    var snapshot = _snapshot(ActivePlaybackSessionSource.remote);
    final positions = <int>[];
    var clearCalls = 0;
    final publisher = ActiveSessionLocalSmtcPublisher(
      readSnapshot: () => snapshot,
      publishActiveSession: (value, {localInput}) async {
        clearCalls++;
      },
      publishActiveSessionPosition: (value, positionMs) async {
        positions.add(positionMs);
      },
    );

    await publisher.publishPosition(12000);
    await publisher.clearDisplay();
    snapshot = ActivePlaybackSessionSnapshot.inactive(revision: 2);
    await publisher.clearDisplay();

    expect(positions, isEmpty);
    expect(clearCalls, 1);
  });
}

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
