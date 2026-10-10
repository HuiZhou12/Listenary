import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/core/database.dart';
import 'package:pure_music/services/music_platform/models/music_models.dart';
import 'package:pure_music/services/music_platform/online_library/online_library_repository.dart';
import 'package:sqlite3/sqlite3.dart';

/// F5（P-48）：**跨平台镜像 ID 空间**的仓储层回归。
///
/// 在线表的主键是复合身份 `(platform, track_id)` ⇒ **不同平台上的同一个 `track_id`
/// 必须是两条互不相干的记录**。本文件只用**真实仓储方法 + 真实数据库**证明这件事，
/// 不借助页面层的内存对象。
///
/// ⚠️ 身份语义不允许为了让测试通过而改动：断言依据就是系统实际的复合主键。
void main() {
  late Database database;
  late OnlineLibraryRepository repository;

  setUp(() {
    database = sqlite3.openInMemory();
    initializeAppDatabase(database);
    repository = OnlineLibraryRepository(database);
  });

  tearDown(() {
    database.dispose();
  });

  test('★ F5-P-48 ① 同 track_id 双平台：元数据各自保存、各自读取', () {
    repository.upsertTrack(
      _track(_netease, 'same', title: 'netease 版', album: 'N 专辑'),
      lastQuality: 'lossless',
      updatedAt: DateTime.utc(2026, 1, 1),
    );
    repository.upsertTrack(
      _track(_qq, 'same', title: 'qq 版', album: 'Q 专辑'),
      lastQuality: 'hq',
      updatedAt: DateTime.utc(2026, 1, 2),
    );

    final neteaseTrack = repository.findTrack(_ref(_netease, 'same'))!;
    final qqTrack = repository.findTrack(_ref(_qq, 'same'))!;

    expect(neteaseTrack.title, 'netease 版');
    expect(neteaseTrack.album, 'N 专辑');
    expect(qqTrack.title, 'qq 版');
    expect(qqTrack.album, 'Q 专辑');
    expect(
      database
          .select('SELECT COUNT(*) AS c FROM online_tracks')
          .single['c'],
      2,
      reason: '复合主键 ⇒ 两条记录，不是一条被覆盖',
    );
    expect(
      database
          .select('SELECT DISTINCT last_quality FROM online_tracks ORDER BY 1')
          .map((row) => row['last_quality']),
      ['hq', 'lossless'],
      reason: 'last_quality 也必须各自独立',
    );
  });

  test('★ F5-P-48 ② 同一个人的歌单里放两个平台的同 ID 曲目：互不覆盖', () {
    final playlistId = repository.createPersonalPlaylist('我的歌单');

    expect(repository.addTrackToPersonalPlaylist(playlistId, _track(_netease, 'same')), isTrue);
    expect(repository.addTrackToPersonalPlaylist(playlistId, _track(_qq, 'same')), isTrue);

    final snapshot = repository.readPersonalPlaylist(playlistId)!;
    expect(
      snapshot.tracks.map((track) => track.ref),
      [_ref(_netease, 'same'), _ref(_qq, 'same')],
      reason: '两个平台各一条，按加入顺序排列',
    );
    expect(
      database
          .select('SELECT COUNT(*) AS c FROM online_playlist_items')
          .single['c'],
      2,
    );
  });

  test('★ F5-P-48 ③ 删除某平台的一条：不会删掉另一平台同 ID 的记录', () {
    final playlistId = repository.createPersonalPlaylist('我的歌单');
    repository.addTrackToPersonalPlaylist(playlistId, _track(_netease, 'same'));
    repository.addTrackToPersonalPlaylist(playlistId, _track(_qq, 'same'));

    expect(
      repository.removeTrackFromPersonalPlaylist(playlistId, _ref(_netease, 'same')),
      isTrue,
    );

    expect(repository.findTrack(_ref(_netease, 'same')), isNull, reason: '已无引用的那条被回收');
    expect(
      repository.findTrack(_ref(_qq, 'same')),
      isNotNull,
      reason: '另一平台同 ID 的记录必须还在（旧的引用保护不得跨平台误删）',
    );
    expect(repository.readPersonalPlaylist(playlistId)!.tracks, hasLength(1));
  });

  test('★ F5-P-48 ④ 刷新一个平台的订阅：不覆盖、不误删另一平台的同 ID 数据', () {
    final neteaseSnapshot = repository.replaceSubscriptionSnapshot(
      _remote(platform: _netease, id: '500', tracks: [_track(_netease, 'same')]),
      refreshedAt: DateTime.utc(2026, 1, 1),
    );
    final qqSnapshot = repository.replaceSubscriptionSnapshot(
      _remote(platform: _qq, id: '500', tracks: [_track(_qq, 'same')]),
      refreshedAt: DateTime.utc(2026, 1, 1),
    );
    expect(neteaseSnapshot.localId, isNot(qqSnapshot.localId), reason: '同 remoteId 不同平台 ⇒ 两条订阅');

    // 只刷新 netease 那条（清单一模一样）。
    repository.replaceSubscriptionSnapshot(
      _remote(platform: _netease, id: '500', tracks: [_track(_netease, 'same')]),
      refreshedAt: DateTime.utc(2026, 1, 5),
    );

    expect(repository.findTrack(_ref(_qq, 'same')), isNotNull, reason: 'qq 的曲目元数据不受影响');
    final qqItems = database.select(
      'SELECT added_at FROM online_playlist_items WHERE playlist_id = ?',
      [qqSnapshot.localId],
    );
    expect(qqItems, hasLength(1), reason: 'qq 的条目不被误删/误去重');
    expect(
      qqItems.single['added_at'],
      DateTime.utc(2026, 1, 1).toIso8601String(),
      reason: 'qq 的加入时间不被 netease 的刷新改动',
    );
    expect(repository.listSubscriptions(), hasLength(2));
  });

  test('★ F5-P-48 ⑤ 去重与重排只作用于正确的复合身份', () {
    final playlistId = repository.createPersonalPlaylist('我的歌单');
    repository.addTrackToPersonalPlaylist(playlistId, _track(_netease, 't1'));
    repository.addTrackToPersonalPlaylist(playlistId, _track(_qq, 't1'));
    repository.addTrackToPersonalPlaylist(playlistId, _track(_netease, 't2'));

    // 重复添加同一复合身份 ⇒ 幂等（不产生第二条）。
    repository.addTrackToPersonalPlaylist(playlistId, _track(_netease, 't1'));
    expect(
      database.select('SELECT COUNT(*) AS c FROM online_playlist_items').single['c'],
      3,
      reason: '(netease,t1)/(qq,t1)/(netease,t2) 三条；重加 (netease,t1) 不得新增',
    );

    // 重排：只动顺序，不跨平台串。
    expect(
      repository.reorderPersonalPlaylist(playlistId, [
        _ref(_qq, 't1'),
        _ref(_netease, 't2'),
        _ref(_netease, 't1'),
      ]),
      isTrue,
    );
    expect(repository.readPersonalPlaylist(playlistId)!.tracks.map((t) => t.ref), [
      _ref(_qq, 't1'),
      _ref(_netease, 't2'),
      _ref(_netease, 't1'),
    ]);
    // 顺序变化不得改变身份集合。
    expect(
      database
          .select('SELECT platform, track_id FROM online_playlist_items ORDER BY platform, track_id')
          .map((row) => '${row['platform']}/${row['track_id']}'),
      ['netease/t1', 'netease/t2', 'qq/t1'],
    );
  });

  test('★ F5-P-48 ⑥ 播放历史与加入时间按平台各自独立', () {
    final neteaseSnapshot = repository.replaceSubscriptionSnapshot(
      _remote(platform: _netease, id: '600', tracks: [_track(_netease, 'same')]),
      refreshedAt: DateTime.utc(2026, 2, 1),
    );
    final qqSnapshot = repository.replaceSubscriptionSnapshot(
      _remote(platform: _qq, id: '600', tracks: [_track(_qq, 'same')]),
      refreshedAt: DateTime.utc(2026, 3, 1),
    );

    expect(
      database
          .select('SELECT platform, added_at FROM online_playlist_items ORDER BY platform')
          .map((row) => '${row['platform']}=${row['added_at']}'),
      [
        'netease=${DateTime.utc(2026, 2, 1).toIso8601String()}',
        'qq=${DateTime.utc(2026, 3, 1).toIso8601String()}',
      ],
      reason: '同 track_id 的两个平台各有自己的加入时间',
    );
    expect(neteaseSnapshot.localId, isNot(qqSnapshot.localId));

    // 播放次数：先入历史才计数（仓储的既有规则）。
    repository.recordPlaybackStarted(
      _track(_netease, 'same'),
      playedAt: DateTime.utc(2026, 3, 2),
    );
    repository.recordPlaybackStarted(
      _track(_qq, 'same'),
      playedAt: DateTime.utc(2026, 3, 3),
    );
    repository.incrementPlayCount(_ref(_netease, 'same'));
    repository.incrementPlayCount(_ref(_netease, 'same'));

    final counts = {
      for (final row in database.select(
        'SELECT platform, play_count FROM online_play_history ORDER BY platform',
      ))
        row['platform'] as String: row['play_count'] as int,
    };
    // 语义回顾：`recordPlaybackStarted` 只**记行**（计数从 0 起），`incrementPlayCount` 才 +1。
    // 关键断言是"两个平台各自的计数互不影响"。
    expect(counts, {'netease': 2, 'qq': 0}, reason: '历史计数按复合身份各自独立');
  });
}

const _netease = MusicPlatform.netease;
const _qq = MusicPlatform.qq;

PlatformTrackRef _ref(MusicPlatform platform, String id) =>
    PlatformTrackRef(platform: platform, trackId: id);

MusicTrack _track(
  MusicPlatform platform,
  String id, {
  String title = 'Track',
  String album = 'Album',
}) => MusicTrack(
  ref: _ref(platform, id),
  title: title,
  artists: const ['Artist'],
  album: album,
  coverUri: Uri.https('example.test', '/cover.jpg'),
  duration: const Duration(minutes: 3),
  availability: TrackAvailability.playable,
);

RemotePlaylist _remote({
  required MusicPlatform platform,
  required String id,
  required List<MusicTrack> tracks,
}) => RemotePlaylist(
  platform: platform,
  id: id,
  name: 'Remote $id',
  creator: 'Remote Creator',
  trackCount: tracks.length,
  tracks: tracks,
);
