import 'dart:io';

import 'package:pure_music/core/settings.dart';
import 'package:path/path.dart' as path;
import 'package:sqlite3/sqlite3.dart';

const latestAppDatabaseVersion = 5;

class AppDb {
  AppDb._();

  static final AppDb instance = AppDb._();

  Database? _db;
  Future<Database>? _opening;

  Future<Database> db() {
    final existing = _db;
    if (existing != null) return Future<Database>.value(existing);
    final opening = _opening;
    if (opening != null) return opening;

    final future = _open();
    _opening = future;
    return future;
  }

  Future<Database> _open() async {
    Database? opened;
    try {
      final dir = await getDbDir();
      final dbFile = File(path.join(dir.path, 'app.sqlite'));
      dbFile.parent.createSync(recursive: true);

      opened = sqlite3.open(dbFile.path);
      initializeAppDatabase(opened);
      _db = opened;
      return opened;
    } catch (_) {
      opened?.dispose();
      rethrow;
    } finally {
      _opening = null;
    }
  }

  void dispose() {
    _db?.dispose();
    _db = null;
  }
}

void initializeAppDatabase(Database db) {
  db.execute('''
PRAGMA journal_mode = WAL;
PRAGMA synchronous = NORMAL;
PRAGMA temp_store = MEMORY;
PRAGMA busy_timeout = 3000;
PRAGMA foreign_keys = ON;

CREATE TABLE IF NOT EXISTS meta (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS playlists (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  name TEXT NOT NULL UNIQUE
);

CREATE TABLE IF NOT EXISTS playlist_items (
  playlist_id INTEGER NOT NULL,
  path TEXT NOT NULL,
  PRIMARY KEY (playlist_id, path)
);

CREATE INDEX IF NOT EXISTS idx_playlist_items_playlist_id ON playlist_items(playlist_id);

CREATE TABLE IF NOT EXISTS lyric_sources (
  path TEXT PRIMARY KEY,
  source TEXT NOT NULL,
  id TEXT
);

CREATE TABLE IF NOT EXISTS album_colors (
  key TEXT PRIMARY KEY,
  sig TEXT NOT NULL,
  p INTEGER NOT NULL,
  on_p INTEGER NOT NULL
);
''');

  _migrateAppDatabase(db);
}

void _migrateAppDatabase(Database db) {
  db.execute('BEGIN');
  try {
    final version =
        db.select('PRAGMA user_version').first['user_version'] as int;
    if (version < 1) {
      db.execute(
          'ALTER TABLE playlist_items ADD COLUMN sort_order INTEGER NOT NULL DEFAULT 0');
      db.execute('PRAGMA user_version = 1');
    }
    if (version < 2) {
      try {
        db.execute('ALTER TABLE playlist_items DROP COLUMN audio_json');
      } catch (_) {}
      db.execute('PRAGMA user_version = 2');
    }
    if (version < 3) {
      db.execute('ALTER TABLE playlists ADD COLUMN cover_source TEXT');
      db.execute('PRAGMA user_version = 3');
    }
    if (version < 4) {
      db.execute('ALTER TABLE playlist_items ADD COLUMN added_at TEXT');
      db.execute('PRAGMA user_version = 4');
    }
    if (version < 5) {
      db.execute('''
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

CREATE INDEX idx_online_history_last_played
  ON online_play_history(last_played_at DESC);
CREATE INDEX idx_online_history_play_count
  ON online_play_history(play_count DESC);

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

CREATE UNIQUE INDEX idx_online_subscription_identity
  ON online_playlists(platform, remote_playlist_id)
  WHERE kind = 'subscription';
CREATE UNIQUE INDEX idx_online_personal_name
  ON online_playlists(name COLLATE NOCASE)
  WHERE kind = 'personal';

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

CREATE INDEX idx_online_playlist_items_playlist
  ON online_playlist_items(playlist_id, sort_order);
''');
      db.execute('PRAGMA user_version = 5');
    }
    db.execute('COMMIT');
  } catch (_) {
    db.execute('ROLLBACK');
    rethrow;
  }
}
