import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/core/library_db.dart';
import 'package:pure_music/core/sqlite_version_guard.dart';
import 'package:sqlite3/sqlite3.dart';

/// R4（写入等价 6 条增量语义）与 R15（快路径）：
/// JSON → `library.sqlite` 同步行为。
///
/// ⚠️ 全程只用 `Directory.systemTemp` 下的临时目录造库；不接触真实用户数据。
void main() {
  late Directory tempDir;
  late String indexPath;
  late String dbPath;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('listenary-libsync-');
    indexPath = '${tempDir.path}${Platform.pathSeparator}index.json';
    dbPath = '${tempDir.path}${Platform.pathSeparator}library.sqlite';
    SqliteVersionGuard.instance.resetForTest();
    _seedEmptyLibrary(dbPath);
    LibraryDb.instance.debugOpenAtForTest(tempDir.path);
  });

  tearDown(() {
    LibraryDb.instance.dispose();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  Map<String, Object?> audioJson({
    required String path,
    String title = 'Track',
    String artist = 'Artist',
    String album = 'Album',
    String? albumArtist = 'Artist',
    int track = 1,
    int disc = 1,
    int duration = 180,
    int? bitrate = 320,
    int? sampleRate = 44100,
    int modified = 4,
    int created = 5,
    String? by = 'Lofty',
  }) => {
    'title': title,
    'artist': artist,
    'album': album,
    'album_artist': albumArtist,
    'track': track,
    'disc': disc,
    'duration': duration,
    'bitrate': bitrate,
    'sample_rate': sampleRate,
    'path': path,
    'modified': modified,
    'created': created,
    'by': by,
  };

  Map<String, Object?> folderJson({
    required String folderPath,
    required int modified,
    required List<Map<String, Object?>> audios,
  }) => {
    'path': folderPath,
    'modified': modified,
    'latest': modified,
    'audios': audios,
  };

  Map<String, Object?> indexJson(
    List<Map<String, Object?>> folders, {
    int version = currentIndexVersion,
  }) => {'version': version, 'folders': folders};

  void writeIndexJson(Map<String, Object?> index) {
    File(indexPath).writeAsStringSync(jsonEncode(index));
  }

  Database openDb() => sqlite3.open(dbPath, mode: OpenMode.readOnly);

  int playCountOf(String path) {
    final db = openDb();
    try {
      final rows = db.select('SELECT play_count FROM audios WHERE path = ?', [
        path,
      ]);
      return rows.isEmpty ? -1 : rows.first['play_count'] as int;
    } finally {
      db.dispose();
    }
  }

  String? metadataKeyOf(String path) {
    final db = openDb();
    try {
      final rows = db.select('SELECT metadata_key FROM audios WHERE path = ?', [
        path,
      ]);
      return rows.isEmpty ? null : rows.first['metadata_key'] as String?;
    } finally {
      db.dispose();
    }
  }

  /// 预置一行「旧引擎写出来的」曲目（含给定 play_count 与身份键）。
  void seedStoredAudio({
    required String path,
    required int playCount,
    String title = 'Track',
    String artist = 'Artist',
    String album = 'Album',
  }) {
    final db = LibraryDb.instance.debugDatabaseForTest!;
    final identity = audioIdentity(
      path: path,
      title: title,
      artist: artist,
      album: album,
      albumArtist: 'Artist',
      track: 1,
      duration: 180,
      bitrate: 320,
      sampleRate: 44100,
    );
    db.execute(
      'INSERT OR REPLACE INTO audios(path, folder_path, title, artist, album, '
      'album_artist, track, disc, duration, bitrate, sample_rate, modified, '
      'created, by, play_count, media_id, metadata_key) '
      'VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
      [
        path,
        path,
        title,
        artist,
        album,
        'Artist',
        1,
        1,
        180,
        320,
        44100,
        4,
        5,
        'Lofty',
        playCount,
        identity.mediaId,
        identity.metadataKey,
      ],
    );
  }

  group('R4 写入等价（6 条增量语义）', () {
    test('1) path normalization reuses play_count via path_lookup_key', () {
      // 旧行用反斜杠 + 大写；新索引用正斜杠 ⇒ 归一后是同一个键。
      seedStoredAudio(path: r'C:\Music\Track.FLAC', playCount: 5);

      LibraryDb.instance.syncIndexJson(
        indexJson([
          folderJson(
            folderPath: 'C:/Music',
            modified: 1,
            audios: [audioJson(path: 'C:/Music/Track.FLAC')],
          ),
        ]),
        indexDir: tempDir.path,
      );

      expect(playCountOf('C:/Music/Track.FLAC'), 5, reason: '归一命中 ⇒ 继承');
    });

    test('2) play_count survives file rename via unique media_id', () {
      final oldFile = File('${tempDir.path}${Platform.pathSeparator}old.flac')
        ..writeAsBytesSync([1, 2, 3, 4]);
      final newFile = File('${tempDir.path}${Platform.pathSeparator}new.flac');

      LibraryDb.instance.syncIndexJson(
        indexJson([
          folderJson(
            folderPath: tempDir.path,
            modified: 1,
            audios: [audioJson(path: oldFile.path)],
          ),
        ]),
        indexDir: tempDir.path,
      );
      LibraryDb.instance.debugDatabaseForTest!.execute(
        'UPDATE audios SET play_count = 9 WHERE path = ?',
        [oldFile.path],
      );

      // 改名：同一物理文件 ⇒ 同一 media_id。
      oldFile.renameSync(newFile.path);
      LibraryDb.instance.syncIndexJson(
        indexJson([
          folderJson(
            folderPath: tempDir.path,
            modified: 1,
            audios: [audioJson(path: newFile.path)],
          ),
        ]),
        indexDir: tempDir.path,
      );

      expect(playCountOf(newFile.path), 9, reason: '唯一 media_id 命中 ⇒ 继承');
      expect(playCountOf(oldFile.path), -1, reason: '旧行作为陈旧行删除');
    });

    test('3) ambiguous metadata match does NOT copy play_count', () {
      final first = File('${tempDir.path}${Platform.pathSeparator}a.flac')
        ..writeAsBytesSync([1]);
      final second = File('${tempDir.path}${Platform.pathSeparator}b.flac')
        ..writeAsBytesSync([2]);
      final gone = '${tempDir.path}/gone.flac';
      // 旧行：元数据与下面两条完全相同（同 metadata_key），但路径已不存在。
      seedStoredAudio(path: gone, playCount: 4);

      LibraryDb.instance.syncIndexJson(
        indexJson([
          folderJson(
            folderPath: tempDir.path,
            modified: 1,
            audios: [
              audioJson(path: first.path),
              audioJson(path: second.path),
            ],
          ),
        ]),
        indexDir: tempDir.path,
      );

      expect(playCountOf(first.path), 0, reason: '歧义（命中 ≥2 处）⇒ 不复制');
      expect(playCountOf(second.path), 0, reason: '也绝不广播');
    });

    test('4) stale audios and folders rows are deleted', () {
      LibraryDb.instance.syncIndexJson(
        indexJson([
          folderJson(
            folderPath: 'C:/Gone',
            modified: 1,
            audios: [audioJson(path: 'C:/Gone/x.flac')],
          ),
        ]),
        indexDir: tempDir.path,
      );
      LibraryDb.instance.syncIndexJson(
        indexJson([folderJson(folderPath: 'C:/Kept', modified: 1, audios: [])]),
        indexDir: tempDir.path,
      );

      final db = openDb();
      try {
        expect(db.select('SELECT path FROM audios'), isEmpty);
        expect(
          db.select('SELECT path FROM folders').map((row) => row['path']),
          ['C:/Kept'],
        );
      } finally {
        db.dispose();
      }
    });

    test('5) orphaned cover_thumbnails rows are pruned', () {
      LibraryDb.instance.syncIndexJson(
        indexJson([
          folderJson(
            folderPath: 'C:/Music',
            modified: 1,
            audios: [audioJson(path: 'C:/Music/keep.flac')],
          ),
        ]),
        indexDir: tempDir.path,
      );
      final writer = LibraryDb.instance.debugDatabaseForTest!;
      writer.execute(
        'INSERT INTO cover_thumbnails(path, width, height, source_modified, '
        'source_size, last_accessed, png) '
        "VALUES('C:/Music/keep.flac', 48, 48, 1, 2, 0, ?)",
        [
          [1, 2, 3],
        ],
      );
      writer.execute(
        'INSERT INTO cover_thumbnails(path, width, height, source_modified, '
        'source_size, last_accessed, png) '
        "VALUES('C:/Music/orphan.flac', 48, 48, 1, 2, 0, ?)",
        [
          [9, 9, 9],
        ],
      );

      LibraryDb.instance.syncIndexJson(
        indexJson([
          folderJson(
            folderPath: 'C:/Music',
            modified: 1,
            audios: [audioJson(path: 'C:/Music/keep.flac')],
          ),
        ]),
        indexDir: tempDir.path,
      );

      final db = openDb();
      try {
        expect(
          db
              .select('SELECT path FROM cover_thumbnails')
              .map((row) => row['path'] as String),
          ['C:/Music/keep.flac'],
        );
      } finally {
        db.dispose();
      }
    });

    test('6) meta.version and index_source_* are written back', () {
      writeIndexJson(
        indexJson([
          folderJson(folderPath: 'C:/Music', modified: 1, audios: []),
        ]),
      );
      LibraryDb.instance.syncIndexJson(
        indexJson([
          folderJson(folderPath: 'C:/Music', modified: 1, audios: []),
        ]),
        indexDir: tempDir.path,
      );

      final db = openDb();
      try {
        final meta = <String, String>{};
        for (final row in db.select(
          'SELECT key, value FROM meta WHERE key IN '
          "('version', 'index_source_modified', 'index_source_size')",
        )) {
          meta[row['key'] as String] = row['value'] as String;
        }
        expect(meta['version'], '$currentIndexVersion');
        expect(
          int.parse(meta['index_source_size']!),
          File(indexPath).lengthSync(),
        );
        expect(meta['index_source_modified'], isNotNull);
      } finally {
        db.dispose();
      }
    });

    test('identical index sync does not rewrite library rows', () {
      // 与旧 Rust `identical_index_sync_does_not_rewrite_library_rows` 等价：
      // 用触发器统计真实行级写次数，重复同步必须为 0。
      writeIndexJson(
        indexJson([
          folderJson(
            folderPath: 'C:/Music',
            modified: 1,
            audios: [audioJson(path: 'C:/Music/track.flac')],
          ),
        ]),
      );
      LibraryDb.instance.syncIndexJson(
        indexJson([
          folderJson(
            folderPath: 'C:/Music',
            modified: 1,
            audios: [audioJson(path: 'C:/Music/track.flac')],
          ),
        ]),
        indexDir: tempDir.path,
      );
      final writer = LibraryDb.instance.debugDatabaseForTest!;
      writer.execute('''
CREATE TABLE sync_audit(kind TEXT NOT NULL);
CREATE TRIGGER a1 AFTER INSERT ON folders
  BEGIN INSERT INTO sync_audit VALUES('folder_insert'); END;
CREATE TRIGGER a2 AFTER UPDATE ON folders
  BEGIN INSERT INTO sync_audit VALUES('folder_update'); END;
CREATE TRIGGER a3 AFTER DELETE ON folders
  BEGIN INSERT INTO sync_audit VALUES('folder_delete'); END;
CREATE TRIGGER a4 AFTER INSERT ON audios
  BEGIN INSERT INTO sync_audit VALUES('audio_insert'); END;
CREATE TRIGGER a5 AFTER UPDATE ON audios
  BEGIN INSERT INTO sync_audit VALUES('audio_update'); END;
CREATE TRIGGER a6 AFTER DELETE ON audios
  BEGIN INSERT INTO sync_audit VALUES('audio_delete'); END;
''');

      LibraryDb.instance.syncIndexJson(
        indexJson([
          folderJson(
            folderPath: 'C:/Music',
            modified: 1,
            audios: [audioJson(path: 'C:/Music/track.flac')],
          ),
        ]),
        indexDir: tempDir.path,
      );

      final db = openDb();
      try {
        expect(
          db.select('SELECT COUNT(*) AS c FROM sync_audit').single['c'],
          0,
          reason: '完全相同的索引不得产生任何行级写',
        );
      } finally {
        db.dispose();
      }
    });

    test(
      'identity keys are byte-compatible with what the old engine stored',
      () {
        // §5.5「跨引擎一致」：先按当前算法算一次写进库，读回后重算，
        // 两者必须逐字符相等（算法漂移会让跨版本继承失效）。
        final path = '${tempDir.path}/中文 曲目.flac';
        LibraryDb.instance.syncIndexJson(
          indexJson([
            folderJson(
              folderPath: tempDir.path,
              modified: 1,
              audios: [
                audioJson(
                  path: path,
                  title: '  中文  标题 ',
                  artist: 'Some  Artist',
                  album: 'Album',
                  bitrate: null,
                  sampleRate: null,
                ),
              ],
            ),
          ]),
          indexDir: tempDir.path,
        );

        final stored = metadataKeyOf(path);
        expect(stored, isNotNull);
        expect(
          stored,
          metadataMatchKey(
            path: path,
            title: '  中文  标题 ',
            artist: 'Some  Artist',
            album: 'Album',
            albumArtist: 'Artist',
            track: 1,
            duration: 180,
            bitrate: null,
            sampleRate: null,
          ),
        );
      },
    );

    test('duplicate folder/audio paths are rejected before any write', () {
      expect(
        () => LibraryDb.instance.syncIndexJson(
          indexJson([
            folderJson(folderPath: 'C:/A', modified: 1, audios: []),
            folderJson(folderPath: 'C:/A', modified: 2, audios: []),
          ]),
          indexDir: tempDir.path,
        ),
        throwsA(isA<StateError>()),
      );
      expect(
        () => LibraryDb.instance.syncIndexJson(
          indexJson([
            folderJson(
              folderPath: 'C:/A',
              modified: 1,
              audios: [
                audioJson(path: 'C:/A/x.flac'),
                audioJson(path: 'C:/A/x.flac'),
              ],
            ),
          ]),
          indexDir: tempDir.path,
        ),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('R15 快路径', () {
    test('snapshot exposes exactly what the fast path needs', () {
      writeIndexJson(
        indexJson([
          folderJson(folderPath: 'C:/Music', modified: 17, audios: []),
        ]),
      );
      LibraryDb.instance.syncIndexJson(
        indexJson([
          folderJson(folderPath: 'C:/Music', modified: 17, audios: []),
        ]),
        indexDir: tempDir.path,
      );

      final snapshot = LibraryDb.instance.readSnapshot();
      expect(snapshot, isNotNull);
      expect(snapshot!.version, currentIndexVersion);
      expect(snapshot.folders.single.path, 'C:/Music');
      expect(snapshot.folders.single.modified, 17);
      expect(
        snapshot.indexSourceSize,
        File(indexPath).lengthSync(),
        reason: '快路径签名必须与文件现状一致',
      );
      expect(snapshot.indexSourceModified, isNotNull);
    });

    test('a changed index.json invalidates the stored signature', () async {
      writeIndexJson(
        indexJson([
          folderJson(folderPath: 'C:/Music', modified: 17, audios: []),
        ]),
      );
      LibraryDb.instance.syncIndexJson(
        indexJson([
          folderJson(folderPath: 'C:/Music', modified: 17, audios: []),
        ]),
        indexDir: tempDir.path,
      );
      // 让 mtime / size 一定变化。
      await Future<void>.delayed(const Duration(milliseconds: 5));
      File(indexPath).writeAsStringSync(
        jsonEncode(
          indexJson([
            folderJson(folderPath: 'C:/Music', modified: 17, audios: []),
            folderJson(folderPath: 'C:/Extra', modified: 1, audios: []),
          ]),
        ),
      );

      final snapshot = LibraryDb.instance.readSnapshot()!;
      expect(
        snapshot.indexSourceSize,
        isNot(File(indexPath).lengthSync()),
        reason: '签名已变 ⇒ 上层不得命中快路径',
      );
    });

    test('readSnapshot returns null when the library is not initialized', () {
      LibraryDb.instance.debugDatabaseForTest!.execute(
        "DELETE FROM meta WHERE key = 'version'",
      );
      expect(LibraryDb.instance.readSnapshot(), isNull);
      expect(LibraryDb.instance.readIndex(), isNull);
    });
  });

  group('syncIndexJsonIfStale', () {
    test('first call syncs, second call is a no-op', () {
      writeIndexJson(
        indexJson([
          folderJson(folderPath: 'C:/Music', modified: 1, audios: []),
        ]),
      );
      expect(
        LibraryDb.instance.syncIndexJsonIfStale(indexDir: tempDir.path),
        isTrue,
      );
      expect(
        LibraryDb.instance.syncIndexJsonIfStale(indexDir: tempDir.path),
        isFalse,
        reason: '签名未变 ⇒ 不重复解析 JSON',
      );
    });

    test('re-syncs after index.json changes', () {
      writeIndexJson(
        indexJson([
          folderJson(folderPath: 'C:/Music', modified: 1, audios: []),
        ]),
      );
      expect(
        LibraryDb.instance.syncIndexJsonIfStale(indexDir: tempDir.path),
        isTrue,
      );
      File(indexPath).writeAsStringSync(
        jsonEncode(
          indexJson([
            folderJson(
              folderPath: 'C:/Music',
              modified: 1,
              audios: [audioJson(path: 'C:/Music/t.flac')],
            ),
          ]),
        ),
      );
      expect(
        LibraryDb.instance.syncIndexJsonIfStale(indexDir: tempDir.path),
        isTrue,
      );
      final db = openDb();
      try {
        expect(db.select('SELECT COUNT(*) AS c FROM audios').single['c'], 1);
      } finally {
        db.dispose();
      }
    });

    test('returns false when there is no index.json', () {
      expect(
        LibraryDb.instance.syncIndexJsonIfStale(indexDir: tempDir.path),
        isFalse,
      );
    });

    test('returns false when the database is closed', () {
      LibraryDb.instance.dispose();
      expect(
        LibraryDb.instance.syncIndexJson(
          indexJson([
            folderJson(folderPath: 'C:/Music', modified: 1, audios: []),
          ]),
          indexDir: tempDir.path,
        ),
        isFalse,
      );
    });
  });
}

/// 建一个空的、带完整 DDL 的 `library.sqlite`（模拟「已有库」）。
void _seedEmptyLibrary(String dbPath) {
  final db = sqlite3.open(dbPath);
  try {
    LibraryDb.instance.initSchema(db);
    db.execute(
      "INSERT OR REPLACE INTO meta(key, value) VALUES('version', '111')",
    );
    db.execute(
      'INSERT OR REPLACE INTO meta(key, value) '
      "VALUES('database_layout_version', '2')",
    );
    db.execute(
      'INSERT OR REPLACE INTO meta(key, value) '
      "VALUES('identity_backfill_v1', '1')",
    );
  } finally {
    db.dispose();
  }
}
