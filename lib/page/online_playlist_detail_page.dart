import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';
import 'package:pure_music/component/motion.dart';
import 'package:pure_music/component/online_search_launcher.dart';
import 'package:pure_music/component/online_track_row.dart';
import 'package:pure_music/component/personal_playlist_picker.dart';
import 'package:pure_music/component/quiet_empty_state.dart';
import 'package:pure_music/component/remote_cover_cache.dart';
import 'package:pure_music/core/enums.dart';
import 'package:pure_music/core/design_tokens.dart';
import 'package:pure_music/core/preference.dart';
import 'package:pure_music/core/utils.dart';
import 'package:pure_music/page/page_scaffold.dart';
import 'package:pure_music/page/uni_detail_page.dart';
import 'package:pure_music/page/uni_page.dart';
import 'package:pure_music/services/music_platform/models/music_models.dart';
import 'package:pure_music/services/music_platform/online_library/online_library_repository.dart';
import 'package:pure_music/services/music_platform/online_library/online_playlist_controller.dart';
import 'package:pure_music/services/music_platform/online_library/personal_online_playlist_controller.dart';

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
  String _searchQuery = '';
  Future<ImageProvider?> _primaryPicFuture = Future.value(null);

  @override
  void initState() {
    super.initState();
    _load();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      context.read<PersonalOnlinePlaylistController>().loadFavorites();
    });
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
        _primaryPicFuture = _coverProvider(snapshot?.playlist.coverUri);
      });
    } catch (_) {
      if (!mounted || request != _loadRequest) return;
      setState(() {
        _loading = false;
        _error = '无法读取在线歌单';
      });
    }
  }

  Future<ImageProvider?> _coverProvider(Uri? uri) async {
    if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) return null;
    return CachedRemoteImageProvider(uri.toString());
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
    final favorites = context.watch<PersonalOnlinePlaylistController>();
    return DirectionalListItemEntrance(
      identity: track.ref,
      child: OnlineTrackRow(
        track: track,
        details: details,
        enabled: playable,
        onTap: playable ? () => _play(playbackTracks, track) : null,
        onAddToPlaylist: () =>
            showPersonalPlaylistPicker(context, track: track),
        showFavorite: true,
        favorite: favorites.isFavorite(track.ref),
        onToggleFavorite: () => favorites.toggleFavorite(track),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final snapshot = _snapshot;
    if (snapshot != null && _error == null) {
      if (snapshot.playlist.tracks.isEmpty) {
        return Scaffold(
          body: PageScaffold(
            title: snapshot.playlist.name,
            actions: [
              IconButton.filledTonal(
                tooltip: '刷新',
                onPressed: _loading ? null : _load,
                icon: const Icon(Symbols.refresh),
              ),
            ],
            body: const QuietEmptyState(
              icon: Symbols.music_off,
              title: '歌单没有可用曲目',
              message: '刷新后会重新读取第三方平台的完整快照。',
            ),
          ),
        );
      }
      return Scaffold(body: _buildLoadedPage(snapshot));
    }
    return Scaffold(
      body: PageScaffold(
        title: snapshot?.playlist.name ?? '在线歌单',
        actions: [
          IconButton.filledTonal(
            tooltip: '刷新',
            onPressed: _loading ? null : _load,
            icon: const Icon(Symbols.refresh),
          ),
        ],
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

  Widget _buildLoadedPage(OnlinePlaylistSnapshot snapshot) {
    final allTracks = snapshot.playlist.tracks;
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
          (track) =>
              track.availability != TrackAvailability.unavailable &&
              track.availability != TrackAvailability.paid,
        )
        .toList(growable: false);
    const primaryActionStyle = ButtonStyle(
      fixedSize: WidgetStatePropertyAll(Size.fromHeight(40)),
      padding: WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 16)),
    );
    final creator = snapshot.playlist.creator?.trim();
    return UniDetailPage<OnlinePlaylistSnapshot, MusicTrack, Object>(
      pref: AppPreference.instance.playlistDetailPagePref,
      primaryContent: snapshot,
      primaryPic: _primaryPicFuture,
      backgroundPic: Future.value(null),
      picShape: PicShape.rrect,
      title: snapshot.playlist.name,
      subtitle: [
        if (creator?.isNotEmpty == true) creator!,
        '${snapshot.playlist.trackCount ?? allTracks.length} 首歌曲 · 只读订阅',
      ].join(' · '),
      secondaryContent: tracks,
      secondaryContentBuilder: (context, track, index, msc, view) =>
          _buildTrackRow(track, tracks),
      enableShufflePlay: false,
      enableSortMethod: true,
      enableSortOrder: true,
      sortMethods: _sortMethods(),
      enableSecondaryContentViewSwitch: true,
      enableSearch: true,
      searchQuery: _searchQuery,
      onSearchChanged: (v) => setState(() => _searchQuery = v),
      extraActions: [
        FilledButton.icon(
          onPressed: playable.isEmpty
              ? null
              : () => _play(tracks, playable.first),
          icon: const Icon(Symbols.play_arrow, size: 20),
          label: const Text('播放全部'),
          style: primaryActionStyle,
        ),
        FilledButton.tonalIcon(
          onPressed: _loading ? null : _load,
          icon: _loading
              ? const SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Symbols.refresh, size: 20),
          label: const Text('刷新'),
          style: ButtonStyle(
            fixedSize: const WidgetStatePropertyAll(Size.fromHeight(40)),
            padding: const WidgetStatePropertyAll(
              EdgeInsets.symmetric(horizontal: 16),
            ),
            shape: WidgetStatePropertyAll(
              RoundedRectangleBorder(borderRadius: AppRadius.smCircular),
            ),
          ),
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
