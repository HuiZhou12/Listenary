import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:pure_music/component/motion.dart';
import 'package:pure_music/component/online_track_row.dart';
import 'package:pure_music/component/personal_playlist_picker.dart';
import 'package:pure_music/core/paths.dart' as app_paths;
import 'package:pure_music/services/music_platform/index.dart';
import 'package:pure_music/services/music_platform/online_library/personal_online_playlist_controller.dart';
/// 一条**在线曲目行**：副标题组装 + 来源标记 + 收藏 + 加入歌单 + 播放中高亮 + 进场动画。
///
/// 为什么要有它：主页、探索页、搜索页、收藏页、自建歌单详情、订阅歌单详情都要同一件事，
/// 而那套组装（读收藏状态、判播放中、拼"艺人 · 专辑"、挂两个操作）此前**每个页面各抄一遍**
/// （R2 逐处清点后收敛）。
/// 抄下一遍之前先把它收敛 —— 否则"来源标记"或"不可播放判定"只要有一处走偏，就会出现
/// "同一首歌在 A 页能点、B 页点不动"。
///
/// **只做行本身**：起播、加载、分页都留给调用方，因此也适用于"新歌""榜单曲目"等场景。
///
/// **可播判据统一在这里**（2026-10-17 ✓）：见 [OnlineTrackEntry.playableOf]。
/// 页面自己算过的结论请**传进来**（`playable:`），别在这里用另一套判据再算一遍 ——
/// 那正是"同一页里行灰掉、按钮却把它算进队列"的成因。
class OnlineTrackEntry extends StatelessWidget {
  const OnlineTrackEntry({
    super.key,
    required this.track,
    required this.onTap,
    this.onRemove,
    this.animateEntrance = true,
    this.leadingIndex,
    this.playable,
  });

  /// **可播判据的唯一出口**（2026-10-17）：界面层不许再各写一份。
  ///
  /// 与 `OnlineMusicCapabilities.canPlayTrack` **逐字同义**：
  /// 「解析侧有人能处理这条曲目身份（[PlatformIdentity]）」**且**「内容平台没有明确声明
  /// 为 `paid` / `unavailable`」；`unknown` **不视为不可播**。
  ///
  /// 为什么必须共用：内容平台的 `availability` **只说明它自己放不放**，而播放解析
  /// （`stream`）是**独立能力、可以路由到别的平台** —— 这不是"多一层校验"，而是
  /// "别拿内容平台的标记去替解析侧下结论"。
  /// 两边各写一遍的下场已经出现过：同一页里"行灰掉、但「播放全部」把这首歌算进去了"。
  ///
  /// [providerCapabilities] 为 null（页面没注册在线音乐 Provider，例如组件级测试）时，
  /// 按**同一套语义**回落：只看身份有效性 + 可用状态，不看平台能力表。
  static bool playableOf({
    required MusicTrack track,
    OnlineMusicCapabilities? providerCapabilities,
  }) {
    if (providerCapabilities != null) {
      return providerCapabilities.canPlayTrack(track);
    }
    // 回落分支与 `canPlayTrack` 的形状保持一致（身份 + 可用状态，`unknown` 放行）。
    return track.ref.hasValidIdentity &&
        track.availability != TrackAvailability.unavailable &&
        track.availability != TrackAvailability.paid;
  }

  final MusicTrack track;
  /// 点这一行做什么（通常是"用当前列表起播"）。为 null 时行不可点。
  final VoidCallback? onTap;
  /// 歌单详情页用来提供"从歌单移除"；其它场景不传。
  final VoidCallback? onRemove;
  /// 是否播放列表进场动画。
  ///
  /// 可重排列表里要关掉：进场动画会和拖拽/重排动画打架。
  final bool animateEntrance;
  /// **行首序号**（可选）：只有"有排序语义"的列表（榜单/专辑）才传，
  /// 普通歌单传 null ⇒ 不显示序号（与参考产品的规则一致）。
  final int? leadingIndex;
  /// **调用方算好的可播结论**（可选）：不传则用 [playableOf] 算。
  ///
  /// 用途只有一个：让"同一页里的行 / 「播放全部」队列 / 「播放全部」按钮"三者
  /// **共用同一个结论**（页面已经算过一遍，就不该在这里用另一套判据再算一遍）。
  /// 不传时行为与既有一致 ⇒ 其余调用点不受影响。
  final bool? playable;
  @override
  Widget build(BuildContext context) {
    // 判据见 [playableOf]：与页面级「播放全部」用的是同一套语义。
    final playable =
        this.playable ??
        playableOf(
          track: track,
          providerCapabilities: context
              .read<OnlineMusicService?>()
              ?.capabilities,
        );
    final artistText = track.artistDisplay;
    final albumText = track.album;
    final details = [
      if (artistText.isNotEmpty) artistText,
      if (albumText.isNotEmpty) albumText,
    ].join(' · ');
    // 详情行**分段**（2026-10-12）：带了对应 id 的那一段才可点 ⇒ 艺人页 / 专辑页 ✓。
    // 没有 id 的段保持纯文本（不猜、不假装可点 ✓）。
    final detailParts = <({String text, VoidCallback? onTap, String? tooltip})>[
      if (artistText.isNotEmpty)
        (
          text: artistText,
          onTap: track.artistIds.isEmpty
              ? null
              : () => context.push(
                  app_paths.ONLINE_ARTIST_PAGE,
                  extra: (
                    platform: track.ref.platform,
                    artistId: track.artistIds.first,
                    name: track.artists.isEmpty ? null : track.artists.first,
                  ),
                ),
          tooltip: track.artistIds.isEmpty ? null : '查看艺人',
        ),
      if (albumText.isNotEmpty)
        (
          text: albumText,
          onTap: track.albumIds.isEmpty
              ? null
              : () => context.push(
                  app_paths.ONLINE_ALBUM_PAGE,
                  extra: (
                    platform: track.ref.platform,
                    albumId: track.albumIds.first,
                    name: albumText,
                  ),
                ),
          tooltip: track.albumIds.isEmpty ? null : '查看专辑',
        ),
    ];
    // 与既有各页一致（非空查找）：收藏状态是这一行的必要输入，页面必须提供它。
    final favorites = context.watch<PersonalOnlinePlaylistController>();
    final row = OnlineTrackRow(
      track: track,
      details: details,
      enabled: playable,
      // **读屏标签**（2026-10-12）：照参考产品的行标签格式 ✓（见 [_semanticLabelFor]）。
      semanticLabel: _semanticLabelFor(track, playable: playable),
      // 来源标签（I1）：任何在线曲目列表里都必须能看出这一行属于哪个平台。
      // **统一取曲目自己的 ref**（而不是外层分组/歌单的字段）—— 两者理论上一致，
      // 但以 ref 为准才不会出现"同一首歌在两页显示不同来源"。
      sourceLabel: platformLabelForRef(track.ref),
      onTap: playable ? onTap : null,
      onAddToPlaylist: () => showPersonalPlaylistPicker(context, track: track),
      showFavorite: true,
      favorite: favorites.isFavorite(track.ref),
      onToggleFavorite: () => favorites.toggleFavorite(track),
      onRemove: onRemove,
      isNowPlaying: isOnlineTrackNowPlaying(context, track.ref),
      leadingIndex: leadingIndex,
      // 详情行分段（艺人 / 专辑）✓；没带 id 的段由上面构造成不可点 ✓。
      detailParts: detailParts,
    );
    if (!animateEntrance) return row;
    return DirectionalListItemEntrance(identity: track.ref, child: row);
  }
}

/// 读屏标签：照参考产品的格式 `播放"<曲名> - <艺人> - <时长>"` ✓
///（不可播放时**不说"播放"** —— 读屏用户不该被告知一个点不动的按钮 ✓）。
String _semanticLabelFor(MusicTrack track, {required bool playable}) {
  final parts = <String>[
    track.title,
    if (track.artistDisplay.isNotEmpty) track.artistDisplay,
    if (track.duration != Duration.zero)
      formatOnlineTrackDuration(track.duration),
  ];
  final body = '"${parts.join(' - ')}"';
  return playable ? '播放$body' : body;
}
