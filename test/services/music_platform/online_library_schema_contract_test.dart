import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/core/database.dart';
import 'package:sqlite3/sqlite3.dart';

/// R10（原 Q5）：schema 守卫从**源码字符串断言**升级为**行为断言**。
///
/// 旧形态（3.5-c 之前）是 `expect(source, contains('latestAppDatabaseVersion = 6'))`
/// ——它只能证明「源码里写了这个数」，不能证明**迁移之后库里真的是这样**。
/// 现在改成：在临时内存/文件库上真跑一次 `initializeAppDatabase`，然后断言
/// `user_version`、表/列结构与 CHECK 约束的**真实行为**。
///
/// ⚠️ 全程只用内存库；不打开任何真实用户数据库文件。
void main() {
  late Database database;

  setUp(() {
    database = sqlite3.openInMemory();
    initializeAppDatabase(database);
  });

  tearDown(() => database.dispose());

  int userVersion() =>
      database.select('PRAGMA user_version').single['user_version'] as int;

  Set<String> tableNames() => database
      .select(
        "SELECT name FROM sqlite_master WHERE type = 'table' "
        "AND name NOT LIKE 'sqlite_%'",
      )
      .map((row) => row['name'] as String)
      .toSet();

  Set<String> columnsOf(String table) => database
      .select('PRAGMA table_info($table)')
      .map((row) => row['name'] as String)
      .toSet();

  group('schema 版本基线', () {
    test('migrating from scratch yields user_version == 7', () {
      expect(userVersion(), 7);
      expect(latestAppDatabaseVersion, 7);
    });

    test('v7 adds exactly one new table: local_play_history', () {
      expect(tableNames(), contains('local_play_history'));
      expect(columnsOf('local_play_history'), {
        'path',
        'play_count',
        'last_played_at',
      });
    });

    test('CHECK(play_count >= 0) really rejects negative values', () {
      // 行为断言：不是「源码里有这行」，而是「插负值真的会失败」。
      expect(
        () => database.execute(
          'INSERT INTO local_play_history(path, play_count) '
          "VALUES('C:/neg.flac', -1)",
        ),
        throwsA(isA<SqliteException>()),
      );
      // 0 是合法的。
      database.execute(
        'INSERT INTO local_play_history(path, play_count) '
        "VALUES('C:/ok.flac', 0)",
      );
      expect(
        database
            .select(
              "SELECT play_count FROM local_play_history WHERE path='C:/ok.flac'",
            )
            .single['play_count'],
        0,
      );
    });
  });

  group('在线内容身份（D1 的持久化守卫）', () {
    test(
      'online_tracks identity is (platform, track_id) — duplicate rejected',
      () {
        database.execute(
          'INSERT INTO online_tracks(platform, track_id, title, created_at, '
          "updated_at) VALUES('netease', 't1', 'A', 'now', 'now')",
        );
        expect(
          () => database.execute(
            'INSERT INTO online_tracks(platform, track_id, title, created_at, '
            "updated_at) VALUES('netease', 't1', 'B', 'now', 'now')",
          ),
          throwsA(isA<SqliteException>()),
          reason: '复合主键必须真的拒绝同一身份的第二行',
        );
        // 同 track_id、不同 platform ⇒ 是两首不同的歌（合法）。
        database.execute(
          'INSERT INTO online_tracks(platform, track_id, title, created_at, '
          "updated_at) VALUES('qq', 't1', 'A', 'now', 'now')",
        );
      },
    );

    test('online_track_artists identity is (platform, track_id, ordinal)', () {
      database.execute(
        'INSERT INTO online_tracks(platform, track_id, title, created_at, '
        "updated_at) VALUES('netease', 't2', 'A', 'now', 'now')",
      );
      database.execute(
        'INSERT INTO online_track_artists(platform, track_id, ordinal, name) '
        "VALUES('netease', 't2', 0, 'X')",
      );
      expect(
        () => database.execute(
          'INSERT INTO online_track_artists(platform, track_id, ordinal, name) '
          "VALUES('netease', 't2', 0, 'Y')",
        ),
        throwsA(isA<SqliteException>()),
      );
      // ordinal 1 是另一位艺人（合法）。
      database.execute(
        'INSERT INTO online_track_artists(platform, track_id, ordinal, name) '
        "VALUES('netease', 't2', 1, 'Y')",
      );
    });

    test(
      'online_playlist_items identity is (playlist_id, platform, track_id)',
      () {
        database.execute(
          'INSERT INTO online_tracks(platform, track_id, title, created_at, '
          "updated_at) VALUES('netease', 't3', 'A', 'now', 'now')",
        );
        database.execute(
          'INSERT INTO online_playlists(kind, name, created_at, updated_at) '
          "VALUES('personal', 'Mine', 'now', 'now')",
        );
        final playlistId = database.lastInsertRowId;
        database.execute(
          'INSERT INTO online_playlist_items(playlist_id, platform, track_id, '
          'sort_order, added_at) VALUES(?, ?, ?, ?, ?)',
          [playlistId, 'netease', 't3', 0, 'now'],
        );
        expect(
          () => database.execute(
            'INSERT INTO online_playlist_items(playlist_id, platform, track_id, '
            'sort_order, added_at) VALUES(?, ?, ?, ?, ?)',
            [playlistId, 'netease', 't3', 1, 'now'],
          ),
          throwsA(isA<SqliteException>()),
          reason: '同一歌单里同一 (platform, track_id) 只能出现一次',
        );
      },
    );
  });

  group('歌单来源 ≠ 条目来源', () {
    test('subscription requires platform + remote_playlist_id', () {
      expect(
        () => database.execute(
          'INSERT INTO online_playlists(kind, name, created_at, updated_at) '
          "VALUES('subscription', 'Bad', 'now', 'now')",
        ),
        throwsA(isA<SqliteException>()),
        reason: 'subscription 缺 platform/remote id ⇒ CHECK 拒绝',
      );
    });

    test('personal must NOT carry platform/remote id', () {
      expect(
        () => database.execute(
          'INSERT INTO online_playlists(kind, name, platform, '
          'remote_playlist_id, created_at, updated_at) '
          "VALUES('personal', 'Bad', 'netease', 'r1', 'now', 'now')",
        ),
        throwsA(isA<SqliteException>()),
      );
    });

    test('a personal playlist can mix platforms through its items', () {
      database.execute(
        'INSERT INTO online_tracks(platform, track_id, title, created_at, '
        "updated_at) VALUES('netease', 'n1', 'A', 'now', 'now')",
      );
      database.execute(
        'INSERT INTO online_tracks(platform, track_id, title, created_at, '
        "updated_at) VALUES('qq', 'q1', 'B', 'now', 'now')",
      );
      database.execute(
        'INSERT INTO online_playlists(kind, name, created_at, updated_at) '
        "VALUES('personal', 'Mixed', 'now', 'now')",
      );
      final id = database.lastInsertRowId;
      for (final entry in <List<Object?>>[
        [id, 'netease', 'n1', 0],
        [id, 'qq', 'q1', 1],
      ]) {
        database.execute(
          'INSERT INTO online_playlist_items(playlist_id, platform, track_id, '
          'sort_order, added_at) VALUES(?, ?, ?, ?, ?)',
          [...entry, 'now'],
        );
      }
      expect(
        database
            .select(
              'SELECT platform FROM online_playlist_items WHERE playlist_id = ? '
              'ORDER BY sort_order',
              [id],
            )
            .map((row) => row['platform']),
        ['netease', 'qq'],
      );
    });
  });

  group('provider 禁入内容身份（D1）', () {
    test('online_tracks has no provider column', () {
      expect(
        columnsOf('online_tracks'),
        isNot(contains('provider')),
        reason:
            'D1：Provider 只是「通过谁访问」，同一 (platform, track_id) 换 Provider '
            '仍是同一首歌，因此不得进入持久化身份',
      );
    });

    test('no online table carries a provider column', () {
      for (final table in <String>[
        'online_tracks',
        'online_track_artists',
        'online_play_history',
        'online_playlists',
        'online_playlist_items',
      ]) {
        expect(
          columnsOf(table),
          isNot(contains('provider')),
          reason: '$table 不得出现 provider 列（D1）',
        );
      }
    });
  });

  group('v6 幂等加列不回退', () {
    test('album_id / artist_id exist and are nullable', () {
      final trackColumns = database.select('PRAGMA table_info(online_tracks)');
      final albumId = trackColumns.firstWhere(
        (row) => row['name'] == 'album_id',
      );
      expect(albumId['notnull'], 0, reason: 'v6 只加可空列');
      final artistColumns = database.select(
        'PRAGMA table_info(online_track_artists)',
      );
      final artistId = artistColumns.firstWhere(
        (row) => row['name'] == 'artist_id',
      );
      expect(artistId['notnull'], 0);
    });

    test(
      're-opening the database keeps version 7 and does not duplicate tables',
      () {
        initializeAppDatabase(database);
        expect(userVersion(), 7);
        expect(
          database
              .select(
                "SELECT COUNT(*) AS c FROM sqlite_master WHERE type='table' "
                "AND name='local_play_history'",
              )
              .single['c'],
          1,
        );
      },
    );
  });
}
