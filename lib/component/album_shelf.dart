import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:pure_music/component/horizontal_shelf.dart';
import 'package:pure_music/component/remote_media_card.dart';
import 'package:pure_music/services/music_platform/index.dart';

/// **专辑横向货架**（2026-10-16 从探索页抽取 ✓）。
///
/// 为什么抽出来：探索页的「新专辑」与**艺人页的「专辑」原本是两套自造样式** ✗ ——
/// 宽度一个是 `_cardWidth * 1.15` ✓、另一个写死 168 ✗；元信息一个有「专辑」前缀 ✓、
/// 一个没有 ✗（用户指出"模块格式还是自造" ✗）。⇒ 现在**只有这一份实现** ✓。
///
/// 约定（与探索页完全一致 ✓）：
/// - 封面宽度 = `RemoteMediaCard.widthFor(size) * 1.15` ✓（R100 起"封面整体放大 15%" ✓）；
/// - 元信息两段式 ✓：「**专辑 · 年份 · N 首**」✓（有什么写什么，不编 ✓）；
/// - 点一张打开专辑页 ✓（由调用方给 [onOpen] ✓）；
/// - 三态分开 ✓：加载 / 失败（可重试）/ 空 ✓。
class AlbumShelf extends StatelessWidget {
  const AlbumShelf({
    super.key,
    required this.albums,
    required this.onOpen,
    this.loading = false,
    this.errorMessage,
    this.onRetry,
    this.emptyMessage = '这里暂时没有专辑。',
  });

  final List<OnlineAlbumSummary> albums;
  final void Function(OnlineAlbumSummary album) onOpen;
  final bool loading;
  final String? errorMessage;
  final VoidCallback? onRetry;
  final String emptyMessage;

  @override
  Widget build(BuildContext context) {
    // 与探索页同一条取宽规则 ✓（不要各页各写一个"看起来差不多"的数 ✗）。
    final width = RemoteMediaCard.widthFor(MediaQuery.sizeOf(context)) * 1.15;
    return HorizontalShelf(
      itemCount: albums.length,
      itemWidth: width,
      itemHeight: RemoteMediaCard.extentFor(width: width, hasFooter: false),
      loading: loading,
      errorMessage: errorMessage,
      onRetry: onRetry,
      emptyMessage: emptyMessage,
      emptyIcon: Symbols.album,
      itemBuilder: (context, index) {
        final album = albums[index];
        return RemoteMediaCard(
          width: width,
          title: album.name,
          coverUri: album.coverUri,
          details: albumDetailsOf(album),
          sourceLabel: platformLabelForIdentityOnly(album.identity),
          placeholderIcon: Symbols.album,
          onTap: () => onOpen(album),
          semanticLabel:
              '${album.name}，来自${platformLabelForIdentityOnly(album.identity)}，点击打开专辑',
        );
      },
    );
  }
}

/// 专辑卡的元信息：**平台声明**的年份与曲目数（有什么说什么 ✓，不编 ✗）。
///
/// 两处共用这一份 ✓（探索页与艺人页各写一遍，迟早一处忘了加「专辑」前缀 ✗）。
String albumDetailsOf(OnlineAlbumSummary album) => [
  '专辑',
  if (album.releaseTime case final time?) '${time.year} 年',
  if (album.trackCount case final count?) '$count 首',
].join(' · ');
