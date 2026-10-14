import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';
import 'package:pure_music/component/content_section.dart';
import 'package:pure_music/component/home_greeting_header.dart';
import 'package:pure_music/component/home_placeholder_shelf.dart';
import 'package:pure_music/component/horizontal_shelf.dart';
import 'package:pure_music/component/online_search_launcher.dart';
import 'package:pure_music/component/online_track_entry.dart';
import 'package:pure_music/component/platform_capability_view.dart';
import 'package:pure_music/component/remote_load_state.dart';
import 'package:pure_music/component/remote_media_card.dart';
import 'package:pure_music/core/design_tokens.dart';
import 'package:pure_music/core/paths.dart' as app_paths;
import 'package:pure_music/core/preference.dart';
import 'package:pure_music/core/utils.dart';
import 'package:pure_music/page/page_scaffold.dart';
import 'package:pure_music/services/music_platform/index.dart';
import 'package:pure_music/services/music_platform/online_library/online_history_controller.dart';
import 'package:pure_music/services/music_platform/online_library/online_library_repository.dart';
import 'package:pure_music/services/music_platform/online_library/online_playlist_controller.dart';
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

  /// 有「歌单列表」能力的平台（服务层推导，未配置的平台不会出现在这里）。
  List<MusicPlatform> _collectionPlatforms = const [];
  final Set<MusicPlatform> _subscribing = {};

  /// 平台歌单按平台各自加载（单平台失败不影响其它平台）。
  final RemoteLoadState<MusicPlatform, RemotePlaylistSummary> remote =
      RemoteLoadState<MusicPlatform, RemotePlaylistSummary>();

  /// **「新歌上线」货架**（2026-10-12 ✓）：对齐参考 Home 里的 `新曲上线` ✓
  ///（参考 Home 有 13 个货架，这是**能借**的那一类 ✓；推荐/视频类不借 ✓）。
  ///
  /// 只对**能播放**的平台出现 ✓（`playableNewSongPlatforms` ✓）——
  /// 摆一堆点不响的曲目比不显示更糟 ✗。
  List<MusicPlatform> _newSongPlatforms = const [];
  final RemoteLoadState<MusicPlatform, MusicTrack> _newSongState =
      RemoteLoadState<MusicPlatform, MusicTrack>();

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

  /// **「关注的艺人」货架**（`followedArtists` 能力，2026-10-12 新增 ✓）。
  ///
  /// 判据：**既列得出、艺人页又打得开** ✓（`openableFollowedArtistPlatforms` ✓）。
  /// ⚠️ 账号没关注任何人时平台会**如实返回 0 条** ✓ ⇒ 走**中性空态**（不是失败 ✓）。
  List<MusicPlatform> _followedArtistPlatforms = const [];
  final RemoteLoadState<MusicPlatform, OnlineArtistSummary>
  _followedArtistState =
      RemoteLoadState<MusicPlatform, OnlineArtistSummary>();

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
    unawaited(_loadCollections());
    unawaited(_loadNewSongs());
    unawaited(_loadRecommended());
    unawaited(_loadRecommendedPlaylists());
    unawaited(_loadFollowedArtists());
  }

  Future<void> _refreshAll() async {
    final history = context.read<OnlineHistoryController>();
    final personal = context.read<PersonalOnlinePlaylistController>();
    unawaited(history.refresh());
    unawaited(personal.load());
    await Future.wait([
      _loadFavorites(),
      _loadCollections(),
      _loadNewSongs(),
      _loadRecommended(),
      _loadRecommendedPlaylists(),
      _loadFollowedArtists(),
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

  Future<void> _loadNewSongs() async {
    final service = context.read<OnlineMusicService?>();
    final platforms = service == null
        ? const <MusicPlatform>[]
        : [
            for (final platform in builtinMusicPlatforms)
              if (service.capabilities.playableNewSongPlatforms.contains(
                platform,
              ))
                platform,
          ];
    if (!mounted) return;
    setState(() => _newSongPlatforms = platforms);
    if (service == null) return;
    await Future.wait([
      for (final platform in platforms) _loadNewSong(service, platform),
    ]);
  }

  Future<void> _loadNewSong(
    OnlineMusicService service,
    MusicPlatform platform,
  ) => loadRemoteList(
    _newSongState,
    platform,
    () => service.fetchNewSongs(
      platform: platform,
      limit: widget.collectionLimit,
      offset: 0,
      cancelToken: newCancelToken(),
    ),
    fallback: '读取该平台新歌失败',
  );

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
            Column(
              children: [
                for (final track in tracks)
                  OnlineTrackEntry(
                    track: track,
                    onTap: () => playOnlineSearchResult(
                      context,
                      tracks: tracks,
                      selectedRef: track.ref,
                    ),
                  ),
              ],
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
      child: Column(
        children: [
          for (final platform in _recommendedPlaylistPlatforms)
            _buildRecommendedPlaylistSection(platform),
        ],
      ),
    );
  }

  Widget _buildRecommendedPlaylistSection(MusicPlatform platform) {
    final scheme = Theme.of(context).colorScheme;
    final items = _recommendedPlaylistState.items(platform);
    final width = _cardWidth;
    // 有内容时把失败留给"加载更多/底部"处理 ✓；这里只负责首屏的失败 ✓（并补上凭据指引 ✓）。
    final loadError = _recommendedPlaylistState.error(platform);
    final errorMessage = items.isEmpty && loadError != null
        ? _credentialFailureHint(loadError)
        : null;
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
          HorizontalShelf(
            loading:
                _recommendedPlaylistState.isLoading(platform) && items.isEmpty,
            errorMessage: errorMessage,
            onRetry: () => _retryRecommendedPlaylists(platform),
            emptyMessage: '该平台这次没有给推荐（也可能今天就是没有）。',
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
          Text(
            musicPlatformLabel(platform),
            style: TextStyle(
              color: scheme.onSurfaceVariant,
              fontSize: AppType.caption,
              fontWeight: AppType.weightSemibold,
            ),
          ),
          const SizedBox(height: Spacing.sm),
          HorizontalShelf(
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

  Widget _buildNewSongs() {    if (_newSongPlatforms.isEmpty) return const SizedBox.shrink();
    return ContentSection(
      title: '新歌上线',
      subtitle: '各平台最近发布的曲目；点一行即从该平台的新歌开始播放',
      actionLabel: '查看全部',
      onAction: () => context.go(app_paths.EXPLORE_PAGE),
      child: Column(
        children: [
          for (final platform in _newSongPlatforms) _buildNewSongSection(platform),
        ],
      ),
    );
  }

  Widget _buildNewSongSection(MusicPlatform platform) {
    final scheme = Theme.of(context).colorScheme;
    final tracks = _newSongState.items(platform);
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
          if (_newSongState.isLoading(platform))
            const Padding(
              padding: EdgeInsets.symmetric(vertical: Spacing.lg),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (_newSongState.error(platform) case final message?)
            InlineFailureHint(
              message: message,
              onRetry: () => _retryNewSongs(platform),
            )
          else if (tracks.isEmpty)
            const InlineEmptyHint(
              icon: Symbols.music_off,
              message: '该平台没有返回新歌。',
            )
          else
            Column(
              children: [
                for (final track in tracks)
                  OnlineTrackEntry(
                    track: track,
                    onTap: () => _playNewSong(tracks, track),
                  ),
              ],
            ),
        ],
      ),
    );
  }

  Future<void> _retryNewSongs(MusicPlatform platform) async {
    final service = context.read<OnlineMusicService?>();
    if (service == null) return;
    await _loadNewSong(service, platform);
  }

  Future<void> _playNewSong(Iterable<MusicTrack> tracks, MusicTrack track) =>
      playOnlineTrackSelection(
        context,
        OnlineTrackSelection.fromResultPage(
          tracks: tracks,
          selectedRef: track.ref,
        ),
      );

  Future<void> _loadCollections() async {
    final service = context.read<OnlineMusicService?>();
    final platforms = service == null
        ? const <MusicPlatform>[]
        : [
            for (final platform in builtinMusicPlatforms)
              if (service.capabilities.playlistCollectionPlatforms.contains(
                platform,
              ))
                platform,
          ];
    if (!mounted) return;
    setState(() => _collectionPlatforms = platforms);
    if (service == null) return;
    await Future.wait([
      for (final platform in platforms) _loadCollection(service, platform),
    ]);
  }

  Future<void> _loadCollection(
    OnlineMusicService service,
    MusicPlatform platform,
  ) => loadRemoteList(
    remote,
    platform,
    () => service.fetchPlaylistCollection(
      platform: platform,
      limit: widget.collectionLimit,
      offset: 0,
      cancelToken: newCancelToken(),
    ),
    fallback: '读取该平台歌单失败',
  );

  /// 把平台歌单**订阅到本机**（复用既有订阅链路），成功后打开详情。
  Future<void> _subscribe(RemotePlaylistSummary summary) async {
    if (_subscribing.contains(summary.platform)) return;
    setState(() => _subscribing.add(summary.platform));
    final controller = context.read<OnlinePlaylistController>();
    final saved = await controller.addOrRefresh(
      platform: summary.platform,
      remotePlaylistId: summary.id,
    );
    if (!mounted) return;
    setState(() => _subscribing.remove(summary.platform));
    if (saved == null) {
      showTextOnSnackBar(
        controller.snapshot.errorMessage ?? '订阅该歌单失败',
        variant: ToastVariant.error,
      );
      return;
    }
    showTextOnSnackBar(
      '已订阅「${saved.playlist.name}」',
      variant: ToastVariant.success,
    );
    await context.push(
      app_paths.ONLINE_PLAYLIST_DETAIL_PAGE,
      extra: saved.localId,
    );
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
          // ③ 翻唱与混音（缺：我们没有这类版权内容 ✓）
          const HomePlaceholderShelf(
            title: '翻唱与混音',
            subtitle: '同一首歌的不同版本，总有一版对味',
            source: '第三方内容源（本应用没有这类版权内容）',
            icon: Symbols.mic,
          ),
          // ④ 为你推荐的音乐视频（缺：我们只能播音频 ✓）
          const HomePlaceholderShelf(
            title: '为你推荐的音乐视频',
            subtitle: '用视频的形式给你推荐歌',
            source: '官方视频推荐接口（本应用目前只能播音频）',
            icon: Symbols.movie,
          ),
          // ⑤ 猜你喜欢（**有推荐能力就是真货架** ✓；没有就保留诚实展位 ✓）
          _buildRecommended(),
          // ⑥ 来自你的媒体库（真实：收藏 ✓ + 自建歌单 ✓ —— 图上是一块，我们拆成两块更清楚 ✓）
          _buildFavorites(),
          _buildPersonalPlaylists(personal),
          // ⑦ 关注的艺人（**有该能力就是真货架** ✓；没有就保留诚实展位 ✓）
          _buildFollowedArtists(),
          // ⑧ 来自社区（缺 ✓）
          const HomePlaceholderShelf(
            title: '来自社区',
            subtitle: '其他听众在做、在听的歌单',
            source: '官方社区接口（需要登录 Cookie）',
            icon: Symbols.groups,
          ),
          // ⑨ 为你推荐的**歌单**（名字如实 ✓：平台给的是歌单 ✓；有该能力就是真货架 ✓）
          _buildRecommendedPlaylists(),
          // ⑩ 新曲上线（真实：各平台新歌 ✓）
          _buildNewSongs(),
          // ⑪⑫⑬ 官方三件套（都缺 ✓）
          const HomePlaceholderShelf(
            title: 'Recap',
            subtitle: '这一段时间你的听歌小结',
            source: '官方 Recap 接口（需要登录 Cookie）',
            icon: Symbols.insights,
          ),
          // ⑫ **每日发现：与「猜你喜欢」同源**（网易云实测两处都指向同一个每日推荐接口 ✓）
          // ⇒ **不摆两块重复内容** ✗ —— 这里不再单独放展位 ✓（已在「猜你喜欢」呈现 ✓）。
          const HomePlaceholderShelf(
            title: '个性化合辑',
            subtitle: '按心情与场景混出来的合辑',
            source: '官方个性化合辑接口（需要登录 Cookie）',
            icon: Symbols.auto_awesome,
          ),

          // ================= 图里没有、但我们本来就有的价值（保留 ✓）=================
          // 用户这轮的指令是"元素全部推翻、采用 YT 设计" ✓ —— 但这两块是我们**已有的真实能力** ✓
          // （各平台歌单 ✓ 与平台能力诊断 ✓），删掉是纯损失 ✗ ⇒ 放在最后保留 ✓，你要删说一句即可 ✓。
          _buildCollections(service),
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
    final entries = history.recent.take(widget.previewLimit).toList();
    return ContentSection(
      // 照用户给的 YT 图改名 ✓：原来是「继续听」✓，图上第一块叫「再听一遍」✓。
      title: '再听一遍',
      subtitle: '来自在线播放历史（按曲目自己的来源标注）',
      actionLabel: '查看全部',
      onAction: () => context.go('${app_paths.STATS_PAGE}?source=online'),
      child: entries.isEmpty
          ? InlineEmptyHint(
              icon: Symbols.history,
              message: history.status == OnlineHistoryLoadStatus.failed
                  ? '播放历史读取失败，可稍后重试。'
                  : '还没有在线播放记录：从探索或搜索进入任一平台曲目即可开始。',
            )
          : Column(
              children: [
                for (final entry in entries)
                  _buildTrackRow(
                    entry.track,
                    onTap: () => playOnlineHistoryEntry(
                      context,
                      entries: history.recent,
                      selectedRef: entry.track.ref,
                    ),
                  ),
              ],
            ),
    );
  }

  // ------------------------------------------------------------- 老歌重温

  /// 「老歌重温」（照用户给的 YT 图第 2 块 ✓）：**真实数据** ✓ ——
  /// 直接复用历史里已有的 `topPlayed`（按**播放次数**排序 ✓）。
  /// 文案如实 ✓：它说的是"你反复听过的那批" ✓，不假装是"年代久远的老歌" ✗（我们没有年代数据 ✓）。
  Widget _buildTopPlayed(OnlineHistoryViewSnapshot history) {
    final entries = history.topPlayed.take(widget.previewLimit).toList();
    return ContentSection(
      title: '老歌重温',
      subtitle: '你反复听过的那几首（按播放次数排序）',
      actionLabel: '查看全部',
      onAction: () => context.go('${app_paths.STATS_PAGE}?source=online'),
      child: entries.isEmpty
          ? InlineEmptyHint(
              icon: Symbols.replay,
              message: history.status == OnlineHistoryLoadStatus.failed
                  ? '播放历史读取失败，可稍后重试。'
                  : '还没有反复听过的曲目：某一首听上几遍，它会出现在这里。',
            )
          : Column(
              children: [
                for (final entry in entries)
                  _buildTrackRow(
                    entry.track,
                    onTap: () => playOnlineHistoryEntry(
                      context,
                      entries: history.topPlayed,
                      selectedRef: entry.track.ref,
                    ),
                  ),
              ],
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

  // --------------------------------------------------------- 平台歌单列表

  Widget _buildCollections(OnlineMusicService? service) {
    if (service == null || _collectionPlatforms.isEmpty) {
      return ContentSection(
        title: '来自平台的歌单',
        subtitle: '来自各平台自己的「歌单列表」能力',
        actionLabel: '去配置',
        onAction: () => context.go(app_paths.SETTINGS_PAGE),
        child: const InlineEmptyHint(
          icon: Symbols.info,
          message:
              '当前没有可用的「歌单列表」服务：先在「设置 → 在线音乐 → 服务提供商」里'
              '为某个条目配置并试跑「歌单列表」能力（保存后重启生效），'
              '再到平台卡里选它做该能力的来源。',
        ),
      );
    }
    return ContentSection(
      title: '来自平台的歌单',
      subtitle: '每个平台各自加载；一个平台失败不影响其它平台',
      actionLabel: '查看全部',
      onAction: () => context.go(app_paths.EXPLORE_PAGE),
      child: Column(
        children: [
          for (final platform in _collectionPlatforms)
            _buildPlatformCollection(platform),
        ],
      ),
    );
  }

  Widget _buildPlatformCollection(MusicPlatform platform) {
    final scheme = Theme.of(context).colorScheme;
    final items = remote.items(platform);
    final width = _cardWidth;
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
          HorizontalShelf(
            loading: remote.isLoading(platform),
            errorMessage: remote.error(platform),
            onRetry: () => _retryCollection(platform),
            emptyMessage: '该平台没有返回歌单。',
            emptyIcon: Symbols.queue_music,
            itemCount: items.length,
            itemWidth: width,
            // 高度取自卡片的同一份声明：卡片变高时货架跟着变，不会溢出。
            itemHeight: RemoteMediaCard.extentFor(
              width: width,
              hasFooter: true,
            ),
            itemBuilder: (context, index) {
              final summary = items[index];
              final busy = _subscribing.contains(platform);
              return RemoteMediaCard(
                width: width,
                title: summary.name,
                coverUri: summary.coverUri,
                details: _detailsOf(summary),
                sourceLabel: platformLabelForIdentityOnly(summary.identity),
                placeholderIcon: Symbols.queue_music,
                onTap: busy ? null : () => _subscribe(summary),
                semanticLabel:
                    '${summary.name}，来自${platformLabelForIdentityOnly(summary.identity)}，点击订阅并打开',
                footer: TextButton(
                  onPressed: busy ? null : () => _subscribe(summary),
                  child: const Text('订阅'),
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  /// 平台歌单卡片：元信息行统一为「**类型 · …**」，类型是「歌单」。
  String _detailsOf(RemotePlaylistSummary summary) {
    final creator = summary.creator?.trim();
    return [
      '歌单',
      if (creator != null && creator.isNotEmpty) creator,
      if (summary.trackCount != null) '${summary.trackCount} 首',
    ].join(' · ');
  }

  Future<void> _retryCollection(MusicPlatform platform) async {
    final service = context.read<OnlineMusicService?>();
    if (service == null) return;
    await _loadCollection(service, platform);
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
