import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:pure_music/component/personal_playlist_picker.dart';
import 'package:pure_music/core/database.dart';
import 'package:pure_music/services/music_platform/models/music_models.dart';
import 'package:pure_music/services/music_platform/online_library/online_library_repository.dart';
import 'package:pure_music/services/music_platform/online_library/personal_online_playlist_controller.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  late Database database;
  late OnlineLibraryRepository repository;
  late PersonalOnlinePlaylistController controller;

  setUp(() {
    database = sqlite3.openInMemory();
    initializeAppDatabase(database);
    repository = OnlineLibraryRepository(database);
    controller = PersonalOnlinePlaylistController(
      repository: SynchronousFuture(repository),
    );
  });

  tearDown(() {
    controller.dispose();
    database.dispose();
  });

  Future<void> pumpPicker(WidgetTester tester) async {
    await tester.pumpWidget(
      ChangeNotifierProvider<PersonalOnlinePlaylistController>.value(
        value: controller,
        child: MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: FilledButton(
                  onPressed: () =>
                      showPersonalPlaylistPicker(context, track: _track('1')),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('lists personal playlists and adds the selected track', (
    tester,
  ) async {
    final id = repository.createPersonalPlaylist('收藏');
    repository.addTrackToPersonalPlaylist(id, _track('0'));

    await pumpPicker(tester);

    expect(find.text('收藏到歌单'), findsOneWidget);
    expect(find.text('收藏'), findsOneWidget);
    expect(find.text('1 首'), findsOneWidget);

    await tester.tap(find.text('收藏'));
    await tester.pumpAndSettle();

    expect(repository.readPersonalPlaylist(id)!.tracks, hasLength(2));
    expect(repository.readPersonalPlaylist(id)!.tracks.last.ref.trackId, '1');
    // 添加成功后弹窗关闭。
    expect(find.text('open'), findsOneWidget);
  });

  testWidgets('creates a playlist and adds the track in one flow', (
    tester,
  ) async {
    await pumpPicker(tester);

    await tester.enterText(find.byType(TextField), '新建歌单');
    await tester.tap(find.text('创建并添加'));
    await tester.pumpAndSettle();

    final playlists = repository.listPersonalPlaylists();
    expect(playlists, hasLength(1));
    expect(playlists.single.name, '新建歌单');
    expect(playlists.single.tracks, hasLength(1));
    expect(playlists.single.tracks.single.ref.trackId, '1');
  });
}

PlatformTrackRef _ref(String id) =>
    PlatformTrackRef(platform: MusicPlatform.netease, trackId: id);

MusicTrack _track(String id) =>
    MusicTrack(ref: _ref(id), title: 'Title $id', artists: const ['Artist']);
