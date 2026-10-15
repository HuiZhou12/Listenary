import 'dart:math' as math;

import 'package:pure_music/services/music_platform/index.dart';
import 'package:pure_music/services/music_platform/online_library/online_library_repository.dart';

/// 这两块货架的**意图**（同一套打分，不同的取舍 ✓）。
enum RediscoveryIntent {
  /// **再听一遍**：你最近一直在听、还想接着听的（"当下循环" ✓）。
  replay,

  /// **好久没听**：你确实听过不少次，但已经很久没碰了（"重温" ✓）。
  ///
  /// ⚠️ 名字刻意**不叫「老歌」** ✗：我们手里**没有发行年份** ✗
  /// （`online_tracks.created_at` 是"我们第一次见到它"的时间 ✓，不是发行时间 ✗）
  /// ⇒ 说"90 年代的老歌"就是编数据 ✓。这里表达的是**你与它的时间间隔** ✓。
  rediscover,
}

/// 一次推荐的结果：曲目 + 为什么是它 ✓。
///
/// [reason] 是**给人看的**（语义标签 / 以后做解释用 ✓），不参与排序 ✓。
final class RediscoveryPick {
  const RediscoveryPick({
    required this.entry,
    required this.score,
    required this.reason,
  });

  final OnlineHistoryEntry entry;

  /// 打分（越大越靠前 ✓）。**只在同一次调用内可比** ✓，不跨调用比较 ✗。
  final double score;

  /// 如实说明"凭什么轮到它" ✓（例如「听过 12 次 · 47 天没听」✓）。
  final String reason;
}

/// **重温引擎**（2026-10-12 新增 ✓）：把"再听一遍 / 好久没听"做成一个**小系统** ✓，
/// 而不是从统计页的数据里直接切前 N 条 ✗。
///
/// ## 为什么不能直接切
///
/// 统计页的 `recent` 是**按时间倒序**、`topPlayed` 是**按播放次数倒序** ✓ ——
/// 这两个都是**单一维度** ✗，直接用会出现：
/// - 再听一遍：刚放过的同一张专辑连排 8 首 ✗（只听了一张专辑的副作用 ✓）；
/// - 老歌重温：把"你昨天刚听第 50 遍"的那首也算进来 ✗（它一点都不"旧" ✓）。
///
/// ## 打分（全部是**可解释的乘性因子** ✓）
///
/// 对每一首：`原始分 = 熟悉度 × 间隔因子 × 时长因子`
///
/// - **熟悉度** `log2(1 + playCount)` ✓：
///   **次线性** —— 听 4 次不是听 2 次的 2 倍 ✓（否则榜首永远是那几首 ✓）；
///   取对数也让"0 次/1 次"和"50 次"不会差出数量级 ✓。
/// - **间隔因子**（`t` = 距上次播放的天数 ✓）：
///   - [RediscoveryIntent.replay]：`exp(-t / 7)` ✓ ⇒ **越近越靠前**（半衰期约 5 天 ✓）；
///   - [RediscoveryIntent.rediscover]：`1 - exp(-t / 30)` ✓ ⇒ **越久越靠前**（约 30 天接近饱和 ✓）；
///     并加一道**硬门槛**：`t < 14 天` 的一律**不出现** ✗（那是"最近在听"，不是"好久没听" ✓）。
/// - **时长因子** `1 + 0.15 * (1 - 归一化时长)` ✓：
///   同样条件下**短一点的先来** ✓（"重温"要挑容易开始的 ✓），权重刻意很小 ✓（不喧宾夺主 ✓）。
///
/// ## 多样性重排（这是"像个系统"的地方 ✓）
///
/// 按分数从高到低**贪心**取，但每取一首就给后面**同艺人 / 同专辑**的候选**打折** ✓：
/// 同艺人 ×0.35 ✓、同专辑 ×0.5 ✓（可叠加 ✓），同平台 ×0.85 ✓（我们本来就跨平台 ✓，
/// 但不该十首全来自一个平台 ✓）。折扣是**累乘**的 ⇒ 重复越多越沉底 ✓。
///
/// ## 边界（都**如实**处理 ✓）
///
/// - 没有历史 / 空列表 ⇒ 返回空 ✓（调用方走**空态** ✓，不是失败 ✗）；
/// - 日程相同 ⇒ 结果**确定** ✓（不用随机 ✓，测试才能钉住 ✓）；
/// - 返回不足 [limit] 条是**正常的** ✓（宁可少给，也不拿不满足门槛的来凑 ✗）。
final class RediscoveryEngine {
  const RediscoveryEngine();

  /// 打分权重（集中放这里 ✓，改权重只改这一处 ✓）。
  static const double _replayHalfLifeDays = 7;
  static const double _rediscoverSaturationDays = 30;

  /// **硬门槛**：少于这个天数的，不算"好久没听" ✓（可解释 ✓：两周内听过就不叫久 ✓）。
  static const int rediscoverMinDays = 14;

  static const double _durationWeight = 0.15;

  /// 多样性折扣 ✓。
  static const double _sameArtistPenalty = 0.35;
  static const double _sameAlbumPenalty = 0.5;
  static const double _samePlatformPenalty = 0.85;

  /// 归一化时长的上限（秒 ✓）：超过它按 1 算 ✓（约 8 分钟 ✓，够覆盖绝大多数曲目 ✓）。
  static const double _durationCeilingSeconds = 480;

  /// 排序并选出前 [limit] 首 ✓。
  ///
  /// [now] 必须由调用方传入 ✓（不在内部取 `DateTime.now()` ✓）——
  /// 否则测试会跟着真实时间漂 ✓，同一份数据不同时刻结果不同 ✗。
  List<RediscoveryPick> rank({
    required List<OnlineHistoryEntry> entries,
    required DateTime now,
    required RediscoveryIntent intent,
    int limit = 12,
  }) {
    if (limit <= 0 || entries.isEmpty) return const [];

    // 1) 算原始分 ✓，同时过滤掉"不满足这次意图门槛"的 ✗。
    final scored = <_Scored>[];
    for (final entry in entries) {
      final days = _daysSince(entry.lastPlayedAt, now);
      if (intent == RediscoveryIntent.rediscover && days < rediscoverMinDays) {
        continue;
      }
      final familiarity = math.log(1 + entry.playCount) / math.ln2;
      final interval = intent == RediscoveryIntent.replay
          ? math.exp(-days / _replayHalfLifeDays)
          : 1 - math.exp(-days / _rediscoverSaturationDays);
      final durationFactor = 1 + _durationWeight * (1 - _durationRatio(entry));
      scored.add(
        _Scored(
          entry: entry,
          days: days,
          base: familiarity * interval * durationFactor,
        ),
      );
    }
    if (scored.isEmpty) return const [];
    // 分数相同时用 `(platform, trackId)` 定序 ✓ ⇒ 结果**确定** ✓（不靠输入顺序 ✓）。
    scored.sort((a, b) {
      final byScore = b.base.compareTo(a.base);
      if (byScore != 0) return byScore;
      final byPlatform = a.entry.track.ref.platform.name.compareTo(
        b.entry.track.ref.platform.name,
      );
      if (byPlatform != 0) return byPlatform;
      return a.entry.track.ref.trackId.compareTo(b.entry.track.ref.trackId);
    });

    // 2) 贪心 + 多样性折扣 ✓。
    final picked = <RediscoveryPick>[];
    final usedArtists = <String>{};
    final usedAlbums = <String>{};
    final usedPlatforms = <String>{};
    final remaining = [...scored];
    while (picked.length < limit && remaining.isNotEmpty) {
      var bestIndex = 0;
      var bestAdjusted = double.negativeInfinity;
      for (var i = 0; i < remaining.length; i++) {
        final candidate = remaining[i];
        var adjusted = candidate.base;
        if (candidate.artistKeys.any(usedArtists.contains)) {
          adjusted *= _sameArtistPenalty;
        }
        if (candidate.albumKey != null && usedAlbums.contains(candidate.albumKey)) {
          adjusted *= _sameAlbumPenalty;
        }
        if (usedPlatforms.contains(candidate.entry.track.ref.platform.name)) {
          adjusted *= _samePlatformPenalty;
        }
        if (adjusted > bestAdjusted) {
          bestAdjusted = adjusted;
          bestIndex = i;
        }
      }
      final chosen = remaining.removeAt(bestIndex);
      picked.add(
        RediscoveryPick(
          entry: chosen.entry,
          score: chosen.base,
          reason: _reason(chosen, intent),
        ),
      );
      usedArtists.addAll(chosen.artistKeys);
      if (chosen.albumKey case final albumKey?) usedAlbums.add(albumKey);
      usedPlatforms.add(chosen.entry.track.ref.platform.name);
    }
    return List.unmodifiable(picked);
  }

  /// 距上次播放的天数 ✓（负数按 0 算 ✓ —— 时钟回拨不该产生"未来听过"✗）。
  double _daysSince(DateTime lastPlayedAt, DateTime now) {
    final seconds = now.difference(lastPlayedAt).inSeconds;
    if (seconds <= 0) return 0;
    return seconds / Duration.secondsPerDay;
  }

  double _durationRatio(OnlineHistoryEntry entry) {
    final seconds = entry.track.duration.inSeconds.toDouble();
    if (seconds <= 0) return 1; // 时长未知 ⇒ 按最长算 ✓（不给它加分 ✓，但也不排除 ✓）。
    return (seconds / _durationCeilingSeconds).clamp(0.0, 1.0);
  }

  String _reason(_Scored scored, RediscoveryIntent intent) {
    final days = scored.days.round();
    final when = days <= 0 ? '今天听过' : '$days 天没听';
    final intentNote = intent == RediscoveryIntent.replay ? '最近在听' : '好久没听';
    return '听过 ${scored.entry.playCount} 次 · $when（$intentNote）';
  }

  /// 曲目的**艺人键**（无艺人信息时退回标题 ✓，避免把不相干的都算成"同一艺人"✗）。
  static Set<String> _artistKeys(MusicTrack track) {
    final names = track.artists
        .map((name) => name.trim().toLowerCase())
        .where((name) => name.isNotEmpty)
        .toSet();
    if (names.isNotEmpty) return names;
    return {track.title.trim().toLowerCase()};
  }
}

final class _Scored {
  _Scored({required this.entry, required this.days, required this.base})
    : artistKeys = RediscoveryEngine._artistKeys(entry.track),
      albumKey = entry.track.album.trim().isEmpty
          ? null
          : entry.track.album.trim().toLowerCase();

  final OnlineHistoryEntry entry;
  final double days;
  final double base;
  final Set<String> artistKeys;
  final String? albumKey;
}
