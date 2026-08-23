import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';
import 'package:pure_music/component/motion.dart';
import 'package:pure_music/component/online_search_launcher.dart';
import 'package:pure_music/component/online_track_row.dart';
import 'package:pure_music/component/quiet_empty_state.dart';
import 'package:pure_music/component/remote_media_cover.dart';
import 'package:pure_music/core/design_tokens.dart';
import 'package:pure_music/page/page_scaffold.dart';
import 'package:pure_music/services/music_platform/models/music_models.dart';
import 'package:pure_music/services/music_platform/online_library/online_library_repository.dart';
import 'package:pure_music/services/music_platform/online_library/personal_online_playlist_controller.dart';

class FavoritesDetailPage extends StatefulWidget {
  const FavoritesDetailPage({super.key});

  @override
  State<FavoritesDetailPage> createState() => _FavoritesDetailPageState();
}

class _FavoritesDetailPageState extends State<FavoritesDetailPage> {
  PersonalOnlinePlaylistSnapshot? _snapshot;
  bool _loading = true;
  int _loadRequest = 0;

  @override
  void initState() {
    super.initState();
    _load();
    context.read<PersonalOnlinePlaylistController>().addListener(
      _onFavoritesChanged,
    );
  }

  @override
  void dispose() {
    context.read<PersonalOnlinePlaylistController>().removeListener(
      _onFavoritesChanged,
    );
    super.dispose();
  }

  void _onFavoritesChanged() {
    unawaited(_refresh());
  }

  Future<void> _load() async {
    final request = ++_loadRequest;
    setState(() => _loading = true);
    try {
      final snapshot = await context
          .read<PersonalOnlinePlaylistController>()
          .readFavorites();
      if (!mounted || request != _loadRequest) return;
      setState(() {
        _snapshot = snapshot;
        _loading = false;
      });
    } catch (_) {
      if (!mounted || request != _loadRequest) return;
      setState(() => _loading = false);
    }
  }

  Future<void> _refresh() async {
    final request = ++_loadRequest;
    final snapshot = await context
        .read<PersonalOnlinePlaylistController>()
        .readFavorites();
    if (!mounted || request != _loadRequest) return;
    setState(() => _snapshot = snapshot);
  }

  Future<void> _play(MusicTrack track) async {
    final snapshot = _snapshot;
    if (snapshot == null) return;
    final tracks = snapshot.tracks
        .where(
          (t) =>
              t.availability != TrackAvailability.unavailable &&
              t.availability != TrackAvailability.paid,
        )
        .toList(growable: false);
    final selectedIndex = tracks.indexWhere((t) => t.ref == track.ref);
    if (selectedIndex < 0) return;
    await playOnlineTrackSelection(
      context,
      OnlineTrackSelection(tracks: tracks, selectedIndex: selectedIndex),
    );
  }

  Future<void> _playRandom(Iterable<MusicTrack> tracks) async {
    final playable = tracks
        .where(
          (t) =>
              t.availability != TrackAvailability.unavailable &&
              t.availability != TrackAvailability.paid,
        )
        .toList(growable: false);
    if (playable.isEmpty) return;
    await _play(playable[math.Random().nextInt(playable.length)]);
  }

  Future<void> _remove(PlatformTrackRef ref) async {
    final snapshot = _snapshot;
    if (snapshot == null) return;
    await context.read<PersonalOnlinePlaylistController>().removeTrack(
      snapshot.localId,
      ref,
    );
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final snapshot = _snapshot;
    if (snapshot != null && !_loading) {
      return _buildLoadedPage(snapshot);
    }
    return PageScaffold(
      title: '我的收藏',
      actions: [
        IconButton.filledTonal(
          tooltip: '刷新',
          onPressed: _loading ? null : _load,
          icon: const Icon(Symbols.refresh),
        ),
      ],
      body: _buildStatusBody(),
    );
  }

  Widget _buildStatusBody() {
    if (_loading) {
      return const Center(
        child: SizedBox.square(
          dimension: 24,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    return const QuietEmptyState(
      icon: Symbols.favorite_border,
      title: '收藏读取失败',
      message: '请稍后重试。',
    );
  }

  Widget _buildLoadedPage(PersonalOnlinePlaylistSnapshot snapshot) {
    final scheme = Theme.of(context).colorScheme;
    final tracks = snapshot.tracks;
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
                      icon: Symbols.favorite_border,
                      title: '还没有收藏',
                      message: '在线歌曲上点爱心即可收藏。',
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
        showFavorite: true,
        favorite: true,
        onToggleFavorite: () => _remove(track.ref),
      ),
    );
  }

  Widget _buildHeader(PersonalOnlinePlaylistSnapshot snapshot) {
    final scheme = Theme.of(context).colorScheme;
    final playable = snapshot.tracks.where(
      (t) =>
          t.availability != TrackAvailability.unavailable &&
          t.availability != TrackAvailability.paid,
    );
    final hasPlayableTracks = playable.isNotEmpty;
    Uri? cover;
    for (final track in snapshot.tracks) {
      final uri = track.coverUri;
      if (uri != null) {
        cover = uri;
        break;
      }
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact =
            constraints.maxWidth.isFinite && constraints.maxWidth < 560;
        final coverSize = compact ? 156.0 : 200.0;
        final gap = compact ? 12.0 : 16.0;
        return Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            ClipRRect(
              borderRadius: AppRadius.smCircular,
              child: SizedBox.square(
                dimension: coverSize,
                child: RemoteMediaCover(
                  coverUri: cover,
                  placeholder: ColoredBox(
                    color: scheme.surfaceContainer,
                    child: Icon(
                      Symbols.favorite,
                      size: 56,
                      color: scheme.primary,
                    ),
                  ),
                  cacheWidth: (coverSize * 2).round(),
                  cacheHeight: (coverSize * 2).round(),
                ),
              ),
            ),
            SizedBox(width: gap),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          '我的收藏',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: compact
                                ? AppType.pageTitle
                                : AppType.hero,
                            fontWeight: AppType.weightBold,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Icon(Symbols.favorite, size: 18, color: scheme.primary),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '${snapshot.tracks.length} 首在线歌曲 · 自动收藏',
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
                            ? () => _playRandom(snapshot.tracks)
                            : null,
                        icon: const Icon(Symbols.shuffle),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}
