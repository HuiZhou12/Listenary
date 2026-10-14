import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hotkey_manager/hotkey_manager.dart';
import 'package:provider/provider.dart';
import 'package:pure_music/component/online_track_row.dart';
import 'package:pure_music/core/database.dart';
import 'package:pure_music/page/online_music_page.dart';
import 'package:pure_music/services/music_platform/index.dart';
import 'package:pure_music/services/music_platform/online_library/online_library_repository.dart';
import 'package:pure_music/services/music_platform/online_library/personal_online_playlist_controller.dart';
import 'package:sqlite3/sqlite3.dart';

/// S8：搜索页的多平台聚合 UI —— 「全部 / 各平台」筛选、来源标签、按平台各自分页、
/// 单平台失败隔离（Spec §8，D6:A / D6b:a / D6c:a）。
///
/// 单平台（注入 `search`）路径的既有行为由 `online_music_page_test.dart` 守着；
/// 本文件只覆盖走 `OnlineMusicService.searchAggregated` 的多平台路径。
void main() {
  const netease = MusicPlatform.netease;
  const qq = MusicPlatform.qq;

  setUpAll(() {
    HotKeyManagerPlatform.instance = _FakeHotKeyManager();
  });

  testWidgets('默认「全部」并行请求所有可搜索平台，每行带来源标签与分组', (tester) async {
    final service = _FakeAggregatedService(
      searchable: const {netease, qq},
      onSearch: (platforms, keyword, limit, offset) async =>
          AggregatedSearchResult(
            perPlatform: {
              netease: _page(netease, [_track(netease, 'n1', 'Netease Song')]),
              qq: _page(qq, [_track(qq, 'q1', 'QQ Song')]),
            },
            failures: const {},
          ),
    );

    await _pumpPage(tester, service);
    expect(find.text('全部'), findsOneWidget);

    await _submit(tester, 'song');

    // 一次并行请求覆盖全部可搜索平台（不按平台发多次）。
    expect(service.calls, hasLength(1));
    expect(service.calls.single.platforms, [netease, qq]);
    expect(service.calls.single.offset, 0);

    expect(find.text('Netease Song'), findsOneWidget);
    expect(find.text('QQ Song'), findsOneWidget);
    // 来源标签：每一行都带自己平台的名字（不是把平台写进标题）。
    expect(
      find.descendant(
        of: find.ancestor(
          of: find.text('Netease Song'),
          matching: find.byType(OnlineTrackRow),
        ),
        matching: find.text('网易云'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.ancestor(
          of: find.text('QQ Song'),
          matching: find.byType(OnlineTrackRow),
        ),
        matching: find.text('QQ音乐'),
      ),
      findsOneWidget,
    );
    // 多平台时有分组表头（便于按平台扫读）。
    expect(
      find.byKey(const ValueKey('online-search-group-netease')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('online-search-group-qq')),
      findsOneWidget,
    );
  });

  testWidgets('单个平台失败只影响该平台分组，其它平台结果照常显示', (tester) async {
    final service = _FakeAggregatedService(
      searchable: const {netease, qq},
      onSearch: (platforms, keyword, limit, offset) async =>
          AggregatedSearchResult(
            perPlatform: {
              netease: _page(netease, [_track(netease, 'n1', 'Netease Song')]),
            },
            failures: {
              qq: const OnlineMusicException(
                kind: OnlineMusicErrorKind.unavailable,
                safeMessage: 'QQ 音乐服务暂时不可用',
              ),
            },
          ),
    );

    await _pumpPage(tester, service);
    await _submit(tester, 'song');

    expect(find.text('Netease Song'), findsOneWidget);
    expect(find.text('QQ 音乐服务暂时不可用'), findsOneWidget);
    expect(find.text('在线搜索失败'), findsNothing);
  });

  testWidgets('全部平台都失败时才是整页失败', (tester) async {
    final service = _FakeAggregatedService(
      searchable: const {netease, qq},
      onSearch: (platforms, keyword, limit, offset) async =>
          AggregatedSearchResult(
            perPlatform: const {},
            failures: const {
              netease: OnlineMusicException(
                kind: OnlineMusicErrorKind.network,
                safeMessage: '网易云服务不可达',
              ),
              qq: OnlineMusicException(
                kind: OnlineMusicErrorKind.network,
                safeMessage: 'QQ 服务不可达',
              ),
            },
          ),
    );

    await _pumpPage(tester, service);
    await _submit(tester, 'song');

    expect(find.text('在线搜索失败'), findsOneWidget);
    expect(find.text('网易云服务不可达'), findsOneWidget);
  });

  testWidgets('分页按平台各自独立：加载更多只请求该平台，并带它自己的 offset', (tester) async {
    final service = _FakeAggregatedService(
      searchable: const {netease, qq},
      onSearch: (platforms, keyword, limit, offset) async {
        final result = <MusicPlatform, MusicSearchPage>{};
        for (final platform in platforms) {
          // QQ 有下一页；网易云一次到底。
          final full = platform == qq;
          if (offset > 0) {
            result[platform] = _page(
              platform,
              [
                _track(
                  platform,
                  '${platform.name}-more',
                  '${platform.name} more',
                ),
              ],
              offset: offset,
              total: 31,
            );
            continue;
          }
          result[platform] = _page(platform, [
            for (var i = 0; i < (full ? 30 : 1); i++)
              _track(platform, '${platform.name}$i', '${platform.name} $i'),
          ], total: full ? 31 : 1);
        }
        return AggregatedSearchResult(perPlatform: result, failures: const {});
      },
    );

    // 视口设得足够高，两个平台的页脚都在构建范围内（不依赖滚动）。
    await _pumpPage(tester, service, size: const Size(1200, 3200));
    await _submit(tester, 'song');

    // 只有 QQ 还有下一页。
    final qqMore = find.byKey(const ValueKey('online-search-load-more-qq'));
    expect(qqMore, findsOneWidget);
    expect(
      find.byKey(const ValueKey('online-search-load-more-netease')),
      findsNothing,
    );

    final callsBefore = service.calls.length;
    await tester.tap(qqMore);
    await tester.pumpAndSettle();

    expect(service.calls, hasLength(callsBefore + 1));
    expect(service.calls.last.platforms, [qq]);
    expect(service.calls.last.offset, 30);
    expect(find.text('qq more'), findsOneWidget);
  });

  testWidgets('单平台模式只请求该平台（W6：不再是"先全搜再过滤"）', (tester) async {
    final service = _FakeAggregatedService(
      searchable: const {netease, qq},
      onSearch: (platforms, keyword, limit, offset) async =>
          AggregatedSearchResult(
            perPlatform: {
              for (final platform in platforms)
                platform: _page(platform, [
                  _track(
                    platform,
                    '${platform.name}1',
                    '${platform.name} Song',
                  ),
                ]),
            },
            failures: const {},
          ),
    );

    await _pumpPage(tester, service);
    await _submit(tester, 'song');
    expect(service.calls, hasLength(1));
    expect(service.calls.single.platforms, [netease, qq]);

    await tester.tap(
      find.descendant(
        of: find.byType(SegmentedButton<MusicPlatform?>),
        matching: find.text('QQ音乐'),
      ),
    );
    await tester.pumpAndSettle();

    // 只请求 QQ：这是"单平台模式"，不是显示过滤。
    expect(service.calls, hasLength(2));
    expect(service.calls.last.platforms, [qq]);
    expect(service.calls.last.offset, 0);
    expect(find.text('qq Song'), findsOneWidget);
    expect(find.text('netease Song'), findsNothing);
    // 只剩一个平台时不摆分组表头（沿用单平台观感）。
    expect(find.byKey(const ValueKey('online-search-group-qq')), findsNothing);

    await tester.tap(
      find.descendant(
        of: find.byType(SegmentedButton<MusicPlatform?>),
        matching: find.text('全部'),
      ),
    );
    await tester.pumpAndSettle();
    // 回到「全部」= 再并行请求所有可搜索平台。
    expect(service.calls, hasLength(3));
    expect(service.calls.last.platforms, [netease, qq]);
    expect(find.text('netease Song'), findsOneWidget);
    expect(find.text('qq Song'), findsOneWidget);
  });

  testWidgets('只有一个可搜索平台时明确写出当前平台', (tester) async {
    final service = _FakeAggregatedService(
      searchable: const {netease},
      onSearch: (platforms, keyword, limit, offset) async =>
          AggregatedSearchResult(
            perPlatform: {
              netease: _page(netease, [_track(netease, 'n1', 'Netease Song')]),
            },
            failures: const {},
          ),
    );

    await _pumpPage(tester, service);
    expect(find.byType(SegmentedButton<MusicPlatform?>), findsNothing);
    // W6：单个平台不摆假选项，但要让人看懂现在搜的是哪一家。
    expect(find.text('当前平台：网易云'), findsOneWidget);

    await _submit(tester, 'song');
    expect(find.text('Netease Song'), findsOneWidget);
    // 单平台下沿用既有的分页 key（既有单平台体验不变）。
    expect(find.byKey(const ValueKey('online-search-load-more')), findsNothing);
    expect(find.text('没有更多了'), findsOneWidget);
  });

  testWidgets('没有任何可搜索平台时给出可操作的提示，且不发请求', (tester) async {
    final service = _FakeAggregatedService(
      searchable: const {},
      onSearch: (platforms, keyword, limit, offset) async =>
          throw StateError('should not be called'),
    );

    await _pumpPage(tester, service);
    await _submit(tester, 'song');

    expect(find.text('没有可搜索的平台'), findsOneWidget);
    expect(find.text('去设置'), findsOneWidget);
    expect(service.calls, isEmpty);
  });
}

Future<void> _pumpPage(
  WidgetTester tester,
  OnlineMusicService service, {
  Size size = const Size(1200, 2000),
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

Future<void> _submit(WidgetTester tester, String query) async {
  await tester.enterText(
    find.byKey(const ValueKey('online-search-field')),
    query,
  );
  await tester.pump();
  await tester.tap(find.byTooltip('在线搜索'));
  await tester.pumpAndSettle();
}

MusicSearchPage _page(
  MusicPlatform platform,
  List<MusicTrack> tracks, {
  int offset = 0,
  int limit = 30,
  int? total,
}) => MusicSearchPage(
  platform: platform,
  items: tracks,
  offset: offset,
  limit: limit,
  total: total ?? tracks.length,
);

MusicTrack _track(MusicPlatform platform, String id, String title) =>
    MusicTrack(
      ref: PlatformTrackRef(platform: platform, trackId: id),
      title: title,
      artists: const ['Test Artist'],
      album: 'Test Album',
      duration: const Duration(seconds: 123),
    );

final class _SearchCall {
  const _SearchCall(this.platforms, this.keyword, this.limit, this.offset);

  final List<MusicPlatform> platforms;
  final String keyword;
  final int limit;
  final int offset;
}

/// 只实现聚合搜索的多平台假服务；其余成员给最小实现（被调用路径不抛
/// `UnimplementedError`，用例失败时才能看到真实断言）。
final class _FakeAggregatedService implements OnlineMusicService {
  @override
  Future<List<RemotePlaylistSummary>> fetchRecommendedPlaylists({
    required MusicPlatform platform,
    int limit = 30,
    int offset = 0,
    required OnlineMusicCancelToken cancelToken,
  }) => throw UnsupportedError('Recommended playlists are not implemented here');

  @override
  Future<List<MusicTrack>> fetchRecommendedTracks({
    required MusicPlatform platform,
    int limit = 30,
    int offset = 0,
    required OnlineMusicCancelToken cancelToken,
  }) => throw UnsupportedError('Recommended tracks are not implemented here');

  @override
  Future<List<OnlineArtistSummary>> searchArtists({
    required MusicPlatform platform,
    required String keyword,
    int limit = 30,
    int offset = 0,
    required OnlineMusicCancelToken cancelToken,
  }) => throw UnsupportedError('Artist search is not implemented here');
  @override
  Future<List<OnlineAlbumSummary>> searchAlbums({
    required MusicPlatform platform,
    required String keyword,
    int limit = 30,
    int offset = 0,
    required OnlineMusicCancelToken cancelToken,
  }) => throw UnsupportedError('Album search is not implemented here');
  @override
  Future<List<OnlineAlbumSummary>> fetchNewAlbums({
    required MusicPlatform platform,
    int limit = 30,
    int offset = 0,
    required OnlineMusicCancelToken cancelToken,
  }) => throw UnsupportedError('New albums are not implemented here');
  @override
  Future<List<MusicTrack>> fetchArtistSongs({
    required MusicPlatform platform,
    required String artistId,
    int limit = 30,
    int offset = 0,
    required OnlineMusicCancelToken cancelToken,
  }) => throw UnsupportedError('Artist songs are not implemented here');
  @override
  Future<List<OnlineAlbumSummary>> fetchArtistAlbums({
    required MusicPlatform platform,
    required String artistId,
    int limit = 30,
    int offset = 0,
    required OnlineMusicCancelToken cancelToken,
  }) => throw UnsupportedError('Artist albums are not implemented here');
  @override
  Future<OnlineAlbum> fetchAlbum({
    required MusicPlatform platform,
    required String albumId,
    required OnlineMusicCancelToken cancelToken,
  }) => throw UnsupportedError('Album detail is not implemented here');
  @override
  Future<OnlineArtist> fetchArtist({
    required MusicPlatform platform,
    required String artistId,
    required OnlineMusicCancelToken cancelToken,
  }) => throw UnsupportedError('Artist detail is not implemented here');
  _FakeAggregatedService({
    required Set<MusicPlatform> searchable,
    required this.onSearch,
    Map<MusicPlatform, String> unavailableSearchReasons = const {},
  }) : capabilities = OnlineMusicCapabilities(
         searchablePlatforms: searchable,
         resolvablePlatforms: searchable,
         unavailableSearchReasons: unavailableSearchReasons,
       );

  @override
  final OnlineMusicCapabilities capabilities;

  final Future<AggregatedSearchResult> Function(
    Iterable<MusicPlatform> platforms,
    String keyword,
    int limit,
    int offset,
  )
  onSearch;

  final List<_SearchCall> calls = [];

  @override
  Future<AggregatedSearchResult> searchAggregated({
    required Iterable<MusicPlatform> platforms,
    required String keyword,
    int limit = 30,
    int offset = 0,
    required OnlineMusicCancelToken cancelToken,
  }) {
    final requested = platforms.toList();
    calls.add(_SearchCall(requested, keyword, limit, offset));
    return onSearch(requested, keyword, limit, offset);
  }

  @override
  Future<MusicSearchPage> search({
    required MusicPlatform platform,
    required String keyword,
    int limit = 30,
    int offset = 0,
    required OnlineMusicCancelToken cancelToken,
  }) async => MusicSearchPage(platform: platform, items: const []);

  @override
  Future<ResolvedStream> resolve(
    PlatformTrackRef ref, {
    required String requestedQuality,
    required OnlineMusicCancelToken cancelToken,
  }) => throw UnsupportedError('resolve');

  @override
  Future<RemotePlaylist> fetchPlaylist({
    required MusicPlatform platform,
    required String playlistId,
    required OnlineMusicCancelToken cancelToken,
  }) => throw UnsupportedError('playlist');

  @override
  Future<List<RemotePlaylistSummary>> fetchPlaylistCollection({
    required MusicPlatform platform,
    int limit = 30,
    int offset = 0,
    String? categoryId,
    required OnlineMusicCancelToken cancelToken,
  }) async => const [];

  @override
  Future<List<RemotePlaylistCategory>> fetchPlaylistCategories({
    required MusicPlatform platform,
    int limit = 30,
    int offset = 0,
    required OnlineMusicCancelToken cancelToken,
  }) => throw UnsupportedError('categories');

  @override
  Future<List<RemotePlaylistSummary>> fetchChartList({
    required MusicPlatform platform,
    int limit = 30,
    int offset = 0,
    required OnlineMusicCancelToken cancelToken,
  }) => throw UnsupportedError('charts');

  @override
  Future<List<MusicTrack>> fetchNewSongs({
    required MusicPlatform platform,
    int limit = 30,
    int offset = 0,
    required OnlineMusicCancelToken cancelToken,
  }) => throw UnsupportedError('new songs');

  @override
  Future<MusicLyrics> fetchLyrics(
    PlatformTrackRef ref, {
    required OnlineMusicCancelToken cancelToken,
  }) => throw UnsupportedError('lyrics');

  @override
  String defaultQualityFor(MusicPlatform platform) => 'lossless';

  @override
  List<PlatformQualityTier> qualityTiersFor(MusicPlatform platform) => const [];

  @override
  PlatformQualitySelection selectQualityFor(
    MusicPlatform platform, {
    required String preference,
  }) => PlatformQualitySelection(
    requestValue: preference,
    displayLabel: preference,
    internalLevel: preference,
  );

  @override
  void dispose() {}
}

final class _FakeHotKeyManager extends HotKeyManagerPlatform {
  @override
  Stream<Map<Object?, Object?>> get onKeyEventReceiver => const Stream.empty();

  @override
  Future<void> register(HotKey hotKey) async {}

  @override
  Future<void> unregister(HotKey hotKey) async {}

  @override
  Future<void> unregisterAll() async {}
}
