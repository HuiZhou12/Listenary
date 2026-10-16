import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';
import 'package:pure_music/component/content_section.dart';
import 'package:pure_music/component/home_greeting_header.dart';
import 'package:pure_music/component/home_placeholder_shelf.dart';
import 'package:pure_music/component/horizontal_shelf.dart';
import 'package:pure_music/component/new_song_shelf.dart';
import 'package:pure_music/component/online_search_launcher.dart';
import 'package:pure_music/component/online_track_entry.dart';
import 'package:pure_music/component/platform_capability_view.dart';
import 'package:pure_music/component/remote_load_state.dart';
import 'package:pure_music/component/remote_media_card.dart';
import 'package:pure_music/component/shelf_arrows.dart';
import 'package:pure_music/component/shelf_scroll_state.dart';
import 'package:pure_music/services/online_history/rediscovery_engine.dart';
import 'package:pure_music/core/design_tokens.dart';
import 'package:pure_music/core/paths.dart' as app_paths;
import 'package:pure_music/core/preference.dart';
import 'package:pure_music/page/page_scaffold.dart';
import 'package:pure_music/services/music_platform/index.dart';
import 'package:pure_music/services/music_platform/online_library/online_history_controller.dart';
import 'package:pure_music/services/music_platform/online_library/online_library_repository.dart';
import 'package:pure_music/services/music_platform/online_library/personal_online_playlist_controller.dart';

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

  /// 记住实例以便在 dispose 时摘掉监听（`context.removeListener` 不存在）。
  PersonalOnlinePlaylistController? _personal;

  PersonalOnlinePlaylistSnapshot? _favorites;
  bool _favoritesLoading = false;
  bool _favoritesFailed = false;

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

  /// **「个性化合辑」货架**（`personalizedPlaylists` 能力，2026-10-12 新增 ✓）。
  ///
  /// 与「为你推荐的歌单」**形状相同** ✓（都是歌单摘要 ✓），但**语义不同** ✓：
  /// 这条**免登录就有内容** ✓（实测 `/personalized` ✓）⇒ 失败时**不给**凭据指引 ✓。
  List<MusicPlatform> _personalizedPlaylistPlatforms = const [];
  final RemoteLoadState<MusicPlatform, RemotePlaylistSummary>
  _personalizedPlaylistState =
      RemoteLoadState<MusicPlatform, RemotePlaylistSummary>();

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
      _personal = context.read<PersonalOnlinePlaylistController>();
      _personal!.addListener(_onPersonalChanged);
      unawaited(_load());
    });
  }

  @override
  void dispose() {
    for (final state in _shelfScrollStates.values) {
      state.dispose();
    }
    _shelfScrollStates.clear();
    _personal?.removeListener(_onPersonalChanged);
    super.dispose();
  }

  void _onPersonalChanged() {
    if (!mounted) return;
    // 收藏是异步读的，且读本身不会触发通知，因此这里直接刷新是安全的。
    unawaited(_loadFavorites());
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
    final personal = context.read<PersonalOnlinePlaylistController>();
    unawaited(history.refresh());
    unawaited(personal.load());
    unawaited(_loadFavorites());
    unawaited(_loadRecommended());
    unawaited(_loadRecommendedPlaylists());
    unawaited(_loadFollowedArtists());
    unawaited(_loadPersonalizedPlaylists());
  }

  Future<void> _refreshAll() async {
    final history = context.read<OnlineHistoryController>();
    final personal = context.read<PersonalOnlinePlaylistController>();
    unawaited(history.refresh());
    unawaited(personal.load());
    await Future.wait([
      _loadFavorites(),
      _loadRecommended(),
      _loadRecommendedPlaylists(),
      _loadFollowedArtists(),
      _loadPersonalizedPlaylists(),
    ]);
  }

  Future<void> _loadFavorites() async {
    if (_favoritesLoading || !mounted) return;
    _favoritesLoading = true;
    try {
      final snapshot = await context
          .read<PersonalOnlinePlaylistController>()
          .readFavorites();
      if (!mounted) return;
      setState(() {
        _favorites = snapshot;
        _favoritesFailed = false;
      });
    } catch (_) {
      // 收藏读不出来时该区块显示**失败**态（不是"还没有收藏"），不影响主页其它区块。
      if (mounted) {
        setState(() {
          _favorites = null;
          _favoritesFailed = true;
        });
      }
    } finally {
      _favoritesLoading = false;
    }
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
  Widget _buildRecommended() {
    if (_recommendedPlatforms.isEmpty) {
      return const HomePlaceholderShelf(
        title: '猜你喜欢',
        subtitle: '根据你的口味挑出来的歌',
        source: '官方推荐接口（需要登录 Cookie）',
        icon: Symbols.favorite,
      );
    }
    return ContentSection(
      title: '猜你喜欢',
      subtitle: '各平台按你的账号推荐的曲目；点一行即从该平台的推荐开始播放',
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
              message: '该平台这次没有给推荐（也可能今天就是没有）。',
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
    if (_recommendedPlaylistPlatforms.isEmpty) {
      return const HomePlaceholderShelf(
        title: '为你推荐的歌单',
        subtitle: '平台按你的账号挑的歌单',
        source: '官方推荐接口（需要登录 Cookie）',
        icon: Symbols.queue_music,
      );
    }
    return ContentSection(
      title: '为你推荐的歌单',
      subtitle: '各平台按你的账号推荐；点一张**预览**（不会自动订阅 ✓）',
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
              emptyMessage: '该平台这次没有给推荐（也可能今天就是没有）。',
              // **凭据型货架** ✓ ⇒ 失败时补上"可能是凭据失效"的指引 ✓。
              decorateError: _credentialFailureHint,
              onRetry: () => _retryRecommendedPlaylists(platform),
            ),
        ],
      ),
    );
  }

  /// 「**个性化合辑**」（`personalizedPlaylists` ✓，2026-10-12 ✓）：实测 `/personalized`
  /// **免登录**就有内容 ✓ ⇒ 与"为你推荐的歌单"形状相同 ✓，但**不补凭据指引** ✗
  ///（它不需要凭据；加了就是误导 ✓）。
  Widget _buildPersonalizedPlaylists() {
    if (_personalizedPlaylistPlatforms.isEmpty) {
      return const HomePlaceholderShelf(
        title: '个性化合辑',
        subtitle: '按心情与场景混出来的合辑',
        source: '官方个性化接口（网易云 /personalized）',
        icon: Symbols.auto_awesome,
      );
    }
    return ContentSection(
      title: '个性化合辑',
      // 文案**不过度承诺** ✓：登录后更贴合而已 ✓，不是"为你量身定做" ✗。
      subtitle: '平台按口味挑的歌单合集（登录后会更贴合你）；点一张预览，不会自动订阅',
      // 同「为你推荐的歌单」✓：区块头右侧是「查看全部」✓，箭头由货架自己画 ✓。
      actionLabel: '查看全部',
      onAction: () => context.go(app_paths.EXPLORE_PAGE),
      child: Column(
        children: [
          for (final platform in _personalizedPlaylistPlatforms)
            _playlistShelfSection(
              platform,
              state: _personalizedPlaylistState,
              emptyMessage: '该平台这次没有给合辑（也可能今天就是没有）。',
              onRetry: () => _retryPersonalizedPlaylists(platform),
            ),
        ],
      ),
    );
  }

  /// 一条**歌单货架**（"为你推荐的歌单" 与 "个性化合辑" 共用 ✓，2026-10-12 ✓）。
  ///
  /// 两者形状完全一样 ✓（都是歌单摘要 ✓），差别只有：标题 ✓、数据状态 ✓、空态文案 ✓，
  /// 以及 **`decorateError`** —— 只有**凭据型**的那条才补"可能是凭据失效"的指引 ✓
  ///（"个性化合辑"免登录就有内容 ✓，给它加凭据指引就是误导 ✗）。
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
    // 探索页三处卡片都是 `_cardWidth * 1.15`（封面整体放大 15% ✓，R100 起的既定尺寸 ✓）；
    // 主页这两块歌单卡此前用的是 `_cardWidth` ✗ ⇒ 看起来"小一号" ✓ ⇒ 对齐 ✓。
    final width = _cardWidth * 1.15;
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
            itemHeight: RemoteMediaCard.extentFor(
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
                onTap: () => context.push(
                  app_paths.REMOTE_PLAYLIST_PAGE,
                  extra: (
                    platform: summary.platform,
                    playlistId: summary.id,
                    name: summary.name,
                    coverUri: summary.coverUri,
                    creator: summary.creator,
                    trackCount: summary.trackCount,
                    ranked: false,
                  ),
                ),
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

  /// **个性化合辑**（`personalizedPlaylists` ✓）：与"推荐歌单"同一套做法 ✓（判据相同 ✓）。
  Future<void> _loadPersonalizedPlaylists() async {
    final service = context.read<OnlineMusicService?>();
    final platforms = service == null
        ? const <MusicPlatform>[]
        : [
            for (final platform in builtinMusicPlatforms)
              if (service
                  .capabilities
                  .openablePersonalizedPlaylistPlatforms
                  .contains(platform))
                platform,
          ];
    if (!mounted) return;
    setState(() => _personalizedPlaylistPlatforms = platforms);
    if (service == null) return;
    await Future.wait([
      for (final platform in platforms)
        _loadPersonalizedPlaylistsFor(service, platform),
    ]);
  }

  Future<void> _loadPersonalizedPlaylistsFor(
    OnlineMusicService service,
    MusicPlatform platform,
  ) => loadRemoteList(
    _personalizedPlaylistState,
    platform,
    () => service.fetchPersonalizedPlaylists(
      platform: platform,
      limit: widget.collectionLimit,
      offset: 0,
      cancelToken: newCancelToken(),
    ),
    fallback: '读取该平台个性化合辑失败',
  );

  Future<void> _retryPersonalizedPlaylists(MusicPlatform platform) async {
    final service = context.read<OnlineMusicService?>();
    if (service == null) return;
    await _loadPersonalizedPlaylistsFor(service, platform);
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
    if (_followedArtistPlatforms.isEmpty) {
      return const HomePlaceholderShelf(
        title: '关注的艺人',
        subtitle: '你关注的艺人的最新动态',
        source: '官方「关注的艺人」接口（需要登录 Cookie）',
        icon: Symbols.artist,
      );
    }
    return ContentSection(
      title: '关注的艺人',
      subtitle: '各平台按你的账号关注的人；点一位打开艺人页',
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
    final width = _cardWidth;
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
            emptyMessage: '这个账号在${musicPlatformLabel(platform)}没有关注任何艺人。',
            emptyIcon: Symbols.artist,
            itemCount: artists.length,
            itemWidth: width,
            itemHeight: RemoteMediaCard.extentFor(
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



  /// 货架里卡片的宽度：**统一取自 `RemoteMediaCard.widthFor`**（与 ResponsiveBuilder 同阈值），
  /// 不在每个页面各写一个断点。
  double get _cardWidth =>
      RemoteMediaCard.widthFor(MediaQuery.sizeOf(context));

  @override
  Widget build(BuildContext context) {
    final service = context.read<OnlineMusicService?>();
    final history = context.watch<OnlineHistoryController>().snapshot;
    final personal = context.watch<PersonalOnlinePlaylistController>().snapshot;
    return PageScaffold(
      title: '主页',
      subtitle: '接着听、你的收藏与各平台内容，来源始终可见',
      actions: [
        IconButton.filledTonal(
          tooltip: '搜索在线音乐',
          onPressed: () => context.go(app_paths.ONLINE_MUSIC_PAGE),
          icon: const Icon(Symbols.search),
        ),
        IconButton.filledTonal(
          tooltip: '刷新主页',
          onPressed: _refreshAll,
          icon: const Icon(Symbols.refresh),
        ),
      ],
      body: ListView(
        padding: const EdgeInsets.only(bottom: Spacing.bottomNav, right: 20),
        children: [
          // ================= 主页重置（2026-10-12，照用户给的 YT Music 图 ✓）=================
          // 顺序与图一致 ✓；**有真实数据的接真实数据** ✓，缺的做成**诚实展位** ✓
          //（展位写明"要接什么接口"✓，不塞假内容 ✗）。
          HomeGreetingHeader(returningAfter: _returningAfter),
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
          // ⑤ 猜你喜欢（**有推荐能力就是真货架** ✓；没有就保留诚实展位 ✓）
          _buildRecommended(),
          // ⑥ 来自你的媒体库（真实：收藏 ✓ + 自建歌单 ✓ —— 图上是一块，我们拆成两块更清楚 ✓）
          _buildFavorites(),
          _buildPersonalPlaylists(personal),
          // ⑦ 关注的艺人（**有该能力就是真货架** ✓；没有就保留诚实展位 ✓）
          _buildFollowedArtists(),
          // ⑧ 「来自社区」**已删除** ✗（2026-10-12 ✓）：
          // 网易云只有 `/topic/sublist`（那是"**你自己订阅的专栏**" ✗，不是别人的社区内容 ✓），
          // 本地更没有社区 ✗ ⇒ 两边都做不到 ⇒ 撤掉 ✓。
          // ⑨ 为你推荐的**歌单**（名字如实 ✓：平台给的是歌单 ✓；有该能力就是真货架 ✓）
          _buildRecommendedPlaylists(),
          // ⑩ 新曲上线：**已按用户指令删除** ✗（2026-10-16 ✓）——
          // 主页不再重复探索页已有的「新歌」块 ✓（那边信息更全 ✓：可翻页、带平台筛选 ✓）。
          // ⑪ Recap：**用本机历史真做** ✓（2026-10-12 ✓）——
          // 官方 Recap 在这个服务上**实测 404** ✗（`/summary/annual` ✓），但**本地完全可做** ✓
          // ⇒ 按用户指令"能本地实现的就实现" ✓，并且**如实说明**这是本机数字 ✓（不冒充官方 Recap ✗）。
          _buildLocalRecap(history),
          // ⑫ **每日发现：与「猜你喜欢」同源**（网易云实测两处都指向同一个每日推荐接口 ✓）
          // ⇒ **不摆两块重复内容** ✗ —— 这里不再单独放展位 ✓（已在「猜你喜欢」呈现 ✓）。
          // ⑬ 个性化合辑（**有该能力就是真货架** ✓；没有就保留诚实展位 ✓）
          _buildPersonalizedPlaylists(),

          // ================= 图里没有、但我们本来就有的价值（保留 ✓）=================
          // 用户这轮的指令是"元素全部推翻、采用 YT 设计" ✓ —— 但这两块是我们**已有的真实能力** ✓
          // （各平台歌单 ✓ 与平台能力诊断 ✓），删掉是纯损失 ✗ ⇒ 放在最后保留 ✓，你要删说一句即可 ✓。
          // 「来自平台的歌单」**已按用户指令删除** ✗（2026-10-16 ✓）——
          // 探索页仍有「平台歌单」那一块 ✓（信息更全：分类筛选 ✓），主页不再重复 ✗。
          PlatformCapabilityView(
            capabilities: service?.capabilities,
            onConfigure: () => context.go(app_paths.SETTINGS_PAGE),
          ),
        ],
      ),
    );
  }

  // --------------------------------------------------------------- 继续听

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
    final reasons = {
      for (final pick in picks) pick.entry.track.ref: pick.reason,
    };
    return ContentSection(
      // 照用户给的 YT 图改名 ✓：原来是「继续听」✓，图上第一块叫「再听一遍」✓。
      title: '再听一遍',
      subtitle: '按"熟悉的程度 × 最近还在听"排的（不是简单按时间倒序）',
      actionLabel: '查看全部',
      onAction: () => context.go('${app_paths.STATS_PAGE}?source=online'),
      // **头部箭头**（2026-10-12 ✓）：参考的箭头在标题那一行 ✓。
      trailing: ShelfArrows(state: _shelfState('recent-history')),
      child: entries.isEmpty
          ? InlineEmptyHint(
              icon: Symbols.history,
              message: history.status == OnlineHistoryLoadStatus.failed
                  ? '播放历史读取失败，可稍后重试。'
                  : '还没有在线播放记录：从探索或搜索进入任一平台曲目即可开始。',
            )
          // **卡片货架**（2026-10-12 ✓，用户裁定 ✓）：参考的第一块就是卡片货架 ✓，
          // 不是一行行的曲目 ✗。数据仍是**真实的**本地历史 ✓。
          : HorizontalShelf(
              scrollState: _shelfState('recent-history'),
              itemCount: entries.length,
              itemWidth: _cardWidth,
              itemHeight: RemoteMediaCard.extentFor(
                width: _cardWidth,
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
      width: _cardWidth,
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

    return ContentSection(
      title: '你的回顾',
      // **口径写在副标题里** ✓：一看就知道这些数是哪来的 ✓。
      subtitle: '按本机播放历史算的（官方 Recap 接口在这个服务上没有，所以这是本地口径）',
      actionLabel: '查看全部',
      onAction: () => context.go('${app_paths.STATS_PAGE}?source=online'),
      child: history.status == OnlineHistoryLoadStatus.failed
          ? const InlineEmptyHint(
              icon: Symbols.insights,
              message: '播放历史读取失败，回顾暂时算不出来。',
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
    final reasons = {
      for (final pick in picks) pick.entry.track.ref: pick.reason,
    };
    return ContentSection(
      title: '好久没听',
      subtitle: '你听过不少次、但已经很久没碰的（听过不到 ${RediscoveryEngine.rediscoverMinDays} 天的不算）',
      actionLabel: '查看全部',
      onAction: () => context.go('${app_paths.STATS_PAGE}?source=online'),
      trailing: ShelfArrows(state: _shelfState('top-played')),
      child: entries.isEmpty
          ? InlineEmptyHint(
              icon: Symbols.replay,
              message: history.status == OnlineHistoryLoadStatus.failed
                  ? '播放历史读取失败，可稍后重试。'
                  : '还没有"好久没听"的曲目：某一首反复听过、又隔上两周没听，它会出现在这里。',
            )
          // 与「再听一遍」同一套卡片货架 ✓（用户裁定：这两块都用卡片 ✓）。
          : HorizontalShelf(
              scrollState: _shelfState('top-played'),
              itemCount: entries.length,
              itemWidth: _cardWidth,
              itemHeight: RemoteMediaCard.extentFor(
                width: _cardWidth,
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

  // ----------------------------------------------------------------- 收藏

  Widget _buildFavorites() {
    final tracks = _favorites?.tracks ?? const <MusicTrack>[];
    final preview = tracks.take(widget.previewLimit).toList();
    return ContentSection(
      title: '我的收藏',
      subtitle: '收藏是跨平台的，每行都标明来源',
      actionLabel: '查看全部',
      onAction: () => context.go(app_paths.FAVORITES_PAGE),
      child: switch (preview) {
        // 读取失败 ≠ 没有收藏：两者文案必须不同，否则一次网络抖动会被读成"收藏丢了"。
        _ when _favoritesFailed => InlineFailureHint(
          message: '收藏读取失败，可稍后重试。',
          onRetry: _loadFavorites,
        ),
        [] => const InlineEmptyHint(
          icon: Symbols.favorite,
          message: '还没有收藏：在在线曲目上点心形图标即可收藏。',
        ),
        _ => Column(
          children: [
            for (final track in preview)
              _buildTrackRow(
                track,
                onTap: () => playOnlineSearchResult(
                  context,
                  tracks: tracks,
                  selectedRef: track.ref,
                ),
              ),
          ],
        ),
      },
    );
  }

  /// 一行在线曲目：组装、来源标记、收藏与"加入歌单"都收敛在 [OnlineTrackEntry] 里
  /// （那段组装此前在四个页面各抄了一遍）。
  Widget _buildTrackRow(MusicTrack track, {required VoidCallback onTap}) =>
      OnlineTrackEntry(track: track, onTap: onTap);

  // ------------------------------------------------------------- 自建歌单

  Widget _buildPersonalPlaylists(PersonalOnlinePlaylistViewSnapshot snapshot) {
    final playlists = snapshot.playlists.take(widget.previewLimit).toList();
    return ContentSection(
      title: '我的在线歌单',
      subtitle: '应用自建的歌单，可以混放不同平台的曲目',
      actionLabel: '管理歌单',
      onAction: () => context.go(app_paths.PLAYLISTS_PAGE),
      child: playlists.isEmpty
          ? const InlineEmptyHint(
              icon: Symbols.playlist_add,
              message: '还没有自建歌单：在歌单页新建一个，就能把不同平台的曲目放在一起。',
            )
          : Column(
              children: [
                for (final playlist in playlists)
                  _PersonalPlaylistTile(
                    playlist: playlist,
                    onTap: () => context.push(
                      app_paths.PERSONAL_PLAYLIST_DETAIL_PAGE,
                      extra: playlist.localId,
                    ),
                  ),
              ],
            ),
    );
  }
}


class _PersonalPlaylistTile extends StatelessWidget {
  const _PersonalPlaylistTile({required this.playlist, required this.onTap});

  final PersonalOnlinePlaylistSnapshot playlist;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      type: MaterialType.transparency,
      borderRadius: AppRadius.smCircular,
      child: InkWell(
        borderRadius: AppRadius.smCircular,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: Spacing.sm,
            vertical: 10,
          ),
          child: Row(
            children: [
              Icon(Symbols.queue_music, color: scheme.onSurfaceVariant),
              const SizedBox(width: Spacing.md),
              Expanded(
                child: Text(
                  playlist.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: scheme.onSurface),
                ),
              ),
              Text(
                '${playlist.tracks.length} 首',
                style: TextStyle(
                  color: scheme.onSurfaceVariant,
                  fontSize: AppType.caption,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
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
