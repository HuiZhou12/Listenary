import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';
import 'package:pure_music/component/content_section.dart';
import 'package:pure_music/component/online_search_launcher.dart';
import 'package:pure_music/component/online_track_entry.dart';
import 'package:pure_music/component/quiet_empty_state.dart';
import 'package:pure_music/component/remote_cover_cache.dart';
import 'package:pure_music/core/design_tokens.dart';
import 'package:pure_music/core/enums.dart';
import 'package:pure_music/core/list_action_state.dart';
import 'package:pure_music/core/preference.dart';
import 'package:pure_music/core/utils.dart';
import 'package:pure_music/page/page_scaffold.dart';
import 'package:pure_music/page/uni_detail_page.dart';
import 'package:pure_music/page/uni_page.dart';
import 'package:pure_music/services/music_platform/index.dart';
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

  /// 读取失败的可读原因；为 null 表示没失败（**"空"与"失败"必须分得开** ✓）。
  String? _error;
  Future<ImageProvider?> _primaryPicFuture = Future.value(null);

  /// 记住控制器实例：**`dispose` 里不能再 `context.read`**（那时 element 已 deactivated，
  /// 框架会直接断言失败）。从前这里在 dispose 里查 provider，导致每次离开本页都会报断言。
  PersonalOnlinePlaylistController? _favorites;

  @override
  void initState() {
    super.initState();
    _load();
    final controller = context.read<PersonalOnlinePlaylistController>();
    _favorites = controller;
    // 让控制器**先把收藏态读进内存**：否则每行的爱心会因为"不知道是否已收藏"
    // 而显示成未收藏（从前这里靠硬编码 `favorite: true` 绕过，等于放弃了状态判断）。
    unawaited(controller.loadFavorites());
    controller.addListener(_onFavoritesChanged);
  }

  @override
  void dispose() {
    _favorites?.removeListener(_onFavoritesChanged);
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
      setState(() {
        _loading = false;
        // **别把失败吞成"空"**（2026-10-17 / F7）：此前这里只把 loading 置回 false ✗，
        // 于是"读库失败"和"确实没有收藏"在界面上长得一模一样 ✓，用户拿不到原因、
        // 也无处重试 ✓。文案沿用姊妹页的**固定可读文案**（不把异常原文抛给用户 ✓）。
        _error = '无法读取收藏';
      });
    }
  }

  Future<void> _refresh() async {
    final request = ++_loadRequest;
    try {
      final snapshot = await context
          .read<PersonalOnlinePlaylistController>()
          .readFavorites();
      if (!mounted || request != _loadRequest) return;
      setState(() {
        _snapshot = snapshot;
        _error = null;
        _primaryPicFuture = _firstCoverProvider(snapshot);
      });
    } catch (_) {
      if (!mounted || request != _loadRequest) return;
      // **刷新失败不清空已有内容** ✓（2026-10-17 / D8）：有快照就只报失败、继续显示旧的；
      // 没有快照才落到整页失败态（否则用户会看到"一片空白"而不是"上次读到的收藏" ✓）。
      if (_snapshot != null) {
        showTextOnSnackBar(
          '收藏刷新失败，显示的是上次读到的内容',
          variant: ToastVariant.error,
        );
        return;
      }
      setState(() => _error = '无法读取收藏');
    }
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

  Future<void> _play(Iterable<MusicTrack> tracks, MusicTrack track) async {
    await playOnlineTrackSelection(
      context,
      OnlineTrackSelection.fromResultPage(
        tracks: tracks,
        selectedRef: track.ref,
      ),
    );
  }

  /// 一行收藏曲目。
  ///
  /// 组装、来源标记、收藏切换与"加入歌单"都收敛在 [OnlineTrackEntry] 里。
  /// 收藏是**跨平台**的（任何平台的曲目都能被收藏）⇒ 每行必须标明来源（I1）。
  Widget _buildTrackRow(MusicTrack track, Iterable<MusicTrack> playbackTracks) =>
      OnlineTrackEntry(
        track: track,
        onTap: () => _play(playbackTracks, track),
      );

  @override
  Widget build(BuildContext context) {
    final snapshot = _snapshot;
    // ⚠️ 2026-10-17（F6）：三个分支都不再套 `Scaffold` ✓ —— 外壳（`AppShell`）已提供，
    // 再套一层会刷不透明的页面底色，盖掉外壳那层封面取色背景 ⇒ 加载/空/失败态下
    // 与侧边栏之间会显出接缝。
    // F7：**失败优先于空** ✓ —— 读不到时说"还没有收藏"是谎，且必须能就地重试。
    if (_error != null) {
      return PageScaffold(
        title: '我的收藏',
        actions: [
          IconButton.filledTonal(
            tooltip: '刷新',
            onPressed: _loading ? null : _load,
            icon: const Icon(Symbols.refresh),
          ),
        ],
        body: QuietEmptyState(
          icon: Symbols.cloud_off,
          title: '收藏读取失败',
          message: _error!,
          action: FilledButton.tonalIcon(
            onPressed: _load,
            icon: const Icon(Symbols.refresh),
            label: const Text('重试'),
          ),
        ),
      );
    }
    if (snapshot != null && !_loading) {
      if (snapshot.tracks.isEmpty) {
        return PageScaffold(
          title: '我的收藏',
          actions: [
            IconButton.filledTonal(
              tooltip: '刷新',
              onPressed: _load,
              icon: const Icon(Symbols.refresh),
            ),
          ],
          body: const QuietEmptyState(
            icon: Symbols.favorite_border,
            title: '还没有收藏',
            message: '在线歌曲上点爱心即可收藏。',
          ),
        );
      }
      return _buildLoadedPage(snapshot);
    }
    return PageScaffold(
      title: '我的收藏',
      actions: const [],
      body: _buildStatusBody(),
    );
  }

  Widget _buildStatusBody() {
    if (_loading) return const PageLoadingIndicator();
    // 走到这里既没在加载、也没记下失败 ⇒ 只是"还没有读到快照"，给一个中性提示 +
    // 明确的重试入口（不再渲染成"读取失败"那种带原因的报错 ✓）。
    return QuietEmptyState(
      icon: Symbols.favorite_border,
      title: '还没有读到收藏',
      message: '稍等一下，或手动刷新一次。',
      action: FilledButton.tonalIcon(
        onPressed: _load,
        icon: const Icon(Symbols.refresh),
        label: const Text('刷新'),
      ),
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
    // 可播判据走**唯一出口** ✓（2026-10-17 / F1 收口）：与行、与其它详情页同一套
    //（解析侧身份 **且** 平台未声明 paid/unavailable，`unknown` 放行 ✓）。
    // 此前这里自己抄了一份"身份 + 可用状态"的内联判据 ✗ —— 形状与 `canPlayTrack` 相同，
    // 但多一处副本就多一次走偏的机会。页面级测试没注册服务 ⇒ 自动走等价回落分支 ✓。
    final capabilities = context
        .read<OnlineMusicService?>()
        ?.capabilities;
    final playable = [
      for (final track in tracks)
        if (OnlineTrackEntry.playableOf(
          track: track,
          providerCapabilities: capabilities,
        ))
          track,
    ];
    const primaryActionStyle = AppButtonStyle.primaryAction;
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
      enableSortMethod: hasEnoughItemsToSort(tracks.length),
      enableSortOrder: hasEnoughItemsToSort(tracks.length),
      sortMethods: _sortMethods(snapshot),
      enableSecondaryContentViewSwitch: false,
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
      ],
    );
  }

  List<SortMethodDesc<MusicTrack>> _sortMethods(
    PersonalOnlinePlaylistSnapshot snapshot,
  ) {
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
      SortMethodDesc<MusicTrack>(
        icon: Symbols.add_circle,
        name: '添加时间',
        method: (list, order) {
          switch (order) {
            case SortOrder.ascending:
              list.sort((a, b) => snapshot.compareByAddedAt(a.ref, b.ref));
              break;
            case SortOrder.decending:
              list.sort(
                (a, b) =>
                    snapshot.compareByAddedAt(a.ref, b.ref, descending: true),
              );
              break;
          }
        },
      ),
    ];
  }
}
