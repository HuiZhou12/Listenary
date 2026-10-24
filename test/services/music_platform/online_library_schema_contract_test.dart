import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// schema 守卫：**v6 只加可空列**的持久化基线 + D1 的持久化守卫。
///
/// v6 只给 `online_tracks` 补 `album_id`、给 `online_track_artists` 补 `artist_id`
/// （均可空），不改在线内容身份。这个测试把基线钉住：
/// - 一旦有人改动 schema 版本基线或在线表主键 → 必须重新走决策流程；
/// - 一旦有人把 `provider` 写进在线表 → 违反 D1（Provider 是访问配置，不是内容事实）。
void main() {
  const databasePath = 'lib/core/database.dart';
  late String source;

  setUpAll(() {
    final file = File(databasePath);
    expect(file.existsSync(), isTrue, reason: '找不到 $databasePath');
    source = file.readAsStringSync();
  });

  test('schema 基线为 6：v6 只加可空列，在线内容身份不变', () {
    expect(source, contains('latestAppDatabaseVersion = 6'));
    expect(source, contains('PRAGMA user_version = 6'));
  });

  test('在线内容身份仍是 (platform, remoteId) 复合主键', () {
    // online_tracks / online_play_history
    expect(source, contains('PRIMARY KEY (platform, track_id)'));
    // online_track_artists
    expect(source, contains('PRIMARY KEY (platform, track_id, ordinal)'));
    // online_playlist_items —— 条目各自带来源，因此 personal 歌单可以混平台
    expect(source, contains('PRIMARY KEY (playlist_id, platform, track_id)'));
  });

  test('"歌单来源 ≠ 条目来源"仍由 CHECK 约束保证', () {
    expect(source, contains("CHECK(kind IN ('subscription', 'personal'))"));
    expect(source, contains("(kind = 'subscription' AND platform IS NOT NULL"));
    expect(source, contains("(kind = 'personal' AND platform IS NULL"));
  });

  test('provider 不在内容身份里（D1）：在线表不得出现 provider 列', () {
    // ⚠️ F5-S2 起 v5 的 DDL 是 `CREATE TABLE IF NOT EXISTS …`（幂等化）
    // ⇒ 锚点改用 `online_tracks (`：外键引用写的是 `online_tracks(platform, …)`（无空格），
    // 因此带空格的那个只出现在建表语句处，对"是否幂等"的写法变化保持鲁棒。
    // 切片**止于 v5 迁移结束**（`PRAGMA user_version = 5`），不扩到 v6 段：
    // 这里只守卫 v5 在线建表段，v6 的可空加列由迁移行为测试覆盖。
    final start = source.indexOf('online_tracks (');
    final end = source.indexOf('PRAGMA user_version = 5');
    expect(start, greaterThanOrEqualTo(0), reason: '找不到在线表定义段');
    expect(end, greaterThan(start), reason: '找不到 v5 迁移的结束位置');

    final onlineSchema = source.substring(start, end);
    expect(
      onlineSchema.contains('provider'),
      isFalse,
      reason:
          'D1：Provider 只是"通过谁访问"，同一 (platform, remoteId) 换 Provider 仍是同一首歌，'
          '因此不得进入持久化身份（否则同一首歌会因为换 Provider 而分裂成两条）',
    );
  });
}
