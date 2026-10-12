import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';
import 'package:pure_music/component/online_search_launcher.dart';
import 'package:pure_music/component/online_source_label.dart';
import 'package:pure_music/component/online_track_entry.dart';
import 'package:pure_music/component/quiet_empty_state.dart';
import 'package:pure_music/component/remote_media_cover.dart';
import 'package:pure_music/core/design_tokens.dart';
import 'package:pure_music/core/hotkeys.dart';
import 'package:pure_music/core/paths.dart' as app_paths;
import 'package:pure_music/core/search_action_state.dart';
import 'package:pure_music/page/page_scaffold.dart';
import 'package:pure_music/services/music_platform/index.dart';
import 'package:pure_music/services/music_platform/online_library/personal_online_playlist_controller.dart';

typedef OnlineMusicSearch =
    Future<MusicSearchPage> Function({
      required String keyword,
      required int limit,
      required int offset,
      required OnlineMusicCancelToken cancelToken,
    });

typedef OnlineTrackSelected =
    Future<void> Function(MusicSearchPage page, MusicTrack selected);

enum _OnlineSearchStatus { idle, loading, success, empty, error, noPlatform }

/// 每页条数（各平台都用同一个页大小，但**各自维护自己的 offset**，D6c:a）。
const int _searchPageSize = 30;

/// 单平台的搜索状态。
///
/// 多平台聚合下每个平台都有自己的一份：自己的累计结果、自己的分页游标、
/// 自己的错误（D6 / D6c:a）。一个平台失败不会动到另一个平台的状态。
final class _PlatformSearchState {
  _PlatformSearchState({required this.platform});

  final MusicPlatform platform;

  /// 该平台**累计**的结果页（`items` 即"已加载的全部结果"）。
  ///
  /// 首请求且未合并过分页时，这里仍是服务返回的**同一个对象** —— 选中某一行时把它
  /// 交给播放链路的既有语义（含对象身份）因此保持不变。
  MusicSearchPage? page;

  /// 该平台整体失败时的错误（D6：单平台失败不影响其它平台）。
  OnlineMusicException? error;

  /// 该平台在途的"加载更多"取消令牌（按平台各自取消，不牵连其它平台）。
  OnlineMusicCancelToken? token;

  OnlineMusicException? loadMoreError;
  bool loadingMore = false;

  /// 该平台"加载更多"自身的代次：同一平台重复触发时丢弃过期响应，
  /// 但**不会**影响别的平台的在途分页。
  int loadMoreRevision = 0;

  /// 上一次分页（含首请求）**原始**返回条数，用于 `hasMore` 的第二重判定。
  int lastPageCount = 0;

  List<MusicTrack> get items => page?.items ?? const <MusicTrack>[];

  int get total => page?.total ?? 0;

  /// `hasMore` 双重判定：已加载数量 < total **且** 上一页原始返回条数 == limit。
  ///
  /// 只信 `total` 不可靠（部分第三方接口不裁剪、或 total 与实际条数不一致），
  /// 沿用 `lyric_source_view.dart:436,443` 的既有先例。
  bool get hasMore {
    if (page == null) return false;
    final loaded = items;
    if (loaded.isEmpty) return false;
    if (lastPageCount < _searchPageSize) return false;
    return loaded.length < total;
  }
}

/// 结果列表的一行（表头 / 曲目 / 平台失败 / 该平台无结果 / 分页页脚）。
sealed class _SearchEntry {
  const _SearchEntry();
}

final class _GroupHeaderEntry extends _SearchEntry {
  const _GroupHeaderEntry(this.platform);

  final MusicPlatform platform;
}

final class _TrackEntry extends _SearchEntry {
  const _TrackEntry(this.group, this.track);

  final _PlatformSearchState group;
  final MusicTrack track;
}

final class _FailureEntry extends _SearchEntry {
  const _FailureEntry(this.group);

  final _PlatformSearchState group;
}

final class _EmptyGroupEntry extends _SearchEntry {
  const _EmptyGroupEntry(this.platform);

  final MusicPlatform platform;
}

/// **专辑结果行**（2026-10-12 ✓）：与曲目行**混在同一个列表**里 ✓，
/// 靠行首的「**专辑 · …**」类型前缀自报家门 ✓ —— 与参考产品"混合结果 + 类型前缀"的做法一致 ✓
///（详见 `docs/specs/home-explore-reference-analysis.md` §4.0 的订正 ✓）。
final class _AlbumEntry extends _SearchEntry {
  const _AlbumEntry(this.album);

  final OnlineAlbumSummary album;
}

/// **艺人结果行**（2026-10-12 ✓）：与曲目/专辑行**混在同一个列表** ✓，
/// 以「**艺人 · …**」自报家门 ✓（参考的混合结果 + 类型前缀 ✓）。
final class _ArtistEntry extends _SearchEntry {
  const _ArtistEntry(this.artist);

  final OnlineArtistSummary artist;
}

/// **艺人搜索失败的提示行**（只属于该平台 ✓，不静默 ✓）。
final class _ArtistFailureEntry extends _SearchEntry {
  const _ArtistFailureEntry(this.platform);

  final MusicPlatform platform;
}

/// **专辑搜索失败的提示行**（只属于该平台 ✓）：不静默 ✓ ——
/// 否则"没有专辑"与"专辑搜索失败"看起来一模一样 ✗。
final class _AlbumFailureEntry extends _SearchEntry {
  const _AlbumFailureEntry(this.platform);

  final MusicPlatform platform;
}

final class _FooterEntry extends _SearchEntry {
  const _FooterEntry(this.group);

  final _PlatformSearchState group;
}

class OnlineMusicPage extends StatefulWidget {
  const OnlineMusicPage({
    super.key,
    this.search,
    this.onTrackSelected,
    this.onHistoryRequested,
  });

  /// 单平台（网易云）搜索注入口。
  ///
  /// 保持既有语义不变：给出它就只走单平台链路、不显示平台筛选；不给出时页面走
  /// `OnlineMusicService.searchAggregated`，对**全部可搜索平台**并行聚合（D6:A）。
  final OnlineMusicSearch? search;

  final OnlineTrackSelected? onTrackSelected;
  final VoidCallback? onHistoryRequested;

  @override
  State<OnlineMusicPage> createState() => _OnlineMusicPageState();
}

class _OnlineMusicPageState extends State<OnlineMusicPage> {
  late final TextEditingController _searchController = TextEditingController();
  /// 搜索结果里的**专辑**（2026-10-12）：按平台各存一份 ✓（与曲目分组一一对应 ✓）。
  final Map<MusicPlatform, List<OnlineAlbumSummary>> _albums = {};

  /// 专辑搜索失败的平台（**只影响该平台的专辑行** ✓，曲目结果照常显示 ✓）。
  final Set<MusicPlatform> _albumsFailed = {};

  /// 搜索结果里的**艺人**（2026-10-12）：与专辑同一套（按平台各存一份 ✓）。
  final Map<MusicPlatform, List<OnlineArtistSummary>> _artists = {};

  /// 艺人搜索失败的平台（同样只影响该平台的艺人行 ✓）。
  final Set<MusicPlatform> _artistsFailed = {};

  _OnlineSearchStatus _status = _OnlineSearchStatus.idle;

  /// 已搜索的平台分组（顺序 = `builtinMusicPlatforms`）。
  final List<_PlatformSearchState> _groups = [];

  /// 「全部 / 各平台」筛选（D6:A）；null = 全部。
  ///
  /// ⚠️ 行为以**实现**为准（W6 起）：切换筛选会**重新发起搜索**（`_onFilterChanged` ⇒
  /// `setState` + `_submitSearch()`）—— 单选某个平台时只请求该平台，避免"为了看一个平台
  /// 却打了全部平台"。此处旧注释曾写"只在已取回结果上做显示过滤、不重新发请求"，
  /// 与实现相反，已按当前行为更正。
  MusicPlatform? _filter;

  /// 首请求（聚合请求）的取消令牌。
  OnlineMusicCancelToken? _cancelToken;

  /// 搜索**代次**：提交新关键词或重置时 +1，用来丢弃过期响应。
  int _generation = 0;

  /// 整次搜索失败（所有平台都失败）时的错误。
  OnlineMusicException? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      context.read<PersonalOnlinePlaylistController>().loadFavorites();
    });
  }

  @override
  void dispose() {
    _cancelAllTokens();
    _searchController.dispose();
    super.dispose();
  }

  void _cancelAllTokens() {
    _cancelToken?.cancel();
    _cancelToken = null;
    for (final group in _groups) {
      group.token?.cancel();
      group.token = null;
    }
  }

  /// 当前可搜索的平台（D3 门槛由服务层的 `searchablePlatforms` 决定）。
  ///
  /// 注入单平台搜索时不读 service —— 组件级测试与单平台嵌入用法都不需要 provider。
  List<MusicPlatform> _availablePlatforms(BuildContext context) {
    if (widget.search != null) return const [MusicPlatform.netease];
    final capabilities = context.read<OnlineMusicService>().capabilities;
    return [
      for (final platform in builtinMusicPlatforms)
        if (capabilities.searchablePlatforms.contains(platform)) platform,
    ];
  }

  _PlatformSearchState? _groupFor(MusicPlatform platform) {
    for (final group in _groups) {
      if (group.platform == platform) return group;
    }
    return null;
  }

  /// 当前实际显示的平台分组（W6 之后 = 本次**真正请求过**的平台）。
  ///
  /// 筛选不再只是"隐藏别的分组"：切换平台会用该平台**重新发起一次搜索**
  /// （单平台模式只请求这一个平台），因此 `_groups` 本身就只包含该平台。
  List<MusicPlatform> get _visiblePlatforms => [
    for (final group in _groups) group.platform,
  ];

  /// 本次搜索要请求的平台：默认「全部」，选定了平台就只请求它。
  List<MusicPlatform> _requestTargets(List<MusicPlatform> available) {
    final filter = _filter;
    if (filter == null) return available;
    return available.contains(filter) ? [filter] : available;
  }

  /// 切换平台筛选（W6）：单平台模式**只请求该平台**，不再"先全搜再过滤"。
  Future<void> _onFilterChanged(MusicPlatform? platform) async {
    if (_filter == platform) return;
    setState(() => _filter = platform);
    // 还没有搜索过（idle 且没有任何分组）时只记住选择，等用户提交关键词。
    if (_status == _OnlineSearchStatus.idle && _groups.isEmpty) return;
    if (normalizedSearchQuery(_searchController.text).isEmpty) return;
    await _submitSearch();
  }

  void _onQueryChanged(String raw) {
    if (_status == _OnlineSearchStatus.idle &&
        _groups.isEmpty &&
        _error == null) {
      return;
    }
    _resetSearch();
  }

  void _resetSearch() {
    // 取消在途请求（含各平台在途分页）并作废其代次，避免旧响应追加到新列表。
    _cancelAllTokens();
    _generation++;
    setState(() {
      _status = _OnlineSearchStatus.idle;
      _groups.clear();
      _error = null;
    });
  }

  void _clearSearch() {
    _searchController.clear();
    _resetSearch();
  }

  /// 发起一次搜索请求。
  ///
  /// - 注入单平台搜索时：只请求网易云，并把结果/错误包成 [AggregatedSearchResult]，
  ///   这样页面只有一条渲染路径；
  /// - 否则：走 `searchAggregated`（并行、每平台独立分页、每平台独立错误）。
  Future<AggregatedSearchResult> _request({
    required Iterable<MusicPlatform> platforms,
    required String keyword,
    required int limit,
    required int offset,
    required OnlineMusicCancelToken cancelToken,
  }) async {
    final injected = widget.search;
    if (injected != null) {
      try {
        final page = await injected(
          keyword: keyword,
          limit: limit,
          offset: offset,
          cancelToken: cancelToken,
        );
        return AggregatedSearchResult(
          perPlatform: {page.platform: page},
          failures: const {},
        );
      } on OnlineMusicException catch (error) {
        return AggregatedSearchResult(
          perPlatform: const {},
          failures: {MusicPlatform.netease: error},
        );
      }
    }
    return context.read<OnlineMusicService>().searchAggregated(
      platforms: platforms,
      keyword: keyword,
      limit: limit,
      offset: offset,
      cancelToken: cancelToken,
    );
  }

  /// **搜专辑**（2026-10-12）：只对"搜得出来、且专辑打得开"的平台 ✓
  ///（`openableSearchAlbumPlatforms` ✓ —— 搜出来点不开比不显示更糟 ✗）。
  ///
  /// 与曲目结果**并行**加载 ✓；单个平台失败**只影响该平台的专辑行** ✓，
  /// 而且会**如实标出**失败 ✓（否则"搜不到专辑"与"专辑搜索失败"看起来一样 ✗）。
  Future<void> _loadAlbums({
    required OnlineMusicService service,
    required List<MusicPlatform> platforms,
    required String keyword,
    required OnlineMusicCancelToken token,
    required int generation,
  }) async {
    final targets = [
      for (final platform in platforms)
        if (service.capabilities.openableSearchAlbumPlatforms.contains(
          platform,
        ))
          platform,
    ];
    if (targets.isEmpty) return;
    final results = await Future.wait([
      for (final platform in targets)
        () async {
          try {
            final albums = await service.searchAlbums(
              platform: platform,
              keyword: keyword,
              limit: _searchPageSize,
              offset: 0,
              cancelToken: token,
            );
            return (
              platform: platform,
              albums: albums,
              failed: false,
            );
          } on Object {
            return (
              platform: platform,
              albums: const <OnlineAlbumSummary>[],
              failed: true,
            );
          }
        }(),
    ]);
    if (!mounted || generation != _generation) return;
    setState(() {
      for (final result in results) {
        if (result.albums.isNotEmpty) _albums[result.platform] = result.albums;
        if (result.failed) _albumsFailed.add(result.platform);
      }
    });
  }

  /// **搜艺人**（2026-10-12）：只对"搜得出来、且艺人页打得开"的平台 ✓
  ///（`openableSearchArtistPlatforms` ✓）。失败**只影响该平台的艺人行**且如实标出 ✓。
  Future<void> _loadArtists({
    required OnlineMusicService service,
    required List<MusicPlatform> platforms,
    required String keyword,
    required OnlineMusicCancelToken token,
    required int generation,
  }) async {
    final targets = [
      for (final platform in platforms)
        if (service.capabilities.openableSearchArtistPlatforms.contains(
          platform,
        ))
          platform,
    ];
    if (targets.isEmpty) return;
    final results = await Future.wait([
      for (final platform in targets)
        () async {
          try {
            final artists = await service.searchArtists(
              platform: platform,
              keyword: keyword,
              limit: _searchPageSize,
              offset: 0,
              cancelToken: token,
            );
            return (
              platform: platform,
              artists: artists,
              failed: false,
            );
          } on Object {
            return (
              platform: platform,
              artists: const <OnlineArtistSummary>[],
              failed: true,
            );
          }
        }(),
    ]);
    if (!mounted || generation != _generation) return;
    setState(() {
      for (final result in results) {
        if (result.artists.isNotEmpty) {
          _artists[result.platform] = result.artists;
        }
        if (result.failed) _artistsFailed.add(result.platform);
      }
    });
  }

  Future<void> _submitSearch() async {
    final query = normalizedSearchQuery(_searchController.text);
    if (query.isEmpty) {
      _resetSearch();
      return;
    }

    final platforms = _requestTargets(_availablePlatforms(context));
    if (platforms.isEmpty) {
      _cancelAllTokens();
      _generation++;
      setState(() {
        _status = _OnlineSearchStatus.noPlatform;
        _groups.clear();
        _error = null;
      });
      return;
    }

    _cancelAllTokens();
    final token = OnlineMusicCancelToken();
    final generation = ++_generation;
    _cancelToken = token;
    setState(() {
      _status = _OnlineSearchStatus.loading;
      _groups
        ..clear()
        ..addAll([
          for (final platform in platforms)
            _PlatformSearchState(platform: platform),
        ]);
      // 专辑/艺人结果与曲目结果**同时开跑** ✓（清掉上一次的 ✓）。
      _albums.clear();
      _albumsFailed.clear();
      _artists.clear();
      _artistsFailed.clear();
      _error = null;
    });

    // 专辑与曲目**并行**：专辑失败只影响专辑行 ✓（曲目照常 ✓）。
    // 用**可空**读取（与本页其它地方一致 ✓：服务未注入时应静默跳过 ✓，不能抛 ✗）。
    final albumService = context.read<OnlineMusicService?>();
    if (albumService != null) {
      unawaited(
        _loadAlbums(
          service: albumService,
          platforms: platforms,
          keyword: query,
          token: token,
          generation: generation,
        ),
      );
      unawaited(
        _loadArtists(
          service: albumService,
          platforms: platforms,
          keyword: query,
          token: token,
          generation: generation,
        ),
      );
    }

    try {
      final result = await _request(
        platforms: platforms,
        keyword: query,
        limit: _searchPageSize,
        offset: 0,
        cancelToken: token,
      );
      if (!mounted || generation != _generation) return;
      setState(() => _applyInitialResult(result, platforms));
    } on OnlineMusicException catch (error) {
      if (!mounted || generation != _generation) return;
      if (error.kind == OnlineMusicErrorKind.cancelled) {
        setState(() => _status = _OnlineSearchStatus.idle);
        return;
      }
      setState(() {
        _error = error;
        _status = _OnlineSearchStatus.error;
      });
    } catch (_) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _error = const OnlineMusicException(
          kind: OnlineMusicErrorKind.unknown,
          safeMessage: '音乐服务请求失败',
        );
        _status = _OnlineSearchStatus.error;
      });
    } finally {
      if (generation == _generation) _cancelToken = null;
    }
  }

  /// 把首请求结果摊进各平台分组，并决定整页状态。
  void _applyInitialResult(
    AggregatedSearchResult result,
    List<MusicPlatform> requested,
  ) {
    _groups
      ..clear()
      ..addAll([
        for (final platform in requested)
          _PlatformSearchState(platform: platform),
      ]);

    for (final group in _groups) {
      final page = result.perPlatform[group.platform];
      if (page != null) {
        group.page = page;
        group.lastPageCount = page.items.length;
      }
      group.error = result.failures[group.platform];
    }

    // 全部平台都失败 ⇒ 整页错误（保留第一个失败的错误分类与文案）。
    final failures = [
      for (final group in _groups)
        if (group.error != null) group.error!,
    ];
    final succeeded = result.perPlatform.isNotEmpty;
    if (!succeeded && failures.isNotEmpty) {
      if (failures.every(
        (error) => error.kind == OnlineMusicErrorKind.cancelled,
      )) {
        _status = _OnlineSearchStatus.idle;
        return;
      }
      _error = failures.first;
      _status = _OnlineSearchStatus.error;
      return;
    }

    // 成功但一条都没有（且没有失败平台）⇒ 既有的"没有找到"空状态。
    if (result.isEmpty && failures.isEmpty) {
      _status = _OnlineSearchStatus.empty;
      return;
    }

    _status = _OnlineSearchStatus.success;
  }

  /// 某个平台各自的「加载更多」：`offset = 该平台已加载数量`、同一 keyword、每页 `_searchPageSize`。
  Future<void> _loadMore(MusicPlatform platform) async {
    final group = _groupFor(platform);
    if (group == null || group.loadingMore || !group.hasMore) return;
    final query = normalizedSearchQuery(_searchController.text);
    if (query.isEmpty) return;

    final offset = group.items.length;
    final generation = _generation;
    final revision = ++group.loadMoreRevision;
    group.token?.cancel();
    final token = OnlineMusicCancelToken();
    group.token = token;
    setState(() {
      group.loadingMore = true;
      group.loadMoreError = null;
    });

    try {
      final result = await _request(
        platforms: [platform],
        keyword: query,
        limit: _searchPageSize,
        offset: offset,
        cancelToken: token,
      );
      if (!mounted || generation != _generation) return;
      if (revision != group.loadMoreRevision) return;
      final failure = result.failures[platform];
      final page = result.perPlatform[platform];
      setState(() {
        if (failure != null) {
          if (failure.kind == OnlineMusicErrorKind.cancelled) {
            group.loadingMore = false;
            return;
          }
          group.loadingMore = false;
          group.loadMoreError = failure;
          return;
        }
        if (page != null) _mergeLoadedPage(group, page);
        group.loadingMore = false;
      });
    } on OnlineMusicException catch (error) {
      if (!mounted ||
          generation != _generation ||
          revision != group.loadMoreRevision) {
        return;
      }
      setState(() {
        group.loadingMore = false;
        if (error.kind != OnlineMusicErrorKind.cancelled) {
          group.loadMoreError = error;
        }
      });
    } catch (_) {
      if (!mounted ||
          generation != _generation ||
          revision != group.loadMoreRevision) {
        return;
      }
      setState(() {
        group.loadingMore = false;
        group.loadMoreError = const OnlineMusicException(
          kind: OnlineMusicErrorKind.unknown,
          safeMessage: '加载更多失败，请稍后重试',
        );
      });
    } finally {
      if (revision == group.loadMoreRevision) group.token = null;
    }
  }

  /// 把新一页追加到该平台已加载结果：按 `track.ref` 去重并保留原有顺序
  /// （搜索链路没有去重，重复 ref 会静默跳过进场动画并让测试 finder 歧义）。
  void _mergeLoadedPage(_PlatformSearchState group, MusicSearchPage next) {
    final current = group.page;
    if (current == null) return;
    final seen = <PlatformTrackRef>{
      for (final track in current.items) track.ref,
    };
    final merged = <MusicTrack>[...current.items];
    for (final track in next.items) {
      if (seen.add(track.ref)) merged.add(track);
    }
    group.page = MusicSearchPage(
      platform: current.platform,
      items: merged,
      offset: current.offset,
      limit: current.limit,
      total: next.total ?? current.total,
    );
    group.lastPageCount = next.items.length;
    group.loadMoreError = null;
  }

  @override
  Widget build(BuildContext context) {
    final platforms = _availablePlatforms(context);
    return PageScaffold(
      title: '在线音乐',
      actions: [
        IconButton.filledTonal(
          tooltip: '在线播放历史',
          onPressed:
              widget.onHistoryRequested ??
              () => context.go('${app_paths.STATS_PAGE}?source=online'),
          icon: const Icon(Symbols.history),
        ),
      ],
      body: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Focus(
              onFocusChange: HotkeysHelper.onFocusChanges,
              child: TextField(
                key: const ValueKey('online-search-field'),
                controller: _searchController,
                textInputAction: TextInputAction.search,
                decoration: InputDecoration(
                  prefixIcon: const Icon(Symbols.search),
                  hintText: '搜索在线音乐',
                  suffixIcon: ListenableBuilder(
                    listenable: _searchController,
                    builder: (context, _) {
                      final hasText = canShowSearchClearAction(
                        _searchController.text,
                      );
                      return Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (hasText)
                            IconButton(
                              tooltip: '清除',
                              onPressed: _clearSearch,
                              icon: const Icon(Symbols.close),
                            ),
                          IconButton(
                            tooltip: '在线搜索',
                            onPressed:
                                hasText &&
                                    _status != _OnlineSearchStatus.loading
                                ? _submitSearch
                                : null,
                            icon: const Icon(Symbols.travel_explore),
                          ),
                        ],
                      );
                    },
                  ),
                ),
                onChanged: _onQueryChanged,
                onSubmitted: (_) {
                  if (_status != _OnlineSearchStatus.loading) _submitSearch();
                },
              ),
            ),
            if (platforms.isNotEmpty) ...[
              const SizedBox(height: 8.0),
              _buildPlatformFilter(platforms),
            ],
            SizedBox(
              height: 12.0,
              child: _status == _OnlineSearchStatus.loading
                  ? const Align(
                      alignment: Alignment.topCenter,
                      child: LinearProgressIndicator(minHeight: 2.0),
                    )
                  : null,
            ),
            Expanded(child: _buildSearchBody()),
          ],
        ),
      ),
    );
  }

  /// 「全部 / 各平台」筛选（D6:A / W6）。
  ///
  /// - ≥2 个可用平台：可切换的「全部 / 各平台」，**切到某个平台就只搜索它**；
  /// - 只有 1 个可用平台：不给假的选项，而是明确写出"当前平台：X" ——
  ///   让用户看得懂现在搜的就是这一家，而不是以为筛选功能不存在。
  Widget _buildPlatformFilter(List<MusicPlatform> platforms) {
    if (platforms.length < 2) {
      final scheme = Theme.of(context).colorScheme;
      return Row(
        children: [
          Icon(Symbols.public, size: 14, color: scheme.onSurfaceVariant),
          const SizedBox(width: Spacing.xs),
          Text(
            '当前平台：${musicPlatformLabel(platforms.single)}',
            key: const ValueKey('online-search-single-platform'),
            style: TextStyle(
              color: scheme.onSurfaceVariant,
              fontSize: AppType.caption,
            ),
          ),
        ],
      );
    }
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: SegmentedButton<MusicPlatform?>(
        showSelectedIcon: false,
        segments: [
          const ButtonSegment<MusicPlatform?>(value: null, label: Text('全部')),
          for (final platform in platforms)
            ButtonSegment<MusicPlatform?>(
              value: platform,
              label: Text(musicPlatformLabel(platform)),
            ),
        ],
        selected: {_filter},
        onSelectionChanged: (selection) => _onFilterChanged(selection.first),
      ),
    );
  }

  Widget _buildSearchBody() {
    return switch (_status) {
      _OnlineSearchStatus.idle => const QuietEmptyState(
        icon: Symbols.cloud,
        title: '在线搜索',
        message: '输入关键词，搜索已启用的在线平台。',
      ),
      _OnlineSearchStatus.loading => const QuietEmptyState(
        icon: Symbols.hourglass_top,
        title: '正在搜索',
        message: '正在获取在线结果。',
      ),
      _OnlineSearchStatus.empty => QuietEmptyState(
        icon: Symbols.cloud_off,
        title: '没有找到在线曲目',
        message: '换个关键词再试试。',
        action: FilledButton.icon(
          onPressed: _submitSearch,
          icon: const Icon(Symbols.refresh),
          label: const Text('重新搜索'),
        ),
      ),
      _OnlineSearchStatus.noPlatform => QuietEmptyState(
        icon: Symbols.cloud_off,
        title: '没有可搜索的平台',
        message: '请先在设置里启用平台，并为其配置可用的服务。',
        action: FilledButton.icon(
          onPressed: () => context.go(app_paths.SETTINGS_PAGE),
          icon: const Icon(Symbols.settings),
          label: const Text('去设置'),
        ),
      ),
      _OnlineSearchStatus.error => _buildError(),
      _OnlineSearchStatus.success => _buildResultList(),
    };
  }

  Widget _buildError() {
    final error = _error!;
    final unauthorized = error.kind == OnlineMusicErrorKind.notConfigured;
    return QuietEmptyState(
      icon: unauthorized ? Symbols.key_off : Symbols.cloud_off,
      title: '在线搜索失败',
      message: error.safeMessage,
      action: FilledButton.icon(
        onPressed: unauthorized
            ? () => context.go(app_paths.SETTINGS_PAGE)
            : _submitSearch,
        icon: Icon(unauthorized ? Symbols.settings : Symbols.refresh),
        label: Text(unauthorized ? '去设置' : '重试'),
      ),
    );
  }

  /// 把各平台分组摊平成一维行列表，交给 `ListView.builder` 保持懒构建。
  List<_SearchEntry> _buildEntries() {
    final visible = _visiblePlatforms;
    // 只有一个平台（或筛选到单一平台）时不摆分组表头：多平台聚合才需要它。
    final showHeaders = visible.length > 1;
    final entries = <_SearchEntry>[];
    for (final group in _groups) {
      if (!visible.contains(group.platform)) continue;
      if (showHeaders) entries.add(_GroupHeaderEntry(group.platform));
      if (group.error != null) {
        entries.add(_FailureEntry(group));
        continue;
      }
      if (group.items.isEmpty) {
        entries.add(_EmptyGroupEntry(group.platform));
        continue;
      }
      for (final track in group.items) {
        entries.add(_TrackEntry(group, track));
      }
      // **专辑结果与曲目混排** ✓（同一平台内：曲目之后接专辑 ✓）——
      // 每行以「专辑 · …」自报家门 ✓，与参考"混合结果 + 类型前缀"一致 ✓。
      final albums = _albums[group.platform];
      if (albums != null) {
        for (final album in albums) {
          entries.add(_AlbumEntry(album));
        }
      }
      if (_albumsFailed.contains(group.platform)) {
        entries.add(_AlbumFailureEntry(group.platform));
      }
      // **艺人结果同样混排** ✓（曲目 → 专辑 → 艺人 ✓；每行自报类型 ✓）。
      final artists = _artists[group.platform];
      if (artists != null) {
        for (final artist in artists) {
          entries.add(_ArtistEntry(artist));
        }
      }
      if (_artistsFailed.contains(group.platform)) {
        entries.add(_ArtistFailureEntry(group.platform));
      }
      entries.add(_FooterEntry(group));
    }
    return entries;
  }

  Widget _buildResultList() {
    final entries = _buildEntries();
    return ListView.builder(
      // 底部留白：迷你播放器浮在底部（64 高 + 32 边距），否则「加载更多」会被它挡住。
      padding: const EdgeInsets.only(bottom: 96.0),
      itemCount: entries.length,
      itemBuilder: (context, index) => switch (entries[index]) {
        _GroupHeaderEntry(:final platform) => _buildGroupHeader(platform),
        _TrackEntry(:final group, :final track) => _buildTrackRow(group, track),
        _AlbumEntry(:final album) => _buildAlbumRow(album),
        _AlbumFailureEntry(:final platform) => _buildAlbumFailureRow(platform),
        _ArtistEntry(:final artist) => _buildArtistRow(artist),
        _ArtistFailureEntry(:final platform) => _buildArtistFailureRow(
          platform,
        ),
        _FailureEntry(:final group) => _buildFailureRow(group),
        _EmptyGroupEntry(:final platform) => _buildEmptyGroupRow(platform),
        _FooterEntry(:final group) => _buildLoadMoreFooter(group),
      },
    );
  }

  Widget _buildGroupHeader(MusicPlatform platform) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(8.0, 12.0, 8.0, 4.0),
      child: Text(
        musicPlatformLabel(platform),
        key: ValueKey('online-search-group-${platform.name}'),
        style: TextStyle(
          color: scheme.onSurfaceVariant,
          fontSize: AppType.caption,
          fontWeight: AppType.weightSemibold,
        ),
      ),
    );
  }

  /// 一行搜索结果。
  ///
  /// 组装、来源标记、收藏与"加入歌单"都收敛在 [OnlineTrackEntry] 里；
  /// 来源取自**曲目自己的 ref**（与其它在线列表同一条规则），而不是搜索分组。
  Widget _buildTrackRow(_PlatformSearchState group, MusicTrack track) =>
      OnlineTrackEntry(
        track: track,
        onTap: () => _selectTrack(group, track),
      );

  /// 一行**专辑结果**：与曲目行混排 ✓，元信息以「**专辑 · 年份 · N 首**」自报家门 ✓。
  ///
  /// 自带透明 `Material` ✓ —— 可点区域**不假设**祖先里有 Material（R84 的教训 ✓）。
  Widget _buildAlbumRow(OnlineAlbumSummary album) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Spacing.sm, vertical: 2),
      child: Material(
        type: MaterialType.transparency,
        borderRadius: AppRadius.smCircular,
        child: InkWell(
          borderRadius: AppRadius.smCircular,
          onTap: () => context.push(
            app_paths.ONLINE_ALBUM_PAGE,
            extra: (
              platform: album.platform,
              albumId: album.id,
              name: album.name,
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: Spacing.sm,
              vertical: 8.0,
            ),
            child: Row(
              children: [
                ClipRRect(
                  borderRadius: AppRadius.xsCircular,
                  child: SizedBox.square(
                    dimension: 48.0,
                    child: RemoteMediaCover(
                      coverUri: album.coverUri,
                      placeholder: ColoredBox(
                        color: scheme.surfaceContainerHighest,
                        child: Icon(
                          Symbols.album,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                      cacheWidth: 96,
                      cacheHeight: 96,
                    ),
                  ),
                ),
                const SizedBox(width: Spacing.md),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        album.name,
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
                        _albumDetailsOf(album),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: scheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
                OnlineSourceLabel(
                  label: platformLabelForIdentityOnly(album.identity),
                  color: scheme.onSurfaceVariant,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 一行**艺人结果**：与专辑行同一套做法 ✓（混排 + 类型前缀 ✓；自带透明 Material ✓）。
  Widget _buildArtistRow(OnlineArtistSummary artist) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Spacing.sm, vertical: 2),
      child: Material(
        type: MaterialType.transparency,
        borderRadius: AppRadius.smCircular,
        child: InkWell(
          borderRadius: AppRadius.smCircular,
          onTap: () => context.push(
            app_paths.ONLINE_ARTIST_PAGE,
            extra: (
              platform: artist.platform,
              artistId: artist.id,
              name: artist.name,
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: Spacing.sm,
              vertical: 8.0,
            ),
            child: Row(
              children: [
                ClipOval(
                  child: SizedBox.square(
                    dimension: 48.0,
                    child: RemoteMediaCover(
                      coverUri: artist.avatarUri,
                      placeholder: ColoredBox(
                        color: scheme.surfaceContainerHighest,
                        child: Icon(
                          Symbols.artist,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                      cacheWidth: 96,
                      cacheHeight: 96,
                    ),
                  ),
                ),
                const SizedBox(width: Spacing.md),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        artist.name,
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
                        '艺人',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: scheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
                OnlineSourceLabel(
                  label: platformLabelForIdentityOnly(artist.identity),
                  color: scheme.onSurfaceVariant,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 艺人搜索失败：**如实标出** ✓（不静默 ✓，也不影响该平台的曲目结果 ✓）。
  Widget _buildArtistFailureRow(MusicPlatform platform) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 8.0),
      child: Row(
        children: [
          Icon(Symbols.artist, size: 16.0, color: scheme.onSurfaceVariant),
          const SizedBox(width: 8.0),
          Expanded(
            child: Text(
              '${musicPlatformLabel(platform)}的艺人结果没取到（曲目结果不受影响）',
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }

  /// 专辑结果的元信息：**平台声明**的事实 ✓（类型前缀 + 年份 + 曲目数 ✓）。
  String _albumDetailsOf(OnlineAlbumSummary album) => [
    '专辑',
    if (album.releaseTime case final time?) '${time.year} 年',
    if (album.trackCount case final count?) '$count 首',
  ].join(' · ');

  /// 专辑搜索失败：**如实标出** ✓（不静默 ✓，也不影响该平台的曲目结果 ✓）。
  Widget _buildAlbumFailureRow(MusicPlatform platform) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 8.0),
      child: Row(
        children: [
          Icon(Symbols.album, size: 16.0, color: scheme.onSurfaceVariant),
          const SizedBox(width: 8.0),
          Expanded(
            child: Text(
              '${musicPlatformLabel(platform)}的专辑结果没取到（曲目结果不受影响）',
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }

  /// 单平台失败：只影响这个分组，其它平台的结果照常显示（D6 / §8）。
  Widget _buildFailureRow(_PlatformSearchState group) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 12.0),
      child: Row(
        children: [
          Icon(Symbols.error, size: 16.0, color: scheme.error),
          const SizedBox(width: 8.0),
          Expanded(
            child: Text(
              group.error!.safeMessage,
              style: TextStyle(color: scheme.error),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyGroupRow(MusicPlatform platform) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 12.0),
      child: Text(
        '${musicPlatformLabel(platform)}没有找到结果',
        style: TextStyle(color: scheme.onSurfaceVariant),
      ),
    );
  }

  /// 某个平台的分页入口：可加载 → 「加载更多」；加载中 → 转圈且禁用；
  /// 失败 → 安全提示 + 可重试；到底 → 「没有更多了」。
  ///
  /// 多平台时 key 带平台名，单平台（含注入单平台搜索与筛选到单一平台）沿用既有 key。
  Widget _buildLoadMoreFooter(_PlatformSearchState group) {
    final scheme = Theme.of(context).colorScheme;
    final single = _visiblePlatforms.length <= 1;
    final loadMoreKey = single
        ? const ValueKey('online-search-load-more')
        : ValueKey('online-search-load-more-${group.platform.name}');
    final retryKey = single
        ? const ValueKey('online-search-load-more-retry')
        : ValueKey('online-search-load-more-retry-${group.platform.name}');
    final error = group.loadMoreError;
    if (error != null) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 12.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              error.safeMessage,
              textAlign: TextAlign.center,
              style: TextStyle(color: scheme.error),
            ),
            const SizedBox(height: 8.0),
            FilledButton.tonalIcon(
              key: retryKey,
              onPressed: () => _loadMore(group.platform),
              icon: const Icon(Symbols.refresh),
              label: const Text('重试'),
            ),
          ],
        ),
      );
    }
    if (group.loadingMore) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 16.0),
        child: Center(
          child: SizedBox(
            width: 20.0,
            height: 20.0,
            child: CircularProgressIndicator(strokeWidth: 2.0),
          ),
        ),
      );
    }
    if (group.hasMore) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 12.0),
        child: Center(
          child: FilledButton.tonalIcon(
            key: loadMoreKey,
            onPressed: () => _loadMore(group.platform),
            icon: const Icon(Symbols.expand_more),
            label: const Text('加载更多'),
          ),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 16.0),
      child: Center(
        child: Text('没有更多了', style: TextStyle(color: scheme.onSurfaceVariant)),
      ),
    );
  }

  Future<void> _selectTrack(
    _PlatformSearchState group,
    MusicTrack selected,
  ) async {
    // `page` 是该平台**累积**后的结果页，`page.items` 即“该平台已加载的全部结果”：
    // 队列因此只包含同一平台的曲目，来源身份不会被混进别的平台（I1）。
    final page = group.page;
    if (page == null) return;
    final onTrackSelected = widget.onTrackSelected;
    if (onTrackSelected != null) {
      await onTrackSelected(page, selected);
      return;
    }
    await playOnlineSearchResult(
      context,
      tracks: page.items,
      selectedRef: selected.ref,
    );
  }
}
