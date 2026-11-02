import 'dart:async';

import 'package:pure_music/core/database.dart';
import 'package:pure_music/core/library_db.dart';
import 'package:pure_music/core/sqlite_version_guard.dart';
import 'package:sqlite3/sqlite3.dart';

/// 统计页「本地」榜的一条。
class LocalPlayEntry {
  const LocalPlayEntry({
    required this.path,
    required this.title,
    required this.artist,
    required this.album,
    required this.playCount,
  });

  final String path;
  final String title;
  final String artist;
  final String album;
  final int playCount;
}

/// 本地播放次数的唯一 owner（3.5-b 起归 `app.sqlite`）。
///
/// `library.sqlite.audios.play_count` 从此**只读不写**：保留列与值，作为
/// 降级兼容与历史快照（Spec §4.1 的 P2 注记）。
class LocalPlayHistory {
  LocalPlayHistory._();

  static final LocalPlayHistory instance = LocalPlayHistory._();

  /// 记一次播放。同一路径累加；不存在就建行。
  ///
  /// 禁写态（SQLite 版本不足）直接返回 `false`，不抛错——调用方据此跳过
  /// 内存计数的自增，语义与今日「写库失败只记日志」一致。
  Future<bool> recordPlayback(String path) async {
    if (!SqliteVersionGuard.instance.canWrite) return false;
    final db = await AppDb.instance.db();
    final saved = _increment(db, [path]);
    return saved > 0;
  }

  /// 写库并返回受影响行数；供测试直接注入临时库。
  int _increment(Database db, List<String> paths) {
    var affected = 0;
    final statement = db.prepare(
      'INSERT INTO local_play_history(path, play_count, last_played_at) '
      'VALUES(?1, 1, ?2) '
      'ON CONFLICT(path) DO UPDATE SET '
      'play_count = local_play_history.play_count + 1, '
      'last_played_at = excluded.last_played_at',
    );
    final now = DateTime.now().toUtc().toIso8601String();
    try {
      for (final path in paths) {
        statement.execute([path, now]);
        affected += db.updatedRows;
      }
    } finally {
      statement.dispose();
    }
    return affected;
  }

  /// 近一次播放时间戳（可空）。
  Future<String?> lastPlayedAt(String path) async {
    final db = await AppDb.instance.db();
    final rows = db.select(
      'SELECT last_played_at FROM local_play_history WHERE path = ?',
      [path],
    );
    if (rows.isEmpty) return null;
    return rows.first['last_played_at'] as String?;
  }

  /// 「最常播放」榜（`play_count > 0`，按次数降序、路径升序）。
  ///
  /// 标题 / 艺人 / 专辑从 `library.sqlite` 补齐；库不可读时退化为只返回
  /// 路径与次数（统计页会用 `AudioLibrary` 里的元数据兜底）。
  Future<List<LocalPlayEntry>> topPlayed({int limit = -1}) async {
    if (!SqliteVersionGuard.instance.canWrite) return const [];
    final db = await AppDb.instance.db();
    return topPlayedFrom(db, limit: limit);
  }

  /// 从给定连接读榜；测试可注入内存库。
  List<LocalPlayEntry> topPlayedFrom(Database db, {int limit = -1}) {
    final rows = limit > 0
        ? db.select(
            'SELECT path, play_count FROM local_play_history '
            'WHERE play_count > 0 ORDER BY play_count DESC, path ASC LIMIT ?',
            [limit],
          )
        : db.select(
            'SELECT path, play_count FROM local_play_history '
            'WHERE play_count > 0 ORDER BY play_count DESC, path ASC',
          );
    if (rows.isEmpty) return const [];
    final metadata = <String, LibraryAudio>{};
    final folders = LibraryDb.instance.readIndex();
    if (folders != null) {
      for (final folder in folders) {
        for (final audio in folder.audios) {
          metadata[audio.path] = audio;
        }
      }
    }
    return rows
        .map((row) {
          final path = row['path'] as String;
          final audio = metadata[path];
          return LocalPlayEntry(
            path: path,
            title: audio?.title ?? '',
            artist: audio?.artist ?? '',
            album: audio?.album ?? '',
            playCount: row['play_count'] as int,
          );
        })
        .toList(growable: false);
  }
}
