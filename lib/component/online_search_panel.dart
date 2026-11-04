import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';
import 'package:pure_music/component/online_album_row.dart';
import 'package:pure_music/component/online_playback_launcher.dart';
import 'package:pure_music/component/online_search_state.dart';
import 'package:pure_music/component/online_source_label.dart';
import 'package:pure_music/component/online_track_entry.dart';
import 'package:pure_music/component/quiet_empty_state.dart';
import 'package:pure_music/component/remote_media_cover.dart';
import 'package:pure_music/core/design_tokens.dart';
import 'package:pure_music/core/paths.dart' as app_paths;
import 'package:pure_music/core/search_action_state.dart';
import 'package:pure_music/services/music_platform/index.dart';

/// 单平台（既有语义）搜索注入口：给出它就只走单平台链路、不显示平台筛选。
typedef OnlineSearchQuery =
    Future<MusicSearchPage> Function({
      required String keyword,
      required int limit,
      required int offset,
      required OnlineMusicCancelToken cancelToken,
    });

enum OnlineSearchStatus { idle, loading, success, empty, error, noPlatform }

/// **在线搜索面板**（2026-11-03 从 `page/online_music_page.dart` 抽出）。
///
/// 只做在线搜索这一段：平台筛选、多平台并行首请求、各平台独立分页、
/// 曲目/专辑/艺人混排、失败如实标出。**不含**输入框与页面外壳 ——
/// 查询词与提交信号由宿主（搜索弹窗）提供，标题由弹窗的 frame 提供。
///
/// 提交语义是**显式提交**（Enter / 「在线搜索」按钮），不是边打边搜：
/// 弹窗每次击键都打满全部平台是不可接受的代价。
///
/// 分层：`component/` ⇒ L3，只 import `services/`（L2）与 L2 公共端口 ⇒ 向下，合法。
/// 边界合规：可搜索判据只读 `OnlineMusicService.capabilities.searchableIdentities`，
/// 不深引 Provider 层配置契约（`online_music_dependency_boundary_test.dart` 守着）。
class OnlineSearchPanel extends StatefulWidget {
  const OnlineSearchPanel({
    super.key,
    required this.query,
    this.search,
    this.onHistoryRequested,
    this.onOpenSettings,
    this.onTrackSelected,
  });

  /// 当前查询词（宿主共享 controller 的**原始文本**；面板自己归一化）。
  ///
  /// 宿主改它 ⇒ 面板把既有结果标记为"查询已过期"并清空（不自动搜）。
  final String query;

  /// 单平台搜索注入口（组件级测试与单平台嵌入用法）；null ⇒ 走聚合服务。
  final OnlineSearchQuery? search;

  /// 「在线播放历史」入口（Spec D6）。null ⇒ 不显示该入口。
  final VoidCallback? onHistoryRequested;

  /// 「去设置」的处置（Spec I4）。null ⇒ 直接 `context.go('/settings')`。
  ///
  /// 搜索弹窗会注入一个"**先关掉自己**再跳"的回调 —— 弹窗挂在 root navigator 上，
  /// 只 `go` 的话它会一直盖在设置页上方。不能指望路由监听的副作用来关：
  /// 那依赖"宿主恰好有个会变化的位置"，在没有路由的宿主里根本不成立。
  final VoidCallback? onOpenSettings;

  /// 覆盖"点曲目起播"（既有做法，测试注入用）；null ⇒ `playOnlineSearchResult`。
  final Future<void> Function(MusicSearchPage page, MusicTrack selected)?
  onTrackSelected;

  @override
  State<OnlineSearchPanel> createState() => OnlineSearchPanelState();
}

class OnlineSearchPanelState extends State<OnlineSearchPanel> {
  /// 搜索结果里的**专辑**（2026-10-12）：按**平台身份**各存一份 ✓（与曲目分组一一对应 ✓）。
  ///
  /// 2.2（R4/G3）：键从枚举换成身份 —— 用枚举时两个自定义平台的专辑会互相覆盖。
  final Map<PlatformIdentity, List<OnlineAlbumSummary>> _albums = {};

  /// 专辑搜索失败的平台身份（**只影响该身份的专辑行** ✓，曲目结果照常显示 ✓）。
  final Set<PlatformIdentity> _albumsFailed = {};

  /// 搜索结果里的**艺人**（2026-10-12）：与专辑同一套（按平台身份各存一份 ✓）。
  final Map<PlatformIdentity, List<OnlineArtistSummary>> _artists = {};

  /// 艺人搜索失败的平台身份（同样只影响该身份的艺人行 ✓）。
  final Set<PlatformIdentity> _artistsFailed = {};

  OnlineSearchStatus _status = OnlineSearchStatus.idle;

  /// 已搜索的平台分组（顺序 = 本次请求的身份顺序）。
  final List<OnlineSearchPlatformState> _groups = [];

  /// 「全部 / 各平台」筛选（D6:A）；null = 全部。
  ///
  /// 2.2：筛选的键是**平台身份**（否则两个自定义平台无法分别筛）。
  ///
  /// ⚠️ 行为以**实现**为准：切换筛选会**重新发起搜索**（`_onFilterChanged` ⇒
  /// `setState` + `submit`）—— 单选某个平台时只请求该平台，避免"为了看一个平台
  /// 却打了全部平台"。此处旧注释曾写"只在已取回结果上做显示过滤、不重新发请求"，
  /// 与实现相反，已按当前行为更正。
  PlatformIdentity? _filter;

  /// 首请求（聚合请求）的取消令牌。
  OnlineMusicCancelToken? _cancelToken;

  /// 搜索**代次**：提交新关键词或重置时 +1，用来丢弃过期响应。
  int _generation = 0;

  /// 整次搜索失败（所有平台都失败）时的错误。
  OnlineMusicException? _error;

  /// 最近一次提交用的查询词（面板自持，不再读宿主的输入框）。
  String _submittedQuery = '';

  @override
  void didUpdateWidget(OnlineSearchPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 查询词变了（还没提交）⇒ 把既有结果标记为"过期"并清空，
    // 避免"结果与输入框不一致"（同原页 `_onQueryChanged → _resetSearch`）。
    // 提交由宿主经 `GlobalKey<OnlineSearchPanelState>.submit(query)` 直接触发 ——
    // 面板可能是在切来源时**新建**的（那时没有任何 `didUpdateWidget`），
    // 用"递增 token"会漏掉这一类首次提交。
    //
    // ⚠️ 判据排除"这正是刚提交用的词"：`submit(query)` 拿的是宿主的**最新**文本，
    // 而 `widget.query` 要到下一次重建才追上来。不排除的话，紧接着的那次重建会把
    // 刚取回的结果当成"查询已改"清掉（表现为"回车后什么都没发生"）。
    final next = normalizedSearchQuery(widget.query);
    final previous = normalizedSearchQuery(oldWidget.query);
    if (next != previous && next != _submittedQuery) {
      _onQueryChanged();
    }
  }

  @override
  void dispose() {
    cancelAll();
    super.dispose();
  }

  /// 取消**全部**在途请求（首请求 + 各平台在途分页）并作废其代次。
  ///
  /// 宿主在切换来源或关闭弹窗时调用；面板自身 dispose 时也调用。
  void cancelAll() {
    _cancelToken?.cancel();
    _cancelToken = null;
    for (final group in _groups) {
      group.token?.cancel();
      group.token = null;
    }
    _generation++;
  }

  OnlineSearchPlatformState? _groupFor(PlatformIdentity identity) {
    final normalized = identity.normalized;
    for (final group in _groups) {
      if (group.identity == normalized) return group;
    }
    return null;
  }

  /// 当前实际显示的**平台身份**分组（W6 之后 = 本次**真正请求过**的平台）。
  ///
  /// 筛选不再只是"隐藏别的分组"：切换平台会用该平台**重新发起一次搜索**
  /// （单平台模式只请求这一个平台），因此 `_groups` 本身就只包含该平台。
  List<PlatformIdentity> get _visibleIdentities => [
    for (final group in _groups) group.identity,
  ];

  /// 本次搜索要请求的平台身份：默认「全部」，选定了平台就只请求它。
  List<PlatformIdentity> _requestTargets(List<PlatformIdentity> available) {
    final filter = _filter;
    if (filter == null) return available;
    return available.contains(filter) ? [filter] : available;
  }

  /// 当前可搜索的**平台身份**（2.2 / R4：按身份列平台，而不是只列内置枚举）。
  ///
  /// 门槛由服务层的 `searchableIdentities` 决定（D3：Search + Stream 候选都要有），
  /// 面板不再自己按枚举过滤 —— 否则自定义平台永远进不了筛选与分组。
  ///
  /// 注入单平台搜索时不读 service —— 组件级测试与单平台嵌入用法都不需要 provider。
  List<PlatformIdentity> _availableIdentities(BuildContext context) {
    if (widget.search != null) {
      return const [PlatformIdentity.builtin(MusicPlatform.netease)];
    }
    final service = context.read<OnlineMusicService?>();
    if (service == null) return const [];
    return [
      for (final identity in service.capabilities.searchableIdentities)
        identity.normalized,
    ];
  }

  /// 切换平台筛选（W6）：单平台模式**只请求该平台**，不再"先全搜再过滤"。
  Future<void> _onFilterChanged(PlatformIdentity? identity) async {
    if (_filter == identity) return;
    setState(() => _filter = identity);
    // 还没有搜索过（idle 且没有任何分组）时只记住选择，等用户提交关键词。
    if (_status == OnlineSearchStatus.idle && _groups.isEmpty) return;
    if (normalizedSearchQuery(widget.query).isEmpty) return;
    await submit(widget.query);
  }

  void _onQueryChanged() {
    if (_status == OnlineSearchStatus.idle &&
        _groups.isEmpty &&
        _error == null) {
      return;
    }
    _resetSearch();
  }

  void _resetSearch() {
    // 取消在途请求（含各平台在途分页）并作废其代次，避免旧响应追加到新列表。
    cancelAll();
    setState(() {
      _status = OnlineSearchStatus.idle;
      _groups.clear();
      _error = null;
    });
  }

  /// 新建一个分组的展示状态（[universe] = 本次并列显示的身份集合，用于同名短 ID）。
  OnlineSearchPlatformState _stateFor(
    PlatformIdentity identity,
    Iterable<PlatformIdentity> universe,
  ) => OnlineSearchPlatformState(
    identity: identity.normalized,
    label: disambiguatedPlatformLabel(identity, universe),
  );

  /// 发起一次搜索请求。
  ///
  /// - 注入单平台搜索时：只请求该平台，并把结果/错误包成 [AggregatedSearchResult]，
  ///   这样面板只有一条渲染路径；
  /// - 否则：优先走**身份版**聚合（`OnlineMusicIdentitySearchSource`，2.2/G3：多个
  ///   自定义平台不会互相覆盖）；实现没有该接口时回落到 `searchAggregated`（既有行为）。
  Future<AggregatedSearchResult> _request({
    required Iterable<PlatformIdentity> identities,
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
          perPlatformIdentity: {
            const PlatformIdentity.builtin(MusicPlatform.netease): page,
          },
          failures: const {},
        );
      } on OnlineMusicException catch (error) {
        return AggregatedSearchResult(
          perPlatform: const {},
          failures: {MusicPlatform.netease: error},
          failuresByIdentity: {
            const PlatformIdentity.builtin(MusicPlatform.netease): error,
          },
        );
      }
    }
    final service = context.read<OnlineMusicService>();
    // 2.2 / G3：实现了窄接口的服务按**身份**聚合（多个自定义平台不会互相覆盖）；
    // 测试替身 / 单平台嵌入没有它 ⇒ 回落到既有枚举版（那正是"只有内置平台"的情形）。
    if (service is OnlineMusicIdentitySearchSource) {
      return (service as OnlineMusicIdentitySearchSource).searchIdentities(
        identities: identities,
        keyword: keyword,
        limit: limit,
        offset: offset,
        cancelToken: cancelToken,
      );
    }
    return service.searchAggregated(
      platforms: [for (final identity in identities) identity.platform],
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
    required List<PlatformIdentity> identities,
    required String keyword,
    required OnlineMusicCancelToken token,
    required int generation,
  }) async {
    // 专辑/艺人两条链路**只按枚举**分发（接口没有身份参数）⇒ 只对内置平台发起，
    // 否则两个自定义平台会共用一个枚举键、互相串行。
    // 自定义平台的曲目结果不受影响（见 `_request` 的身份版搜索）。
    final targets = [
      for (final identity in identities)
        if (identity.isBuiltin &&
            service.capabilities.openableSearchAlbumPlatforms.contains(
              identity.platform,
            ))
          identity.platform,
    ];
    if (targets.isEmpty) return;
    final results = await Future.wait([
      for (final platform in targets)
        () async {
          try {
            final albums = await service.searchAlbums(
              platform: platform,
              keyword: keyword,
              limit: onlineSearchPageSize,
              offset: 0,
              cancelToken: token,
            );
            return (platform: platform, albums: albums, failed: false);
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
        // 只对内置平台发起（见上）⇒ 键用内置身份。
        final identity = PlatformIdentity.builtin(result.platform);
        if (result.albums.isNotEmpty) _albums[identity] = result.albums;
        if (result.failed) _albumsFailed.add(identity);
      }
    });
  }

  /// **搜艺人**（2026-10-12）：只对"搜得出来、且艺人页打得开"的平台 ✓
  ///（`openableSearchArtistPlatforms` ✓）。失败**只影响该平台的艺人行**且如实标出 ✓。
  Future<void> _loadArtists({
    required OnlineMusicService service,
    required List<PlatformIdentity> identities,
    required String keyword,
    required OnlineMusicCancelToken token,
    required int generation,
  }) async {
    // 同 `_loadAlbums`：艺人检索同样只有枚举入口 ⇒ 只对内置平台发起。
    final targets = [
      for (final identity in identities)
        if (identity.isBuiltin &&
            service.capabilities.openableSearchArtistPlatforms.contains(
              identity.platform,
            ))
          identity.platform,
    ];
    if (targets.isEmpty) return;
    final results = await Future.wait([
      for (final platform in targets)
        () async {
          try {
            final artists = await service.searchArtists(
              platform: platform,
              keyword: keyword,
              limit: onlineSearchPageSize,
              offset: 0,
              cancelToken: token,
            );
            return (platform: platform, artists: artists, failed: false);
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
        final identity = PlatformIdentity.builtin(result.platform);
        if (result.artists.isNotEmpty) {
          _artists[identity] = result.artists;
        }
        if (result.failed) _artistsFailed.add(identity);
      }
    });
  }

  /// 提交一次搜索（宿主在 Enter / 点「在线搜索」/ 切来源时调用）。
  Future<void> submit(String rawQuery) async {
    final query = normalizedSearchQuery(rawQuery);
    _submittedQuery = query;
    if (query.isEmpty) {
      _resetSearch();
      return;
    }

    final identities = _requestTargets(_availableIdentities(context));
    if (identities.isEmpty) {
      cancelAll();
      setState(() {
        _status = OnlineSearchStatus.noPlatform;
        _groups.clear();
        _error = null;
      });
      return;
    }

    cancelAll();
    final token = OnlineMusicCancelToken();
    final generation = ++_generation;
    _cancelToken = token;
    setState(() {
      _status = OnlineSearchStatus.loading;
      _groups
        ..clear()
        ..addAll([
          for (final identity in identities) _stateFor(identity, identities),
        ]);
      // 专辑/艺人结果与曲目结果**同时开跑** ✓（清掉上一次的 ✓）。
      _albums.clear();
      _albumsFailed.clear();
      _artists.clear();
      _artistsFailed.clear();
      _error = null;
    });

    // 专辑与曲目**并行**：专辑失败只影响专辑行 ✓（曲目照常 ✓）。
    // 用**可空**读取（与本组件其它地方一致 ✓：服务未注入时应静默跳过 ✓，不能抛 ✗）。
    final albumService = context.read<OnlineMusicService?>();
    if (albumService != null) {
      unawaited(
        _loadAlbums(
          service: albumService,
          identities: identities,
          keyword: query,
          token: token,
          generation: generation,
        ),
      );
      unawaited(
        _loadArtists(
          service: albumService,
          identities: identities,
          keyword: query,
          token: token,
          generation: generation,
        ),
      );
    }

    try {
      final result = await _request(
        identities: identities,
        keyword: query,
        limit: onlineSearchPageSize,
        offset: 0,
        cancelToken: token,
      );
      if (!mounted || generation != _generation) return;
      setState(() => _applyInitialResult(result, identities));
    } on OnlineMusicException catch (error) {
      if (!mounted || generation != _generation) return;
      if (error.kind == OnlineMusicErrorKind.cancelled) {
        setState(() => _status = OnlineSearchStatus.idle);
        return;
      }
      setState(() {
        _error = error;
        _status = OnlineSearchStatus.error;
      });
    } catch (_) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _error = const OnlineMusicException(
          kind: OnlineMusicErrorKind.unknown,
          safeMessage: '音乐服务请求失败',
        );
        _status = OnlineSearchStatus.error;
      });
    } finally {
      if (generation == _generation) _cancelToken = null;
    }
  }

  /// 把首请求结果摊进各平台分组，并决定整页状态。
  ///
  /// 2.2（R4）：结果先按**身份键**取（`perPlatformIdentity`，自定义平台的权威来源），
  /// 退回枚举键 —— 枚举键在多个自定义平台同时请求时会被聚合层守卫移除。
  void _applyInitialResult(
    AggregatedSearchResult result,
    List<PlatformIdentity> requested,
  ) {
    _groups
      ..clear()
      ..addAll([
        for (final identity in requested) _stateFor(identity, requested),
      ]);

    for (final group in _groups) {
      final identity = group.identity;
      final page =
          result.perPlatformIdentity[identity] ??
          result.perPlatform[identity.platform];
      if (page != null) {
        group.page = page;
        group.lastPageCount = page.items.length;
      }
      group.error =
          result.failuresByIdentity[identity] ??
          result.failures[identity.platform];
    }

    // 全部平台都失败 ⇒ 整页错误（保留第一个失败的错误分类与文案）。
    final failures = [
      for (final group in _groups)
        if (group.error != null) group.error!,
    ];
    final succeeded =
        result.perPlatformIdentity.isNotEmpty || result.perPlatform.isNotEmpty;
    if (!succeeded && failures.isNotEmpty) {
      if (failures.every(
        (error) => error.kind == OnlineMusicErrorKind.cancelled,
      )) {
        _status = OnlineSearchStatus.idle;
        return;
      }
      _error = failures.first;
      _status = OnlineSearchStatus.error;
      return;
    }

    // 成功但一条都没有（且没有失败平台）⇒ 既有的"没有找到"空状态。
    if (result.isEmpty && failures.isEmpty) {
      _status = OnlineSearchStatus.empty;
      return;
    }

    _status = OnlineSearchStatus.success;
  }

  /// 某个平台身份各自的「加载更多」：`offset = 该平台已加载数量`、同一 keyword、
  /// 每页 `onlineSearchPageSize`（2.2：按身份定位分组 ⇒ 两个自定义平台各自分页）。
  Future<void> _loadMore(PlatformIdentity identity) async {
    final group = _groupFor(identity);
    if (group == null || group.loadingMore || !group.hasMore) return;
    final query = _submittedQuery;
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
        identities: [group.identity],
        keyword: query,
        limit: onlineSearchPageSize,
        offset: offset,
        cancelToken: token,
      );
      if (!mounted || generation != _generation) return;
      if (revision != group.loadMoreRevision) return;
      final failure =
          result.failuresByIdentity[group.identity] ??
          result.failures[group.identity.platform];
      final page =
          result.perPlatformIdentity[group.identity] ??
          result.perPlatform[group.identity.platform];
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
  void _mergeLoadedPage(OnlineSearchPlatformState group, MusicSearchPage next) {
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
    final identities = _availableIdentities(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Spec D6：顶部保留「在线播放历史」入口（撤销 `/online` 页后该入口的替代）。
        if (widget.onHistoryRequested != null)
          Align(
            alignment: Alignment.centerRight,
            child: IconButton.filledTonal(
              tooltip: '在线播放历史',
              onPressed: widget.onHistoryRequested,
              icon: const Icon(Symbols.history),
            ),
          ),
        if (identities.isNotEmpty) ...[
          if (widget.onHistoryRequested != null) const SizedBox(height: 8.0),
          _buildPlatformFilter(identities),
        ],
        SizedBox(
          height: 12.0,
          child: _status == OnlineSearchStatus.loading
              ? const Align(
                  alignment: Alignment.topCenter,
                  child: LinearProgressIndicator(minHeight: 2.0),
                )
              : null,
        ),
        Expanded(child: _buildSearchBody()),
      ],
    );
  }

  /// 「全部 / 各平台」筛选（D6:A / W6）。
  ///
  /// - ≥2 个可用平台：可切换的「全部 / 各平台」，**切到某个平台就只搜索它**；
  /// - 只有 1 个可用平台：不给假的选项，而是明确写出"当前平台：X" ——
  ///   让用户看得懂现在搜的就是这一家，而不是以为筛选功能不存在。
  ///
  /// 2.2（R4/G3/G6）：选项是**平台身份**（自定义平台按自己的 `platformName` 显示），
  /// 因此两个自定义平台在筛选里是两个可分辨的选项，而不是一个「自定义平台」；
  /// **同名**时按 [identities] 这条并列清单附短 ID（同设置页规则）。
  Widget _buildPlatformFilter(List<PlatformIdentity> identities) {
    if (identities.length < 2) {
      final scheme = Theme.of(context).colorScheme;
      return Row(
        children: [
          Icon(Symbols.public, size: 14, color: scheme.onSurfaceVariant),
          const SizedBox(width: Spacing.xs),
          Text(
            '当前平台：${disambiguatedPlatformLabel(identities.single, identities)}',
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
      child: SegmentedButton<PlatformIdentity?>(
        showSelectedIcon: false,
        segments: [
          const ButtonSegment<PlatformIdentity?>(
            value: null,
            label: Text('全部'),
          ),
          for (final identity in identities)
            ButtonSegment<PlatformIdentity?>(
              value: identity,
              label: Text(disambiguatedPlatformLabel(identity, identities)),
            ),
        ],
        selected: {_filter},
        onSelectionChanged: (selection) => _onFilterChanged(selection.first),
      ),
    );
  }

  Widget _buildSearchBody() {
    return switch (_status) {
      OnlineSearchStatus.idle => const QuietEmptyState(
        icon: Symbols.cloud,
        title: '在线搜索',
        message: '输入关键词，搜索已启用的在线平台。',
      ),
      OnlineSearchStatus.loading => const QuietEmptyState(
        icon: Symbols.hourglass_top,
        title: '正在搜索',
        message: '正在获取在线结果。',
      ),
      OnlineSearchStatus.empty => QuietEmptyState(
        icon: Symbols.cloud_off,
        title: '没有找到在线曲目',
        message: '换个关键词再试试。',
        action: FilledButton.icon(
          onPressed: () => submit(widget.query),
          icon: const Icon(Symbols.refresh),
          label: const Text('重新搜索'),
        ),
      ),
      OnlineSearchStatus.noPlatform => QuietEmptyState(
        icon: Symbols.cloud_off,
        title: '没有可搜索的平台',
        message: '请先在设置里启用平台，并为其配置可用的服务。',
        action: FilledButton.icon(
          onPressed: _openSettings,
          icon: const Icon(Symbols.settings),
          label: const Text('去设置'),
        ),
      ),
      OnlineSearchStatus.error => _buildError(),
      OnlineSearchStatus.success => _buildResultList(),
    };
  }

  /// 「去设置」：有宿主回调就交给宿主（弹窗会先关掉自己再跳），否则直接 go。
  void _openSettings() {
    final handler = widget.onOpenSettings;
    if (handler != null) {
      handler();
      return;
    }
    context.go(app_paths.SETTINGS_PAGE);
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
            ? _openSettings
            : () => submit(widget.query),
        icon: Icon(unauthorized ? Symbols.settings : Symbols.refresh),
        label: Text(unauthorized ? '去设置' : '重试'),
      ),
    );
  }

  /// 把各平台分组摊平成一维行列表（摊平顺序见 [flattenOnlineSearchEntries]）。
  List<OnlineSearchEntry> _buildEntries() {
    final visible = _visibleIdentities;
    // 只有一个平台（或筛选到单一平台）时不摆分组表头：多平台聚合才需要它。
    return flattenOnlineSearchEntries(
      groups: [
        for (final group in _groups)
          if (visible.contains(group.identity)) group,
      ],
      albums: _albums,
      albumsFailed: _albumsFailed,
      artists: _artists,
      artistsFailed: _artistsFailed,
      showHeaders: visible.length > 1,
    );
  }

  Widget _buildResultList() {
    final entries = _buildEntries();
    // **不留 `Spacing.bottomNav`**（Spec 4.5）：那是给页面级迷你播放器让位的；
    // 面板现在住在搜索弹窗里，弹窗内没有迷你播放器 ⇒ 底部留白只会浪费高度。
    return ListView.builder(
      itemCount: entries.length,
      itemBuilder: (context, index) => switch (entries[index]) {
        OnlineSearchGroupHeaderEntry(:final group) => _buildGroupHeader(group),
        OnlineSearchTrackEntry(:final group, :final track) => _buildTrackRow(
          group,
          track,
        ),
        // 专辑行已抽成公共组件 ✓（搜索结果与「新发行」页共用 ✓，R95 ✓）。
        OnlineSearchAlbumEntry(:final album) => OnlineAlbumRow(album: album),
        OnlineSearchAlbumFailureEntry(:final group) => _buildAlbumFailureRow(
          group,
        ),
        OnlineSearchArtistEntry(:final artist) => _buildArtistRow(artist),
        OnlineSearchArtistFailureEntry(:final group) =>
          _buildArtistFailureRow(group),
        OnlineSearchFailureEntry(:final group) => _buildFailureRow(group),
        OnlineSearchEmptyGroupEntry(:final group) => _buildEmptyGroupRow(group),
        OnlineSearchFooterEntry(:final group) => _buildLoadMoreFooter(group),
      },
    );
  }

  Widget _buildGroupHeader(OnlineSearchPlatformState group) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(8.0, 12.0, 8.0, 4.0),
      child: Text(
        group.label,
        key: ValueKey('online-search-group-${group.keySuffix}'),
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
  Widget _buildTrackRow(OnlineSearchPlatformState group, MusicTrack track) =>
      OnlineTrackEntry(track: track, onTap: () => _selectTrack(group, track));

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
  Widget _buildArtistFailureRow(OnlineSearchPlatformState group) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 8.0),
      child: Row(
        children: [
          Icon(Symbols.artist, size: 16.0, color: scheme.onSurfaceVariant),
          const SizedBox(width: 8.0),
          Expanded(
            child: Text(
              '${group.label}的艺人结果没取到（曲目结果不受影响）',
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }

  /// 专辑搜索失败：**如实标出** ✓（不静默 ✓，也不影响该平台的曲目结果 ✓）。
  Widget _buildAlbumFailureRow(OnlineSearchPlatformState group) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 8.0),
      child: Row(
        children: [
          Icon(Symbols.album, size: 16.0, color: scheme.onSurfaceVariant),
          const SizedBox(width: 8.0),
          Expanded(
            child: Text(
              '${group.label}的专辑结果没取到（曲目结果不受影响）',
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }

  /// 单平台失败：只影响这个分组，其它平台的结果照常显示（D6 / §8）。
  Widget _buildFailureRow(OnlineSearchPlatformState group) {
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

  Widget _buildEmptyGroupRow(OnlineSearchPlatformState group) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 12.0),
      child: Text(
        '${group.label}没有找到结果',
        style: TextStyle(color: scheme.onSurfaceVariant),
      ),
    );
  }

  /// 某个平台的分页入口：可加载 → 「加载更多」；加载中 → 转圈且禁用；
  /// 失败 → 安全提示 + 可重试；到底 → 「没有更多了」。
  ///
  /// 多平台时 key 带平台名（自定义平台带稳定 ID，避免两个分组撞 key），
  /// 单平台（含注入单平台搜索与筛选到单一平台）沿用既有 key。
  Widget _buildLoadMoreFooter(OnlineSearchPlatformState group) {
    final scheme = Theme.of(context).colorScheme;
    final single = _visibleIdentities.length <= 1;
    final loadMoreKey = single
        ? const ValueKey('online-search-load-more')
        : ValueKey('online-search-load-more-${group.keySuffix}');
    final retryKey = single
        ? const ValueKey('online-search-load-more-retry')
        : ValueKey('online-search-load-more-retry-${group.keySuffix}');
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
              onPressed: () => _loadMore(group.identity),
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
            onPressed: () => _loadMore(group.identity),
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
    OnlineSearchPlatformState group,
    MusicTrack selected,
  ) async {
    // `page` 是该平台**累积**后的结果页，`page.items` 即"该平台已加载的全部结果"：
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
