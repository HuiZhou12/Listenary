import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:pure_music/component/online_track_entry.dart';
import 'package:pure_music/core/database.dart';
import 'package:pure_music/services/music_platform/models/music_models.dart';
import 'package:pure_music/services/music_platform/online_library/online_library_repository.dart';
import 'package:pure_music/services/music_platform/online_library/personal_online_playlist_controller.dart';
import 'package:sqlite3/sqlite3.dart';

/// **曲目行的读屏语义**（2026-10-12，依据 `docs/reference/ytmusic/` 的本地可访问性树 ✓）。
///
/// 参考产品里一条曲目行是**一个带完整标签的按钮**：`播放"<曲名> - <艺人> - <时长>"` ✓。
/// 我们此前只有 `InkWell`（**没有标签、没有 button 角色** ✗）⇒ 读屏用户听到的是一堆散字 ✓。
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

  MusicTrack track({
    String title = '光年之外',
    List<String> artists = const ['G.E.M.邓紫棋'],
    Duration duration = const Duration(minutes: 3, seconds: 55),
    TrackAvailability availability = TrackAvailability.unknown,
  }) => MusicTrack(
    ref: const PlatformTrackRef(platform: MusicPlatform.netease, trackId: '1'),
    title: title,
    artists: artists,
    duration: duration,
    availability: availability,
  );

  Future<void> pumpEntry(WidgetTester tester, MusicTrack item) =>
      tester.pumpWidget(
        ChangeNotifierProvider<PersonalOnlinePlaylistController>.value(
          value: favorites,
          child: MaterialApp(
            home: Scaffold(
              body: OnlineTrackEntry(
                track: item,
                animateEntrance: false,
                onTap: () {},
              ),
            ),
          ),
        ),
      );

  testWidgets('可播放的行 = 一个带完整标签的按钮（标签格式照参考）', (tester) async {
    final handle = tester.ensureSemantics();
    await pumpEntry(tester, track());

    // 从行内的文字往上找最近的语义节点 = 我们给整行加的 Semantics ✓。
    final node = tester.getSemantics(find.text('光年之外'));
    expect(
      node.label,
      contains('播放"光年之外 - G.E.M.邓紫棋 - 3:55"'),
      reason: '参考的格式是 `播放"<曲名> - <艺人> - <时长>"` ✓',
    );
    expect(
      node.flagsCollection.isButton,
      isTrue,
      reason: '行必须是 button 角色，读屏才知道"这一行可以点" ✓',
    );
    handle.dispose();
  });

  testWidgets('不可播放的行**不说"播放"**（不谎报可点）', (tester) async {
    final handle = tester.ensureSemantics();
    await pumpEntry(
      tester,
      track(availability: TrackAvailability.unavailable),
    );

    // 从行内的文字往上找最近的语义节点 = 我们给整行加的 Semantics ✓。
    final node = tester.getSemantics(find.text('光年之外'));
    expect(node.label, contains('"光年之外 - G.E.M.邓紫棋 - 3:55"'));
    expect(
      node.label,
      isNot(contains('播放')),
      reason: '点不动的内容不该被读成"播放…"（那是谎 ✓）',
    );
    handle.dispose();
  });

  testWidgets('没有时长时不硬凑（标签里不出现 0:00）', (tester) async {
    final handle = tester.ensureSemantics();
    await pumpEntry(
      tester,
      track(duration: Duration.zero, artists: const []),
    );

    // 从行内的文字往上找最近的语义节点 = 我们给整行加的 Semantics ✓。
    final node = tester.getSemantics(find.text('光年之外'));
    expect(node.label, contains('"光年之外"'));
    expect(node.label, isNot(contains('0:00')));
    handle.dispose();
  });
}
