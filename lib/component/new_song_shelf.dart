import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:pure_music/component/remote_media_cover.dart';
import 'package:pure_music/core/design_tokens.dart';
import 'package:pure_music/services/music_platform/index.dart';

/// **歌曲格货架**（2026-10-16 从探索页抽出来 ✓）：三栏 × 每页 4 行 + 左右翻页 ✓。
///
/// 为什么抽成公共组件：探索页的「新歌」与主页的「猜你喜欢」**必须是同一份实现** ✓ ——
/// 抄一份"看起来差不多"的，两边必然慢慢走偏 ✗（这条规矩在本仓库反复吃过亏 ✓）。
///
/// 排布依据用户的参考图 ✓：每条 = **封面 + 歌名 + 艺人 · 专辑** ✓，整行可点即播 ✓；
/// 参考在标题左边还有序号 —— 那是**榜单的名次** ✓ ⇒ 这里**不编号** ✓（不编造 ✓）。
/// 窄窗口（< 900）退回两栏 ✓，避免挤成一团 ✗；每页行数固定 ⇒ 货架高度固定 ✓。
class NewSongShelf extends StatefulWidget {
  const NewSongShelf({
    super.key,
    required this.tracks,
    required this.onPlay,
    this.rowsPerPage = 4,
  });

  final List<MusicTrack> tracks;
  final void Function(MusicTrack track) onPlay;
  final int rowsPerPage;

  @override
  State<NewSongShelf> createState() => _NewSongShelfState();
}

class _NewSongShelfState extends State<NewSongShelf> {
  static const _itemHeight = 64.0;

  final PageController _controller = PageController();
  int _page = 0;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = constraints.maxWidth < 900 ? 2 : 3;
        final perPage = columns * widget.rowsPerPage;
        final pageCount = (widget.tracks.length / perPage).ceil();
        final current = _page.clamp(0, pageCount - 1);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            // 左右翻页（参考的块头就是「更多 + ◀ ▶」✓）：只在真的还有一页时出现 ✓。
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (current > 0)
                  IconButton(
                    tooltip: '上一页',
                    onPressed: () => _controller.previousPage(
                      duration: const Duration(milliseconds: 200),
                      curve: Curves.easeOut,
                    ),
                    icon: const Icon(Symbols.chevron_left),
                  ),
                if (current < pageCount - 1)
                  IconButton(
                    tooltip: '下一页',
                    onPressed: () => _controller.nextPage(
                      duration: const Duration(milliseconds: 200),
                      curve: Curves.easeOut,
                    ),
                    icon: const Icon(Symbols.chevron_right),
                  ),
              ],
            ),
            SizedBox(
              height: widget.rowsPerPage * _itemHeight,
              child: PageView.builder(
                controller: _controller,
                onPageChanged: (value) => setState(() => _page = value),
                itemCount: pageCount,
                itemBuilder: (context, page) => Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (var column = 0; column < columns; column++) ...[
                      if (column > 0) const SizedBox(width: Spacing.md),
                      Expanded(
                        child: Column(
                          children: [
                            for (var row = 0; row < widget.rowsPerPage; row++)
                              SizedBox(
                                height: _itemHeight,
                                child:
                                    page * perPage +
                                            column * widget.rowsPerPage +
                                            row <
                                        widget.tracks.length
                                    ? _TrackShelfItem(
                                        track: widget.tracks[page * perPage +
                                            column * widget.rowsPerPage +
                                            row],
                                        onTap: () => widget.onPlay(
                                          widget.tracks[page * perPage +
                                              column * widget.rowsPerPage +
                                              row],
                                        ),
                                      )
                                    : const SizedBox.shrink(),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// 一条歌曲 item：**封面 + 歌名 + 艺人/专辑**，整行可点 ✓。
class _TrackShelfItem extends StatelessWidget {
  const _TrackShelfItem({required this.track, required this.onTap});

  final MusicTrack track;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final details = [
      track.artistDisplay,
      if (track.album.isNotEmpty) track.album,
    ].join(' · ');
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Material(
        type: MaterialType.transparency,
        borderRadius: AppRadius.smCircular,
        child: InkWell(
          borderRadius: AppRadius.smCircular,
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: Spacing.sm),
            child: Row(
              children: [
                ClipRRect(
                  borderRadius: AppRadius.xsCircular,
                  child: SizedBox.square(
                    dimension: 48,
                    child: RemoteMediaCover(
                      coverUri: track.coverUri,
                      placeholder: ColoredBox(
                        color: scheme.surfaceContainerHighest,
                        child: Icon(
                          Symbols.music_note,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                      cacheWidth: 96,
                      cacheHeight: 96,
                    ),
                  ),
                ),
                const SizedBox(width: Spacing.md),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        track.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: scheme.onSurface,
                          fontSize: AppType.caption,
                          fontWeight: AppType.weightMedium,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        details,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: scheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
