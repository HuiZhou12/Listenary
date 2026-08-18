import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';
import 'package:pure_music/component/motion.dart';
import 'package:pure_music/component/online_search_launcher.dart';
import 'package:pure_music/component/quiet_empty_state.dart';
import 'package:pure_music/component/remote_media_cover.dart';
import 'package:pure_music/core/design_tokens.dart';
import 'package:pure_music/core/utils.dart';
import 'package:pure_music/page/stats_page/stats_components.dart';
import 'package:pure_music/services/music_platform/online_library/online_history_controller.dart';
import 'package:pure_music/services/music_platform/online_library/online_library_repository.dart';

class OnlineHistoryStatsView extends StatefulWidget {
  const OnlineHistoryStatsView({super.key});

  @override
  State<OnlineHistoryStatsView> createState() => _OnlineHistoryStatsViewState();
}

class _OnlineHistoryStatsViewState extends State<OnlineHistoryStatsView> {
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

    final entries = snapshot.topPlayed;
    final artists = _buildTopArtists(entries);
    final maxPlays = entries.isEmpty ? 0 : entries.first.playCount;
    return CustomScrollView(
      slivers: [
        if (snapshot.status == OnlineHistoryLoadStatus.loading)
          const SliverToBoxAdapter(
            child: LinearProgressIndicator(minHeight: 2),
          ),
        if (snapshot.status == OnlineHistoryLoadStatus.failed)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.only(bottom: Spacing.xs),
              child: Text(
                '刷新失败，显示上次结果',
                style: TextStyle(
                  color: scheme.error,
                  fontSize: AppType.caption,
                ),
              ),
            ),
          ),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(
            Spacing.sm,
            Spacing.sm,
            Spacing.sm,
            0,
          ),
          sliver: SliverToBoxAdapter(
            child: _OnlineHistoryOverview(snapshot: snapshot),
          ),
        ),
        if (artists.isNotEmpty)
          SliverToBoxAdapter(
            child: _OnlineArtistSection(artists: artists),
          ),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              Spacing.sm,
              Spacing.xl,
              Spacing.sm,
              Spacing.md,
            ),
            child: Row(
              children: [
                Text(
                  '最常播放',
                  style: TextStyle(
                    fontSize: AppType.sectionTitle,
                    fontWeight: AppType.weightSemibold,
                    color: scheme.onSurface,
                  ),
                ),
                const Spacer(),
                Text(
                  '${entries.length} 首曲目',
                  style: TextStyle(
                    fontSize: AppType.caption,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(width: Spacing.sm),
                IconButton(
                  tooltip: '清空在线播放历史',
                  onPressed:
                      snapshot.status == OnlineHistoryLoadStatus.loading
                      ? null
                      : () => _confirmClear(context, controller),
                  icon: const Icon(Symbols.delete_sweep),
                ),
              ],
            ),
          ),
        ),
        if (entries.isEmpty)
          const SliverToBoxAdapter(
            child: QuietEmptyState(
              icon: Symbols.bar_chart,
              title: '暂无播放排行',
              message: '成功播放在线歌曲后，这里会出现排行。',
            ),
          )
        else
          SliverList.builder(
            itemCount: entries.length,
            itemBuilder: (context, index) => DirectionalListItemEntrance(
              identity: entries[index].track.ref,
              child: _OnlineHistoryRow(
                entry: entries[index],
                index: index,
                maxPlays: maxPlays,
                onTap: () => playOnlineHistoryEntry(
                  context,
                  entries: entries,
                  selectedRef: entries[index].track.ref,
                ),
              ),
            ),
          ),
        const SliverToBoxAdapter(
          child: SizedBox(height: Spacing.bottomNav),
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
    final tracks = snapshot.recent;
    final artists = <String>{};
    final albums = <String>{};
    var duration = 0;
    for (final entry in tracks) {
      artists.addAll(entry.track.artists.where((artist) => artist.isNotEmpty));
      if (entry.track.album.isNotEmpty) albums.add(entry.track.album);
      duration += entry.track.duration.inSeconds;
    }
    return Container(
      padding: const EdgeInsets.all(Spacing.md),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: AppRadius.smCircular,
        border: Border.all(
          color: scheme.outlineVariant.withValues(alpha: 0.45),
        ),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final columns = constraints.maxWidth >= 1000
              ? 4
              : constraints.maxWidth >= 520
              ? 2
              : 1;
          final width =
              (constraints.maxWidth - (columns - 1) * Spacing.sm) / columns;
          return Wrap(
            spacing: Spacing.sm,
            runSpacing: Spacing.sm,
            children: [
              _metric(
                scheme,
                width: width,
                icon: Symbols.play_arrow,
                color: scheme.primary,
                label: '累计播放',
                value: _formatCount(snapshot.totalPlayCount),
              ),
              _metric(
                scheme,
                width: width,
                icon: Symbols.library_music,
                color: scheme.tertiary,
                label: '听过的曲目',
                value: snapshot.trackCount.toString(),
              ),
              _metric(
                scheme,
                width: width,
                icon: Symbols.album,
                color: scheme.secondary,
                label: '艺术家 / 专辑',
                value: '${artists.length} / ${albums.length}',
              ),
              _metric(
                scheme,
                width: width,
                icon: Symbols.schedule,
                color: scheme.onSurfaceVariant,
                label: '曲目总时长',
                value: _formatDuration(duration),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _metric(
    ColorScheme scheme, {
    required double width,
    required IconData icon,
    required Color color,
    required String label,
    required String value,
  }) {
    return SizedBox(
      width: width,
      height: 68,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: Spacing.sm),
        child: Row(
          children: [
            StatsMetricIcon(icon: icon, color: color),
            const SizedBox(width: Spacing.md),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    value,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: scheme.onSurface,
                      fontSize: AppType.pageTitle,
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
        ),
      ),
    );
  }
}

class _OnlineHistoryRow extends StatelessWidget {
  const _OnlineHistoryRow({
    required this.entry,
    required this.index,
    required this.maxPlays,
    required this.onTap,
  });

  final OnlineHistoryEntry entry;
  final int index;
  final int maxPlays;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final track = entry.track;
    final fraction = maxPlays > 0 ? entry.playCount / maxPlays : 0.0;
    final showAlbum = MediaQuery.sizeOf(context).width >= 760;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Spacing.sm, vertical: 2),
      child: SizedBox(
        height: 64,
        child: Material(
          type: MaterialType.transparency,
          borderRadius: AppRadius.smCircular,
          child: InkWell(
            onTap: onTap,
            hoverColor: scheme.onSurface.withValues(alpha: Alpha.hover),
            borderRadius: AppRadius.smCircular,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: Spacing.sm),
              child: Row(
                children: [
                  SizedBox(
                    width: 36,
                    child: Text(
                      '${index + 1}',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: AppType.caption,
                        fontWeight: index < 3
                            ? AppType.weightBold
                            : AppType.weightRegular,
                        color: index < 3
                            ? scheme.primary
                            : scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  _OnlineHistoryCover(coverUri: track.coverUri),
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
                            fontSize: AppType.subtitle,
                            fontWeight: AppType.weightMedium,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          track.artistDisplay,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: scheme.onSurfaceVariant),
                        ),
                      ],
                    ),
                  ),
                  if (showAlbum && track.album.isNotEmpty) ...[
                    const SizedBox(width: Spacing.lg),
                    SizedBox(
                      width: 180,
                      child: Text(
                        track.album,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: scheme.onSurfaceVariant),
                      ),
                    ),
                  ],
                  const SizedBox(width: Spacing.lg),
                  SizedBox(
                    width: 84,
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text(
                          '${_formatCount(entry.playCount)} 次',
                          style: TextStyle(
                            color: scheme.primary,
                            fontSize: AppType.body,
                            fontWeight: AppType.weightSemibold,
                          ),
                        ),
                        const SizedBox(height: 6),
                        ClipRRect(
                          borderRadius: AppRadius.xsCircular,
                          child: LinearProgressIndicator(
                            value: fraction,
                            minHeight: 3,
                            backgroundColor: scheme.primaryContainer.withValues(
                              alpha: 0.3,
                            ),
                            valueColor: AlwaysStoppedAnimation<Color>(
                              scheme.primary.withValues(alpha: 0.68),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
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
      borderRadius: AppRadius.smCircular,
      child: SizedBox.square(
        dimension: 48,
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

class _OnlineArtistSection extends StatelessWidget {
  const _OnlineArtistSection({required this.artists});

  final List<_OnlineArtistPlayStat> artists;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final maxPlays = artists.first.playCount;
    return Padding(
      padding: const EdgeInsets.fromLTRB(Spacing.sm, Spacing.xl, Spacing.sm, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '常听艺术家',
            style: TextStyle(
              fontSize: AppType.sectionTitle,
              fontWeight: AppType.weightSemibold,
              color: scheme.onSurface,
            ),
          ),
          const SizedBox(height: Spacing.md),
          LayoutBuilder(
            builder: (context, constraints) {
              final columns = constraints.maxWidth >= 980
                  ? 3
                  : constraints.maxWidth >= 560
                  ? 2
                  : 1;
              final width =
                  (constraints.maxWidth - (columns - 1) * Spacing.lg) / columns;
              return Wrap(
                spacing: Spacing.lg,
                runSpacing: Spacing.md,
                children: [
                  for (var i = 0; i < artists.length; i++)
                    SizedBox(
                      width: width,
                      child: _OnlineArtistStat(
                        artist: artists[i],
                        rank: i + 1,
                        maxPlays: maxPlays,
                      ),
                    ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

class _OnlineArtistStat extends StatelessWidget {
  const _OnlineArtistStat({
    required this.artist,
    required this.rank,
    required this.maxPlays,
  });

  final _OnlineArtistPlayStat artist;
  final int rank;
  final int maxPlays;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final fraction = maxPlays > 0 ? artist.playCount / maxPlays : 0.0;
    return Row(
      children: [
        SizedBox(
          width: 28,
          child: Text(
            rank.toString().padLeft(2, '0'),
            style: TextStyle(
              fontSize: AppType.caption,
              fontWeight: AppType.weightSemibold,
              color: rank <= 3 ? scheme.tertiary : scheme.onSurfaceVariant,
            ),
          ),
        ),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      artist.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: AppType.body,
                        fontWeight: AppType.weightMedium,
                        color: scheme.onSurface,
                      ),
                    ),
                  ),
                  const SizedBox(width: Spacing.sm),
                  Text(
                    '${_formatCount(artist.playCount)} 次',
                    style: TextStyle(
                      fontSize: AppType.caption,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              ClipRRect(
                borderRadius: AppRadius.xsCircular,
                child: LinearProgressIndicator(
                  value: fraction,
                  minHeight: 3,
                  backgroundColor: scheme.surfaceContainerHighest.withValues(
                    alpha: 0.5,
                  ),
                  valueColor: AlwaysStoppedAnimation<Color>(
                    scheme.tertiary.withValues(alpha: 0.72),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _OnlineArtistPlayStat {
  const _OnlineArtistPlayStat(this.name, this.playCount);

  final String name;
  final int playCount;
}

List<_OnlineArtistPlayStat> _buildTopArtists(
  List<OnlineHistoryEntry> entries,
) {
  final counts = <String, int>{};
  for (final entry in entries) {
    for (final artist in entry.track.artists) {
      final name = artist.trim();
      if (name.isEmpty) continue;
      counts.update(
        name,
        (value) => value + entry.playCount,
        ifAbsent: () => entry.playCount,
      );
    }
  }
  final result =
      counts.entries
          .map((entry) => _OnlineArtistPlayStat(entry.key, entry.value))
          .toList()
        ..sort((a, b) {
          final byCount = b.playCount.compareTo(a.playCount);
          return byCount != 0 ? byCount : a.name.compareTo(b.name);
        });
  return result.take(6).toList(growable: false);
}

String _formatCount(int value) {
  if (value >= 10000) {
    return '${(value / 10000).toStringAsFixed(1)} 万'.replaceFirst('.0', '');
  }
  if (value >= 1000) {
    return '${(value / 1000).toStringAsFixed(1)} 千'.replaceFirst('.0', '');
  }
  return value.toString();
}

String _formatDuration(int seconds) {
  if (seconds <= 0) return '0 分钟';
  final totalMinutes = seconds ~/ 60;
  final days = totalMinutes ~/ (24 * 60);
  final hours = totalMinutes.remainder(24 * 60) ~/ 60;
  final minutes = totalMinutes.remainder(60);
  if (days > 0) return '$days 天 $hours 小时';
  if (hours > 0) return '$hours 小时 $minutes 分钟';
  return '$minutes 分钟';
}
