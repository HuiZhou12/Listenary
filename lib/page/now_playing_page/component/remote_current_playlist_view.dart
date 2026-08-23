import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:pure_music/core/design_tokens.dart';
import 'package:pure_music/core/list_action_state.dart';
import 'package:pure_music/play_service/active_playback_session.dart';
import 'package:pure_music/play_service/remote_playback_queue.dart';

class RemoteCurrentPlaylistView extends StatefulWidget {
  const RemoteCurrentPlaylistView({
    super.key,
    required this.queueSourceSwitcher,
    required this.queue,
    required this.currentIndex,
    required this.mode,
    required this.onSelect,
    required this.onReorder,
    required this.onRemove,
    required this.onClear,
  });

  final Widget queueSourceSwitcher;
  final List<ActivePlaybackSessionItem> queue;
  final int? currentIndex;
  final RemotePlaybackMode mode;
  final ValueChanged<int> onSelect;
  final void Function(int oldIndex, int newIndex) onReorder;
  final ValueChanged<int> onRemove;
  final VoidCallback onClear;

  @override
  State<RemoteCurrentPlaylistView> createState() =>
      _RemoteCurrentPlaylistViewState();
}

class _RemoteCurrentPlaylistViewState extends State<RemoteCurrentPlaylistView> {
  static const _itemExtent = 64.0;

  late final ScrollController _scrollController;
  bool _isReordering = false;

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
    if (oldWidget.mode == RemotePlaybackMode.shuffle &&
        widget.mode != RemotePlaybackMode.shuffle) {
      _isReordering = false;
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
    final canReorder =
        hasEnoughItemsToReorder(queue.length) &&
        widget.mode != RemotePlaybackMode.shuffle;

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
                if (queue.length > 1)
                  IconButton(
                    tooltip: widget.mode == RemotePlaybackMode.shuffle
                        ? '先退出随机播放再排序'
                        : _isReordering
                        ? '完成排序'
                        : '排序',
                    icon: Icon(
                      _isReordering ? Symbols.check : Symbols.reorder,
                    ),
                    style: IconButton.styleFrom(
                      foregroundColor: _isReordering
                          ? scheme.onTertiaryContainer
                          : scheme.onSecondaryContainer,
                      disabledForegroundColor: scheme.onSecondaryContainer
                          .withValues(alpha: 0.38),
                      backgroundColor: _isReordering
                          ? scheme.tertiaryContainer
                          : null,
                    ),
                    onPressed: canReorder
                        ? () => setState(() => _isReordering = !_isReordering)
                        : null,
                  ),
                if (queue.isNotEmpty)
                  IconButton(
                    tooltip: _isReordering ? '完成排序后再清空队列' : '清空播放队列',
                    icon: const Icon(Symbols.clear_all),
                    style: IconButton.styleFrom(
                      foregroundColor: scheme.error,
                      disabledForegroundColor: scheme.onSecondaryContainer
                          .withValues(alpha: 0.38),
                    ),
                    onPressed: _isReordering ? null : widget.onClear,
                  ),
              ],
            ),
          ),
          Expanded(
            child: queue.isEmpty
                ? _EmptyRemotePlaylist(colorScheme: scheme)
                : _isReordering
                ? _buildReorderList(queue, scheme)
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
                        onRemove: () => widget.onRemove(index),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildReorderList(
    List<ActivePlaybackSessionItem> queue,
    ColorScheme scheme,
  ) {
    return ReorderableListView.builder(
      padding: const EdgeInsets.only(bottom: 8.0),
      buildDefaultDragHandles: false,
      itemCount: queue.length,
      onReorderItem: widget.onReorder,
      proxyDecorator: (child, index, animation) => Material(
        elevation: 4,
        borderRadius: AppRadius.smCircular,
        child: child,
      ),
      itemBuilder: (context, index) {
        final item = queue[index];
        final isCurrent = widget.currentIndex == index;
        return _RemoteReorderItem(
          key: ValueKey('remote_reorder_$index'),
          item: item,
          index: index,
          isCurrent: isCurrent,
          colorScheme: scheme,
        );
      },
    );
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }
}

class _RemoteReorderItem extends StatelessWidget {
  const _RemoteReorderItem({
    super.key,
    required this.item,
    required this.index,
    required this.isCurrent,
    required this.colorScheme,
  });

  final ActivePlaybackSessionItem item;
  final int index;
  final bool isCurrent;
  final ColorScheme colorScheme;

  @override
  Widget build(BuildContext context) {
    final scheme = colorScheme;
    return SizedBox(
      height: 64,
      child: Material(
        color: Colors.transparent,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4.0),
          child: Row(
            children: [
              ReorderableDragStartListener(
                index: index,
                child: Padding(
                  padding: const EdgeInsets.all(8.0),
                  child: Icon(
                    Symbols.drag_indicator,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
              const SizedBox(width: 4.0),
              Expanded(
                child: DefaultTextStyle(
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: isCurrent
                        ? scheme.primary
                        : scheme.onSecondaryContainer,
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
                        item.artist,
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
            ],
          ),
        ),
      ),
    );
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

class _RemotePlaylistItem extends StatefulWidget {
  const _RemotePlaylistItem({
    required this.item,
    required this.isCurrent,
    required this.onTap,
    required this.onRemove,
  });

  final ActivePlaybackSessionItem item;
  final bool isCurrent;
  final VoidCallback? onTap;
  final VoidCallback onRemove;

  @override
  State<_RemotePlaylistItem> createState() => _RemotePlaylistItemState();
}

class _RemotePlaylistItemState extends State<_RemotePlaylistItem> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final subtitle = widget.item.album.isEmpty
        ? widget.item.artist
        : '${widget.item.artist} - ${widget.item.album}';

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: InkWell(
        borderRadius: AppRadius.smCircular,
        onTap: widget.onTap,
        child: Padding(
          padding: const EdgeInsets.only(left: 8.0, right: 2.0),
          child: DefaultTextStyle(
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: widget.isCurrent
                  ? scheme.primary
                  : scheme.onSecondaryContainer,
              fontSize: AppType.body,
            ),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.item.title,
                        style: TextStyle(
                          fontWeight: widget.isCurrent
                              ? AppType.weightSemibold
                              : FontWeight.normal,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        style: TextStyle(
                          fontSize: AppType.caption,
                          color: widget.isCurrent
                              ? scheme.primary.withAlpha(179)
                              : scheme.onSecondaryContainer.withAlpha(179),
                        ),
                      ),
                    ],
                  ),
                ),
                // 移除按钮：悬停时显示，与本地队列一致。
                AnimatedOpacity(
                  opacity: _hovered ? 1.0 : 0.0,
                  duration: const Duration(milliseconds: 120),
                  child: IgnorePointer(
                    ignoring: !_hovered,
                    child: IconButton(
                      tooltip: '从队列移除',
                      onPressed: widget.onRemove,
                      icon: Icon(
                        Symbols.remove_circle_outline,
                        size: 20,
                        color: scheme.onSecondaryContainer.withAlpha(153),
                      ),
                      visualDensity: VisualDensity.compact,
                    ),
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
