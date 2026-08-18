import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';
import 'package:pure_music/component/online_search_launcher.dart';
import 'package:pure_music/component/online_track_row.dart';
import 'package:pure_music/component/quiet_empty_state.dart';
import 'package:pure_music/component/remote_media_cover.dart';
import 'package:pure_music/component/motion.dart';
import 'package:pure_music/core/design_tokens.dart';
import 'package:pure_music/page/page_scaffold.dart';
import 'package:pure_music/services/music_platform/models/music_models.dart';
import 'package:pure_music/services/music_platform/online_library/online_library_repository.dart';
import 'package:pure_music/services/music_platform/online_library/online_playlist_controller.dart';

class OnlinePlaylistDetailPage extends StatefulWidget {
  const OnlinePlaylistDetailPage({super.key, required this.localId});

  final int localId;

  @override
  State<OnlinePlaylistDetailPage> createState() =>
      _OnlinePlaylistDetailPageState();
}

class _OnlinePlaylistDetailPageState extends State<OnlinePlaylistDetailPage> {
  OnlinePlaylistSnapshot? _snapshot;
  String? _error;
  bool _loading = true;
  int _loadRequest = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final request = ++_loadRequest;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final snapshot = await context
          .read<OnlinePlaylistController>()
          .readSnapshot(widget.localId);
      if (!mounted || request != _loadRequest) return;
      setState(() {
        _snapshot = snapshot;
        _loading = false;
        _error = snapshot == null ? '在线歌单不存在或已被删除' : null;
      });
    } catch (_) {
      if (!mounted || request != _loadRequest) return;
      setState(() {
        _loading = false;
        _error = '无法读取在线歌单';
      });
    }
  }

  Future<void> _play(MusicTrack track) async {
    final selection = await context
        .read<OnlinePlaylistController>()
        .playbackSelection(localId: widget.localId, selectedRef: track.ref);
    if (!mounted || selection == null) return;
    await playOnlineTrackSelection(
      context,
      OnlineTrackSelection(
        tracks: selection.tracks,
        selectedIndex: selection.selectedIndex,
      ),
    );
  }

  Future<void> _playRandom(Iterable<MusicTrack> tracks) async {
    final playable = tracks
        .where(
          (track) =>
              track.availability != TrackAvailability.unavailable &&
              track.availability != TrackAvailability.paid,
        )
        .toList(growable: false);
    if (playable.isEmpty) return;
    await _play(playable[math.Random().nextInt(playable.length)]);
  }

  @override
  Widget build(BuildContext context) {
    final snapshot = _snapshot;
    if (snapshot != null && _error == null) {
      return _buildLoadedPage(snapshot);
    }
    return PageScaffold(
      title: snapshot?.playlist.name ?? '在线歌单',
      subtitle: snapshot == null
          ? null
          : '${snapshot.playlist.trackCount ?? snapshot.playlist.tracks.length} 首歌曲 · 网易订阅',
      actions: [
        IconButton.filledTonal(
          tooltip: '刷新',
          onPressed: _loading ? null : _load,
          icon: const Icon(Symbols.refresh),
        ),
      ],
      body: _buildStatusBody(snapshot),
    );
  }

  Widget _buildStatusBody(OnlinePlaylistSnapshot? snapshot) {
    if (_loading) {
      return const Center(
        child: SizedBox.square(
          dimension: 24,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    if (_error != null || snapshot == null) {
      return QuietEmptyState(
        icon: Symbols.cloud_off,
        title: '在线歌单读取失败',
        message: _error ?? '无法读取在线歌单',
        action: FilledButton.tonalIcon(
          onPressed: _load,
          icon: const Icon(Symbols.refresh),
          label: const Text('重试'),
        ),
      );
    }
    return _buildLoadedPage(snapshot);
  }

  Widget _buildLoadedPage(OnlinePlaylistSnapshot snapshot) {
    final scheme = Theme.of(context).colorScheme;
    final tracks = snapshot.playlist.tracks;
    return ColoredBox(
      color: scheme.surfaceContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            _buildHeader(snapshot),
            const SizedBox(height: 16),
            Expanded(
              child: tracks.isEmpty
                  ? const QuietEmptyState(
                      icon: Symbols.music_off,
                      title: '歌单没有可用曲目',
                      message: '刷新后会重新读取第三方平台的完整快照。',
                    )
                  : Material(
                      type: MaterialType.transparency,
                      borderRadius: AppRadius.smCircular,
                      child: ListView.builder(
                        padding: const EdgeInsets.only(bottom: 96),
                        itemCount: tracks.length,
                        itemBuilder: (context, index) =>
                            _buildTrackRow(tracks[index]),
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTrackRow(MusicTrack track) {
    final playable =
        track.availability != TrackAvailability.unavailable &&
        track.availability != TrackAvailability.paid;
    final details = [
      if (track.artistDisplay.isNotEmpty) track.artistDisplay,
      if (track.album.isNotEmpty) track.album,
    ].join(' · ');
    return DirectionalListItemEntrance(
      identity: track.ref,
      child: OnlineTrackRow(
        track: track,
        details: details,
        enabled: playable,
        onTap: playable ? () => _play(track) : null,
      ),
    );
  }

  Widget _buildHeader(OnlinePlaylistSnapshot snapshot) {
    final scheme = Theme.of(context).colorScheme;
    final playable = snapshot.playlist.tracks.where(
      (track) =>
          track.availability != TrackAvailability.unavailable &&
          track.availability != TrackAvailability.paid,
    );
    final hasPlayableTracks = playable.isNotEmpty;
    final creator = snapshot.playlist.creator?.trim();
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact =
            constraints.maxWidth.isFinite && constraints.maxWidth < 560;
        final coverSize = compact ? 156.0 : 200.0;
        final gap = compact ? 12.0 : 16.0;
        final metadata = Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Flexible(
                  child: Text(
                    snapshot.playlist.name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: compact ? AppType.pageTitle : AppType.hero,
                      fontWeight: AppType.weightBold,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Icon(Symbols.cloud, size: 20, color: scheme.primary),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Icon(
                  Symbols.account_circle,
                  size: 20,
                  color: scheme.onSurfaceVariant,
                ),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    creator?.isNotEmpty == true ? creator! : '网易用户',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: scheme.onSurfaceVariant),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              '${snapshot.playlist.trackCount ?? snapshot.playlist.tracks.length} 首歌曲 · 只读订阅',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.icon(
                  onPressed: hasPlayableTracks
                      ? () => _play(playable.first)
                      : null,
                  icon: const Icon(Symbols.play_arrow),
                  label: const Text('播放全部'),
                ),
                IconButton.filledTonal(
                  tooltip: '随机播放',
                  onPressed: hasPlayableTracks
                      ? () => _playRandom(snapshot.playlist.tracks)
                      : null,
                  icon: const Icon(Symbols.shuffle),
                ),
                IconButton.filledTonal(
                  tooltip: '刷新',
                  onPressed: _loading ? null : _load,
                  icon: _loading
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Symbols.refresh),
                ),
              ],
            ),
          ],
        );
        return Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            ClipRRect(
              borderRadius: AppRadius.smCircular,
              child: SizedBox.square(
                dimension: coverSize,
                child: RemoteMediaCover(
                  coverUri: snapshot.playlist.coverUri,
                  placeholder: ColoredBox(
                    color: scheme.surfaceContainerHighest,
                    child: Icon(
                      Symbols.queue_music,
                      size: 48,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  cacheWidth: (coverSize * 2).round(),
                  cacheHeight: (coverSize * 2).round(),
                ),
              ),
            ),
            SizedBox(width: gap),
            Expanded(
              child: compact
                  ? metadata
                  : SizedBox(
                      height: coverSize,
                      child: Align(
                        alignment: Alignment.bottomLeft,
                        child: metadata,
                      ),
                    ),
            ),
          ],
        );
      },
    );
  }
}
