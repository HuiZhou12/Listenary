import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:pure_music/core/paths.dart' as app_paths;
import 'package:pure_music/page/explore_page.dart';
import 'package:pure_music/page/platform_playlists_page.dart';
import 'package:pure_music/services/music_platform/index.dart';

/// **分类 tag 点击 → 进子页面**（2026-10-12 用户报告"一点击就爆红崩溃" ✗，
/// 并明确要求"用户点击就进入子页面" ✓）。
///
/// 用最小假件把「歌单分类」渲染出来并**真的点一下 tag** ⇒ 断言它会跳到
/// [PlatformPlaylistsPage]（并且带着这个分类 ✓）。
void main() {
  testWidgets('点一个分类 tag：进子页面（分类页），不抛异常', (tester) async {
    tester.view.physicalSize = const Size(1200, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final router = GoRouter(
      initialLocation: app_paths.EXPLORE_PAGE,
      routes: [
        GoRoute(
          path: app_paths.EXPLORE_PAGE,
          builder: (context, state) => const ExplorePage(),
          routes: [
            GoRoute(
              path: 'playlists',
              pageBuilder: (context, state) {
                final extra =
                    state.extra
                        as ({
                          MusicPlatform platform,
                          String? categoryId,
                          String title,
                        })?;
                return NoTransitionPage(
                  child: PlatformPlaylistsPage(
                    platform: extra!.platform,
                    categoryId: extra.categoryId,
                    title: extra.title,
                  ),
                );
              },
            ),
          ],
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      Provider<OnlineMusicService?>.value(
        value: _CategoryService(),
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('华语'), findsOneWidget);
    await tester.tap(find.text('华语'));
    await tester.pumpAndSettle();

    // 进了子页面：标题带平台与分类名 ✓，且列出该分类下的歌单 ✓。
    expect(find.text('网易云 · 华语'), findsOneWidget);
    expect(find.text('歌单 lang_1'), findsOneWidget);
  });
}

/// 极简假件：只实现"分类 + 分类下的歌单"需要的成员，其余交给 `noSuchMethod`。
final class _CategoryService implements OnlineMusicService {
  @override
  OnlineMusicCapabilities get capabilities => OnlineMusicCapabilities(
    searchablePlatforms: const [],
    resolvablePlatforms: const [],
    playlistCollectionPlatforms: const [MusicPlatform.netease],
    playlistCategoryPlatforms: const [MusicPlatform.netease],
  );

  @override
  Future<List<RemotePlaylistCategory>> fetchPlaylistCategories({
    required MusicPlatform platform,
    int limit = 30,
    int offset = 0,
    required OnlineMusicCancelToken cancelToken,
  }) async => const [
    RemotePlaylistCategory(
      platform: MusicPlatform.netease,
      id: 'lang_1',
      name: '华语',
    ),
    RemotePlaylistCategory(
      platform: MusicPlatform.netease,
      id: 'lang_2',
      name: '欧美',
    ),
  ];

  @override
  Future<List<RemotePlaylistSummary>> fetchPlaylistCollection({
    required MusicPlatform platform,
    int limit = 30,
    int offset = 0,
    String? categoryId,
    required OnlineMusicCancelToken cancelToken,
  }) async => [
    RemotePlaylistSummary(
      id: 'pl-${categoryId ?? 'all'}-$offset',
      name: '歌单 ${categoryId ?? 'all'}',
      platform: MusicPlatform.netease,
    ),
  ];

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('这个测试用不到：${invocation.memberName}');
}
