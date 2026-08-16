import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:pure_music/core/design_tokens.dart';
import 'package:pure_music/play_service/active_playback_session.dart';

class RemoteCurrentPlaylistView extends StatefulWidget {
  const RemoteCurrentPlaylistView({
    super.key,
    required this.queueSourceSwitcher,
    required this.queue,
    required this.currentIndex,
    required this.onSelect,
  });

  final Widget queueSourceSwitcher;
  final List<ActivePlaybackSessionItem> queue;
  final int? currentIndex;
  final ValueChanged<int> onSelect;

  @override
  State<RemoteCurrentPlaylistView> createState() =>
      _RemoteCurrentPlaylistViewState();
}

class _RemoteCurrentPlaylistViewState extends State<RemoteCurrentPlaylistView> {
  static const _itemExtent = 64.0;

  late final ScrollController _scrollController;

  @override
  void initState() {
    super.initState();
    _scrollController = ScrollController(
      initialScrollOffset: (widget.currentIndex ?? 0) * _itemExtent,
    );
    _scheduleCurrentItem();
  }

  @override
  void didUpdateWidget(RemoteCurrentPlaylistView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.currentIndex != widget.currentIndex) {
      _scheduleCurrentItem();
    }
  }

  void _scheduleCurrentItem() {
    final index = widget.currentIndex;
    if (index == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      final maxScroll = _scrollController.position.maxScrollExtent;
      final offset = (index * _itemExtent).clamp(0.0, maxScroll);
      if ((_scrollController.offset - offset).abs() < 1.0) return;
      _scrollController.jumpTo(offset);
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final queue = widget.queue;

    return Material(
      type: MaterialType.transparency,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(8.0, 8.0, 4.0, 8.0),
            child: Row(
              children: [
                Text(
                  '播放列表',
                  style: TextStyle(
                    color: scheme.onSecondaryContainer,
                    fontSize: AppType.hero,
                    fontWeight: AppType.weightBold,
                  ),
                ),
                const SizedBox(width: 12.0),
                Expanded(
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: widget.queueSourceSwitcher,
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: queue.isEmpty
                ? _EmptyRemotePlaylist(colorScheme: scheme)
                : ListView.builder(
                    controller: _scrollController,
                    itemCount: queue.length,
                    itemExtent: _itemExtent,
                    itemBuilder: (context, index) {
                      final item = queue[index];
                      final isCurrent = widget.currentIndex == index;
                      return _RemotePlaylistItem(
                        item: item,
                        isCurrent: isCurrent,
                        onTap: isCurrent ? null : () => widget.onSelect(index),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }
}

class _EmptyRemotePlaylist extends StatelessWidget {
  const _EmptyRemotePlaylist({required this.colorScheme});

  final ColorScheme colorScheme;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(32.0),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 280),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Symbols.queue_music,
                color: colorScheme.onSecondaryContainer.withValues(alpha: 0.62),
                size: 32,
              ),
              const SizedBox(height: 14),
              Text(
                '播放队列还是空的',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: colorScheme.onSecondaryContainer,
                  fontSize: AppType.subtitle,
                  fontWeight: AppType.weightBold,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                '选择歌曲后，它们会出现在这里。',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: colorScheme.onSecondaryContainer.withValues(
                    alpha: 0.62,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RemotePlaylistItem extends StatelessWidget {
  const _RemotePlaylistItem({
    required this.item,
    required this.isCurrent,
    required this.onTap,
  });

  final ActivePlaybackSessionItem item;
  final bool isCurrent;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final subtitle = item.album.isEmpty
        ? item.artist
        : '${item.artist} - ${item.album}';

    return InkWell(
      borderRadius: AppRadius.smCircular,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8.0),
        child: DefaultTextStyle(
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: isCurrent ? scheme.primary : scheme.onSecondaryContainer,
            fontSize: AppType.body,
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                item.title,
                style: TextStyle(
                  fontWeight: isCurrent
                      ? AppType.weightSemibold
                      : FontWeight.normal,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                subtitle,
                style: TextStyle(
                  fontSize: AppType.caption,
                  color: isCurrent
                      ? scheme.primary.withAlpha(179)
                      : scheme.onSecondaryContainer.withAlpha(179),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
