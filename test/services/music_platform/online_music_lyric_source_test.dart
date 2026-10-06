import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/services/music_platform/models/music_models.dart';
import 'package:pure_music/services/music_platform/online_music_error.dart';
import 'package:pure_music/services/music_platform/online_music_request.dart';
import 'package:pure_music/services/music_platform/provider/composite_online_music_service.dart';
import 'package:pure_music/services/music_platform/provider/online_music_capability.dart';
import 'package:pure_music/services/music_platform/provider/online_music_provider.dart';
import 'package:pure_music/services/music_platform/provider/online_music_provider_registry.dart';

/// S6：歌词必须**按 Track 来源**取（D9），并带回来源身份（不变量 I1）。
///
/// 在线歌词的唯一入口是 `OnlineMusicService.fetchLyrics(ref)`；它不允许被
/// 任何"全局歌词源"接管 —— 那属于本地歌曲的第二套机制（`lyric_sources` /
/// `preferredOnlineSource`），本切片不合并、也不允许它服务在线曲目。
void main() {
  const netease = MusicPlatform.netease;
  const qq = MusicPlatform.qq;

  const neteaseRef = PlatformTrackRef(platform: netease, trackId: '1475869988');
  const qqRef = PlatformTrackRef(platform: qq, trackId: '0039MnYb0qxYhV');

  CompositeOnlineMusicService serviceWith(List<_LyricProvider> providers) =>
      CompositeOnlineMusicService(
        registry: OnlineMusicProviderRegistry(providers: providers),
      );

  Future<MusicLyrics> lyricsOf(
    CompositeOnlineMusicService service,
    PlatformTrackRef ref,
  ) => service.fetchLyrics(ref, cancelToken: OnlineMusicCancelToken());

  test('按 ref.platform 选歌词 Provider，并把来源回填到结果上（I1）', () async {
    final neteaseProvider = _LyricProvider('neteaseLyric', netease);
    final qqProvider = _LyricProvider('qqLyric', qq);
    final service = serviceWith([neteaseProvider, qqProvider]);

    final lyrics = await lyricsOf(service, neteaseRef);

    expect(neteaseProvider.fetchCalls, 1);
    expect(qqProvider.fetchCalls, 0, reason: '不同平台的歌词 Provider 不能串源');
    expect(lyrics.ref, neteaseRef, reason: '歌词必须能回答它属于哪条在线曲目');
    expect(lyrics.original, contains('netease'));
  });

  test('来源不同的同一首歌各走各的 Provider，且结果来源各不相同', () async {
    final neteaseProvider = _LyricProvider('neteaseLyric', netease);
    final qqProvider = _LyricProvider('qqLyric', qq);
    final service = serviceWith([neteaseProvider, qqProvider]);

    final neteaseLyrics = await lyricsOf(service, neteaseRef);
    final qqLyrics = await lyricsOf(service, qqRef);

    expect(neteaseLyrics.ref!.platform, netease);
    expect(qqLyrics.ref!.platform, qq);
    expect(neteaseLyrics.original, isNot(qqLyrics.original));
    expect(neteaseProvider.fetchCalls, 1);
    expect(qqProvider.fetchCalls, 1);
  });

  test('该平台没有歌词候选时明确 unavailable，且不触达任何 Provider', () async {
    final qqProvider = _LyricProvider('qqLyric', qq);
    final service = serviceWith([qqProvider]);

    await expectLater(
      lyricsOf(service, neteaseRef),
      throwsA(
        isA<OnlineMusicException>().having(
          (error) => error.kind,
          'kind',
          OnlineMusicErrorKind.unavailable,
        ),
      ),
    );
    expect(qqProvider.fetchCalls, 0, reason: '不允许"静默换源"到别的平台');
  });

  test('Provider 自己带回来的 ref 优先于请求 ref（不覆盖更精确的来源）', () async {
    final provider = _LyricProvider(
      'neteaseLyric',
      netease,
      returnedRef: const PlatformTrackRef(
        platform: netease,
        trackId: 'returned',
      ),
    );
    final service = serviceWith([provider]);

    final lyrics = await lyricsOf(service, neteaseRef);

    expect(lyrics.ref!.trackId, 'returned');
  });
}

final class _LyricProvider extends UnsupportedOnlineMusicProvider {
  _LyricProvider(this.providerId, this.platform, {this.returnedRef});

  @override
  final String providerId;

  final MusicPlatform platform;
  final PlatformTrackRef? returnedRef;

  int fetchCalls = 0;

  @override
  Set<MusicPlatform> platformsFor(OnlineMusicCapability capability) =>
      capability == OnlineMusicCapability.lyric ? {platform} : const {};

  @override
  Future<MusicLyrics> fetchLyrics(
    PlatformTrackRef ref, {
    required OnlineMusicCancelToken cancelToken,
  }) async {
    fetchCalls++;
    return MusicLyrics(
      original: '[00:00.00]${platform.name}-lyric',
      ref: returnedRef,
    );
  }
}
