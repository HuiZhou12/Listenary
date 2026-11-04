import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';
import 'package:pure_music/component/album_tile.dart';
import 'package:pure_music/component/artist_tile.dart';
import 'package:pure_music/component/audio_tile.dart';
import 'package:pure_music/component/motion.dart';
import 'package:pure_music/component/online_search_panel.dart';
import 'package:pure_music/component/quiet_empty_state.dart';
import 'package:pure_music/component/search_dialog_layout.dart';
import 'package:pure_music/core/hotkeys.dart';
import 'package:pure_music/core/list_action_state.dart';
import 'package:pure_music/core/menu_styles.dart';
import 'package:pure_music/core/paths.dart' as app_paths;
import 'package:pure_music/core/search_action_state.dart';
import 'package:pure_music/library/audio_library.dart';
import 'package:pure_music/library/playlist.dart';
import 'package:pure_music/library/union_search_result.dart';
import 'package:pure_music/play_service/play_service.dart';
import 'package:pure_music/core/utils.dart';
import 'package:pure_music/services/music_platform/index.dart';
import 'package:pure_music/services/music_platform/online_library/personal_online_playlist_controller.dart';

/// 搜索来源（Spec D1）：一个入口、一个弹窗、两种来源。
///
/// 默认 [local]（D3 已拍板）：标题栏搜索按钮打开的就是本地搜索；
/// 「在线」由用户在弹窗内显式切换，未启用任何在线平台时不可切（点击给引导）。
enum SearchSource { local, online }

class _SearchEmptyState extends StatelessWidget {
  const _SearchEmptyState({
    required this.icon,
    required this.title,
    required this.message,
  });

  final IconData icon;
  final String title;
  final String message;

  @override
  Widget build(BuildContext context) {
    return QuietEmptyState(
      icon: icon,
      title: title,
      message: message,
      maxWidth: 380.0,
    );
  }
}

class SearchDialog extends StatefulWidget {
  const SearchDialog({super.key, this.initialSource = SearchSource.local});

  /// 打开时的来源（默认本地）。切换来源由弹窗自己承接。
  final SearchSource initialSource;

  static Future<void> show(
    BuildContext context, {
    SearchSource initialSource = SearchSource.local,
  }) {
    return showDialog(
      context: context,
      barrierDismissible: true,
      builder: (context) => SearchDialog(initialSource: initialSource),
    );
  }

  @override
  State<SearchDialog> createState() => _SearchDialogState();
}

class _SearchCategory {
  final String label;
  final IconData icon;
  const _SearchCategory(this.label, this.icon);
}

class _SearchDialogState extends State<SearchDialog> {
  late final TextEditingController _searchController = TextEditingController();
  late final ValueNotifier<UnionSearchResult> _result = ValueNotifier(
    UnionSearchResult(''),
  );
  late final ValueNotifier<bool> _isSearching = ValueNotifier(false);
  final GlobalKey<OnlineSearchPanelState> _panelKey = GlobalKey();
  Timer? _debounce;
  Timer? _queuedNextResetTimer;
  Audio? _queuedNextAudio;
  Audio? _addingAudioToPlaylist;
  Playlist? _addingTargetPlaylist;
  int _currentIndex = 0;
  int _searchVersion = 0;
  late SearchSource _source = widget.initialSource;

  /// 弹窗打开时的路由位置，用于"行内 push 打开子页时弹窗自动让位"（见 [_onRouteChanged]）。
  String? _locationAtOpen;
  GoRouter? _router;

  static const _tabs = [
    _SearchCategory('音乐', Symbols.music_note),
    _SearchCategory('艺术家', Symbols.person),
    _SearchCategory('专辑', Symbols.album),
  ];

  @override
  void initState() {
    super.initState();
    // 在线行的收藏状态首帧（原在线搜索页 initState 的同一时机、同一语义）：
    // `OnlineTrackEntry` 无条件 `watch` 收藏控制器 ⇒ 切到在线来源时爱心不该是空的。
    // 未启用在线平台时也调：成本一次空仓库读，`_favoritesLoaded` 置位后短路。
    // **可空读取**：组件级测试（`search_dialog_test.dart`）不装 provider，
    // 那里没有在线行可渲染，静默跳过即可，不能因此抛异常。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      context.read<PersonalOnlinePlaylistController?>()?.loadFavorites();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 行内 `context.push` 打开在线专辑/艺人页时，弹窗挂在 root navigator 上，
    // 而 push 走的是路由壳的 navigator ⇒ 新页会出现在**弹窗遮罩之下**（点不动）。
    // 处置：记住打开时的位置，位置一变就让弹窗自己退出（等价于 pop-then-push 的观感，
    // 但不动 `OnlineAlbumRow` / `OnlineTrackEntry` 的调用点 —— 那些行在弹窗外也要用）。
    final router = GoRouter.maybeOf(context);
    if (!identical(router, _router)) {
      _router?.routerDelegate.removeListener(_onRouteChanged);
      _router = router;
      _locationAtOpen = router?.state.uri.toString();
      router?.routerDelegate.addListener(_onRouteChanged);
    }
  }

  void _onRouteChanged() {
    if (!mounted) return;
    if (_router?.state.uri.toString() != _locationAtOpen) {
      Navigator.of(context).maybePop();
    }
  }

  @override
  void dispose() {
    _router?.routerDelegate.removeListener(_onRouteChanged);
    _debounce?.cancel();
    _queuedNextResetTimer?.cancel();
    _searchController.dispose();
    _result.dispose();
    _isSearching.dispose();
    super.dispose();
  }

  /// 当前可搜索的**平台身份**（D3）：只读 `capabilities.searchableIdentities`。
  ///
  /// 可空读取：组件级测试没有 provider ⇒ 返回空表 ⇒「在线」视觉置灰但仍可点（I3）。
  /// **禁止**在这里读任何配置符号（见边界测试的符号禁令）。
  List<PlatformIdentity> _searchableIdentities() {
    final service = context.read<OnlineMusicService?>();
    if (service == null) return const [];
    return [
      for (final identity in service.capabilities.searchableIdentities)
        identity.normalized,
    ];
  }

  void _onQueryChanged(String raw) {
    final query = normalizedSearchQuery(raw);
    // 在线来源**不**触发搜索（I2）：只把面板的既有结果标记为"查询已过期"。
    // 面板由 `query` 变化自己重置（同原在线搜索页的 `_resetSearch`）。
    if (_source == SearchSource.online) {
      setState(() {});
      return;
    }

    _debounce?.cancel();
    if (query.isEmpty) {
      _result.value = UnionSearchResult('');
      _isSearching.value = false;
      return;
    }

    _isSearching.value = true;
    _debounce = Timer(const Duration(milliseconds: 450), () {
      if (!mounted) return;
      _searchVersion++;
      _search(query);
      _isSearching.value = false;
    });
  }

  void _search(String query) {
    final scope = SearchScope.values[_currentIndex];
    _result.value = UnionSearchResult.search(query, scope: scope);
  }

  void _clearSearch() {
    _debounce?.cancel();
    _searchController.clear();
    _result.value = UnionSearchResult('');
    _isSearching.value = false;
    if (_source == SearchSource.online) _panelKey.currentState?.cancelAll();
    setState(() {});
  }

  void _switchCategory(int index) {
    _debounce?.cancel();
    setState(() => _currentIndex = index);

    final query = normalizedSearchQuery(_searchController.text);
    if (query.isEmpty) return;
    _searchVersion++;
    _search(query);
    _isSearching.value = false;
  }

  /// 提交在线搜索（Enter / 「在线搜索」按钮）：直接调面板的 `submit`。
  ///
  /// 面板可能还没挂上（刚从本地切到在线、或上一帧刚被替换）⇒ 排到帧后再提交，
  /// 这样"切来源时新建的面板"也能收到这一次提交。
  void _submitOnlineSearch() {
    final query = normalizedSearchQuery(_searchController.text);
    final panel = _panelKey.currentState;
    if (panel != null) {
      unawaited(panel.submit(query));
      return;
    }
    _submitOnlineAfterFrame(query);
  }

  /// 等这一帧把面板建好再提交（面板在切换来源的那次 setState 里才第一次出现）。
  void _submitOnlineAfterFrame(String query) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _source != SearchSource.online) return;
      final panel = _panelKey.currentState;
      if (panel != null) unawaited(panel.submit(query));
    });
  }

  /// 来源切换（Spec §5.2 状态机）。
  void _switchSource(SearchSource next) {
    if (next == _source) return;

    if (next == SearchSource.online) {
      // 没有可搜索平台 ⇒ **不切换来源**，弹引导（D3 / I3）。
      if (_searchableIdentities().isEmpty) {
        unawaited(_showNoPlatformGuide());
        return;
      }
      _debounce?.cancel();
      _isSearching.value = false;
      final query = normalizedSearchQuery(_searchController.text);
      setState(() => _source = SearchSource.online);
      // 切过去就有词 ⇒ 立刻搜一次（与"点「在线搜索」"同一入口）。
      if (query.isNotEmpty) _submitOnlineAfterFrame(query);
      return;
    }

    // 在线 → 本地：先取消全部在途请求，再**立即**搜（不等 debounce）。
    _panelKey.currentState?.cancelAll();
    final query = normalizedSearchQuery(_searchController.text);
    setState(() => _source = SearchSource.local);
    if (query.isEmpty) return;
    _searchVersion++;
    _search(query);
    _isSearching.value = false;
  }

  /// 未启用任何在线平台时的引导（I4：先去设置页，再关弹窗 —— 否则弹窗会盖住目标页）。
  Future<void> _showNoPlatformGuide() {
    return showDialog<void>(
      context: context,
      builder: (guideContext) => AlertDialog(
        title: const Text('还没有可搜索的在线平台'),
        content: const Text('请先在设置里启用平台，并为它配置可用的服务。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(guideContext).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.of(guideContext).pop();
              _closeAndGo(app_paths.SETTINGS_PAGE);
            },
            child: const Text('去设置'),
          ),
        ],
      ),
    );
  }

  /// 关掉本弹窗，再跳到 [location]（I4：弹窗会盖住目标页）。
  void _closeAndGo(String location) {
    final router = GoRouter.maybeOf(context);
    Navigator.of(context).pop();
    router?.go(location);
  }

  void _addSearchResultToNext(Audio audio) {
    PlayService.instance.playbackService.addToNext(audio);
    _queuedNextResetTimer?.cancel();
    setState(() => _queuedNextAudio = audio);
    _queuedNextResetTimer = Timer(const Duration(milliseconds: 1200), () {
      if (!mounted) return;
      setState(() => _queuedNextAudio = null);
    });
  }

  Future<void> _addSearchResultToPlaylist(
    Audio audio,
    Playlist playlist,
  ) async {
    if (_addingAudioToPlaylist != null) {
      return;
    }

    final added = playlist.containsPath(audio.path);
    if (added) {
      showTextOnSnackBar('歌曲已在歌单中');
      return;
    }

    setState(() {
      _addingAudioToPlaylist = audio;
      _addingTargetPlaylist = playlist;
    });
    try {
      playlist.addPath(audio.path);
      final saved = await savePlaylists();
      if (!mounted) return;
      if (!saved) {
        playlist.removeByPath(audio.path);
        showTextOnSnackBar('保存歌单失败', variant: ToastVariant.error);
        return;
      }
      showTextOnSnackBar('已添加到歌单');
    } finally {
      _addingAudioToPlaylist = null;
      _addingTargetPlaylist = null;
      if (mounted) setState(() {});
    }
  }

  Widget _musicActionBar(Audio audio) {
    final isAddingThisAudio = identical(_addingAudioToPlaylist, audio);
    final isQueuedNext = identical(_queuedNextAudio, audio);
    final hasNowPlaying =
        PlayService.instance.playbackService.nowPlaying != null;
    final canAddNext = canAddAudioToNext(
      hasNowPlaying: hasNowPlaying,
      isPendingFeedback: isQueuedNext,
    );
    final playlistMemberships = playlists
        .map((playlist) => playlist.containsPath(audio.path))
        .toList(growable: false);
    final canOpenPlaylistMenu = canOpenSingleAudioAddToPlaylistMenu(
      hasAudio: true,
      isBusy: _addingAudioToPlaylist != null,
      alreadyInPlaylists: playlistMemberships,
    );
    final alreadyInAllPlaylists =
        playlists.isNotEmpty && playlistMemberships.every((value) => value);
    final scheme = Theme.of(context).colorScheme;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          tooltip: isQueuedNext
              ? '已加入下一首'
              : hasNowPlaying
              ? '下一首播放'
              : '先播放一首歌',
          // 行内操作图标统一 20px ✓（2026-10-17 / F24）：与 `audio_tile`、
          // `online_track_row`、`remote_media_card` 的既有约定一致（此前这里走默认 24 ✗）。
          iconSize: 20,
          style: IconButton.styleFrom(
            backgroundColor: isQueuedNext ? scheme.primaryContainer : null,
            disabledBackgroundColor: isQueuedNext
                ? scheme.primaryContainer
                : null,
            disabledForegroundColor: isQueuedNext
                ? scheme.onPrimaryContainer
                : null,
          ),
          onPressed: canAddNext ? () => _addSearchResultToNext(audio) : null,
          icon: AnimatedSwitcher(
            // 用动画令牌 ✓（2026-10-17 / Q8）：180ms 正是 MotionDuration.fast，手感不变 ✓。
            duration: MotionDuration.fast,
            child: Icon(
              isQueuedNext ? Symbols.check : Symbols.plus_one,
              key: ValueKey(isQueuedNext),
            ),
          ),
        ),
        MenuAnchor(
          consumeOutsideTap: true,
          // 菜单外观走**全局样式** ✓（2026-10-17 / F24）：全仓 26 处都用它，
          // 只有这里漏了 ⇒ 同一个"加入歌单"菜单在搜索框里是默认 Material 形状 ✗。
          style: appMenuStyle,
          menuChildren: List.generate(playlists.length, (playlistIndex) {
            final playlist = playlists[playlistIndex];
            final isAddingTarget =
                isAddingThisAudio && identical(_addingTargetPlaylist, playlist);
            final alreadyInPlaylist = playlist.containsPath(audio.path);
            return MenuItemButton(
              style: appMenuItemStyle,
              onPressed: _addingAudioToPlaylist == null && !alreadyInPlaylist
                  ? () => _addSearchResultToPlaylist(audio, playlist)
                  : null,
              leadingIcon: isAddingTarget
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Icon(
                      alreadyInPlaylist ? Symbols.check : Symbols.queue_music,
                    ),
              child: Text(playlist.name),
            );
          }),
          builder: (context, controller, _) {
            return IconButton(
              // 同上：行内操作图标统一 20px ✓。
              iconSize: 20,
              tooltip: isAddingThisAudio
                  ? '添加中'
                  : alreadyInAllPlaylists
                  ? '已存在于所有歌单'
                  : '添加到歌单',
              onPressed: canOpenPlaylistMenu
                  ? () {
                      if (controller.isOpen) {
                        controller.close();
                      } else {
                        controller.open();
                      }
                    }
                  : null,
              icon: isAddingThisAudio
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Icon(
                      alreadyInAllPlaylists
                          ? Symbols.check
                          : Symbols.queue_music,
                    ),
            );
          },
        ),
      ],
    );
  }

  /// 标题栏：标题 + 来源切换（SegmentedButton）。
  ///
  /// I3：没有可搜索平台时「在线」**不是 disabled 段**（disabled 段不可点，也就
  /// 无从"点击引导去设置"）⇒ 视觉置灰 + 仍可点，点击走引导。
  Widget _buildTitle() {
    final scheme = Theme.of(context).colorScheme;
    final hasOnline = _searchableIdentities().isNotEmpty;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Text('搜索'),
        const SizedBox(width: 16.0),
        SegmentedButton<SearchSource>(
          showSelectedIcon: false,
          segments: [
            const ButtonSegment<SearchSource>(
              value: SearchSource.local,
              label: Text('本地'),
            ),
            ButtonSegment<SearchSource>(
              value: SearchSource.online,
              label: Text(
                '在线',
                style: hasOnline
                    ? null
                    : TextStyle(
                        color: scheme.onSurface.withValues(alpha: 0.38),
                      ),
              ),
            ),
          ],
          selected: {_source},
          onSelectionChanged: (selection) => _switchSource(selection.first),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final online = _source == SearchSource.online;

    return SearchDialogFrame(
      title: _buildTitle(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Focus(
            onFocusChange: HotkeysHelper.onFocusChanges,
            child: TextField(
              // 在线来源沿用原在线搜索页的 key（既有测试可直接命中同一实例；
              // controller 由本 State 持有，换 key 不会重建 controller）。
              key: online ? const ValueKey('online-search-field') : null,
              controller: _searchController,
              autofocus: true,
              textInputAction: online
                  ? TextInputAction.search
                  : TextInputAction.done,
              style: TextStyle(color: scheme.onSurface),
              decoration: InputDecoration(
                prefixIcon: const Icon(Symbols.search),
                // 提示文案随来源切换：本地搜本机曲库，在线搜已启用的在线平台。
                hintText: online
                    ? '搜索在线音乐'
                    : '搜索本地曲库（歌曲、艺术家、专辑）',
                suffixIcon: ValueListenableBuilder<TextEditingValue>(
                  valueListenable: _searchController,
                  builder: (context, value, _) {
                    final hasText = canShowSearchClearAction(value.text);
                    return Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (hasText)
                          IconButton(
                            tooltip: '清除',
                            onPressed: _clearSearch,
                            icon: const Icon(Symbols.close),
                          ),
                        // 在线分支沿用**显式提交**（I2）：不套 450ms debounce，
                        // 否则弹窗内每次击键都会打满全部平台。
                        if (online)
                          IconButton(
                            tooltip: '在线搜索',
                            onPressed: hasText ? _submitOnlineSearch : null,
                            icon: const Icon(Symbols.travel_explore),
                          ),
                      ],
                    );
                  },
                ),
              ),
              onChanged: _onQueryChanged,
              onSubmitted: online ? (_) => _submitOnlineSearch() : null,
            ),
          ),
          if (!online)
            ValueListenableBuilder(
              valueListenable: _isSearching,
              builder: (context, searching, _) => AnimatedSwitcher(
                duration: const Duration(milliseconds: 150),
                child: searching
                    ? const Padding(
                        padding: EdgeInsets.only(top: 8.0),
                        child: LinearProgressIndicator(minHeight: 2.0),
                      )
                    : const SizedBox(height: 12.0),
              ),
            ),
          Expanded(
            child: online ? _buildOnlineBranch() : _buildLocalBranch(),
          ),
        ],
      ),
    );
  }

  /// 在线分支：面板自己带平台筛选、进度条与结果列表（D6：顶部保留播放历史入口）。
  ///
  /// 提交**不走参数**：宿主在 Enter / 点按钮 / 切来源时直接调
  /// `_panelKey.currentState!.submit(query)` —— 面板只在一帧的提交路径上被新建时，
  /// "递增一个参数"根本不会被它看见（那正是先前 `submitToken` 的坑）。
  Widget _buildOnlineBranch() {
    return OnlineSearchPanel(
      key: _panelKey,
      query: _searchController.text,
      onHistoryRequested: () =>
          _closeAndGo('${app_paths.STATS_PAGE}?source=online'),
      // 「去设置」必须让弹窗**先关掉自己**（I4）：弹窗挂在 root navigator 上，
      // 只让面板 `go('/settings')` 的话它会一直盖在设置页上方。
      onOpenSettings: () => _closeAndGo(app_paths.SETTINGS_PAGE),
    );
  }

  Widget _buildLocalBranch() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ValueListenableBuilder(
          valueListenable: _result,
          builder: (context, result, _) {
            return Padding(
              padding: const EdgeInsets.only(top: 12.0, bottom: 12.0),
              child: Wrap(
                spacing: 8.0,
                runSpacing: 8.0,
                children: List.generate(_tabs.length, (i) {
                  final selected = _currentIndex == i;
                  final canSwitch = canSwitchTab(
                    currentIndex: _currentIndex,
                    targetIndex: i,
                  );
                  final count = switch (i) {
                    0 => result.audios.length,
                    1 => result.artists.length,
                    _ => result.album.length,
                  };
                  final currentQuery = normalizedSearchQuery(
                    _searchController.text,
                  );
                  final showCount =
                      selected &&
                      result.query.isNotEmpty &&
                      result.query == currentQuery;
                  return SearchCategoryButton(
                    label: _tabs[i].label,
                    icon: _tabs[i].icon,
                    selected: selected,
                    count: showCount ? count : null,
                    onPressed: canSwitch ? () => _switchCategory(i) : null,
                  );
                }),
              ),
            );
          },
        ),
        Expanded(
          child: ValueListenableBuilder(
            valueListenable: _result,
            builder: (context, value, _) {
              final query = value.query.trim();
              if (query.isEmpty) {
                return const _SearchEmptyState(
                  icon: Symbols.search,
                  title: '输入关键词开始搜索',
                  message: '搜索范围：本机曲库里的歌曲、艺术家、专辑。',
                );
              }

              return DirectionalTabView(
                key: ValueKey('search_$_searchVersion'),
                index: _currentIndex,
                children: [
                  _buildMusicList(value),
                  _buildArtistList(value),
                  _buildAlbumList(value),
                ],
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildMusicList(UnionSearchResult value) {
    if (value.audios.isEmpty) {
      return const _SearchEmptyState(
        icon: Symbols.music_note,
        title: '本地曲库没有匹配的音乐',
        message: '换个关键词，或者切到艺术家、专辑再看。',
      );
    }
    return CustomScrollView(
      slivers: [
        SliverList.builder(
          itemCount: value.audios.length,
          itemBuilder: (context, i) => AudioTile(
            audioIndex: i,
            playlist: value.audios,
            action: _musicActionBar(value.audios[i]),
          ),
        ),
        const SliverPadding(padding: EdgeInsets.only(bottom: 12.0)),
      ],
    );
  }

  Widget _buildArtistList(UnionSearchResult value) {
    if (value.artists.isEmpty) {
      return const _SearchEmptyState(
        icon: Symbols.person,
        title: '本地曲库没有匹配的艺术家',
        message: '换个关键词，或者回到音乐结果里找。',
      );
    }
    return CustomScrollView(
      slivers: [
        SliverList.builder(
          itemCount: value.artists.length,
          itemBuilder: (context, i) => ArtistTile(artist: value.artists[i]),
        ),
        const SliverPadding(padding: EdgeInsets.only(bottom: 12.0)),
      ],
    );
  }

  Widget _buildAlbumList(UnionSearchResult value) {
    if (value.album.isEmpty) {
      return const _SearchEmptyState(
        icon: Symbols.album,
        title: '本地曲库没有匹配的专辑',
        message: '换个关键词，或者先从歌曲结果进入专辑。',
      );
    }
    return CustomScrollView(
      slivers: [
        SliverList.builder(
          itemCount: value.album.length,
          itemBuilder: (context, i) => AlbumTile(album: value.album[i]),
        ),
        const SliverPadding(padding: EdgeInsets.only(bottom: 12.0)),
      ],
    );
  }
}
