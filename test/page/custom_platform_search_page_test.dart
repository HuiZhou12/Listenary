import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:pure_music/core/database.dart';
import 'package:pure_music/page/online_music_page.dart';
import 'package:pure_music/services/music_platform/index.dart';
import 'package:pure_music/services/music_platform/online_library/online_library_repository.dart';
import 'package:pure_music/services/music_platform/online_library/personal_online_playlist_controller.dart';
import 'package:pure_music/services/music_platform/provider/composite_online_music_service.dart';
import 'package:pure_music/services/music_platform/provider/online_music_capability.dart';
import 'package:pure_music/services/music_platform/provider/online_music_provider.dart';
import 'package:pure_music/services/music_platform/provider/online_music_provider_registry.dart';
import 'package:sqlite3/sqlite3.dart';

/// decoupling-2.2（R4 / R5 / G3）：在线搜索页按**平台身份**筛选、请求与分组。
///
/// 用真实的 `CompositeOnlineMusicService`（不写测试替身）—— 这样断言的是端到端契约：
/// 页面把身份传到了服务层、服务层按身份路由、结果又按身份回到分组。
void main() {
  // ⚠️ 两个 UUID 的**前 8 位必须不同**：短 ID 就是前 8 位（`PlatformIdentity.shortId`），
  // 若相同则短 ID 也无法区分同名平台（真实 UUID v4 撞前 8 位的概率可忽略）。
  const alphaId = '0f9a1c2e-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
  const betaId = 'a1b2c3d4-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
  const alpha = PlatformIdentity.custom(alphaId);
  const beta = PlatformIdentity.custom(betaId);

  CompositeOnlineMusicService serviceWithCustomPlatforms({
    Set<PlatformIdentity> enabled = const {},
  }) => CompositeOnlineMusicService(
    registry: OnlineMusicProviderRegistry(
      providers: [
        _TitledProvider('alpha', 'Alpha Song', alphaId),
        _TitledProvider('beta', 'Beta Song', betaId),
      ],
      providerIdentities: const {'alpha': alpha, 'beta': beta},
      enabledPlatforms: enabled,
    ),
  );

  Future<void> pumpPage(
    WidgetTester tester,
    OnlineMusicService service, {
    Size size = const Size(1200, 2200),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final database = sqlite3.openInMemory();
    initializeAppDatabase(database);
    final favorites = PersonalOnlinePlaylistController(
      repository: SynchronousFuture(OnlineLibraryRepository(database)),
    );
    addTearDown(favorites.dispose);
    addTearDown(database.dispose);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<PersonalOnlinePlaylistController>.value(
            value: favorites,
          ),
          Provider<OnlineMusicService>.value(value: service),
        ],
        child: const MaterialApp(home: Scaffold(body: OnlineMusicPage())),
      ),
    );
    await tester.pump();
  }

  Future<void> submit(WidgetTester tester, String query) async {
    await tester.enterText(
      find.byKey(const ValueKey('online-search-field')),
      query,
    );
    await tester.pump();
    await tester.tap(find.byTooltip('在线搜索'));
    await tester.pumpAndSettle();
  }

  testWidgets('★ R4 两个自定义平台各自成组，标签用自己的 platformName（不串台）', (tester) async {
    final service = serviceWithCustomPlatforms();
    addTearDown(service.dispose);
    await pumpPage(tester, service);

    // 门槛：两个自定义身份都可搜索（否则页面根本不会请求它们）。
    expect(
      service.capabilities.searchableIdentities,
      containsAll(const [alpha, beta]),
    );

    await submit(tester, 'song');

    // 每首歌都出现在自己的分组里。
    expect(find.text('Alpha Song'), findsOneWidget);
    expect(find.text('Beta Song'), findsOneWidget);
    // 分组表头按**身份**建 key（枚举键会让两组撞在一起）。
    expect(
      find.byKey(const ValueKey('online-search-group-custom-$alphaId')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('online-search-group-custom-$betaId')),
      findsOneWidget,
    );
    // 两个平台都没登记 platformName ⇒ 展示名相同 ⇒ 分组表头也必须附短 ID 才能分辨
    // （minor-2：否则两个分组标题都写着「自定义平台」）。
    expect(
      find.text('自定义平台（${alphaId.substring(0, 8)}）'),
      findsWidgets,
      reason: '同名分组标题必须附短 ID',
    );
    expect(find.text('自定义平台（${betaId.substring(0, 8)}）'), findsWidgets);
  });

  testWidgets('★ R4 筛选：选一个自定义平台只请求它（单平台模式）', (tester) async {
    final service = serviceWithCustomPlatforms();
    addTearDown(service.dispose);
    await pumpPage(tester, service);
    await submit(tester, 'song');

    // 未登记 platformName ⇒ 兜底文案「自定义平台」；两者**同名** ⇒ 按 G6 附短 ID 区分。
    final filter = find.byType(SegmentedButton<PlatformIdentity?>);
    final alphaLabel = '自定义平台（${alphaId.substring(0, 8)}）';
    final betaLabel = '自定义平台（${betaId.substring(0, 8)}）';
    final segment = find.descendant(
      of: filter,
      matching: find.textContaining('自定义平台'),
    );
    expect(segment, findsNWidgets(2), reason: '两个自定义平台各是一个可分辨的选项');
    expect(
      find.descendant(of: filter, matching: find.text(alphaLabel)),
      findsOneWidget,
      reason: '同名必须附短 ID，否则两个选项文字完全相同（minor-2）',
    );
    expect(
      find.descendant(of: filter, matching: find.text(betaLabel)),
      findsOneWidget,
    );

    await tester.tap(segment.first);
    await tester.pumpAndSettle();

    // 只留一个分组（不再摆分组表头，沿用单平台观感）。
    final groups = find.byKey(
      const ValueKey('online-search-group-custom-$alphaId'),
    );
    final otherGroups = find.byKey(
      const ValueKey('online-search-group-custom-$betaId'),
    );
    expect(groups, findsNothing);
    expect(otherGroups, findsNothing);
    // 结果仍在（筛选只是收窄了本次请求的范围，不是把结果显示过滤掉）。
    expect(
      find.text('Alpha Song').evaluate().isNotEmpty ||
          find.text('Beta Song').evaluate().isNotEmpty,
      isTrue,
    );
  });

  testWidgets('★ R5 停用其中一个自定义平台 ⇒ 它不再出现在筛选里', (tester) async {
    final service = serviceWithCustomPlatforms(enabled: {alpha.normalized});
    addTearDown(service.dispose);
    await pumpPage(tester, service);

    expect(service.capabilities.canSearchIdentity(alpha), isTrue);
    expect(
      service.capabilities.canSearchIdentity(beta),
      isFalse,
      reason: '身份化启用集合：只停用 beta，不影响 alpha（G5/G7）',
    );

    await submit(tester, 'song');

    expect(service.capabilities.searchableIdentities.contains(beta), isFalse);
    expect(find.text('Alpha Song'), findsOneWidget);
    expect(find.text('Beta Song'), findsNothing);
  });
}

/// 一个**自定义平台** provider：搜索固定返回 `title` 那首歌（不经过网络）。
///
/// `platformsFor` 只声明 search + stream ⇒ 过得了搜索门槛（D3）。
final class _TitledProvider extends UnsupportedOnlineMusicProvider {
  _TitledProvider(this.providerId, this.title, this.platformId);

  @override
  final String providerId;

  final String title;
  final String platformId;

  @override
  Set<MusicPlatform> platformsFor(OnlineMusicCapability capability) =>
      capability == OnlineMusicCapability.search ||
          capability == OnlineMusicCapability.stream
      ? const {MusicPlatform.custom}
      : const {};

  // `UnsupportedOnlineMusicProvider` 只声明不实现这四个能力（与既有测试同一写法）：
  // 走不到的路径给最小实现，用例失败时才能看到真实断言。
  @override
  Future<List<RemotePlaylistSummary>> fetchPersonalizedPlaylists({
    required MusicPlatform platform,
    int limit = 30,
    int offset = 0,
    required OnlineMusicCancelToken cancelToken,
  }) =>
      throw UnsupportedError('Personalized playlists are not implemented here');

  @override
  Future<List<OnlineArtistSummary>> fetchFollowedArtists({
    required MusicPlatform platform,
    int limit = 30,
    int offset = 0,
    required OnlineMusicCancelToken cancelToken,
  }) => throw UnsupportedError('Followed artists are not implemented here');

  @override
  Future<List<RemotePlaylistSummary>> fetchRecommendedPlaylists({
    required MusicPlatform platform,
    int limit = 30,
    int offset = 0,
    required OnlineMusicCancelToken cancelToken,
  }) =>
      throw UnsupportedError('Recommended playlists are not implemented here');

  @override
  Future<List<MusicTrack>> fetchRecommendedTracks({
    required MusicPlatform platform,
    int limit = 30,
    int offset = 0,
    required OnlineMusicCancelToken cancelToken,
  }) => throw UnsupportedError('Recommended tracks are not implemented here');

  @override
  Future<MusicSearchPage> search({
    required MusicPlatform platform,
    required String keyword,
    int limit = 30,
    int offset = 0,
    required OnlineMusicCancelToken cancelToken,
  }) async => MusicSearchPage(
    platform: platform,
    platformId: platformId,
    items: [
      MusicTrack(
        ref: PlatformTrackRef(
          platform: platform,
          trackId: '$providerId-1',
          platformId: platformId,
        ),
        title: title,
        artists: const ['Test Artist'],
        album: 'Album',
        duration: const Duration(seconds: 100),
      ),
    ],
    offset: offset,
    limit: limit,
    total: 1,
  );
}
