import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/core/database.dart';
import 'package:pure_music/services/music_platform/models/music_models.dart';
import 'package:pure_music/services/music_platform/online_library/online_library_repository.dart';
import 'package:sqlite3/sqlite3.dart';

/// F5-P-39（P4）：数据库**按平台身份**读写闭环（用户必需测试 ①⑤⑩ 的数据层部分）。
///
/// 复用现有 `platform TEXT` 列承载稳定 ID ⇒ **无需迁移**。
void main() {
  late Database database;
  late OnlineLibraryRepository repository;

  setUp(() {
    database = sqlite3.openInMemory();
    initializeAppDatabase(database);
    repository = OnlineLibraryRepository(database);
  });

  tearDown(() => database.dispose());

  const alpha = PlatformIdentity.custom('0f9a1c2e-aaaa-4aaa-8aaa-aaaaaaaaaaaa');
  const beta = PlatformIdentity.custom('0f9a1c2e-bbbb-4bbb-8bbb-bbbbbbbbbbbb');

  test('★ P4-⑤ 写入再读回：两个自定义平台身份保持一致（同 trackId 不串台）', () {
    repository.upsertTrack(
      _track(alpha, 'same', title: 'alpha 的歌'),
      updatedAt: DateTime.utc(2026, 5, 1),
    );
    repository.upsertTrack(
      _track(beta, 'same', title: 'beta 的歌'),
      updatedAt: DateTime.utc(2026, 5, 2),
    );

    // 落库值就是稳定 ID（可容纳于既有 platform TEXT 列）。
    expect(
      database
          .select('SELECT platform FROM online_tracks ORDER BY platform')
          .map((row) => row['platform']),
      [alpha.platformId, beta.platformId],
    );

    final alphaRow = repository.findTrack(PlatformTrackRef.of(alpha, 'same'))!;
    final betaRow = repository.findTrack(PlatformTrackRef.of(beta, 'same'))!;
    expect(alphaRow.title, 'alpha 的歌');
    expect(betaRow.title, 'beta 的歌');
    expect(alphaRow.ref.identity, alpha, reason: '读回的身份必须与写入的一致');
    expect(betaRow.ref.identity, beta);
  });

  test('★ P4-① 两个自定义平台同 trackId：删除其一不影响另一个', () {
    repository.upsertTrack(_track(alpha, 't1'), updatedAt: DateTime.utc(2026, 5, 1));
    repository.upsertTrack(_track(beta, 't1'), updatedAt: DateTime.utc(2026, 5, 1));

    final playlistId = repository.createPersonalPlaylist('自建歌单');
    repository.addTrackToPersonalPlaylist(playlistId, _track(alpha, 't1'));
    repository.addTrackToPersonalPlaylist(playlistId, _track(beta, 't1'));

    expect(
      repository.removeTrackFromPersonalPlaylist(
        playlistId,
        PlatformTrackRef.of(alpha, 't1'),
      ),
      isTrue,
    );
    expect(repository.findTrack(PlatformTrackRef.of(alpha, 't1')), isNull);
    expect(
      repository.findTrack(PlatformTrackRef.of(beta, 't1')),
      isNotNull,
      reason: '另一平台同 ID 的记录必须还在',
    );
  });

  test('★ P4-⑩ 身份缺失（自定义平台无稳定 ID）⇒ 明确报错，不写入损坏行', () {
    expect(
      () => repository.upsertTrack(
        _track(const PlatformIdentity.custom(''), 't1'),
        updatedAt: DateTime.utc(2026, 5, 1),
      ),
      throwsA(isA<ArgumentError>()),
    );
    expect(
      database.select('SELECT COUNT(*) AS c FROM online_tracks').single['c'],
      0,
      reason: '无效身份不得落库',
    );
  });

  test('★ P4-⑦ 未知历史平台值：读回为 custom + 原值（不回落网易云，不抛错）', () {
    // 直接写一行"历史值"（模拟旧库/外部写入），绕过仓储的写入路径。
    database.execute(
      'INSERT INTO online_tracks(platform, track_id, title, created_at, updated_at) '
      "VALUES('LegacyProxy', 't9', '历史曲目', "
      "'2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z')",
    );

    final row = repository.findTrack(
      PlatformTrackRef.of(
        const PlatformIdentity.custom('LegacyProxy'),
        't9',
      ),
    );
    expect(row, isNotNull, reason: '历史值必须能安全保留原始身份');
    expect(row!.ref.identity.platform, MusicPlatform.custom);
    expect(row.ref.identity.platformId, 'LegacyProxy');
    expect(row.ref.identity.platform, isNot(MusicPlatform.netease));
  });
}

MusicTrack _track(PlatformIdentity identity, String id, {String title = 'Track'}) =>
    MusicTrack(
      ref: PlatformTrackRef.of(identity, id),
      title: title,
      artists: const ['Artist'],
      album: 'Album',
      coverUri: Uri.https('example.test', '/cover.jpg'),
      duration: const Duration(minutes: 3),
      availability: TrackAvailability.playable,
    );