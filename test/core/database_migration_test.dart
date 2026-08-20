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
