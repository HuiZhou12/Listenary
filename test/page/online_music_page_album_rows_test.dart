import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:pure_music/core/database.dart';
import 'package:pure_music/page/online_music_page.dart';
import 'package:pure_music/services/music_platform/index.dart';
import 'package:pure_music/services/music_platform/online_library/online_library_repository.dart';
import 'package:pure_music/services/music_platform/online_library/personal_online_playlist_controller.dart';
import 'package:sqlite3/sqlite3.dart';

/// **搜索结果里的专辑行**（2026-10-12 新增 ✓）。
///
/// 依据：参考产品的搜索结果是**混合行**（每行用「**类型 • 具体信息**」自报家门 ✓），
/// 而**不是**分区 ✓（这一条是从参考素材里核对出来的订正 ✓）。
/// ⇒ 我们的专辑结果也**混在同一个列表**里，行内元信息以「**专辑 · 年份 · N 首**」开头 ✓
///（年份与曲目数都只写**平台声明**的事实 ✓）。
///
/// （单独一个文件：既有的 `online_music_page_test.dart` 很大，**不动它** ✓ —— 这一课是 R92 学到的 ✓。）
void main() {
  testWidgets('搜索结果里混排专辑行，并以「专辑 · 年份 · N 首」自报家门', (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
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
      ChangeNotifierProvider<PersonalOnlinePlaylistController>.value(
        value: favorites,
        child: Provider<OnlineMusicService?>.value(
          value: _AlbumSearchService(),
          child: MaterialApp(
            home: Scaffold(
              body: OnlineMusicPage(
                // 曲目链路用注入的搜索（只走单平台）✓；专辑链路走注入的服务 ✓。
                search:
                    ({
                      required keyword,
                      required limit,
                      required offset,
                      required cancelToken,
                    }) async => MusicSearchPage(
                      platform: MusicPlatform.netease,
                      items: [
                        MusicTrack(
                          ref: const PlatformTrackRef(
                            platform: MusicPlatform.netease,
                            trackId: 't1',
                          ),
                          title: '曲目一',
                          artists: const ['甲'],
                        ),
                      ],
                      offset: offset,
                      limit: limit,
                      total: 1,
                    ),
                onTrackSelected: (page, selected) async {},
                onHistoryRequested: () {},
              ),
            ),
          ),
        ),
      ),
    );

    await tester.enterText(
      find.byKey(const ValueKey('online-search-field')),
      '故里逢春',
    );
    // 本页是"**显式提交**才搜"✓：在输入框上回车即可（`onSubmitted` ✓）。
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();

    // 曲目行照常 ✓，专辑行**混在同一列表里** ✓。
    final visible = tester
        .widgetList<Text>(find.byType(Text))
        .map((w) => w.data)
        .whereType<String>()
        .toList(growable: false);
    expect(
      find.text('曲目一'),
      findsOneWidget,
      reason: '界面上的文字：$visible',
    );
    expect(find.text('故里逢春'), findsWidgets);
    expect(find.textContaining('专辑 · 2020 年 · 2 首'), findsOneWidget);
    // **艺人行**同样混排 ✓，以「艺人」自报家门 ✓（参考的第三种类型 ✓）。
    expect(find.text('阿YueYue'), findsOneWidget);
    expect(find.text('艺人'), findsOneWidget);
    // 来源徽章照旧 ✓（这一行属于哪个平台 ✓）。
    expect(find.text('网易云'), findsWidgets);
  });
}

/// 极简假件：只实现"搜专辑"需要的成员，其余交给 `noSuchMethod`（Dart 允许 ✓）。
final class _AlbumSearchService implements OnlineMusicService {
  @override
  Future<List<OnlineArtistSummary>> searchArtists({
    required MusicPlatform platform,
    required String keyword,
    int limit = 30,
    int offset = 0,
    required OnlineMusicCancelToken cancelToken,
  }) async => [
    OnlineArtistSummary(
      platform: MusicPlatform.netease,
      id: 'ar1',
      name: '阿YueYue',
    ),
  ];
  @override
  OnlineMusicCapabilities get capabilities => OnlineMusicCapabilities(
    searchablePlatforms: const [MusicPlatform.netease],
    resolvablePlatforms: const [],
    // 专辑要**打得开**才会显示专辑行 ✓（搜得出来点不开比不显示更糟 ✗）。
    albumPlatforms: const [MusicPlatform.netease],
    searchableAlbumPlatforms: const [MusicPlatform.netease],
    // 艺人同理：**打得开艺人页**才显示艺人行 ✓。
    artistPlatforms: const [MusicPlatform.netease],
    searchableArtistPlatforms: const [MusicPlatform.netease],
  );

  @override
  Future<List<OnlineAlbumSummary>> searchAlbums({
    required MusicPlatform platform,
    required String keyword,
    int limit = 30,
    int offset = 0,
    required OnlineMusicCancelToken cancelToken,
  }) async => [
    OnlineAlbumSummary(
      platform: MusicPlatform.netease,
      id: 'a1',
      name: '故里逢春',
      trackCount: 2,
      releaseTime: DateTime.utc(2020, 7, 29),
    ),
  ];

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('这个测试用不到：${invocation.memberName}');
}
