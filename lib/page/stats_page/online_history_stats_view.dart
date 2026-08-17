import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';
import 'package:pure_music/component/online_search_launcher.dart';
import 'package:pure_music/component/quiet_empty_state.dart';
import 'package:pure_music/component/remote_media_cover.dart';
import 'package:pure_music/core/design_tokens.dart';
import 'package:pure_music/core/utils.dart';
import 'package:pure_music/services/music_platform/online_library/online_history_controller.dart';
import 'package:pure_music/services/music_platform/online_library/online_library_repository.dart';

enum _OnlineHistoryMode { recent, topPlayed }

class OnlineHistoryStatsView extends StatefulWidget {
  const OnlineHistoryStatsView({super.key});

  @override
  State<OnlineHistoryStatsView> createState() => _OnlineHistoryStatsViewState();
}

class _OnlineHistoryStatsViewState extends State<OnlineHistoryStatsView> {
  _OnlineHistoryMode _mode = _OnlineHistoryMode.recent;
  bool _initialLoadRequested = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_initialLoadRequested) return;
    _initialLoadRequested = true;
    final controller = context.read<OnlineHistoryController>();
    if (controller.snapshot.status == OnlineHistoryLoadStatus.idle) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted &&
            controller.snapshot.status == OnlineHistoryLoadStatus.idle) {
          unawaited(controller.refresh());
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<OnlineHistoryController>();
    final snapshot = controller.snapshot;
    final scheme = Theme.of(context).colorScheme;
    if (snapshot.status == OnlineHistoryLoadStatus.loading &&
        !snapshot.hasData) {
      return const Center(child: CircularProgressIndicator());
    }
    if (snapshot.status == OnlineHistoryLoadStatus.failed &&
        !snapshot.hasData) {
      return QuietEmptyState(
        icon: Symbols.sync_problem,
        title: '在线播放历史读取失败',
        message: '请稍后重试。',
        action: FilledButton.icon(
          onPressed: controller.refresh,
          icon: const Icon(Symbols.refresh),
          label: const Text('重试'),
        ),
      );
    }
    if (!snapshot.hasData) {
      return const QuietEmptyState(
        icon: Symbols.history,
        title: '暂无在线播放历史',
        message: '成功播放在线歌曲后，这里会保留安全的歌曲信息。',
      );
    }

    final entries = _mode == _OnlineHistoryMode.recent
        ? snapshot.recent
        : snapshot.topPlayed;
    return Column(
      children: [
        if (snapshot.status == OnlineHistoryLoadStatus.loading)
          const LinearProgressIndicator(minHeight: 2),
        if (snapshot.status == OnlineHistoryLoadStatus.failed)
          Padding(
            padding: const EdgeInsets.only(bottom: Spacing.xs),
            child: Text(
              '刷新失败，显示上次结果',
              style: TextStyle(color: scheme.error, fontSize: AppType.caption),
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(
            Spacing.sm,
            Spacing.sm,
            Spacing.sm,
            0,
          ),
          child: _OnlineHistoryOverview(snapshot: snapshot),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: Spacing.sm,
            vertical: Spacing.md,
          ),
          child: Row(
            children: [
              SegmentedButton<_OnlineHistoryMode>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(
                    value: _OnlineHistoryMode.recent,
                    label: Text('最近播放'),
                  ),
                  ButtonSegment(
                    value: _OnlineHistoryMode.topPlayed,
                    label: Text('最常播放'),
                  ),
                ],
                selected: {_mode},
                onSelectionChanged: (selection) {
                  setState(() => _mode = selection.single);
                },
              ),
              const Spacer(),
              IconButton(
                tooltip: '清空在线播放历史',
                onPressed: snapshot.status == OnlineHistoryLoadStatus.loading
                    ? null
                    : () => _confirmClear(context, controller),
                icon: const Icon(Symbols.delete_sweep),
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView.separated(
            padding: const EdgeInsets.only(bottom: Spacing.bottomNav),
            itemCount: entries.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (context, index) => _OnlineHistoryRow(
              entry: entries[index],
              mode: _mode,
              onTap: () => playOnlineHistoryEntry(
                context,
                entries: entries,
                selectedRef: entries[index].track.ref,
              ),
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _confirmClear(
    BuildContext context,
    OnlineHistoryController controller,
  ) async {
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('清空在线播放历史？'),
        content: const Text('这会清除历史和统计，但不会删除任何在线歌单。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const ValueKey('confirm-clear-online-history'),
            onPressed: () async {
              try {
                await controller.clearHistory();
                if (dialogContext.mounted) Navigator.of(dialogContext).pop();
              } catch (_) {
                showTextOnSnackBar('无法清空在线播放历史', variant: ToastVariant.error);
              }
            },
            child: const Text('清空'),
          ),
        ],
      ),
    );
  }
}

class _OnlineHistoryOverview extends StatelessWidget {
  const _OnlineHistoryOverview({required this.snapshot});

  final OnlineHistoryViewSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(Spacing.md),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: AppRadius.smCircular,
        border: Border.all(
          color: scheme.outlineVariant.withValues(alpha: 0.45),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: _metric(
              scheme,
              icon: Symbols.play_arrow,
              label: '累计播放',
              value: snapshot.totalPlayCount.toString(),
            ),
          ),
          SizedBox(
            height: 40,
            child: VerticalDivider(color: scheme.outlineVariant),
          ),
          Expanded(
            child: _metric(
              scheme,
              icon: Symbols.library_music,
              label: '听过的曲目',
              value: snapshot.trackCount.toString(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _metric(
    ColorScheme scheme, {
    required IconData icon,
    required String label,
    required String value,
  }) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(icon, color: scheme.primary),
        const SizedBox(width: Spacing.sm),
        Flexible(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                value,
                style: TextStyle(
                  color: scheme.onSurface,
                  fontSize: AppType.sectionTitle,
                  fontWeight: AppType.weightSemibold,
                ),
              ),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: scheme.onSurfaceVariant,
                  fontSize: AppType.caption,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _OnlineHistoryRow extends StatelessWidget {
  const _OnlineHistoryRow({
    required this.entry,
    required this.mode,
    required this.onTap,
  });

  final OnlineHistoryEntry entry;
  final _OnlineHistoryMode mode;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final track = entry.track;
    final details = [
      if (track.artistDisplay.isNotEmpty) track.artistDisplay,
      if (track.album.isNotEmpty) track.album,
    ].join(' · ');
    return ListTile(
      minTileHeight: 64,
      leading: _OnlineHistoryCover(coverUri: track.coverUri),
      title: Text(track.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: details.isEmpty
          ? null
          : Text(details, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: Text(
        mode == _OnlineHistoryMode.recent
            ? _formatPlayedAt(entry.lastPlayedAt)
            : '${entry.playCount} 次',
        style: TextStyle(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
          fontSize: AppType.caption,
        ),
      ),
      onTap: onTap,
    );
  }
}

class _OnlineHistoryCover extends StatelessWidget {
  const _OnlineHistoryCover({required this.coverUri});

  final Uri? coverUri;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final placeholder = ColoredBox(
      color: scheme.surfaceContainerHighest,
      child: Icon(Symbols.music_note, color: scheme.onSurfaceVariant, size: 20),
    );
    return ClipRRect(
      borderRadius: AppRadius.xsCircular,
      child: SizedBox.square(
        dimension: 44,
        child: RemoteMediaCover(
          coverUri: coverUri,
          placeholder: placeholder,
          cacheWidth: 96,
          cacheHeight: 96,
        ),
      ),
    );
  }
}

String _formatPlayedAt(DateTime value) {
  final local = value.toLocal();
  String twoDigits(int number) => number.toString().padLeft(2, '0');
  return '${local.month}/${local.day} '
      '${twoDigits(local.hour)}:${twoDigits(local.minute)}';
}
