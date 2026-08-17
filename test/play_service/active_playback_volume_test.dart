import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/play_service/active_playback_volume.dart';

void main() {
  test('routes shared volume only to the active local target', () {
    var remoteActive = false;
    var hasLocalSession = true;
    final local = _VolumeTarget();
    final remoteValues = <double>[];
    final persistedRemoteValues = <double>[];
    final router = ActivePlaybackVolumeRouter<_VolumeTarget>(
      initialVolume: 0.5,
      isRemoteActive: () => remoteActive,
      hasLocalSession: () => hasLocalSession,
      localTarget: () => local,
      setLocalVolume: (target, volume) => target.values.add(volume),
      persistRemoteVolume: persistedRemoteValues.add,
    )..bindRemote(remoteValues.add);

    expect(router.setVolume(0.7), isTrue);
    expect(local.values, [0.7]);
    expect(remoteValues, isEmpty);
    expect(persistedRemoteValues, isEmpty);

    remoteActive = true;
    expect(router.setVolume(0.8), isTrue);
    expect(local.values, [0.7]);
    expect(remoteValues, [0.8]);
    expect(persistedRemoteValues, [0.8]);

    remoteActive = false;
    hasLocalSession = false;
    expect(router.setVolume(0.9), isFalse);
    expect(router.value, 0.8);
  });

  test('remote route is unavailable without a bound backend', () {
    final router = ActivePlaybackVolumeRouter<_VolumeTarget>(
      initialVolume: 0.5,
      isRemoteActive: () => true,
      hasLocalSession: () => false,
      localTarget: () => null,
      setLocalVolume: (_, _) {},
      persistRemoteVolume: (_) {},
    );

    expect(router.canSetVolume, isFalse);
    expect(router.setVolume(0.7), isFalse);
    expect(router.value, 0.5);
  });

  test('clamps values before routing and publishing', () {
    final remoteValues = <double>[];
    final router = ActivePlaybackVolumeRouter<_VolumeTarget>(
      initialVolume: 2,
      isRemoteActive: () => true,
      hasLocalSession: () => false,
      localTarget: () => null,
      setLocalVolume: (_, _) {},
      persistRemoteVolume: (_) {},
    )..bindRemote(remoteValues.add);

    expect(router.value, 1);
    expect(router.setVolume(-1), isTrue);
    expect(remoteValues, [0]);
    expect(router.value, 0);
  });
}

final class _VolumeTarget {
  final values = <double>[];
}
