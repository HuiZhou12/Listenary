import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';
import 'package:pure_music/component/content_section.dart';
import 'package:pure_music/component/horizontal_shelf.dart';
import 'package:pure_music/component/new_song_shelf.dart';
import 'package:pure_music/component/home_greeting_header.dart';
import 'package:pure_music/component/home_hero_banner.dart';
import 'package:pure_music/component/online_search_launcher.dart';
import 'package:pure_music/component/platform_capability_view.dart';
import 'package:pure_music/component/remote_load_state.dart';
import 'package:pure_music/component/remote_media_card.dart';
import 'package:pure_music/component/remote_playlist_launcher.dart';
import 'package:pure_music/component/shelf_arrows.dart';
import 'package:pure_music/component/shelf_geometry.dart';
import 'package:pure_music/component/shelf_scroll_state.dart';
import 'package:pure_music/services/online_history/rediscovery_engine.dart';
import 'package:pure_music/core/design_tokens.dart';
import 'package:pure_music/core/paths.dart' as app_paths;
import 'package:pure_music/core/preference.dart';
import 'package:pure_music/services/music_platform/index.dart';
import 'package:pure_music/services/music_platform/online_library/online_history_controller.dart';

/// **聚合主页**：先把**你自己的东西**放前面，再是平台内容，最后才是配置诊断。
///
/// 设计口径：
/// - 区块顺序 = 价值顺序：「继续听」→「我的收藏」→「我的在线歌单」→「来自平台的歌单」；
/// - **平台能力是诊断信息，不是内容** ⇒ 收进底部一个默认收起的区块，不再占据首屏；
/// - 内容按**已启用平台 + 真实可用能力**动态生成，能力不足的平台如实说明；
/// - 平台原生内容由对应 Provider 提供，应用内部数据走应用自己的数据层；
/// - **单平台失败不影响整页**：每个平台的歌单列表各自加载、各自报错、各自可重试；
/// - 不硬编码任何歌曲/歌单，也不为没有接口依据的数据源编造 API。
class HomePage extends StatefulWidget {
  const HomePage({super.key, this.previewLimit = 6, this.collectionLimit = 12});

  /// 每个"最近播放 / 收藏 / 自建歌单"区块最多展示多少条。
  final int previewLimit;

  /// 每个平台歌单列表一次拉多少条。
  final int collectionLimit;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with RemoteListLoading<HomePage> {
  bool _loaded = false;

  /// **「猜你喜欢」货架**（`recommendedTracks` 能力，2026-10-12 新增 ✓）。
  ///
  /// 与「新曲上线」同一条规矩 ✓：只对**能播放**的平台出现 ✓
  ///（`playableRecommendedTrackPlatforms` ✓ —— 列一堆点不响的不如不显示 ✗）。
  /// **没有任何平台具备该能力时**，主页保留那块**诚实展位** ✓（写明要接什么接口 ✓），
  /// 而不是摆一个空货架 ✗ —— 这样"还没配"与"配上但没有推荐"一眼可辨 ✓。
  List<MusicPlatform> _recommendedPlatforms = const [];
  final RemoteLoadState<MusicPlatform, MusicTrack> _recommendedState =
      RemoteLoadState<MusicPlatform, MusicTrack>();

  /// **「为你推荐的歌单」货架**（`recommendedPlaylists` 能力，2026-10-12 新增 ✓）。
  ///
  /// 判据与「新专辑」一致 ✓：**既列得出、又打得开**（`openableRecommendedPlaylistPlatforms` ✓）
  /// —— 点进去是死链比不显示更糟 ✗。
  List<MusicPlatform> _recommendedPlaylistPlatforms = const [];
  final RemoteLoadState<MusicPlatform, RemotePlaylistSummary>
  _recommendedPlaylistState =
      RemoteLoadState<MusicPlatform, RemotePlaylistSummary>();

  // **「个性化合辑」模块已按用户指令删除** ✗（2026-10-17）：
  // 它与「为你推荐的歌单」**功能重合** ✓（都是平台给的一批歌单 ✓），主页摆两块就是重复 ✓。
  // ⚠️ 只是**主页不再展示** ✓：`personalizedPlaylists` 这个**能力**仍在服务层 ✓
  //（设置页的能力清单、声明式配方、探测都还在用它 ✓ ⇒ 没有连带删能力 ✓）。

  /// **「关注的艺人」货架**（`followedArtists` 能力，2026-10-12 新增 ✓）。
  ///
  /// 判据：**既列得出、艺人页又打得开** ✓（`openableFollowedArtistPlatforms` ✓）。
  /// ⚠️ 账号没关注任何人时平台会**如实返回 0 条** ✓ ⇒ 走**中性空态**（不是失败 ✓）。
  List<MusicPlatform> _followedArtistPlatforms = const [];
  final RemoteLoadState<MusicPlatform, OnlineArtistSummary>
  _followedArtistState =
      RemoteLoadState<MusicPlatform, OnlineArtistSummary>();

  /// **重温引擎**（2026-10-12 ✓）：无状态、纯函数 ✓ ⇒ 一个常量实例就够 ✓（不必每帧新建 ✓）。
  static const RediscoveryEngine _rediscovery = RediscoveryEngine();

  /// **每个货架自己的滚动状态**（2026-10-12 ✓）：交给区块头部画「◀ ▶」用 ✓
  ///（参考产品的箭头就在标题那一行 ✓）。同一页可能同时有好几条货架 ⇒ 按 key 各存一个 ✓。
  final Map<String, ShelfScrollState> _shelfScrollStates = {};

  ShelfScrollState _shelfState(String key) =>
      _shelfScrollStates.putIfAbsent(key, ShelfScrollState.new);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(_load());
    });
  }

  @override
  void dispose() {
    for (final state in _shelfScrollStates.values) {
      state.dispose();
    }
    _shelfScrollStates.clear();
    super.dispose();
  }

  /// 这次打开距上次打开的间隔 ✓（null = 首次安装或不知道为什么 ✓）⇒ 交给问候头决定说不说"好久不见" ✓。
  Duration? _returningAfter;

  Future<void> _load() async {
    if (_loaded) {
      await _refreshAll();
      return;
    }
    _loaded = true;
    // **"好久不见"的口径**（2026-10-12 ✓）：先算"这次距上次打开过了多久"✓，
    // 再记下本次时间 ✓ —— 顺序不能反 ✗（反了永远是"刚刚打开过" ✓）。
    // 只读/写一个偏好键 ✓，**不动数据库** ✓；首次安装没有记录 ⇒ 不说"好久不见" ✓。
    final lastOpened = AppPreference.instance.lastOpenedAt;
    if (lastOpened != null) {
      final absence = DateTime.now().toUtc().difference(lastOpened);
      if (!absence.isNegative) _returningAfter = absence;
    }
    AppPreference.instance.lastOpenedAt = DateTime.now().toUtc();
    AppPreference.instance.save().ignore();
    final history = context.read<OnlineHistoryController>();
    unawaited(history.refresh());
    unawaited(_loadRecommended());
    unawaited(_loadRecommendedPlaylists());
    unawaited(_loadFollowedArtists());
  }

  Future<void> _refreshAll() async {
    final history = context.read<OnlineHistoryController>();
    unawaited(history.refresh());
    await Future.wait([
      _loadRecommended(),
      _loadRecommendedPlaylists(),
      _loadFollowedArtists(),
    ]);
  }

  /// **推荐曲目**（`recommendedTracks` ✓）：与「新歌」同一套做法 ✓ ——
  /// 只对**能播放**的平台加载 ✓，单平台失败不影响其它平台 ✓。
  Future<void> _loadRecommended() async {
    final service = context.read<OnlineMusicService?>();
    final platforms = service == null
        ? const <MusicPlatform>[]
        : [
            for (final platform in builtinMusicPlatforms)
              if (service.capabilities.playableRecommendedTrackPlatforms
                  .contains(platform))
                platform,
          ];
    if (!mounted) return;
    setState(() => _recommendedPlatforms = platforms);
    if (service == null) return;
    await Future.wait([
      for (final platform in platforms)
        _loadRecommendedFor(service, platform),
    ]);
  }

  Future<void> _loadRecommendedFor(
    OnlineMusicService service,
    MusicPlatform platform,
  ) => loadRemoteList(
    _recommendedState,
    platform,
    () => service.fetchRecommendedTracks(
      platform: platform,
      limit: widget.collectionLimit,
      offset: 0,
      cancelToken: newCancelToken(),
    ),
    fallback: '读取该平台推荐曲目失败',
  );

  /// 「猜你喜欢」：**有平台具备该能力**就是真货架 ✓；一个都没有 ⇒ 保留**诚实展位** ✓
  ///（写明要接什么 ✓，不摆空货架 ✗）。"凭据没配/失效"由**平台自己的失败态**如实呈现 ✓
  ///（与"没有推荐"分开 ✓）。
  /// **主页的模块显示规则**（2026-10-17 用户指令 ✓）：
  /// **模块内没有内容就整块不渲染** ✓ —— 不再摆"还没有…"这类空态 ✓。
  ///
  /// "没有内容" = 该模块的**所有平台都取完了、而且每条都是空** ✓。
  ///
  /// 两种情况**仍然显示**（它们不是"空"）：
  /// - **加载中**：还没有结论；藏起来会让模块忽隐忽现 ✓；
  /// - **失败**：读不到 ≠ 没有。藏起来会把一次网络失败变成"这个模块消失了" ✓
  ///（比一条空态更误导 —— 用户会以为平台没数据 ✓）。
  bool _hasAnyContent<T>(
    List<MusicPlatform> platforms,
    RemoteLoadState<MusicPlatform, T> state,
  ) {
    for (final platform in platforms) {
      if (state.items(platform).isNotEmpty ||
          state.isLoading(platform) ||
          state.error(platform) != null) {
        return true;
      }
    }
    return false;
  }

  Widget _buildRecommended() {
    // 没有内容（或根本没有可用平台）⇒ 整块不渲染 ✓。
    if (!_hasAnyContent(_recommendedPlatforms, _recommendedState)) {
      return const SizedBox.shrink();
    }
    return ContentSection(
      title: '猜你喜欢',
      subtitle: '各平台按你的账号推荐；点一行即可播放',
      child: Column(
        children: [
          for (final platform in _recommendedPlatforms)
            _buildRecommendedSection(platform),
        ],
      ),
    );
  }

  /// **凭据型货架的失败提示**（2026-10-12 ✓）。
  ///
  /// 为什么单独加这一行：**猜你喜欢 / 为你推荐的歌单 / 关注的艺人**这三个货架背后的能力
  /// **按设计就需要 cookie** ✓（配方里带 `Cookie` 敏感头 + 凭据引用 ✓）⇒ 失败时**最可能**
  /// 是"凭据没配或已过期" ✓。**其它货架不加** ✗ —— 它们的能力不需要凭据，加了就是误导 ✓。
  ///
  /// 措辞是"**可能的原因**"✓：登录失效只是最常见的那一种 ✓，网络/风控同样会失败 ✓
  /// ⇒ 不把话说成"一定是凭据问题" ✗（那就是在编一个我们并不确知的诊断 ✓）。
  String _credentialFailureHint(String message) =>
      '$message\n可能的原因：登录凭据没配置或已过期。'
      '到「设置 → 在线音乐 → 该平台条目」重新填写凭据并保存，再回来重试。';

  Widget _buildRecommendedSection(MusicPlatform platform) {
    final scheme = Theme.of(context).colorScheme;
    final tracks = _recommendedState.items(platform);
    return Padding(
      padding: const EdgeInsets.only(bottom: Spacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            musicPlatformLabel(platform),
            style: TextStyle(
              color: scheme.onSurfaceVariant,
              fontSize: AppType.caption,
              fontWeight: AppType.weightSemibold,
            ),
          ),
          const SizedBox(height: Spacing.sm),
          if (_recommendedState.isLoading(platform))
            const Padding(
              padding: EdgeInsets.symmetric(vertical: Spacing.lg),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (_recommendedState.error(platform) case final message?)
            InlineFailureHint(
              // **凭据型货架**：失败时给出可能原因与去处 ✓（见 `_credentialFailureHint` ✓）。
              message: _credentialFailureHint(message),
              onRetry: () => _retryRecommended(platform),
            )
          else if (tracks.isEmpty)
            // **空 ≠ 失败**：平台没有推荐（或者今天就是没有 ✓）⇒ 中性提示、不给重试 ✓。
            // 凭据失效会走上面的失败分支 ✓ —— 两者不混 ✓。
            const InlineEmptyHint(
              icon: Symbols.favorite,
              message: '该平台今天没有推荐',
            )
          else
            // **与探索页「新歌」同一份实现** ✓（2026-10-16 用户裁定 ✓）：
            // 三栏行式条目 + 横向翻页 + 每页 4 行 ✓ —— 抽成 `NewSongShelf` ✓ 两页共用 ✓
            //（抄一份"看起来差不多"的必然会慢慢走偏 ✗）。
            NewSongShelf(
              tracks: tracks,
              onPlay: (track) => playOnlineSearchResult(
                context,
                tracks: tracks,
                selectedRef: track.ref,
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _retryRecommended(MusicPlatform platform) async {
    final service = context.read<OnlineMusicService?>();
    if (service == null) return;
    await _loadRecommendedFor(service, platform);
  }

  /// **推荐歌单**（`recommendedPlaylists` ✓）：与"歌单列表"同一套做法 ✓。
  Future<void> _loadRecommendedPlaylists() async {
    final service = context.read<OnlineMusicService?>();
    final platforms = service == null
        ? const <MusicPlatform>[]
        : [
            for (final platform in builtinMusicPlatforms)
              if (service.capabilities.openableRecommendedPlaylistPlatforms
                  .contains(platform))
                platform,
          ];
    if (!mounted) return;
    setState(() => _recommendedPlaylistPlatforms = platforms);
    if (service == null) return;
    await Future.wait([
      for (final platform in platforms)
        _loadRecommendedPlaylistsFor(service, platform),
    ]);
  }

  Future<void> _loadRecommendedPlaylistsFor(
    OnlineMusicService service,
    MusicPlatform platform,
  ) => loadRemoteList(
    _recommendedPlaylistState,
    platform,
    () => service.fetchRecommendedPlaylists(
      platform: platform,
      limit: widget.collectionLimit,
      offset: 0,
      cancelToken: newCancelToken(),
    ),
    fallback: '读取该平台推荐歌单失败',
  );

  /// 「为你推荐的歌单」✓ —— **名字如实** ♥：平台给的就是**歌单**（网易云 `/recommend/resource` 实测 ✓），
  /// 不是"推荐的专辑" ✗ ⇒ 不沿用参考图里那个名字（那会名不副实 ✓）。
  Widget _buildRecommendedPlaylists() {
    // 没有内容 ⇒ 整块不渲染 ✓（规则见 `_hasAnyContent`）。
    if (!_hasAnyContent(
      _recommendedPlaylistPlatforms,
      _recommendedPlaylistState,
    )) {
      return const SizedBox.shrink();
    }
    return ContentSection(
      title: '为你推荐的歌单',
      subtitle: '各平台按你的账号推荐；点封面可先预览，不会自动订阅',
      // **与探索页「新专辑 / 歌单」同一套区块头** ✓（2026-10-16 用户指令 ✓）：
      // 标题行右侧是「**查看全部**」✓ —— 不是那对 ◀ ▶ ✗（箭头由货架自己在左右两侧画 ✓）。
      actionLabel: '查看全部',
      onAction: () => context.go(app_paths.EXPLORE_PAGE),
      child: Column(
        children: [
          for (final platform in _recommendedPlaylistPlatforms)
            _playlistShelfSection(
              platform,
              state: _recommendedPlaylistState,
              emptyMessage: '该平台今天没有推荐',
              // **凭据型货架** ✓ ⇒ 失败时补上"可能是凭据失效"的指引 ✓。
              decorateError: _credentialFailureHint,
              onRetry: () => _retryRecommendedPlaylists(platform),
            ),
        ],
      ),
    );
  }

  /// 一条**歌单货架**（2026-10-12 ✓；2026-10-17 起只剩「为你推荐的歌单」在用 ✓）。
  ///
  /// 参数 `decorateError` 保留 ✓：只有**凭据型**的货架才补"可能是凭据失效"的指引 ✓
  ///（不是凭据型的货架给它加这段就是误导 ✗）。
  Widget _playlistShelfSection(
    MusicPlatform platform, {
    required RemoteLoadState<MusicPlatform, RemotePlaylistSummary> state,
    required String emptyMessage,
    required Future<void> Function() onRetry,
    String Function(String message)? decorateError,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final items = state.items(platform);
    // **与探索页的「歌单 / 新专辑」卡片同一套封面格式** ✓（2026-10-16 用户指令 ✓）：
    // 2026-10-17（F5）：取宽统一走 `ShelfGeometry` ✓ —— 主页四族货架（歌单 / 关注艺人 /
    // 再听一遍 / 好久没听）此前**各自**算一遍宽高（其中两族还是未放大的 `widthFor` ✗）
    // ⇒ 现在是同一个来源 ✓，同一页不会再有"大一号/小一号"的两排卡 ✓。
    final width = ShelfGeometry.cardWidth(context);
    final loadError = state.error(platform);
    final errorMessage = items.isEmpty && loadError != null
        ? (decorateError?.call(loadError) ?? loadError)
        : null;
    return Padding(
      padding: const EdgeInsets.only(bottom: Spacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  musicPlatformLabel(platform),
                  style: TextStyle(
                    color: scheme.onSurfaceVariant,
                    fontSize: AppType.caption,
                    fontWeight: AppType.weightSemibold,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: Spacing.sm),
          HorizontalShelf(
            // ⚠️ 2026-10-16 修正 ✓：**不再接头部箭头** ✗ ——
            // 用户指出这两块要照探索页的「新专辑 / 歌单」样式 ✓，而那两处的箭头是
            // `HorizontalShelf` **自带的覆盖层箭头**（只在还能横滑时才出现 ✓），
            // 标题行右侧放的是「**查看全部**」✓，不是我加的那对 ◀ ▶ ✗。
            loading: state.isLoading(platform) && items.isEmpty,
            errorMessage: errorMessage,
            onRetry: onRetry,
            emptyMessage: emptyMessage,
            emptyIcon: Symbols.queue_music,
            itemCount: items.length,
            itemWidth: width,
            itemHeight: ShelfGeometry.cardExtent(
              width: width,
              hasFooter: false,
            ),
            itemBuilder: (context, index) {
              final summary = items[index];
              return RemoteMediaCard(
                width: width,
                title: summary.name,
                coverUri: summary.coverUri,
                details: [
                  '歌单',
                  if (summary.creator case final creator?
                      when creator.isNotEmpty)
                    creator,
                  if (summary.trackCount case final count?) '$count 首',
                ].join(' · '),
                sourceLabel: platformLabelForIdentityOnly(summary.identity),
                placeholderIcon: Symbols.queue_music,
                // 与探索页同一条规则 ✓：**点封面 = 只读预览**（不是偷偷订阅 ✗）。
                // 跳转走共享入口 ✓（2026-10-17 / F2 收口），字段拼装只有一份。
                onTap: () => openRemotePlaylistSummaryPreview(context, summary),
                semanticLabel: '${summary.name}，点击预览（不会订阅）',
              );
            },
          ),
        ],
      ),
    );
  }

  Future<void> _retryRecommendedPlaylists(MusicPlatform platform) async {
    final service = context.read<OnlineMusicService?>();
    if (service == null) return;
    await _loadRecommendedPlaylistsFor(service, platform);
  }

  /// **关注的艺人**（`followedArtists` ✓）：与"推荐歌单"同一套做法 ✓。
  Future<void> _loadFollowedArtists() async {
    final service = context.read<OnlineMusicService?>();
    final platforms = service == null
        ? const <MusicPlatform>[]
        : [
            for (final platform in builtinMusicPlatforms)
              if (service.capabilities.openableFollowedArtistPlatforms.contains(
                platform,
              ))
                platform,
          ];
    if (!mounted) return;
    setState(() => _followedArtistPlatforms = platforms);
    if (service == null) return;
    await Future.wait([
      for (final platform in platforms)
        _loadFollowedArtistsFor(service, platform),
    ]);
  }

  Future<void> _loadFollowedArtistsFor(
    OnlineMusicService service,
    MusicPlatform platform,
  ) => loadRemoteList(
    _followedArtistState,
    platform,
    () => service.fetchFollowedArtists(
      platform: platform,
      limit: widget.collectionLimit,
      offset: 0,
      cancelToken: newCancelToken(),
    ),
    fallback: '读取该平台关注的艺人失败',
  );

  Widget _buildFollowedArtists() {
    // 没有内容 ⇒ 整块不渲染 ✓（规则见 `_hasAnyContent`）。
    if (!_hasAnyContent(_followedArtistPlatforms, _followedArtistState)) {
      return const SizedBox.shrink();
    }
    return ContentSection(
      title: '关注的艺人',
      subtitle: '各平台按你的账号关注的人；点一位可进入艺人页',
      child: Column(
        children: [
          for (final platform in _followedArtistPlatforms)
            _buildFollowedArtistSection(platform),
        ],
      ),
    );
  }

  Widget _buildFollowedArtistSection(MusicPlatform platform) {
    final scheme = Theme.of(context).colorScheme;
    final artists = _followedArtistState.items(platform);
    // 2026-10-17（F5）：与主页其它货架、探索页同一份取宽 ✓（此前这一族用的是**未放大**的
    // `widthFor` ✗ ⇒ 与相邻货架差 15% ✓）。
    final width = ShelfGeometry.cardWidth(context);
    // 与"推荐歌单"同一条：首屏失败时补上**凭据可能失效**的指引 ✓。
    final loadError = _followedArtistState.error(platform);
    final errorMessage = artists.isEmpty && loadError != null
        ? _credentialFailureHint(loadError)
        : null;
    return Padding(
      padding: const EdgeInsets.only(bottom: Spacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  musicPlatformLabel(platform),
                  style: TextStyle(
                    color: scheme.onSurfaceVariant,
                    fontSize: AppType.caption,
                    fontWeight: AppType.weightSemibold,
                  ),
                ),
              ),
              ShelfArrows(
                state: _shelfState('followed-artists-${platform.name}'),
              ),
            ],
          ),
          const SizedBox(height: Spacing.sm),
          HorizontalShelf(
            scrollState: _shelfState('followed-artists-${platform.name}'),
            loading: _followedArtistState.isLoading(platform) &&
                artists.isEmpty,
            errorMessage: errorMessage,
            onRetry: () => _retryFollowedArtists(platform),
            // **空 ≠ 失败**：这个账号可能真的没关注任何人 ✓（如实说 ✓）。
            emptyMessage: '这个账号在${musicPlatformLabel(platform)}还没有关注任何艺人',
            emptyIcon: Symbols.artist,
            itemCount: artists.length,
            itemWidth: width,
            itemHeight: ShelfGeometry.cardExtent(
              width: width,
              hasFooter: false,
            ),
            itemBuilder: (context, index) {
              final artist = artists[index];
              return RemoteMediaCard(
                width: width,
                title: artist.name,
                coverUri: artist.avatarUri,
                details: '艺人',
                sourceLabel: platformLabelForIdentityOnly(artist.identity),
                placeholderIcon: Symbols.artist,
                onTap: () => context.push(
                  app_paths.ONLINE_ARTIST_PAGE,
                  extra: (
                    platform: artist.platform,
                    artistId: artist.id,
                    name: artist.name,
                  ),
                ),
                semanticLabel: '${artist.name}，打开艺人页',
              );
            },
          ),
        ],
      ),
    );
  }

  Future<void> _retryFollowedArtists(MusicPlatform platform) async {
    final service = context.read<OnlineMusicService?>();
    if (service == null) return;
    await _loadFollowedArtistsFor(service, platform);
  }



  @override
  Widget build(BuildContext context) {
    final service = context.read<OnlineMusicService?>();
    final history = context.watch<OnlineHistoryController>().snapshot;
    // **主页不再用页壳** ✓（2026-10-17）：
    // 1. 页壳给左右各 16 的硬内边距 ⇒ 顶部的名片带贴不到窗口边 ✗；
    // 2. 页壳的标题行已去掉（问候语就是这一页唯一的一级标题 ✓）。
    //
    // 结构（视觉与逻辑解耦 ✓）：
    // - **一张"用户名片"**（问候语 + 右侧横幅背景）作为滚动内容的**第一项** ✓
    //   ⇒ 它跟着内容一起滚走 ✓（不会像别的页那样被钉在顶上 ✗），
    //     并且**按内容宽度等比例定高** ✓（不是写死的 200×720 小方块 ✗）；
    // - **名片的下面**才是各模块（再听一遍 / 猜你喜欢 …）✓ —— 二者**不重叠** ✓。
    // ⚠️ **不拆 `ContentSection`** ✓ —— 区块自己管自己的头与内容，
    // "没内容整块隐藏"的逻辑完全不动 ✓。
    return ListView(
      padding: const EdgeInsets.only(bottom: Spacing.bottomNav),
      children: [
        // ① 用户名片：问候 + 横幅背景（等比例定高，随内容滚动 ✓）。
        _buildIdentityBand(context),
        // ② 名片下面是内容区（左右留白：右侧多出的 20 是滚动条位置 ✓）。
        Padding(
          padding: const EdgeInsets.only(
            left: Spacing.lg,
            right: Spacing.lg + 20,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // ① 再听一遍（真实：本地在线历史 ✓）
              _buildHistory(history),
          // ② 老歌重温（真实：历史里**播放次数最高**的那批 ✓ —— 复用既有的 `topPlayed` ✓）
          _buildTopPlayed(history),
          // ③ 「翻唱与混音」**已删除** ✗（2026-10-12 ✓）：
          // 网易云没有"翻唱/混音"这种**策展货架** ✗（只有关键词搜索 ✓，那不算推荐源 ✓），
          // 本地也没有这类内容 ✗ ⇒ 两边都做不到 ⇒ 按用户指令撤掉 ✓（不留空壳 ✗）。
          // ④ 「为你推荐的音乐视频」**已删除** ✗（2026-10-12 ✓）：
          // 网易云有 `/personalized/mv`（实测可用 ✓）但**是视频** ✗ —— 本应用只能播音频 ✓，
          // 本地也没有任何视频内容 ✗ ⇒ **两边都做不到** ⇒ 撤掉 ✓（不留空壳 ✗）。
          // ⑤ 猜你喜欢（**有内容才出现** ✓ —— 见下方"模块显示规则"）
          _buildRecommended(),
          // ⑥ ⑦ 「我的收藏」「我的在线歌单」**已按用户指令移除** ✗（2026-10-17 ✓）：
          // 这两类内容在各自的页面里都有 ✓（收藏页 / 歌单页），主页不再重复摆 ✓。
          // ⑧ 关注的艺人（**有内容才出现** ✓）
          _buildFollowedArtists(),
          // ⑨ 「来自社区」**已删除** ✗（2026-10-12 ✓）：
          // 网易云只有 `/topic/sublist`（那是"**你自己订阅的专栏**" ✗，不是别人的社区内容 ✓），
          // 本地更没有社区 ✗ ⇒ 两边都做不到 ⇒ 撤掉 ✓。
          // ⑩ 为你推荐的**歌单**（名字如实 ✓：平台给的是歌单 ✓；有内容才出现 ✓）
          _buildRecommendedPlaylists(),
          // ⑪ 新曲上线：**已按用户指令删除** ✗（2026-10-16 ✓）——
          // 主页不再重复探索页已有的「新歌」块 ✓（那边信息更全 ✓：可翻页、带平台筛选 ✓）。
          // ⑫ Recap：**用本机历史真做** ✓（2026-10-12 ✓）——
          // 官方 Recap 在这个服务上**实测 404** ✗（`/summary/annual` ✓），但**本地完全可做** ✓
          // ⇒ 按用户指令"能本地实现的就实现" ✓，并且**如实说明**这是本机数字 ✓（不冒充官方 Recap ✗）。
          _buildLocalRecap(history),
          // ⑬ **每日发现：与「猜你喜欢」同源**（网易云实测两处都指向同一个每日推荐接口 ✓）
          // ⇒ **不摆两块重复内容** ✗ —— 这里不再单独放展位 ✓（已在「猜你喜欢」呈现 ✓）。
          // ⑭ 个性化合辑（**有内容才出现** ✓）
          // ⑭ 「个性化合辑」**已按用户指令删除** ✗（2026-10-17 ✓）：
          // 它与「为你推荐的歌单」**功能重合** ✓（都是平台给的一批歌单 ✓）⇒ 主页只留一块 ✓。
          //（能力本身仍在服务层 ✓，只是主页不再展示 ✓。）

          // ================= 图里没有、但我们本来就有的价值（保留 ✓）=================
          // 平台能力诊断 ✓：它不是"内容模块"，不需要遵守"没内容就隐藏" ✓
          //（它正好要在**没配好**的时候告诉你去哪配 ✓）。
          PlatformCapabilityView(
            capabilities: service?.capabilities,
            onConfigure: () => context.go(app_paths.SETTINGS_PAGE),
          ),
            ],
          ),
        ),
      ],
    );
  }

  /// **用户名片带**：横幅背景 + 左下问候 + 右侧刷新 ✓。
  ///
  /// 高度**按内容宽度等比例**取（`宽 × 比例`，再夹在上下限之间）✓ ——
  /// 全屏时它跟着变高变宽 ✓，而不是永远那个 200×720 的小方块 ✗（用户实测指出的问题）。
  Widget _buildIdentityBand(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final height = (constraints.maxWidth * _identityHeightRatio).clamp(
          _identityMinHeight,
          _identityMaxHeight,
        );
        return SizedBox(
          height: height,
          child: Stack(
            fit: StackFit.expand,
            children: [
              // 背景：用户横幅（没设置 ⇒ 什么都不画，页面底色露出来 ✓）。
              ValueListenableBuilder<String?>(
                valueListenable: AppPreference.instance.homeBannerPathListenable,
                builder: (context, bannerPath, _) =>
                    HomeHeroBanner(bannerPath: bannerPath),
              ),
              // 前景：问候语压在左下、刷新在右端 ✓。
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  Spacing.lg,
                  Spacing.md,
                  Spacing.lg,
                  Spacing.md,
                ),
                child: Align(
                  alignment: Alignment.bottomLeft,
                  child: HomeGreetingHeader(
                    returningAfter: _returningAfter,
                    // 横向与底部留白由名片带统一给 ✓（避免两处再各加一份）。
                    padding: EdgeInsets.zero,
                    action: IconButton.filledTonal(
                      tooltip: '刷新主页',
                      onPressed: _refreshAll,
                      icon: const Icon(Symbols.refresh),
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  /// 名片带的高度比例：宽度 × 这个数，再夹到 [_identityMinHeight]~[_identityMaxHeight] ✓。
  ///
  /// 0.20 ≈ 1500 宽时 300 高（被 280 上限接住）、900 宽时 180 ✓ —— 全屏与窄窗都自然 ✓。
  static const double _identityHeightRatio = 0.20;
  static const double _identityMinHeight = 140;
  static const double _identityMaxHeight = 280;

  // --------------------------------------------------------------- 继续听

  /// 「再听一遍」：**自己管自己的头与内容** ✓（`ContentSection` 保持完整 ✓）。
  ///
  /// 与横幅的"浸入式融合"靠**布局**实现（横幅在底下多延伸一截）✓，
  /// **不靠**把区块头搬进背景组件 ✗ —— 那会破坏区块组件的内聚性 ✓。
  Widget _buildHistory(OnlineHistoryViewSnapshot history) {
    // **不再直接切统计的前 N 条** ✗（2026-10-12 用户要求 ✓）：
    // 统计的 `recent` 只有"时间倒序"这一个维度 ✓ ⇒ 连听一张专辑就会整块被它占满 ✗。
    // 交给重温引擎 ✓：次线性熟悉度 × 近因因子 × 时长因子 + 多样性重排 ✓。
    final picks = _rediscovery.rank(
      entries: history.recent,
      now: DateTime.now(),
      intent: RediscoveryIntent.replay,
      limit: widget.previewLimit,
    );
    final entries = [for (final pick in picks) pick.entry];
    // **模块内没有内容就整块不渲染** ✓（2026-10-17 用户指令）：不再摆空态文案 ✓。
    if (entries.isEmpty) return const SizedBox.shrink();
    final reasons = {
      for (final pick in picks) pick.entry.track.ref: pick.reason,
    };
    return ContentSection(
      // 照用户给的 YT 图改名 ✓：原来是「继续听」✓，图上第一块叫「再听一遍」✓。
      title: '再听一遍',
      subtitle: '你最近常听的，接着听',
      actionLabel: '查看全部',
      onAction: () => context.go('${app_paths.STATS_PAGE}?source=online'),
      // 2026-10-16 用户指令 ✓：标题行右侧只留「查看全部」✓，**不放头部箭头** ✗；
      // 箭头交给货架自己画在左右两侧 ✓（还能往那一侧滑时才出现 ✓）。
      // **卡片货架**（2026-10-12 ✓，用户裁定 ✓）：参考的第一块就是卡片货架 ✓，
      // 不是一行行的曲目 ✗。数据仍是**真实的**本地历史 ✓。
      child: HorizontalShelf(
        // 同上 ✓：不再把滚动状态接到头部（那会抢走货架自己的左右箭头 ✓）。
        // **不传 `scrollState`** ✓ ⇒ `HorizontalShelf` 自己画覆盖层箭头 ✓（与探索页一致 ✓）。
        itemCount: entries.length,
        itemWidth: ShelfGeometry.cardWidth(context),
        itemHeight: ShelfGeometry.cardExtent(
          width: ShelfGeometry.cardWidth(context),
          hasFooter: false,
        ),
        itemBuilder: (context, index) => _historyCard(
          entries[index].track,
          reason: reasons[entries[index].track.ref],
          onTap: () => playOnlineHistoryEntry(
            context,
            entries: history.recent,
            selectedRef: entries[index].track.ref,
          ),
        ),
      ),
    );
  }

  /// 历史类货架的一张卡（再听一遍 / 好久没听共用 ✓）：封面 + 曲名 + **艺人 · 专辑**（两行 ✓）。
  ///
  /// [reason] 是引擎给的"凭什么轮到它" ✓ ⇒ 进**语义标签** ✓
  /// （屏幕上不堆解释文字 ✓，但读屏与自动化都能拿到这个理由 ✓）。
  Widget _historyCard(
    MusicTrack track, {
    required VoidCallback onTap,
    String? reason,
  }) {
    final base = '播放"${track.title} - ${track.artistDisplay}"';
    return RemoteMediaCard(
      width: ShelfGeometry.cardWidth(context),
      title: track.title,
      coverUri: track.coverUri,
      details: [
        track.artistDisplay,
        if (track.album.isNotEmpty) track.album,
      ].join(' · '),
      sourceLabel: platformLabelForIdentityOnly(track.ref.identity),
      placeholderIcon: Symbols.music_note,
      onTap: onTap,
      semanticLabel: reason == null ? base : '$base（推荐理由：$reason）',
    );
  }

  // ------------------------------------------------------------- 好久没听

  /// 「**你的回顾**」（Recap 的**本地版** ✓，2026-10-12 ✓）。
  ///
  /// 为什么是本地的：官方 Recap 端点在这个服务上**实测 404** ✗，
  /// 而"听过多少、最近在听什么、最常听谁"这些**我们本地就有真数据** ✓ ⇒ 自己做 ✓。
  ///
  /// ⚠️ **口径必须说清** ✓（否则就是拿总次数冒充"本月"✗）：
  /// - 「最近 30 天在听的曲目」= `lastPlayedAt` 落在窗口内的**曲目条数** ✓（能算准 ✓）；
  /// - 「历史总播放」= `totalPlayCount` ✓（**全时段** ✓，不是本月 ✗）；
  /// - 「最常听的艺人」= 按**累计次数**聚合 ✓（同样是全时段 ✓）。
  /// 我们把窗口与全时段**分开写清** ✓ —— 数字不编 ✓。
  Widget _buildLocalRecap(OnlineHistoryViewSnapshot history) {
    final now = DateTime.now();
    final windowStart = now.subtract(const Duration(days: 30));
    final recentTracks = history.recent
        .where((entry) => entry.lastPlayedAt.isAfter(windowStart))
        .length;

    // 全时段最常听的艺人：把每首的累计次数加到它的每个艺人身上 ✓。
    final byArtist = <String, int>{};
    for (final entry in history.recent) {
      for (final artist in entry.track.artists) {
        final name = artist.trim();
        if (name.isEmpty) continue;
        byArtist[name] = (byArtist[name] ?? 0) + entry.playCount;
      }
    }
    String? topArtist;
    var topArtistPlays = 0;
    for (final item in byArtist.entries) {
      if (item.value > topArtistPlays ||
          (item.value == topArtistPlays &&
              topArtist != null &&
              item.key.compareTo(topArtist) < 0)) {
        topArtist = item.key;
        topArtistPlays = item.value;
      }
    }

    // **没有任何播放记录 ⇒ 整块不渲染** ✓（2026-10-17 模块显示规则）：
    // 这一块是"本机数字"，没有数字就没有内容 ✓。**失败仍然显示** ✓ ——
    // "读不到"不等于"没有"，藏起来会让人以为这台机器从没播放过 ✓。
    if (history.recent.isEmpty &&
        history.status != OnlineHistoryLoadStatus.failed) {
      return const SizedBox.shrink();
    }

    return ContentSection(
      title: '你的回顾',
      // **口径写在副标题里** ✓：一看就知道这些数是哪来的 ✓。
      subtitle: '根据这台电脑上的播放记录整理',
      actionLabel: '查看全部',
      onAction: () => context.go('${app_paths.STATS_PAGE}?source=online'),
      child: history.status == OnlineHistoryLoadStatus.failed
          ? const InlineEmptyHint(
              icon: Symbols.insights,
              message: '播放记录读不到，回顾暂时出不来',
            )
          : Row(
              // ⚠️ **不能用 `stretch`** ✗：这里是 `Column` 的孩子 ⇒ 高度无界 ✓，
              // `stretch` 会当场抛异常（整个主页都渲染不出来 ✗）。
              // 用 `start` ⇒ 三格各自按内容定高 ✓（数字长短不同也无所谓 ✓）。
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: _RecapTile(
                    icon: Symbols.schedule,
                    value: '$recentTracks',
                    label: '最近 30 天在听的曲目',
                  ),
                ),
                const SizedBox(width: Spacing.md),
                Expanded(
                  child: _RecapTile(
                    icon: Symbols.play_circle,
                    value: '${history.totalPlayCount}',
                    label: '历史总播放次数',
                  ),
                ),
                const SizedBox(width: Spacing.md),
                Expanded(
                  child: _RecapTile(
                    icon: Symbols.artist,
                    value: topArtist ?? '—',
                    label: topArtist == null
                        ? '最常听的艺人（还没有数据）'
                        : '最常听的艺人（$topArtistPlays 次）',
                  ),
                ),
              ],
            ),
    );
  }

  /// 「**好久没听**」（照用户给的 YT 图第 2 块 ✓，2026-10-12 **改名** ✓）。
  ///
  /// ⚠️ **为什么改名**（用户指出"老歌"有歧义 ✓）：
  /// - 读法 A「**上世纪 90 年代的歌**」✗ —— **我们做不到** ✗：库里**没有发行年份** ✗
  ///   （`online_tracks.created_at` 是"我们第一次见到它"的时间 ✓，不是发行时间 ✗）
  ///   ⇒ 照这个读法做就是**编数据** ✓（要真做，得先抓专辑 `publishTime` 并加一列 ✓）。
  /// - 读法 B「**你确实听过、但好久没听**」✓ —— 这正是我们两个信号
  ///   （`play_count` + `last_played_at` ✓）能**如实**表达的 ✓ ⇒ 采用它 ✓，并**改名消歧** ✓。
  ///
  /// 排序同样交给重温引擎 ✓（**不是**按播放次数倒序 ✗）：它要求"听过 ≥14 天才算久" ✓，
  /// 再用 `1-exp(-t/30)` 让"越久越靠前" ✓，并做同艺人/同专辑/同平台**多样性重排** ✓。
  Widget _buildTopPlayed(OnlineHistoryViewSnapshot history) {
    final picks = _rediscovery.rank(
      entries: history.topPlayed,
      now: DateTime.now(),
      intent: RediscoveryIntent.rediscover,
      limit: widget.previewLimit,
    );
    final entries = [for (final pick in picks) pick.entry];
    // 模块内没有内容 ⇒ 整块不渲染 ✓（与「再听一遍」同一条规则）。
    if (entries.isEmpty) return const SizedBox.shrink();
    final reasons = {
      for (final pick in picks) pick.entry.track.ref: pick.reason,
    };
    return ContentSection(
      title: '好久没听',
      subtitle: '你很喜欢、但有一阵没听了',
      actionLabel: '查看全部',
      onAction: () => context.go('${app_paths.STATS_PAGE}?source=online'),
      // 同「再听一遍」✓：标题行只留「查看全部」✓，箭头由货架自己画 ✓。
      // 与「再听一遍」同一套卡片货架 ✓（用户裁定：这两块都用卡片 ✓）。
      child: HorizontalShelf(
        // 不传 `scrollState` ✓ ⇒ 货架自己画左右箭头 ✓（与「再听一遍」和探索页一致 ✓）。
        itemCount: entries.length,
        itemWidth: ShelfGeometry.cardWidth(context),
        itemHeight: ShelfGeometry.cardExtent(
          width: ShelfGeometry.cardWidth(context),
          hasFooter: false,
        ),
        itemBuilder: (context, index) => _historyCard(
          entries[index].track,
          reason: reasons[entries[index].track.ref],
          onTap: () => playOnlineHistoryEntry(
            context,
            entries: history.topPlayed,
            selectedRef: entries[index].track.ref,
          ),
        ),
      ),
    );
  }

  // 「我的收藏」与「我的在线歌单」两块**已按用户指令移除** ✓（2026-10-17）：
  // 这两类内容原本在主页与各自的页面里各显示一遍 ✓（收藏页 / 歌单页），
  // 主页不再重复摆 ✓ —— 侧边栏与各自页面仍是一级入口 ✓。
}

/// 「你的回顾」里的一格数字（**本机口径** ✓，2026-10-12 ✓）。
///
/// 刻意做成"数字 + 说明"两行 ✓：数字再漂亮，**口径说不清**就等于编 ✓
/// （所以每格的 [label] 必须写明白它是全时段还是最近 30 天 ✓）。
class _RecapTile extends StatelessWidget {
  const _RecapTile({
    required this.icon,
    required this.value,
    required this.label,
  });

  final IconData icon;
  final String value;
  final String label;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(Spacing.md),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: AppRadius.smCircular,
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: scheme.onSurfaceVariant),
          const SizedBox(height: Spacing.sm),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: scheme.onSurface,
              fontSize: AppType.subtitle,
              fontWeight: AppType.weightSemibold,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: scheme.onSurfaceVariant,
              fontSize: AppType.caption,
            ),
          ),
        ],
      ),
    );
  }
}
