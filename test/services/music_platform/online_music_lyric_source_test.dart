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

  // ⚠️ 这条用例原先是「Provider 自己带回来的 ref **优先**于请求 ref（不覆盖更精确的来源）」，
  // 断言 `lyrics.ref!.trackId == 'returned'` —— 也就是说：**Provider 返回了别首的歌词，
  // 我们照样当成这首歌的歌词**。这正是 P-42 要修的"身份错配无法检出"：
  // 同平台多 Provider 回退时，另一家返回的歌词会被静默贴到当前曲目上。
  // F2-S13 起改为：**带回的 ref 必须与请求的是同一首**，否则直接失败（不采信、不回退掩盖）。
  // （"不覆盖"这一半仍然成立：同一首时原样保留 Provider 的 ref，不会被改写。）
  test('★ P-42 Provider 带回**同一首**的 ref ⇒ 原样保留（不被改写）', () async {
    final provider = _LyricProvider(
      'neteaseLyric',
      netease,
      returnedRef: const PlatformTrackRef(
        platform: netease,
        trackId: '1475869988',
      ),
    );
    final service = serviceWith([provider]);

    final lyrics = await lyricsOf(service, neteaseRef);

    expect(lyrics.ref, neteaseRef, reason: '同一首 ⇒ 采信并保留它带回来的身份');
  });

  test('★ P-42 Provider 带回**别首**的 ref ⇒ 拒绝使用该结果（invalidResponse）', () async {
    final provider = _LyricProvider(
      'neteaseLyric',
      netease,
      returnedRef: const PlatformTrackRef(
        platform: netease,
        trackId: 'someoneElse',
      ),
    );
    final service = serviceWith([provider]);

    await expectLater(
      lyricsOf(service, neteaseRef),
      throwsA(
        isA<OnlineMusicException>().having(
          (error) => error.kind,
          'kind',
          OnlineMusicErrorKind.invalidResponse,
        ),
      ),
      reason: 'P-42：无法证明是同一首 ⇒ 直接失败，而不是把别人的歌词贴上去',
    );
  });
}

final class _LyricProvider extends UnsupportedOnlineMusicProvider {
  @override
  Future<List<MusicTrack>> fetchRecommendedTracks({
    required MusicPlatform platform,
    int limit = 30,
    int offset = 0,
    required OnlineMusicCancelToken cancelToken,
  }) => throw UnsupportedError('Recommended tracks are not implemented here');

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
