import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:pure_music/component/motion.dart';
import 'package:pure_music/component/online_track_row.dart';
import 'package:pure_music/component/personal_playlist_picker.dart';
import 'package:pure_music/core/preference.dart';
import 'package:pure_music/services/music_platform/index.dart';
import 'package:pure_music/services/music_platform/provider/online_music_provider_settings.dart';
import 'package:pure_music/services/music_platform/online_library/personal_online_playlist_controller.dart';

/// 一条**在线曲目行**：副标题组装 + 来源标记 + 收藏 + 加入歌单 + 播放中高亮 + 进场动画。
///
/// 为什么要有它：主页、探索页、搜索页、收藏页、自建歌单详情、订阅歌单详情都要同一件事，
/// 而那套组装（读收藏状态、判播放中、拼"艺人 · 专辑"、挂两个操作）此前**每个页面各抄一遍**
/// （R2 逐处清点后收敛，见 `docs/history/home-explore-r2-report.md`）。
/// 抄下一遍之前先把它收敛 —— 否则"来源标记"或"不可播放判定"只要有一处走偏，就会出现
/// "同一首歌在 A 页能点、B 页点不动"。
///
/// **只做行本身**：起播、加载、分页都留给调用方，因此也适用于"新歌""榜单曲目"等场景。
class OnlineTrackEntry extends StatelessWidget {
  const OnlineTrackEntry({
    super.key,
    required this.track,
    required this.onTap,
    this.onRemove,
    this.animateEntrance = true,
  });

  final MusicTrack track;

  /// 点这一行做什么（通常是"用当前列表起播"）。为 null 时行不可点。
  final VoidCallback? onTap;

  /// 歌单详情页用来提供"从歌单移除"；其它场景不传。
  final VoidCallback? onRemove;

  /// 是否播放列表进场动画。
  ///
  /// 可重排列表里要关掉：进场动画会和拖拽/重排动画打架。
  final bool animateEntrance;

  @override
  Widget build(BuildContext context) {
    // 与既有各页一致的判定：明确标为"不可用/付费"的曲目不给点。
    // P-63：可用性判据加**平台身份**维度 —— 身份无效（自定义平台缺稳定 ID）不可播；
    // 既有 unavailable/paid 语义保留，只呈现状态、不改数据。
    final playable =
        track.ref.hasValidIdentity &&
        track.availability != TrackAvailability.unavailable &&
        track.availability != TrackAvailability.paid;
    final details = [
      if (track.artistDisplay.isNotEmpty) track.artistDisplay,
      if (track.album.isNotEmpty) track.album,
    ].join(' · ');
    // 与既有各页一致（非空查找）：收藏状态是这一行的必要输入，页面必须提供它。
    final favorites = context.watch<PersonalOnlinePlaylistController>();
    final row = OnlineTrackRow(
      track: track,
      details: details,
      enabled: playable,
      // 来源标签（I1）：任何在线曲目列表里都必须能看出这一行属于哪个平台。
      // **统一取曲目自己的 ref**（而不是外层分组/歌单的字段）—— 两者理论上一致，
      // 但以 ref 为准才不会出现"同一首歌在两页显示不同来源"。
      sourceLabel: platformLabelForIdentity(AppPreference.instance.onlineMusicSettings, track.ref.identity),
      onTap: playable ? onTap : null,
      onAddToPlaylist: () => showPersonalPlaylistPicker(context, track: track),
      showFavorite: true,
      favorite: favorites.isFavorite(track.ref),
      onToggleFavorite: () => favorites.toggleFavorite(track),
      onRemove: onRemove,
      isNowPlaying: isOnlineTrackNowPlaying(context, track.ref),
    );
    if (!animateEntrance) return row;
    return DirectionalListItemEntrance(identity: track.ref, child: row);
  }
}
