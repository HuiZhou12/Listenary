import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:pure_music/component/remote_media_cover.dart';
import 'package:pure_music/core/database.dart';
import 'package:pure_music/page/online_artist_page.dart';
import 'package:pure_music/services/music_platform/index.dart';
import 'package:pure_music/services/music_platform/online_library/online_library_repository.dart';
import 'package:pure_music/services/music_platform/online_library/personal_online_playlist_controller.dart';
import 'package:sqlite3/sqlite3.dart';

/// **艺人页 hero 的两条硬约束**（2026-10-12，用户逐条指出 ✓）：
/// 1. 简介**超长 + 展开**时**不许溢出** ✗（之前写死高度 ⇒ `BOTTOM OVERFLOWED` ✗）；
/// 2. 渐变颜色必须**跟随主题**（用户报告"不随主题动态改变" ✗ ⇒ 用这条测来判真假 ✓）。
void main() {
  late Database database;
  late PersonalOnlinePlaylistController favorites;

  setUp(() {
    database = sqlite3.openInMemory();
    initializeAppDatabase(database);
    favorites = PersonalOnlinePlaylistController(
      repository: SynchronousFuture(OnlineLibraryRepository(database)),
    );
  });

  tearDown(() {
    favorites.dispose();
    database.dispose();
  });

  /// 最小宿主：**主题可运行时切换** ✓（就为了验第 2 条 ✓）。
  Future<void> pumpWithTheme(
    WidgetTester tester,
    ValueNotifier<ThemeData> theme,
    OnlineMusicService service,
  ) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ChangeNotifierProvider<PersonalOnlinePlaylistController>.value(
        value: favorites,
        child: Provider<OnlineMusicService>.value(
          value: service,
          child: ValueListenableBuilder<ThemeData>(
            valueListenable: theme,
            builder: (context, value, _) => MaterialApp(
              theme: value,
              home: const OnlineArtistPage(
                platform: MusicPlatform.netease,
                artistId: '7763',
              ),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('超长简介：「展开」之后 hero 跟着长，不出现溢出', (tester) async {
    final service = _FakeService(
      artist: OnlineArtist(
        platform: MusicPlatform.netease,
        id: '7763',
        name: '孙燕姿',
        // 真实平台上就有这种一整段的长简介 ✓（用户截图里的那条 ✓）。
        description: '孙燕姿（Stefanie Sun），新加坡人，华语流行女歌手。' * 60,
        hotSongs: [track('1', '我不难过')],
      ),
    );

    await pumpWithTheme(
      tester,
      ValueNotifier<ThemeData>(ThemeData.light()),
      service,
    );
    await tester.pumpAndSettle();

    // 超长 ⇒ 一定有「展开」✓（不超长还给按钮才是骗人 ✓）。
    await tester.tap(find.text('展开'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('收起'));
    await tester.pumpAndSettle();

    // **核心断言**：整个过程中没有 RenderFlex 溢出等异常 ✓。
    expect(tester.takeException(), isNull);
  });

  testWidgets('hero 渐变颜色跟随主题：运行时切到暗色，渐变色必须变', (tester) async {
    final service = _FakeService(
      artist: OnlineArtist(
        platform: MusicPlatform.netease,
        id: '7763',
        name: '孙燕姿',
        description: '新加坡华语女歌手',
        hotSongs: [track('1', '我不难过')],
      ),
    );
    final theme = ValueNotifier<ThemeData>(ThemeData.light());
    addTearDown(theme.dispose);

    await pumpWithTheme(tester, theme, service);
    await tester.pumpAndSettle();

    final lightColor = _heroGradientColor(tester);
    expect(
      lightColor,
      ThemeData.light().scaffoldBackgroundColor,
      reason: '渐变的底色必须就是"页面刷的那层色"（scaffoldBackgroundColor ✓）',
    );
    // 测试里封面不会真的解码出来 ⇒ 画的就是占位 ✓（见 `RemoteMediaCover.build`）。
    // hero 的封面是页面里**第一个** `RemoteMediaCover`（在 hero 之后才轮到热门歌曲行 ✓）。
    final lightPlaceholder = _heroPlaceholderColor(tester, index: 0);
    expect(
      lightPlaceholder,
      ThemeData.light().colorScheme.surfaceContainerHighest,
      reason: 'hero 占位色必须取主题的封面底色 ✓',
    );
    expect(
      lightPlaceholder,
      isNot(const Color(0xFF1B1B1B)),
      reason: '浅色主题下不能再是那块近黑占位 ✗',
    );

    // **运行时切主题**（不重建页面 ✓）⇒ 渐变必须跟着变 ✓。
    theme.value = ThemeData.dark();
    await tester.pumpAndSettle();

    final darkColor = _heroGradientColor(tester);
    expect(
      darkColor,
      ThemeData.dark().scaffoldBackgroundColor,
      reason: '切到暗色后渐变底色也要变成暗色的页面底色 ✓',
    );
    expect(darkColor, isNot(lightColor), reason: '两种主题下不能是同一个颜色 ✗');
    // 占位色同样跟着主题走 ✓（与渐变同一条主题约束 ✓）。
    expect(
      _heroPlaceholderColor(tester, index: 0),
      ThemeData.dark().colorScheme.surfaceContainerHighest,
      reason: '切到暗色后占位色也要跟着变 ✓',
    );
  });
}

/// 取 hero 那条渐变的首色 ✓（hero 的是**四段**的 ✓，与页面其它渐变区分开 ✓）。
Color _heroGradientColor(WidgetTester tester) {
  for (final box in tester.widgetList<DecoratedBox>(
    find.byType(DecoratedBox, skipOffstage: false),
  )) {
    final decoration = box.decoration;
    if (decoration is BoxDecoration && decoration.gradient is LinearGradient) {
      final gradient = decoration.gradient! as LinearGradient;
      if (gradient.colors.length == 4) return gradient.colors.first;
    }
  }
  fail('没找到艺人页 hero 的渐变（四段那条 ✓）');
}

/// 取 hero 封面**占位块**的颜色 ✓。
///
/// ⚠️ 两条坑（都踩过）：
/// 1. hero 外层有一层"页面色兜底"的 `ColoredBox`（`online_artist_page.dart`）⇒ 靠
///    `find.ancestor` 会先拿到页面底色 ✗；
/// 2. 页面里**不止一个** `RemoteMediaCover`（热门歌曲行的小封面也是 ✓）⇒ 必须取 hero 那个。
///
/// 因此直接从 `RemoteMediaCover.placeholder` 这个**组件属性**上读 ✓，不看渲染树 ✓。
Color _heroPlaceholderColor(WidgetTester tester, {required int index}) {
  final covers = tester
      .widgetList<RemoteMediaCover>(
        find.byType(RemoteMediaCover, skipOffstage: false),
      )
      .toList();
  if (covers.length <= index) {
    fail('艺人页里没有第 ${index + 1} 个 RemoteMediaCover（实际 ${covers.length} 个）✓');
  }
  final placeholder = covers[index].placeholder;
  if (placeholder is! ColoredBox) {
    fail('hero 占位不是 ColoredBox，而是 ${placeholder.runtimeType} ✗');
  }
  return placeholder.color;
}

MusicTrack track(String id, String title) => MusicTrack(
  ref: PlatformTrackRef(platform: MusicPlatform.netease, trackId: id),
  title: title,
  artists: const ['孙燕姿'],
  album: '未完成',
);

/// 只实现这一页要用的成员，其余交给 `noSuchMethod`。
final class _FakeService implements OnlineMusicService {
  _FakeService({required this.artist});

  final OnlineArtist artist;

  @override
  OnlineMusicCapabilities get capabilities => OnlineMusicCapabilities(
    searchablePlatforms: const [],
    resolvablePlatforms: const [MusicPlatform.netease],
    artistPlatforms: const [MusicPlatform.netease],
  );

  @override
  Future<OnlineArtist> fetchArtist({
    required MusicPlatform platform,
    required String artistId,
    required OnlineMusicCancelToken cancelToken,
  }) async => artist;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('这个测试用不到：${invocation.memberName}');
}
