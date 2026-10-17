import 'dart:ui' show ImageFilter;
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';
import 'package:pure_music/component/album_shelf.dart';
import 'package:pure_music/component/content_section.dart';
import 'package:pure_music/component/online_search_launcher.dart';
import 'package:pure_music/component/quiet_empty_state.dart';
import 'package:pure_music/component/remote_media_cover.dart';
import 'package:pure_music/component/track_card_shelf.dart';
import 'package:pure_music/core/design_tokens.dart';
import 'package:pure_music/core/paths.dart' as app_paths;
import 'package:pure_music/page/page_scaffold.dart';
import 'package:pure_music/services/music_platform/index.dart';

/// **在线艺人页**（`artist` 能力，2026-10-12 新增）。
///
/// 与参考产品的 IA 对齐：头部是艺人（头像 + 名字 + 简介），下面是**热门歌曲**列表。
/// 参考产品的艺人页把「热门歌曲」放在「专辑」**之前** ✓（见 `docs/specs/`
/// 的参考分析 §3.1）；我们这一版先做热门歌曲 —— **专辑/单曲列表还没有对应能力**
/// （那需要"艺人作品列表"能力，属后续阶段 ✓），因此这里**不假装**有那一块 ✓。
///
/// 三态如实区分（与 Home/Explore 同一条纪律）：
/// - **未配置 / 不支持**：进入前就该被拦住（能力集合里没有该平台）⇒ 这里给中性说明 ✓；
/// - **失败**：错误文案 + 重试 ✓；
/// - **空**：该艺人**确实没有**热门曲目 ⇒ 中性提示、**不给重试** ✓。
class OnlineArtistPage extends StatefulWidget {
  const OnlineArtistPage({
    super.key,
    required this.platform,
    required this.artistId,
    this.initialName,
  });

  final MusicPlatform platform;

  /// 平台自己的艺人 id（**来自请求输入** ✓）。
  final String artistId;

  /// 从曲目行跳进来时已知的显示名：先渲染它，避免加载期间白屏 ✓。
  final String? initialName;

  @override
  State<OnlineArtistPage> createState() => _OnlineArtistPageState();
}

class _OnlineArtistPageState extends State<OnlineArtistPage> {
  OnlineArtist? _artist;
  String? _error;
  bool _loading = true;

  /// 首帧不在这里读 `context`（`initState` 里 `context.read` 会报错）⇒ 用这个开关
  /// 在 `didChangeDependencies` 里只启动一次 ✓。
  bool _started = false;

  OnlineMusicCancelToken? _token;

  /// **专辑区块**（`artistAlbums`，2026-10-12）：与热门歌曲**各算各的** ✓。
  ///
  /// `_albumsSupported` 为 false 时**整块不显示** ✓ —— 平台不支持还摆一个空区块，
  /// 只会让人以为"这个艺人没有专辑"（那是谎 ✓）。
  bool _albumsSupported = false;
  bool _albumsLoading = false;
  String? _albumsError;
  List<OnlineAlbumSummary> _albums = const [];
  OnlineMusicCancelToken? _albumsToken;

  /// **单曲区块**（`artistSongs`，2026-10-12）：参考里的「单曲和迷你专辑」✓。
  bool _songsSupported = false;
  bool _songsLoading = false;
  String? _songsError;
  List<MusicTrack> _songs = const [];
  OnlineMusicCancelToken? _songsToken;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    _load();
  }

  @override
  void dispose() {
    _token?.cancel();
    _albumsToken?.cancel();
    _songsToken?.cancel();
    super.dispose();
  }

  /// 艺人**单曲列表**（`artistSongs`）：与其它区块**互不影响** ✓。
  Future<void> _loadSongs(OnlineMusicService service) async {
    if (!service.capabilities.playableArtistSongPlatforms.contains(
      widget.platform,
    )) {
      if (!mounted) return;
      setState(() {
        _songsSupported = false;
        _songsLoading = false;
        _songs = const [];
      });
      return;
    }
    _songsToken?.cancel();
    final token = OnlineMusicCancelToken();
    _songsToken = token;
    setState(() {
      _songsSupported = true;
      _songsLoading = true;
      _songsError = null;
    });
    try {
      final songs = await service.fetchArtistSongs(
        platform: widget.platform,
        artistId: widget.artistId,
        cancelToken: token,
      );
      if (!mounted || token.isCancelled) return;
      setState(() {
        _songs = songs;
        _songsLoading = false;
      });
    } on Object catch (error) {
      if (!mounted || token.isCancelled) return;
      setState(() {
        _songsLoading = false;
        _songsError = error is OnlineMusicException
            ? error.safeMessage
            : '读取艺人单曲失败';
      });
    }
  }

  /// 艺人**专辑列表**（`artistAlbums`）：与热门歌曲**互不影响** ✓
  ///（热门歌曲失败不该把专辑区块也拖下水，反之亦然 ✓）。
  Future<void> _loadAlbums(OnlineMusicService service) async {
    if (!service.capabilities.openableArtistAlbumPlatforms.contains(
      widget.platform,
    )) {
      if (!mounted) return;
      setState(() {
        _albumsSupported = false;
        _albumsLoading = false;
        _albums = const [];
      });
      return;
    }
    _albumsToken?.cancel();
    final token = OnlineMusicCancelToken();
    _albumsToken = token;
    setState(() {
      _albumsSupported = true;
      _albumsLoading = true;
      _albumsError = null;
    });
    try {
      final albums = await service.fetchArtistAlbums(
        platform: widget.platform,
        artistId: widget.artistId,
        cancelToken: token,
      );
      if (!mounted || token.isCancelled) return;
      setState(() {
        _albums = albums;
        _albumsLoading = false;
      });
    } on Object catch (error) {
      if (!mounted || token.isCancelled) return;
      setState(() {
        _albumsLoading = false;
        _albumsError = error is OnlineMusicException
            ? error.safeMessage
            : '读取艺人专辑失败';
      });
    }
  }

  Future<void> _load() async {
    final service = context.read<OnlineMusicService?>();
    _token?.cancel();
    final token = OnlineMusicCancelToken();
    _token = token;
    if (service == null) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '在线音乐服务不可用：请先在设置里配置平台条目';
      });
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    // 专辑区块与热门歌曲**并行**加载 ✓（互不阻塞、互不牵连 ✓）。
    unawaited(_loadAlbums(service));
    unawaited(_loadSongs(service));
    try {
      final artist = await service.fetchArtist(
        platform: widget.platform,
        artistId: widget.artistId,
        cancelToken: token,
      );
      if (!mounted || token.isCancelled) return;
      setState(() {
        _artist = artist;
        _loading = false;
      });
    } on Object catch (error) {
      if (!mounted || token.isCancelled) return;
      setState(() {
        _loading = false;
        // 服务层给的是**可读且脱敏**的 `safeMessage`（与其它页面同一条纪律 ✓）。
        _error = error is OnlineMusicException
            ? error.safeMessage
            : '读取艺人详情失败';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final artist = _artist;
    final title = artist?.name ?? widget.initialName ?? '艺人';

    // ⚠️ 2026-10-17（F4）：这两个状态占的是**整页** ⇒ 用页面级组件
    //（[PageLoadingIndicator] / [QuietEmptyState]），不再用区块级的 `Inline*Hint`
    // 与默认尺寸的转圈 —— 该页**区块内**的三态（热门歌曲/单曲）仍用 `Inline*Hint` ✓。
    if (_error case final message?) {
      return PageScaffold(
        title: title,
        subtitle: '来源：${musicPlatformLabel(widget.platform)}',
        actions: [
          // 页头动作统一成 filledTonal（2026-10-17 / Q10）：与主页、探索页、榜单页一致；
          // 这里只有"刷新"一个动作，且没有禁用态 ⇒ 操作语义不变。
          IconButton.filledTonal(
            tooltip: '刷新',
            onPressed: _load,
            icon: const Icon(Symbols.refresh),
          ),
        ],
        body: QuietEmptyState(
          icon: Symbols.cloud_off,
          title: '艺人信息读取失败',
          message: message,
          action: FilledButton.tonalIcon(
            onPressed: _load,
            icon: const Icon(Symbols.refresh),
            label: const Text('重试'),
          ),
        ),
      );
    }
    if (_loading || artist == null) {
      return PageScaffold(
        title: title,
        subtitle: '来源：${musicPlatformLabel(widget.platform)}',
        actions: const [],
        body: const PageLoadingIndicator(),
      );
    }

    // **成功时页壳不画标题**（2026-10-12 用户要求 ✓）：名字就在 hero 里 ✓，
    // 页壳再写一遍就是"同一个名字出现两次" ✗ —— 参考页顶部也只有 hero ✓。
    return PageScaffold(
      title: null,
      actions: const [],
      body: ListView(
        padding: const EdgeInsets.only(bottom: Spacing.bottomNav),
        children: [
          _ArtistHero(
            artist: artist,
            onShuffle: () => _shuffleHotSongs(artist),
          ),
          const SizedBox(height: Spacing.lg),
          ContentSection(
            title: '热门歌曲',
            subtitle: '来自${musicPlatformLabel(artist.platform)}；点一行即从该艺人的热门歌曲开始播放',
            // 「**全部显示**」→ 子页面（参考页里热门歌曲下面正是它 ✓）。
            // 只在**确实超过预览条数**时给 ✓（不超过还给就是骗人 ✗）。
            actionLabel: artist.hotSongs.length > _hotSongsPreview
                ? '全部显示'
                : null,
            onAction: artist.hotSongs.length > _hotSongsPreview
                ? () => context.push(
                    app_paths.ARTIST_HOT_SONGS_PAGE,
                    extra: (artist: artist),
                  )
                : null,
            child: artist.hotSongs.isEmpty
                // **空是合法的**（艺人可能确实没有热门曲目）⇒ 中性提示、**不给重试** ✓。
                ? const InlineEmptyHint(
                    icon: Symbols.music_off,
                    message: '该艺人暂时没有热门曲目。',
                  )
                : Column(
                    children: [
                      // **一次只显示这么多**（参考页是 5 行 ✓），其余进子页面 ✓。
                      for (final track in artist.hotSongs.take(_hotSongsPreview))
                        _ArtistTrackRow(
                          track: track,
                          onTap: () => _play(artist, track),
                        ),
                    ],
                  ),
          ),
          // **专辑区块**（`artistAlbums`）：参考艺人页里「热门歌曲」之后正是「专辑」✓。
          // 平台不支持时**整块不显示** ✓ —— 摆一个空区块会让人以为"这艺人没有专辑"（那是谎 ✗）。
          if (_albumsSupported) ...[
            const SizedBox(height: Spacing.lg),
            ContentSection(
              title: '专辑',
              subtitle: '来自${musicPlatformLabel(artist.platform)}；点一张打开专辑页',
              // 2026-10-16：**复用探索页「新专辑」那个模块** ✓（用户指出这里也是自造格式 ✗）。
              // 宽度、元信息格式（「专辑 · 年份 · N 首」）、三态文案全部统一 ✓。
              child: AlbumShelf(
                albums: _albums,
                loading: _albumsLoading,
                errorMessage: _albumsError,
                onRetry: _retryAlbums,
                emptyMessage: '这位艺人暂时没有公开专辑。',
                onOpen: (album) => context.push(
                  app_paths.ONLINE_ALBUM_PAGE,
                  extra: (
                    platform: album.platform,
                    albumId: album.id,
                    name: album.name,
                  ),
                ),
              ),
            ),
          ],
          // **单曲和迷你专辑区块**（`artistSongs`）：参考艺人页里「专辑」之后就是它 ✓。
          if (_songsSupported) ...[
            const SizedBox(height: Spacing.lg),
            ContentSection(
              title: '单曲和迷你专辑',
              subtitle: '来自${musicPlatformLabel(artist.platform)}；点一张即从这些单曲开始播放',
              child: _songsBody(),
            ),
          ],
        ],
      ),
    );
  }

  /// 热门歌曲的**预览条数**：参考页正好显示 5 行，其余交给「全部显示」进子页 ✓。
  static const int _hotSongsPreview = 5;

  /// 「随机播放」：把这一批热门曲目**本地打乱**后从第一首开始播 ✓
  ///（我们没有任何"平台推荐顺序"可用 ⇒ 不假装有 ✓；打乱是**我们自己的**行为 ✓）。
  Future<void> _shuffleHotSongs(OnlineArtist artist) async {
    if (artist.hotSongs.isEmpty) return;
    final shuffled = [...artist.hotSongs]..shuffle();
    await playOnlineTrackSelection(
      context,
      OnlineTrackSelection.fromResultPage(
        tracks: shuffled,
        selectedRef: shuffled.first.ref,
      ),
    );
  }

  void _retryAlbums() {
    final service = context.read<OnlineMusicService?>();
    if (service == null) return;
    unawaited(_loadAlbums(service));
  }

  void _retrySongs() {
    final service = context.read<OnlineMusicService?>();
    if (service == null) return;
    unawaited(_loadSongs(service));
  }

  /// 单曲区块的三种状态（**空 ≠ 失败**：空给中性提示、失败才给重试 ✓）。
  Widget _songsBody() {
    if (_songsLoading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: Spacing.lg),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    final error = _songsError;
    if (error != null) {
      return InlineFailureHint(message: error, onRetry: _retrySongs);
    }
    if (_songs.isEmpty) {
      return const InlineEmptyHint(
        icon: Symbols.music_off,
        message: '这位艺人暂时没有单曲。',
      );
    }
    // 2026-10-16：**改成卡片** ✓（用户指出这里用了列表 ✗，而同一页的「专辑」是卡片 ✓
    // ⇒ 一页两套规则就是杂乱 ✓）。
    // 2026-10-17（F3/F5）：**抽成与 `AlbumShelf` 并列的 `TrackCardShelf`** ✓ ——
    // 这里原本在页面里**内联重算**宽度与高度 ✗，于是同一页两排卡片的几何各有一份实现
    //（正是 `AlbumShelf` 的注释里警告过的漂移起点 ✗）。现在宽/高统一走 `ShelfGeometry` ✓。
    // 用**卡片**货架而不是 `NewSongShelf`（多行分页）✓：两处职责不同，刻意不合并 ✓。
    return TrackCardShelf(
      tracks: _songs,
      onPlay: _playSongs,
      emptyMessage: '这位艺人暂时没有单曲。',
    );
  }

  Future<void> _playSongs(MusicTrack song) => playOnlineTrackSelection(
    context,
    OnlineTrackSelection.fromResultPage(tracks: _songs, selectedRef: song.ref),
  );

  Future<void> _play(OnlineArtist artist, MusicTrack track) =>
      playOnlineTrackSelection(
        context,
        OnlineTrackSelection.fromResultPage(
          tracks: artist.hotSongs,
          selectedRef: track.ref,
        ),
      );
}

/// **艺人名片（hero）**：按参考页做 —— 一张**通栏照片** ✓，底部压一层渐变保证白字可读 ✓，
/// 左下依次是**名字**（大 ✓）、**简介**（超出两行时给「展开」✓）、动作行 ✓。
///
/// 诚实说明：我们只有**方形头像**（`picUrl` ✓），没有宽幅横幅 ✗ ⇒ 这里用**同一张真图**
/// 放大裁切（`BoxFit.cover` ✓）——是**同一张艺人本人的图** ✓，不是编造素材 ✓。
/// 参考页上的「每月听众」「订阅 N」「合辑」我们**没有数据/能力** ⇒ **不显示** ✓。
class _ArtistHero extends StatelessWidget {
  const _ArtistHero({required this.artist, required this.onShuffle});

  final OnlineArtist artist;
  final VoidCallback onShuffle;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // **页面真正的底色** ✓（主题里 `scaffoldBackgroundColor = surfaceContainerLow` ✓）——
    // 渐变必须用它，否则与页面差一点、会显出边缘 ✗（用户指出的那个白边 ✓）。
    final pageBackground = Theme.of(context).scaffoldBackgroundColor;
    final description = artist.description?.trim();
    return ClipRRect(
      borderRadius: AppRadius.mdCircular,
      // **页面色兜底**（用户两次报"照片侧漏" ✓）：hero 内部任何没被画到的亚像素缝隙，
      // 露出来的都会是**页面色** ✓，而不是照片 ✓（照片只画在它自己那块 fill 上 ✓）。
      child: ColoredBox(
        color: pageBackground,
        child: LayoutBuilder(
          builder: (context, constraints) {
          // **至少** 16:7 的大图 ✓，但内容（名字 + 简介 + 动作）变高时 hero **跟着长** ✓ ——
          // 之前把高度写死成 `AspectRatio(16/7)` ✗ ⇒ 简介一「展开」就
          // `BOTTOM OVERFLOWED BY 164 PIXELS` ✗（用户截图为证 ✓）。
          final minHeight = constraints.maxWidth * 7 / 16;
          return ConstrainedBox(
            constraints: BoxConstraints(minHeight: minHeight),
            // 照片与渐变用 `Positioned.fill` **铺满最终高度** ✓；内容自己决定这个高度 ✓。
            // ⚠️ `alignment: bottomLeft` 是必须写的 ✓：内容作为**非定位子节点**时，
            // Stack 按**自己的** alignment 放它 ✗ —— 上一版漏了这句 ⇒ 文字跑到**顶部**、
            // 下面空出一大片（用户："好丑啊" ✓）✓。现在退回**左下角压在照片上** ✓（上一版的观感 ✓）。
            child: Stack(
              alignment: Alignment.bottomLeft,
              children: [
                Positioned.fill(
                  // ⚠️ 2026-10-16 改 ✓：平台**只给方形头像** ✗（`backgroundUrl` 这个本地服务
                  // 根本不返回 ✓，带凭据也不返回 ✗）⇒ 宽横幅里**必然留空** ✗。
                  // 以前用 `cover` 硬撑 ✗ ⇒ 主体被放大得发虚 ✓、还被裁掉一截 ✗（用户两次都指这个 ✓）。
                  // 现在：**模糊底补空** ✓ + **主体 `contain` 完整显示** ✓ ⇒ 不虚 ✓、不裁 ✓。
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      // ① 背景：同一张图的放大模糊版（只负责补空 ✓，不承担清晰度 ✓）。
                      ImageFiltered(
                        imageFilter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
                        child: RemoteMediaCover(
                          coverUri: hiResCoverUri(artist.avatarUri),
                          placeholder: ColoredBox(
                            color: scheme.surfaceContainerHighest,
                          ),
                          // 模糊底不需要细节 ⇒ 小图即可 ✓（省内存 ✓）。
                          cacheWidth: 640,
                          cacheHeight: 640,
                        ),
                      ),
                      // ② 主体：**完整、不裁、不拉伸** ✓。
                      RemoteMediaCover(
                        coverUri: hiResCoverUri(artist.avatarUri),
                        placeholder: const SizedBox.shrink(),
                        cacheWidth: 1920,
                        cacheHeight: 1920,
                        fit: BoxFit.contain,
                      ),
                    ],
                  ),
                ),
                // 渐变铺满整幅 ✓（hero 长高时它也跟着长 ✓），颜色 = 页面真正刷的那层色 ✓。
                Positioned.fill(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.bottomCenter,
                        end: Alignment.topCenter,
                        colors: [
                          pageBackground,
                          pageBackground,
                          pageBackground.withValues(alpha: 0.55),
                          pageBackground.withValues(alpha: 0.0),
                        ],
                        stops: const [0, 0.32, 0.66, 1],
                      ),
                    ),
                  ),
                ),
            Align(
              alignment: Alignment.bottomLeft,
              child: Padding(
                // ⚠️ 2026-10-16 修 ✓：**左右必须与页面正文对齐** ✗。
                // 正文由 `PageScaffold` 统一留 `horizontal: 16` ✓；这里原来用 `all: Spacing.xl`
                // ⇒ 文字比下面的「热门歌曲」**右移几像素** ✗（用户："还缩进来了一点" ✓）。
                padding: const EdgeInsets.fromLTRB(16, Spacing.xl, 16, Spacing.xl),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Semantics(
                      header: true,
                      child: Text(
                        artist.name,
                        // Key 只为测试用 ✓：断言"**页面级大标题只有这一个**"（防止再出现
                        // "顶栏一次 + hero 一次"那种重复 ✗）；表格"艺人"列里的同名文字是**数据** ✓。
                        key: const Key('artistHeroName'),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: AppType.display,
                          fontWeight: AppType.weightBold,
                          // 坐在"页面色"上 ⇒ 用主题文字色 ✓（白色在浅色主题看不见 ✗）。
                          color: scheme.onSurface,
                        ),
                      ),
                    ),
                    if (description != null && description.isNotEmpty) ...[
                      const SizedBox(height: Spacing.sm),
                      _ExpandableDescription(text: description, maxLines: 2),
                    ],
                    const SizedBox(height: Spacing.md),
                    Row(
                      children: [
                        FilledButton.icon(
                          onPressed: onShuffle,
                          icon: const Icon(Symbols.shuffle, size: 18),
                          label: const Text('随机播放'),
                        ),
                        const SizedBox(width: Spacing.md),
                        Text(
                          musicPlatformLabel(artist.platform),
                          style: TextStyle(
                            color: scheme.onSurfaceVariant,
                            fontSize: AppType.caption,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
                // **底部实心压条**（用户发现"底部一像素照片侧漏" ✓）：
                // 渐变的最后一段在**非整数高度**下会留下一行没被画到 ✗ ⇒ 照片从那条缝里露出来 ✓。
                // 这条 2px 的页面底色把缝隙**盖死** ✓（比调 stops 稳 ✓）。
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  // 加厚到 6px ✓（2px 时仍被报"还有缝" ✗）。
                  height: 6,
                  child: ColoredBox(color: pageBackground),
                ),
              ],
            ),
          );
        },
        ),
      ),
    );
  }
}

/// **可展开的简介**（2026-10-12 用户补充要求 ✓）：
/// 描述**超出指定行数**时才出现「**展开**」✓（不超出就不显示按钮 ✗ —— 那会骗人 ✓）；
/// 点它展开成全文 ✓，再点变「收起」✓。
class _ExpandableDescription extends StatefulWidget {
  const _ExpandableDescription({required this.text, this.maxLines = 2});

  final String text;
  final int maxLines;

  @override
  State<_ExpandableDescription> createState() => _ExpandableDescriptionState();
}

class _ExpandableDescriptionState extends State<_ExpandableDescription> {
  /// 展开后的**高度上限**（用户要求 ✓）：描述过长就**限高 + 出滚动条** ✓，
  /// 不让它把 hero 一直撑高 ✗（那会把整页顶得很难看 ✓）。
  static const double _expandedMaxHeight = 140;

  final ScrollController _scroll = ScrollController();
  bool _expanded = false;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // 文字坐在"页面色"上（渐变底部是主题页面色 ✓）⇒ 跟随主题 ✓，不再写死白色 ✗。
    final style = TextStyle(
      color: scheme.onSurfaceVariant,
      fontSize: AppType.body,
      height: 1.4,
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        // 先**量一遍**：只有真的超高才给「展开」✓（宽度未知时按"需要展开"处理 ✗ → 这里宽度已知 ✓）。
        final painter = TextPainter(
          text: TextSpan(text: widget.text, style: style),
          maxLines: widget.maxLines,
          textDirection: Directionality.of(context),
        )..layout(maxWidth: constraints.maxWidth);
        final overflows = painter.didExceedMaxLines;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!_expanded)
              Text(
                widget.text,
                style: style,
                maxLines: widget.maxLines,
                overflow: TextOverflow.ellipsis,
              )
            else
              // **展开态**：限高 + 可滚动 + 可见滚动条 ✓（内容再长也不会把 hero 撑爆 ✓）。
              ConstrainedBox(
                constraints: const BoxConstraints(
                  maxHeight: _expandedMaxHeight,
                ),
                child: Scrollbar(
                  controller: _scroll,
                  thumbVisibility: true,
                  child: SingleChildScrollView(
                    controller: _scroll,
                    child: Text(widget.text, style: style),
                  ),
                ),
              ),
            if (overflows)
              TextButton(
                onPressed: () => setState(() => _expanded = !_expanded),
                style: TextButton.styleFrom(
                  foregroundColor: scheme.onSurface,
                  padding: const EdgeInsets.symmetric(vertical: Spacing.xs),
                  minimumSize: const Size(0, 32),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: Text(_expanded ? '收起' : '展开'),
              ),
          ],
        );
      },
    );
  }
}

/// **热门歌曲的一行**（按参考页的表格排布 ✓）：封面 ｜ 曲名 ｜ 艺人 ｜ 专辑。
///
/// 参考页还有一列「播放次数 N 万」✗ —— 那是视频平台的观看数 ✓，我们**没有**这个数据 ✗
/// ⇒ **不显示该列** ✓（编一个数字就是伪造 ✓）；改用我们真有的「**专辑**」✓。
class _ArtistTrackRow extends StatelessWidget {
  const _ArtistTrackRow({required this.track, required this.onTap});

  final MusicTrack track;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final metaStyle = TextStyle(
      color: scheme.onSurfaceVariant,
      fontSize: AppType.caption,
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Material(
        type: MaterialType.transparency,
        borderRadius: AppRadius.smCircular,
        child: InkWell(
          borderRadius: AppRadius.smCircular,
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: Spacing.sm,
              vertical: 6,
            ),
            child: Row(
              children: [
                ClipRRect(
                  borderRadius: AppRadius.xsCircular,
                  child: SizedBox.square(
                    dimension: 40,
                    child: RemoteMediaCover(
                      coverUri: track.coverUri,
                      placeholder: ColoredBox(
                        color: scheme.surfaceContainerHighest,
                        child: Icon(
                          Symbols.music_note,
                          size: 18,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                      cacheWidth: 80,
                      cacheHeight: 80,
                    ),
                  ),
                ),
                const SizedBox(width: Spacing.md),
                Expanded(
                  flex: 4,
                  child: Text(
                    track.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: scheme.onSurface,
                      fontSize: AppType.body,
                      fontWeight: AppType.weightMedium,
                    ),
                  ),
                ),
                const SizedBox(width: Spacing.sm),
                Expanded(
                  flex: 3,
                  child: Text(
                    track.artistDisplay,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: metaStyle,
                  ),
                ),
                if (track.album.isNotEmpty) ...[
                  const SizedBox(width: Spacing.sm),
                  Expanded(
                    flex: 3,
                    // **专辑这一列可点**（用户要求：艺人 / 专辑入口要覆盖到 ✓）——
                    // 艺人列不点（我们**正在**这个艺人的页面上 ✓，再点自己是空动作 ✗）。
                    child: track.albumIds.isEmpty
                        ? Text(
                            track.album,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: metaStyle,
                          )
                        : Tooltip(
                            message: '查看专辑',
                            child: InkWell(
                              borderRadius: AppRadius.xsCircular,
                              onTap: () => context.push(
                                app_paths.ONLINE_ALBUM_PAGE,
                                extra: (
                                  platform: track.ref.platform,
                                  albumId: track.albumIds.first,
                                  name: track.album,
                                ),
                              ),
                              child: Text(
                                track.album,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: metaStyle,
                              ),
                            ),
                          ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// **向平台 CDN 要更大的同一张图**（2026-10-16 ✓）。
///
/// 网易云的图片地址支持 `?param=WxH` ✓：实测同一张艺人图**原始 236 KB**、
/// `?param=1920y1920` 下发 **498 KB** ✓ ⇒ 是**真的更清晰** ✓，不是把 ~500px 放大 ✗
///（用户报的"背景照片像素很低"就是放大造成的 ✓）。
///
/// 只对网易云自家 CDN 加这个参数 ✓：别的 CDN 不认它 ✗（加了可能反而出错 ✓），
/// 所以这里**有明确的域判断** ✓，不写"给所有 URL 都拼一个参数" ✗。
Uri? hiResCoverUri(Uri? uri) {
  if (uri == null) return null;
  final text = uri.toString();
  if (!text.contains('music.126.net')) return uri;
  return Uri.parse(
    text.contains('?') ? '$text&param=1920y1920' : '$text?param=1920y1920',
  );
}
