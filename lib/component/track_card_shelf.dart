import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:pure_music/component/horizontal_shelf.dart';
import 'package:pure_music/component/remote_media_card.dart';
import 'package:pure_music/component/shelf_geometry.dart';
import 'package:pure_music/services/music_platform/index.dart';

/// **歌曲横向货架**（2026-10-17 从艺人页抽出来 ✓）。
///
/// 为什么与 [AlbumShelf] **并列**而不是塞进它：那个组件的名字与语义都是"专辑"
/// （元信息是「专辑 · 年份 · N 首」），把歌塞进去会让"一个组件管两种内容形状"。
/// 两者的**共同点只是几何**，所以宽/高统一走 [ShelfGeometry] ✓ —— 不各写一份 ✓。
///
/// 约定：
/// - 封面宽度 = [ShelfGeometry.cardWidth] ✓、高度 = [ShelfGeometry.cardExtent] ✓；
/// - 元信息沿用既有曲目行的拼法「**艺人 · 专辑**」（有什么写什么，不编 ✓）；
/// - 点一行即播（由调用方给 [onPlay] ✓）；
/// - 三态分开 ✓：加载 / 失败（可重试）/ 空 ✓。
class TrackCardShelf extends StatelessWidget {
  const TrackCardShelf({
    super.key,
    required this.tracks,
    required this.onPlay,
    this.loading = false,
    this.errorMessage,
    this.onRetry,
    this.emptyMessage = '这里暂时没有曲目。',
  });

  final List<MusicTrack> tracks;
  final void Function(MusicTrack track) onPlay;
  final bool loading;
  final String? errorMessage;
  final VoidCallback? onRetry;
  final String emptyMessage;

  /// 曲目卡的元信息：**艺人 · 专辑**（与曲目行的副标题同一条拼法 ✓）。
  ///
  /// 缺哪段就不写哪段 —— 与 `albumDetailsOf` 同一条纪律：只写平台给的事实 ✓。
  static String detailsOf(MusicTrack track) => [
    if (track.artistDisplay.isNotEmpty) track.artistDisplay,
    if (track.album.isNotEmpty) track.album,
  ].join(' · ');

  @override
  Widget build(BuildContext context) {
    final width = ShelfGeometry.cardWidth(context);
    return HorizontalShelf(
      itemCount: tracks.length,
      itemWidth: width,
      itemHeight: ShelfGeometry.cardExtent(width: width),
      loading: loading,
      errorMessage: errorMessage,
      onRetry: onRetry,
      emptyMessage: emptyMessage,
      emptyIcon: Symbols.music_note,
      itemBuilder: (context, index) {
        final track = tracks[index];
        final source = platformLabelForIdentityOnly(track.ref.identity);
        return RemoteMediaCard(
          width: width,
          title: track.title,
          coverUri: track.coverUri,
          details: detailsOf(track),
          sourceLabel: source,
          placeholderIcon: Symbols.music_note,
          onTap: () => onPlay(track),
          semanticLabel: '播放"${track.title} - ${track.artistDisplay}"，来自$source',
        );
      },
    );
  }
}
