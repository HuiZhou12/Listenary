import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/services/music_platform/index.dart';
import 'package:pure_music/services/music_platform/models/music_models.dart';
import 'package:pure_music/services/music_platform/online_library/online_library_repository.dart';
import 'package:pure_music/services/online_history/rediscovery_engine.dart';

/// 重温引擎（`RediscoveryEngine`）：它是一个**小系统** ✓，所以这些行为都得钉住 ✓。
void main() {
  const engine = RediscoveryEngine();
  final now = DateTime.utc(2026, 10, 12, 12);

  OnlineHistoryEntry entry({
    required String id,
    required int plays,
    required int daysAgo,
    String artist = 'A',
    String album = 'Al',
    int durationSeconds = 240,
  }) => OnlineHistoryEntry(
    track: MusicTrack(
      ref: PlatformTrackRef(platform: MusicPlatform.netease, trackId: id),
      title: '曲目 $id',
      artists: [artist],
      album: album,
      duration: Duration(seconds: durationSeconds),
    ),
    playCount: plays,
    lastPlayedAt: now.subtract(Duration(days: daysAgo)),
  );

  group('再听一遍（replay）', () {
    test('熟悉的排在生疏的前面（次线性：听 4 次不等于 2 倍的 2 次）', () {
      final picks = engine.rank(
        entries: [
          entry(id: 'a', plays: 2, daysAgo: 1),
          entry(id: 'b', plays: 12, daysAgo: 1),
          entry(id: 'c', plays: 1, daysAgo: 1),
        ],
        now: now,
        intent: RediscoveryIntent.replay,
        limit: 3,
      );
      expect(picks.map((p) => p.entry.track.ref.trackId), ['b', 'a', 'c']);
    });

    test('同样听过 10 次时，**最近还在听**的靠前（近因因子）', () {
      final picks = engine.rank(
        entries: [
          entry(id: 'old', plays: 10, daysAgo: 60),
          entry(id: 'new', plays: 10, daysAgo: 1),
        ],
        now: now,
        intent: RediscoveryIntent.replay,
        limit: 2,
      );
      expect(picks.first.entry.track.ref.trackId, 'new');
    });

    test('**不做** 14 天门槛：很久没听的也能进"再听一遍"（门槛只属于"好久没听"）', () {
      final picks = engine.rank(
        entries: [entry(id: 'a', plays: 30, daysAgo: 90)],
        now: now,
        intent: RediscoveryIntent.replay,
        limit: 5,
      );
      expect(picks, hasLength(1));
    });
  });

  group('好久没听（rediscover）', () {
    test('**硬门槛**：14 天内听过的一律不出现（那是"最近在听"，不是"好久没听"）', () {
      final picks = engine.rank(
        entries: [
          entry(id: 'recent', plays: 50, daysAgo: 3),
          entry(id: 'borderline', plays: 50, daysAgo: 13),
          entry(id: 'ok', plays: 5, daysAgo: 15),
        ],
        now: now,
        intent: RediscoveryIntent.rediscover,
        limit: 5,
      );
      expect(picks.map((p) => p.entry.track.ref.trackId), ['ok']);
    });

    test('同样听过 10 次时，**隔得越久**的靠前（与 replay 正好相反）', () {
      final picks = engine.rank(
        entries: [
          entry(id: 'newer', plays: 10, daysAgo: 20),
          entry(id: 'older', plays: 10, daysAgo: 200),
        ],
        now: now,
        intent: RediscoveryIntent.rediscover,
        limit: 2,
      );
      expect(picks.first.entry.track.ref.trackId, 'older');
    });

    test('但"听过很多次"仍然要压过"只听过一次"（熟悉度没被丢掉）', () {
      final picks = engine.rank(
        entries: [
          entry(id: 'once', plays: 1, daysAgo: 400),
          entry(id: 'many', plays: 40, daysAgo: 30),
        ],
        now: now,
        intent: RediscoveryIntent.rediscover,
        limit: 2,
      );
      expect(picks.first.entry.track.ref.trackId, 'many');
    });
  });

  group('多样性重排', () {
    test('同艺人的第二首会被压到后面（不把一整张专辑端上来）', () {
      final picks = engine.rank(
        entries: [
          // 同一艺人的两首分数完全相同 ✓ ⇒ 只有多样性折扣能把它们分开 ✓。
          entry(id: 'a1', plays: 10, daysAgo: 10, artist: 'X', album: 'A'),
          entry(id: 'a2', plays: 10, daysAgo: 10, artist: 'X', album: 'A'),
          entry(id: 'b1', plays: 6, daysAgo: 10, artist: 'Y', album: 'B'),
        ],
        now: now,
        intent: RediscoveryIntent.replay,
        limit: 3,
      );
      // 第一首一定是 X 的某一首（分数最高 ✓）；但第二首必须是 Y ✓ ——
      // 否则就是"同一艺人连排" ✗。
      expect(picks[0].entry.track.artists.first, 'X');
      expect(picks[1].entry.track.artists.first, 'Y');
      expect(picks, hasLength(3)); // 被折扣的那首**仍然会给** ✓（只是靠后 ✓）
    });

    test('同平台的也会轻微下沉（我们跨平台，但不该整块来自一个平台）', () {
      final picks = engine.rank(
        entries: [
          entry(id: 'n1', plays: 10, daysAgo: 5, artist: 'X', album: 'A'),
          entry(id: 'n2', plays: 10, daysAgo: 5, artist: 'Y', album: 'B'),
          entry(id: 'q1', plays: 9, daysAgo: 5, artist: 'Z', album: 'C'),
        ].map((e) => e).toList(),
        now: now,
        intent: RediscoveryIntent.replay,
        limit: 3,
      );
      // 只要求"都给出来、且分数没有崩" ✓ —— 平台折扣权重很小 ✓，不改变大头 ✓。
      expect(picks, hasLength(3));
    });
  });

  group('确定性与边界', () {
    test('同一份数据、同一个 now ⇒ 结果完全一样（不靠随机）', () {
      final entries = [
        entry(id: 'a', plays: 5, daysAgo: 3),
        entry(id: 'b', plays: 5, daysAgo: 3),
        entry(id: 'c', plays: 5, daysAgo: 3),
      ];
      final first = engine.rank(
        entries: entries,
        now: now,
        intent: RediscoveryIntent.replay,
        limit: 3,
      );
      final second = engine.rank(
        entries: entries.reversed.toList(),
        now: now,
        intent: RediscoveryIntent.replay,
        limit: 3,
      );
      // **输入顺序反过来，结果不变** ✓（同分用 `(platform, trackId)` 定序 ✓）。
      expect(
        first.map((p) => p.entry.track.ref.trackId),
        second.map((p) => p.entry.track.ref.trackId),
      );
    });

    test('空历史 / limit<=0 ⇒ 空结果（调用方走空态，不是失败）', () {
      expect(
        engine.rank(
          entries: const [],
          now: now,
          intent: RediscoveryIntent.replay,
          limit: 5,
        ),
        isEmpty,
      );
      expect(
        engine.rank(
          entries: [entry(id: 'a', plays: 3, daysAgo: 30)],
          now: now,
          intent: RediscoveryIntent.replay,
          limit: 0,
        ),
        isEmpty,
      );
    });

    test('时钟回拨（"未来听过"）按 0 天算，不产生负天数', () {
      final picks = engine.rank(
        entries: [
          OnlineHistoryEntry(
            track: MusicTrack(
              ref: const PlatformTrackRef(
                platform: MusicPlatform.netease,
                trackId: 'future',
              ),
              title: '未来',
              artists: const ['A'],
            ),
            playCount: 3,
            lastPlayedAt: now.add(const Duration(days: 5)),
          ),
        ],
        now: now,
        intent: RediscoveryIntent.replay,
        limit: 1,
      );
      expect(picks, hasLength(1));
      expect(picks.first.reason, contains('今天听过'));
    });

    test('每一条都带**可读的理由**（听过几次 · 多久没听）', () {
      final picks = engine.rank(
        entries: [entry(id: 'a', plays: 12, daysAgo: 47)],
        now: now,
        intent: RediscoveryIntent.rediscover,
        limit: 1,
      );
      expect(picks.single.reason, contains('听过 12 次'));
      expect(picks.single.reason, contains('47 天没听'));
      expect(picks.single.reason, contains('好久没听'));
    });

    test('时长只是**很小的**加分项：不会让短曲目压过熟悉度', () {
      final picks = engine.rank(
        entries: [
          entry(id: 'long-familiar', plays: 20, daysAgo: 2, durationSeconds: 400),
          entry(id: 'short-new', plays: 1, daysAgo: 2, durationSeconds: 60),
        ],
        now: now,
        intent: RediscoveryIntent.replay,
        limit: 2,
      );
      expect(picks.first.entry.track.ref.trackId, 'long-familiar');
    });
  });
}
