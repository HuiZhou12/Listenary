import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/core/database.dart';
import 'package:pure_music/services/music_platform/index.dart';
import 'package:pure_music/services/music_platform/online_library/online_library_repository.dart';
import 'package:pure_music/services/music_platform/online_library/personal_online_playlist_controller.dart';
import 'package:sqlite3/sqlite3.dart';

/// **不变式：远端 id 的形状由 Provider 决定。**
///
/// 为什么单独有这条测试：网易云的 id 恰好是纯数字，于是"数字假设"曾经**散落在两层里**
/// —— `OnlinePlaylistController._fetchAndReplace`（校验请求的 id）与
/// `OnlineLibraryRepository._requiredRemotePlaylistId`（校验返回的 id）。
/// R25 只修了前者，R26 才发现后者：**歌单取回来了却存不进去**。
///
/// 教训是"同一个假设可以藏在多个层里"，所以这里不再逐层去查，而是**把整条链跑一遍**：
/// 搜索（用带字母数字 id 的曲目）→ 收藏 → 进自建歌单 → 订阅平台歌单 → 读回。
/// **任何一层再假设"id 是数字"，这条测试就会红。**
void main() {
  late Database database;
  late OnlineLibraryRepository repository;

  setUp(() {
    database = sqlite3.openInMemory();
    initializeAppDatabase(database);
    repository = OnlineLibraryRepository(database);
  });

  tearDown(() => database.dispose());

  // 刻意用**不像网易云**的 id：字母数字混排、带前导零、带大小写、带下划线。
  const remotePlaylistId = 'pl-0A_bC-99';
  PlatformTrackRef trackRef(String id) =>
      PlatformTrackRef(platform: MusicPlatform.netease, trackId: id);

  MusicTrack track(String id) => MusicTrack(
    ref: trackRef(id),
    title: '曲目 $id',
    artists: const ['甲'],
    album: '专辑一',
  );

  test('★ 字母数字的**曲目 id**：收藏与自建歌单全程原样保留', () async {
    final favorites = PersonalOnlinePlaylistController(
      repository: SynchronousFuture(repository),
    );
    addTearDown(favorites.dispose);

    for (final id in ['tr-0a_1', 'TrAbC', '007']) {
      final item = track(id);
      repository.toggleFavorite(item);
      expect(repository.isFavorite(item.ref), isTrue, reason: 'id=$id');

      final playlistId = repository.createPersonalPlaylist('歌单-$id');
      repository.addTrackToPersonalPlaylist(playlistId, item);
      expect(
        repository
            .readPersonalPlaylist(playlistId)!
            .tracks
            .map((saved) => saved.ref.trackId),
        [id],
        reason: '曲目 id 必须原样读回（它是统一内容身份的一半）',
      );
    }
  });

  test('★ 字母数字的**歌单 id**：订阅后原样读回（取回 ≠ 存下）', () {
    final saved = repository.replaceSubscriptionSnapshot(
      RemotePlaylist(
        platform: MusicPlatform.netease,
        id: remotePlaylistId,
        name: '自建服务的歌单',
        trackCount: 1,
        tracks: [track('tr-0a_1')],
      ),
    );

    final readBack = repository.readSubscriptionSnapshot(saved.localId)!;
    expect(readBack.playlist.id, remotePlaylistId);
    expect(readBack.playlist.tracks.single.ref.trackId, 'tr-0a_1');
  });

  test('★ 空 / 全空白 id 仍然明确失败（放宽的是**形状**，不是"有没有"）', () {
    for (final bad in ['', '   ']) {
      expect(
        () => repository.replaceSubscriptionSnapshot(
          RemotePlaylist(
            platform: MusicPlatform.netease,
            id: bad,
            name: '空 id',
            trackCount: 0,
            tracks: const [],
          ),
        ),
        throwsArgumentError,
        reason: 'id="$bad" 应该失败',
      );
    }
  });
}
