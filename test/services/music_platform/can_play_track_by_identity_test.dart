import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/services/music_platform/chksz/index.dart';

/// F5-P-39（P-63）：曲目"能否播放"的**统一判据** `canPlayTrack`（身份判据 + 既有可用性语义）。
void main() {
  const alphaId = '0f9a1c2e-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
  const otherId = '0f9a1c2e-cccc-4ccc-8ccc-cccccccccccc';

  OnlineMusicCapabilities caps({Set<PlatformIdentity> identities = const {}}) =>
      OnlineMusicCapabilities(
        searchablePlatforms: const {MusicPlatform.netease},
        resolvablePlatforms: const {MusicPlatform.netease},
        resolvableIdentities: identities,
      );

  MusicTrack track(
    PlatformIdentity identity, {
    TrackAvailability availability = TrackAvailability.playable,
  }) => MusicTrack(
    ref: PlatformTrackRef.of(identity, 't1'),
    title: 'x',
    artists: const ['a'],
    album: 'b',
    coverUri: Uri.https('example.test', '/c.jpg'),
    duration: const Duration(minutes: 3),
    availability: availability,
  );

  test('★ P63-5 内置平台：沿用既有可用性语义（可播/下架/付费）', () {
    final c = caps();
    expect(
      c.canPlayTrack(track(const PlatformIdentity.builtin(MusicPlatform.netease))),
      isTrue,
    );
    expect(
      c.canPlayTrack(
        track(
          const PlatformIdentity.builtin(MusicPlatform.netease),
          availability: TrackAvailability.unavailable,
        ),
      ),
      isFalse,
    );
    expect(
      c.canPlayTrack(
        track(
          const PlatformIdentity.builtin(MusicPlatform.netease),
          availability: TrackAvailability.paid,
        ),
      ),
      isFalse,
      reason: '付费曲目在"我的库"里不算可直接播放（既有语义）',
    );
  });

  test('★ P63-6 自定义平台：身份可解析才可播；不同 ID/未知值一律 false（不串台）', () {
    final c = caps(identities: {const PlatformIdentity.custom(alphaId)});
    expect(c.canPlayTrack(track(const PlatformIdentity.custom(alphaId))), isTrue);
    expect(
      c.canPlayTrack(track(const PlatformIdentity.custom(otherId))),
      isFalse,
      reason: '另一个自定义平台（或未知历史值）不得被当成可播',
    );
    expect(
      c.canPlayTrack(track(const PlatformIdentity.custom(''))),
      isFalse,
      reason: '身份无效 ⇒ fail-closed（只呈现状态，不删数据、不改身份）',
    );
  });

  test('★ P63-7 未登记任何身份的自定义曲目 ⇒ false（旧配置/缺失配置场景）', () {
    final c = caps();
    expect(c.canPlayTrack(track(const PlatformIdentity.custom(alphaId))), isFalse);
  });
}