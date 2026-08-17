import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/play_service/remote_playback_timeline.dart';

void main() {
  test('unknown snapshot keeps position and duration explicit', () {
    const snapshot = RemotePlaybackTimelineSnapshot.unknown();

    expect(snapshot.position, isNull);
    expect(snapshot.duration, isNull);
    expect(snapshot.hasKnownPosition, isFalse);
    expect(snapshot.hasKnownDuration, isFalse);
    expect(snapshot.progress, isNull);
  });

  test('normalizes invalid position and duration to unknown', () {
    final snapshot = RemotePlaybackTimelineSnapshot.normalized(
      position: const Duration(milliseconds: -1),
      duration: Duration.zero,
    );

    expect(snapshot.position, isNull);
    expect(snapshot.duration, isNull);
  });

  test('keeps a known zero position with unknown duration', () {
    final snapshot = RemotePlaybackTimelineSnapshot.normalized(
      position: Duration.zero,
      duration: null,
    );

    expect(snapshot.position, Duration.zero);
    expect(snapshot.duration, isNull);
    expect(snapshot.hasKnownPosition, isTrue);
    expect(snapshot.progress, isNull);
  });

  test('clamps position to a known duration', () {
    final snapshot = RemotePlaybackTimelineSnapshot.normalized(
      position: const Duration(seconds: 80),
      duration: const Duration(seconds: 60),
    );

    expect(snapshot.position, const Duration(seconds: 60));
    expect(snapshot.duration, const Duration(seconds: 60));
    expect(snapshot.progress, 1.0);
  });

  test('supports value equality for stable projections', () {
    final first = RemotePlaybackTimelineSnapshot.normalized(
      position: const Duration(seconds: 15),
      duration: const Duration(seconds: 60),
    );
    final second = RemotePlaybackTimelineSnapshot.normalized(
      position: const Duration(seconds: 15),
      duration: const Duration(seconds: 60),
    );

    expect(first, second);
    expect(first.hashCode, second.hashCode);
    expect(first.progress, 0.25);
  });
}
