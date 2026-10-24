import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/core/database.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  test('creates the complete current schema for a new database', () {
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

  test('★ v5→v6 只加可空列：旧行逐列保留、外键一致且重复初始化幂等', () {
    final database = sqlite3.openInMemory();
    try {
      _createVersion5Database(database);

      // 先证明夹具确实是 v5，且是 **v6 之前**的旧形态（两列还不存在）。
      expect(_userVersion(database), 5);
      expect(
        _columnNames(database, 'online_tracks'),
        isNot(contains('album_id')),
      );
      expect(
        _columnNames(database, 'online_track_artists'),
        isNot(contains('artist_id')),
      );

      initializeAppDatabase(database);

      expect(_userVersion(database), 6);
      _expectNullableTextColumn(database, 'online_tracks', 'album_id');
      _expectNullableTextColumn(database, 'online_track_artists', 'artist_id');

      // 旧行**逐列保留**；新列只能是 NULL（不重建表、不清数据、不编造 id）。
      final track = _selectOldTrack(database);
      expect(track['platform'], 'netease');
      expect(track['track_id'], 'old-1');
      expect(track['title'], '旧曲目');
      expect(track['album'], '旧专辑');
      expect(track['cover_uri'], 'cover://old');
      expect(track['duration_ms'], 245000);
      expect(track['availability'], 'available');
      expect(track['last_quality'], '320k');
      expect(track['created_at'], '2026-01-01T00:00:00Z');
      expect(track['updated_at'], '2026-01-02T00:00:00Z');
      expect(track['album_id'], isNull, reason: '老数据补不上就是 NULL ✓');

      final artist = _selectOldArtist(database);
      expect(artist['platform'], 'netease');
      expect(artist['track_id'], 'old-1');
      expect(artist['ordinal'], 0);
      expect(artist['name'], '旧艺人');
      expect(artist['artist_id'], isNull, reason: '老数据补不上就是 NULL ✓');

      expect(database.select('PRAGMA foreign_key_check'), isEmpty);
      expect(
        database
            .select(
              'SELECT COUNT(*) AS count FROM online_track_artists a '
              'JOIN online_tracks t '
              'ON t.platform = a.platform AND t.track_id = a.track_id',
            )
            .single['count'],
        1,
        reason: '旧行的外键关联仍然成立',
      );

      // 再次初始化：v6 已是 no-op（不抛 duplicate column），旧行与 NULL 不变。
      initializeAppDatabase(database);
      expect(_userVersion(database), 6);
      expect(_selectOldTrack(database)['title'], '旧曲目');
      expect(_selectOldTrack(database)['album_id'], isNull);
      expect(_selectOldArtist(database)['artist_id'], isNull);
      expect(
        database
            .select('SELECT COUNT(*) AS count FROM online_track_artists')
            .single['count'],
        1,
        reason: '重复初始化不得重建或清空旧行',
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

/// **v6 之前**的 v5 库（在线表缺少 `album_id` / `artist_id`）与旧行。
///
/// 不能复用当前 v5 建表语句：当前代码的 v5 DDL 已经带上了 v6 的两列
/// （全新库直接建出最新形态），用它构造会变成"在 v6 上自证 v6"，
/// 测不到真实老库（v6 之前创建的 v5 库）的升级路径。
void _createVersion5Database(Database database) {
  database.execute('''
CREATE TABLE meta (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL
);
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
CREATE TABLE lyric_sources (
  path TEXT PRIMARY KEY,
  source TEXT NOT NULL,
  id TEXT
);
CREATE TABLE album_colors (
  key TEXT PRIMARY KEY,
  sig TEXT NOT NULL,
  p INTEGER NOT NULL,
  on_p INTEGER NOT NULL
);
CREATE TABLE online_tracks (
  platform TEXT NOT NULL,
  track_id TEXT NOT NULL,
  title TEXT NOT NULL,
  album TEXT NOT NULL DEFAULT '',
  cover_uri TEXT,
  duration_ms INTEGER NOT NULL DEFAULT 0 CHECK(duration_ms >= 0),
  availability TEXT NOT NULL DEFAULT 'unknown',
  last_quality TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  PRIMARY KEY (platform, track_id)
);
CREATE TABLE online_track_artists (
  platform TEXT NOT NULL,
  track_id TEXT NOT NULL,
  ordinal INTEGER NOT NULL CHECK(ordinal >= 0),
  name TEXT NOT NULL,
  PRIMARY KEY (platform, track_id, ordinal),
  FOREIGN KEY (platform, track_id)
    REFERENCES online_tracks(platform, track_id) ON DELETE CASCADE
);
CREATE TABLE online_play_history (
  platform TEXT NOT NULL,
  track_id TEXT NOT NULL,
  play_count INTEGER NOT NULL DEFAULT 0 CHECK(play_count >= 0),
  last_played_at TEXT NOT NULL,
  PRIMARY KEY (platform, track_id),
  FOREIGN KEY (platform, track_id)
    REFERENCES online_tracks(platform, track_id) ON DELETE CASCADE
);
CREATE TABLE online_playlists (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  kind TEXT NOT NULL CHECK(kind IN ('subscription', 'personal')),
  name TEXT NOT NULL,
  platform TEXT,
  remote_playlist_id TEXT,
  cover_uri TEXT,
  creator TEXT,
  description TEXT,
  remote_track_count INTEGER CHECK(
    remote_track_count IS NULL OR remote_track_count >= 0
  ),
  last_refreshed_at TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  CHECK(
    (kind = 'subscription' AND platform IS NOT NULL
      AND remote_playlist_id IS NOT NULL)
    OR
    (kind = 'personal' AND platform IS NULL
      AND remote_playlist_id IS NULL)
  )
);
CREATE TABLE online_playlist_items (
  playlist_id INTEGER NOT NULL,
  platform TEXT NOT NULL,
  track_id TEXT NOT NULL,
  sort_order INTEGER NOT NULL CHECK(sort_order >= 0),
  added_at TEXT NOT NULL,
  PRIMARY KEY (playlist_id, platform, track_id),
  UNIQUE (playlist_id, sort_order),
  FOREIGN KEY (playlist_id)
    REFERENCES online_playlists(id) ON DELETE CASCADE,
  FOREIGN KEY (platform, track_id)
    REFERENCES online_tracks(platform, track_id)
);
INSERT INTO online_tracks(
  platform, track_id, title, album, cover_uri, duration_ms,
  availability, last_quality, created_at, updated_at
) VALUES(
  'netease', 'old-1', '旧曲目', '旧专辑', 'cover://old', 245000,
  'available', '320k', '2026-01-01T00:00:00Z', '2026-01-02T00:00:00Z'
);
INSERT INTO online_track_artists(platform, track_id, ordinal, name)
VALUES('netease', 'old-1', 0, '旧艺人');
PRAGMA user_version = 5;
''');
}

Row _selectOldTrack(Database database) => database
    .select(
      'SELECT * FROM online_tracks '
      "WHERE platform = 'netease' AND track_id = 'old-1'",
    )
    .single;

Row _selectOldArtist(Database database) => database
    .select(
      'SELECT * FROM online_track_artists '
      "WHERE platform = 'netease' AND track_id = 'old-1' AND ordinal = 0",
    )
    .single;

void _expectNullableTextColumn(
  Database database,
  String table,
  String column,
) {
  final info = database
      .select('PRAGMA table_info($table)')
      .singleWhere((row) => row['name'] == column);
  expect(info['type'], 'TEXT');
  expect(info['notnull'], 0, reason: 'v6 加列必须可空（老数据补不上就是 NULL）');
}

Set<String> _columnNames(Database database, String table) => database
    .select('PRAGMA table_info($table)')
    .map((row) => row['name'] as String)
    .toSet();

int _userVersion(Database database) =>
    database.select('PRAGMA user_version').single['user_version'] as int;

Set<String> _tableNames(Database database) => database
    .select("SELECT name FROM sqlite_master WHERE type = 'table'")
    .map((row) => row['name'] as String)
    .toSet();
