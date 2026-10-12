import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';
import 'package:pure_music/component/online_search_launcher.dart';
import 'package:pure_music/component/online_track_entry.dart';
import 'package:pure_music/component/quiet_empty_state.dart';
import 'package:pure_music/component/remote_cover_cache.dart';
import 'package:pure_music/core/enums.dart';
import 'package:pure_music/core/design_tokens.dart';
import 'package:pure_music/core/list_action_state.dart';
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

  /// 从第三方平台重新拉取歌单并覆盖本地快照（真正的「同步」）。
  /// 失败时保留当前已显示的快照，只提示，不清空页面。
  Future<void> _refresh() async {
    final request = ++_loadRequest;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final controller = context.read<OnlinePlaylistController>();
      final refreshed = await controller.refresh(widget.localId);
      if (!mounted || request != _loadRequest) return;
      final snapshot =
          refreshed ?? await controller.readSnapshot(widget.localId);
      if (!mounted || request != _loadRequest) return;
      if (refreshed == null) {
        setState(() => _loading = false);
        showTextOnSnackBar('同步在线歌单失败，请稍后重试', variant: ToastVariant.error);
        return;
      }
      setState(() {
        _snapshot = snapshot;
        _loading = false;
        _error = snapshot == null ? '在线歌单不存在或已被删除' : null;
        _primaryPicFuture = _coverProvider(snapshot?.playlist.coverUri);
      });
    } catch (_) {
      if (!mounted || request != _loadRequest) return;
      setState(() => _loading = false);
      showTextOnSnackBar('同步在线歌单失败，请稍后重试', variant: ToastVariant.error);
    }
  }

  Future<ImageProvider?> _coverProvider(Uri? uri) async {
    if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) return null;
    return CachedRemoteImageProvider(uri.toString());
  }

  Future<void> _play(Iterable<MusicTrack> tracks, MusicTrack track) async {
    await playOnlineTrackSelection(
      context,
      OnlineTrackSelection.fromResultPage(
        tracks: tracks,
        selectedRef: track.ref,
      ),
    );
  }

  /// 一行订阅歌单曲目。
  ///
  /// 组装、来源标记（取**曲目自己的 ref**，而不是歌单的字段）、收藏与操作
  /// 都收敛在 [OnlineTrackEntry] 里。
  ///
  /// [leadingIndex] 只在**名次集合**（从榜单订阅进来的）时给：参考产品的规则是
  /// "榜单/专辑有序号、普通歌单没有"，我们照此办理 ✓。
  Widget _buildTrackRow(
    MusicTrack track,
    Iterable<MusicTrack> playbackTracks, {
    int? leadingIndex,
  }) => OnlineTrackEntry(
    track: track,
    onTap: () => _play(playbackTracks, track),
    leadingIndex: leadingIndex,
  );

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
                onPressed: _loading ? null : _refresh,
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
              track.ref.hasValidIdentity &&
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
      pref: AppPreference.instance.onlinePlaylistDetailPagePref,
      primaryContent: snapshot,
      primaryPic: _primaryPicFuture,
      backgroundPic: Future.value(null),
      picShape: PicShape.rrect,
      title: snapshot.playlist.name,
      subtitle: [
        // 来源平台紧跟标题：订阅歌单本身就有明确来源（I1）。
        musicPlatformLabel(snapshot.playlist.platform),
        if (creator?.isNotEmpty == true) creator!,
        '${snapshot.playlist.trackCount ?? allTracks.length} 首歌曲 · 只读订阅',
      ].join(' · '),
      secondaryContent: tracks,
      secondaryContentBuilder:
          (context, track, index, msc, view) => _buildTrackRow(
            track,
            tracks,
            // 名次集合（榜单订阅）才显示行首序号；判据记在偏好里（不动 DB schema ✓）。
            leadingIndex: AppPreference.instance.isRankedSubscription(
              widget.localId,
            )
                ? index + 1
                : null,
          ),
      enableShufflePlay: false,
      enableSortMethod: hasEnoughItemsToSort(allTracks.length),
      enableSortOrder: hasEnoughItemsToSort(allTracks.length),
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
          // 接 `_refresh` 而不是 `_load`：这是**已加载页**上的刷新，用户点它是因为
          // "平台上改了内容，我要拉新的"。`_load` 只重读本地快照 ⇒ 对用户就是个空按钮
          // （同一个页面里空歌单视图的刷新一直是接 `_refresh` 的，这里与它对齐）。
          onPressed: _loading ? null : _refresh,
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
      // 默认：保持第三方平台返回的顺序（即服务器默认顺序），不做任何排序。
      SortMethodDesc<MusicTrack>(
        icon: Symbols.reorder,
        name: '默认',
        method: (list, order) {},
      ),
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
