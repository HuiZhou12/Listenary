import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/core/database.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  test('creates the complete v5 schema for a new database', () {
    final database = sqlite3.openInMemory();
    try {
      initializeAppDatabase(database);

      expect(_userVersion(database), latestAppDatabaseVersion);
      expect(
        _tableNames(database),
        containsAll(<String>{
          'online_tracks',
          'online_track_artists',
          'online_play_history',
          'online_playlists',
          'online_playlist_items',
        }),
      );
      expect(
        database.select('PRAGMA foreign_keys').single['foreign_keys'],
        1,
      );
      expect(
        () => database.execute(
          'INSERT INTO online_track_artists('
          'platform, track_id, ordinal, name) '
          "VALUES('netease', 'missing', 0, 'Artist')",
        ),
        throwsA(isA<SqliteException>()),
      );
    } finally {
      database.dispose();
    }
  });

  test('migrates a v4 database and remains idempotent', () {
    final database = sqlite3.openInMemory();
    try {
      _createVersion4Database(database);

      initializeAppDatabase(database);
      initializeAppDatabase(database);

      expect(_userVersion(database), latestAppDatabaseVersion);
      expect(
        database
            .select(
              'SELECT COUNT(*) AS count FROM sqlite_master '
              "WHERE type = 'table' AND name LIKE 'online_%'",
            )
            .single['count'],
        5,
      );
      expect(
        database.select('SELECT name FROM playlists').single['name'],
        'Local',
      );
    } finally {
      database.dispose();
    }
  });

  test('rolls back the complete v5 migration when one table conflicts', () {
    final database = sqlite3.openInMemory();
    try {
      _createVersion4Database(database);
      database.execute(
        'CREATE VIEW online_playlists AS SELECT 1 AS id',
      );

      expect(
        () => initializeAppDatabase(database),
        throwsA(isA<SqliteException>()),
      );

      expect(_userVersion(database), 4);
      expect(
        _tableNames(database),
        isNot(contains('online_tracks')),
      );
      expect(
        _tableNames(database),
        isNot(contains('online_play_history')),
      );
    } finally {
      database.dispose();
    }
  });

  test('online schema has no storage columns for playback credentials', () {
    final database = sqlite3.openInMemory();
    try {
      initializeAppDatabase(database);
      final columns = <String>{};
      for (final table in _tableNames(database).where(
        (name) => name.startsWith('online_'),
      )) {
        columns.addAll(
          database
              .select('PRAGMA table_info($table)')
              .map((row) => row['name'] as String),
        );
      }

      for (final sensitiveColumn in <String>{
        'playback_url',
        'stream_url',
        'api_key',
        'cookie',
        'authorization',
        'signature',
        'raw_response',
      }) {
        expect(columns, isNot(contains(sensitiveColumn)));
      }
    } finally {
      database.dispose();
    }
  });
  test('★ F5-S2 表已存在但 user_version 落后 ⇒ 幂等升级且既有数据不丢', () {
    final database = sqlite3.openInMemory();
    try {
      // 先正常升到 v5（建出**结构正确**的在线表），再把版本号"回退"——
      // 这正好模拟"迁移跑过、但版本号没推进"的库（审计里说的半迁移形态）。
      _createVersion4Database(database);
      initializeAppDatabase(database);
      expect(_userVersion(database), latestAppDatabaseVersion);
      database.execute('PRAGMA user_version = 4');
      database.execute(
        'INSERT INTO online_tracks('
        'platform, track_id, title, created_at, updated_at) '
        "VALUES('netease', 't1', '已有曲目', "
        "'2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z')",
      );

      // 第二次升级：幂等必须成立（旧实现会因裸 CREATE TABLE 直接抛错）。
      initializeAppDatabase(database);

      expect(_userVersion(database), latestAppDatabaseVersion);
      expect(
        database
            .select("SELECT title FROM online_tracks WHERE track_id = 't1'")
            .single['title'],
        '已有曲目',
        reason: '既有数据不得被清掉或重建',
      );
      expect(
        database.select('PRAGMA foreign_key_check'),
        isEmpty,
        reason: '升级后外键一致性仍然成立',
      );
    } finally {
      database.dispose();
    }
  });

  test('★ F5-S2 已存在但**结构不符**的在线表 ⇒ 明确失败并整体回滚（不掩盖损坏）', () {
    final database = sqlite3.openInMemory();
    try {
      _createVersion4Database(database);
      // 结构错误：online_tracks 缺列（早期错误形态 / 被外部改过 / 已损坏）。
      database.execute('CREATE TABLE online_tracks (platform TEXT, track_id TEXT)');

      expect(
        () => initializeAppDatabase(database),
        throwsA(
          isA<StateError>().having(
            (error) => error.toString(),
            'message',
            allOf(
              contains('online_tracks'),
              contains('缺少列'),
              contains('原库未被修改'),
            ),
          ),
        ),
        reason: '幂等不能把"结构不对"掩盖成"迁移成功"',
      );

      // 回滚语义：版本号不变、其它在线表**没有**被建出来、那张错表原样保留（不做修复）。
      expect(_userVersion(database), 4);
      final tables = _tableNames(database);
      expect(tables, contains('online_tracks'), reason: '错表原样保留');
      expect(tables, isNot(contains('online_playlists')));
      expect(tables, isNot(contains('online_play_history')));
      expect(tables, isNot(contains('online_playlist_items')));
      expect(
        database.select('PRAGMA table_info(online_tracks)').length,
        2,
        reason: '错表结构未被改动',
      );
    } finally {
      database.dispose();
    }
  });
}

void _createVersion4Database(Database database) {
  database.execute('''
CREATE TABLE playlists (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  name TEXT NOT NULL UNIQUE,
  cover_source TEXT
);
CREATE TABLE playlist_items (
  playlist_id INTEGER NOT NULL,
  path TEXT NOT NULL,
  sort_order INTEGER NOT NULL DEFAULT 0,
  added_at TEXT,
  PRIMARY KEY (playlist_id, path)
);
INSERT INTO playlists(name, cover_source) VALUES('Local', NULL);
PRAGMA user_version = 4;
''');
}

int _userVersion(Database database) =>
    database.select('PRAGMA user_version').single['user_version'] as int;

Set<String> _tableNames(Database database) => database
    .select("SELECT name FROM sqlite_master WHERE type = 'table'")
    .map((row) => row['name'] as String)
    .toSet();
