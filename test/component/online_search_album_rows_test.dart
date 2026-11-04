import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:pure_music/component/online_search_panel.dart';
import 'package:pure_music/core/database.dart';
import 'package:pure_music/services/music_platform/index.dart';
import 'package:pure_music/services/music_platform/online_library/online_library_repository.dart';
import 'package:pure_music/services/music_platform/online_library/personal_online_playlist_controller.dart';
import 'package:sqlite3/sqlite3.dart' hide Row;

/// **搜索结果里的专辑行**（2026-10-12 新增 ✓）。
///
/// 依据：参考产品的搜索结果是**混合行**（每行用「**类型 • 具体信息**」自报家门 ✓），
/// 而**不是**分区 ✓（这一条是从参考素材里核对出来的订正 ✓）。
/// ⇒ 我们的专辑结果也**混在同一个列表**里，行内元信息以「**专辑 · 年份 · N 首**」开头 ✓
///（年份与曲目数都只写**平台声明**的事实 ✓）。
///
/// 2026-11-03：宿主由 `OnlineMusicPage` 改为 `OnlineSearchPanel`（页面撤销，D2）——
/// 断言逐条保留，它们正是 D1「专辑/艺人混排」的验收证据。
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
          child: MaterialApp(home: Scaffold(body: _AlbumRowHost())),
        ),
      ),
    );
    await tester.pump();

    // 面板是"**显式提交**才搜"✓：宿主在输入框上回车即可（`onSubmitted` ✓）。
    await tester.enterText(
      find.byKey(const ValueKey('online-search-field')),
      '故里逢春',
    );
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
    // 2026-11-04：面板新增分类 tab（「全部 / 单曲 / 专辑 / 艺人」）⇒ 界面上有两处「艺人」。
    // 断言收窄到**艺人行内部**，才能继续证明"这一行自报家门"（而不是数到 tab 就算过）。
    expect(find.text('艺人'), findsNWidgets(2), reason: '分类 tab + 艺人行各一处');
    expect(
      find.descendant(
        of: find
            .ancestor(
              of: find.text('阿YueYue'),
              matching: find.byType(InkWell),
            )
            .first,
        matching: find.text('艺人'),
      ),
      findsOneWidget,
      reason: '艺人行仍以「艺人」自报家门',
    );
    // 来源徽章照旧 ✓（这一行属于哪个平台 ✓）。
    expect(find.text('网易云'), findsWidgets);
  });
}

/// 面板的最小宿主：一个输入框 + `GlobalKey` 直调提交（面板不再自带输入框，D2）。
class _AlbumRowHost extends StatefulWidget {
  @override
  State<_AlbumRowHost> createState() => _AlbumRowHostState();
}

class _AlbumRowHostState extends State<_AlbumRowHost> {
  final _controller = TextEditingController();
  final _panelKey = GlobalKey<OnlineSearchPanelState>();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// 提交（回车）：直接调面板的 `submit`（与弹窗同一条路径）。
  void _submit() {
    final query = _controller.text;
    final panel = _panelKey.currentState;
    if (panel != null) {
      panel.submit(query);
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _panelKey.currentState?.submit(query);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        TextField(
          key: const ValueKey('online-search-field'),
          controller: _controller,
          textInputAction: TextInputAction.search,
          onChanged: (_) => setState(() {}),
          onSubmitted: (_) => _submit(),
        ),
        Expanded(
          child: OnlineSearchPanel(
            key: _panelKey,
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
            query: _controller.text,
          ),
        ),
      ],
    );
  }
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
