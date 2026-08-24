import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';
import 'package:pure_music/component/motion.dart';
import 'package:pure_music/component/online_search_launcher.dart';
import 'package:pure_music/component/online_track_row.dart';
import 'package:pure_music/component/quiet_empty_state.dart';
import 'package:pure_music/component/remote_cover_cache.dart';
import 'package:pure_music/core/enums.dart';
import 'package:pure_music/core/preference.dart';
import 'package:pure_music/core/utils.dart';
import 'package:pure_music/page/page_scaffold.dart';
import 'package:pure_music/page/uni_detail_page.dart';
import 'package:pure_music/page/uni_page.dart';
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
  String _searchQuery = '';
  Future<ImageProvider?> _primaryPicFuture = Future.value(null);

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
        _primaryPicFuture = _firstCoverProvider(snapshot);
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
    setState(() {
      _snapshot = snapshot;
      _primaryPicFuture = _firstCoverProvider(snapshot);
    });
  }

  Future<ImageProvider?> _firstCoverProvider(
    PersonalOnlinePlaylistSnapshot? snapshot,
  ) async {
    final snapshotLocal = snapshot;
    if (snapshotLocal == null) return null;
    for (final track in snapshotLocal.tracks) {
      final uri = track.coverUri;
      if (uri != null && uri.scheme == 'https' && uri.host.isNotEmpty) {
        return CachedRemoteImageProvider(uri.toString());
      }
    }
    return null;
  }

  Future<void> _play(
    Iterable<MusicTrack> tracks,
    MusicTrack track,
  ) async {
    await playOnlineTrackSelection(
      context,
      OnlineTrackSelection.fromResultPage(
        tracks: tracks,
        selectedRef: track.ref,
      ),
    );
  }

  Future<void> _unfavorite(PlatformTrackRef ref) async {
    final snapshot = _snapshot;
    if (snapshot == null) return;
    await context.read<PersonalOnlinePlaylistController>().removeTrack(
      snapshot.localId,
      ref,
    );
  }

  Widget _buildTrackRow(
    MusicTrack track,
    Iterable<MusicTrack> playbackTracks,
  ) {
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
        onTap: playable ? () => _play(playbackTracks, track) : null,
        showFavorite: true,
        favorite: true,
        onToggleFavorite: () => _unfavorite(track.ref),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final snapshot = _snapshot;
    if (snapshot != null && !_loading) {
      if (snapshot.tracks.isEmpty) {
        return const Scaffold(
          body: PageScaffold(
            title: '我的收藏',
            actions: [],
            body: QuietEmptyState(
              icon: Symbols.favorite_border,
              title: '还没有收藏',
              message: '在线歌曲上点爱心即可收藏。',
            ),
          ),
        );
      }
      return Scaffold(body: _buildLoadedPage(snapshot));
    }
    return Scaffold(
      body: PageScaffold(
        title: '我的收藏',
        actions: const [],
        body: _buildStatusBody(),
      ),
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
    final allTracks = snapshot.tracks;
    final query = _searchQuery.toLowerCase();
    final tracks = _searchQuery.isEmpty
        ? List<MusicTrack>.from(allTracks)
        : allTracks
              .where(
                (t) =>
                    t.title.toLowerCase().contains(query) ||
                    t.artistDisplay.toLowerCase().contains(query) ||
                    t.album.toLowerCase().contains(query),
              )
              .toList(growable: false);
    final playable = tracks
        .where(
          (t) =>
              t.availability != TrackAvailability.unavailable &&
              t.availability != TrackAvailability.paid,
        )
        .toList(growable: false);
    const primaryActionStyle = ButtonStyle(
      fixedSize: WidgetStatePropertyAll(Size.fromHeight(40)),
      padding: WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 16)),
    );
    return UniDetailPage<PersonalOnlinePlaylistSnapshot, MusicTrack, Object>(
      pref: AppPreference.instance.playlistDetailPagePref,
      primaryContent: snapshot,
      primaryPic: _primaryPicFuture,
      backgroundPic: Future.value(null),
      picShape: PicShape.rrect,
      title: '我的收藏',
      subtitle: '${snapshot.tracks.length} 首在线歌曲 · 自动收藏',
      secondaryContent: tracks,
      secondaryContentBuilder: (context, track, index, msc, view) =>
          _buildTrackRow(track, tracks),
      enableShufflePlay: false,
      enableSortMethod: true,
      enableSortOrder: true,
      sortMethods: _sortMethods(),
      enableSecondaryContentViewSwitch: false,
      enableSearch: true,
      searchQuery: _searchQuery,
      onSearchChanged: (v) => setState(() => _searchQuery = v),
      extraActions: [
        FilledButton.icon(
          onPressed: playable.isEmpty ? null : () => _play(tracks, playable.first),
          icon: const Icon(Symbols.play_arrow, size: 20),
          label: const Text('播放全部'),
          style: primaryActionStyle,
        ),
      ],
    );
  }

  List<SortMethodDesc<MusicTrack>> _sortMethods() {
    return [
      SortMethodDesc<MusicTrack>(
        icon: Symbols.title,
        name: '标题',
        method: (list, order) {
          switch (order) {
            case SortOrder.ascending:
              list.sort((a, b) => a.title.naturalCompareTo(b.title));
              break;
            case SortOrder.decending:
              list.sort((a, b) => b.title.naturalCompareTo(a.title));
              break;
          }
        },
      ),
      SortMethodDesc<MusicTrack>(
        icon: Symbols.artist,
        name: '歌手',
        method: (list, order) {
          switch (order) {
            case SortOrder.ascending:
              list.sort(
                (a, b) => a.artistDisplay.naturalCompareTo(b.artistDisplay),
              );
              break;
            case SortOrder.decending:
              list.sort(
                (a, b) => b.artistDisplay.naturalCompareTo(a.artistDisplay),
              );
              break;
          }
        },
      ),
      SortMethodDesc<MusicTrack>(
        icon: Symbols.album,
        name: '专辑',
        method: (list, order) {
          switch (order) {
            case SortOrder.ascending:
              list.sort((a, b) => a.album.naturalCompareTo(b.album));
              break;
            case SortOrder.decending:
              list.sort((a, b) => b.album.naturalCompareTo(a.album));
              break;
          }
        },
      ),
    ];
  }
}
