/// **「新专辑」与「新歌」两个落地页**（2026-10-17 从单页拆开 ✓）。
///
/// 为什么拆：此前它们合在一个「**专辑和单曲**」页里，页标题之下又各有一个区块标题
/// （「新专辑」「新歌」）⇒ **同一个层级出现两次标题** ✓，看起来就像两页被硬塞进一页；
/// 更关键的是探索页那两个「查看全部」**都落到同一页** ✗ —— 用户点「新歌 → 查看全部」
/// 却看到「新专辑」排在最前面 ✓。
///
/// 现在：**一个入口一页** ✓，每页只有**页标题 + 平台分组**两层，没有区块标题 ✓。
///
/// 两页共用同一个平台分组渲染（[NewReleasePlatformGroup]）✓ —— 加载 / 失败可重试 /
/// **空 ⇒ 中性提示**三态一致 ✓。
///
/// 参考页里**没有**「加载更多」按钮 ✓（素材可证 ✓）⇒ 我们也不给"加载更多"，
/// 只拉一页并**如实说明**这是首批 ✓（不让人以为这就是全部 ✓）。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';
import 'package:pure_music/component/content_section.dart';
import 'package:pure_music/component/online_album_row.dart';
import 'package:pure_music/component/online_search_launcher.dart';
import 'package:pure_music/component/online_track_entry.dart';
import 'package:pure_music/component/remote_load_state.dart';
import 'package:pure_music/core/design_tokens.dart';
import 'package:pure_music/page/page_scaffold.dart';
import 'package:pure_music/services/music_platform/index.dart';

/// 新专辑列表页。
class NewAlbumsPage extends StatefulWidget {
  const NewAlbumsPage({super.key, this.platforms = const [], this.limit = 30});

  /// 要展示的平台（由 Explore 传入 ✓；为空时自行按能力推导 ✓）。
  final List<MusicPlatform> platforms;
  final int limit;

  @override
  State<NewAlbumsPage> createState() => _NewAlbumsPageState();
}

class _NewAlbumsPageState extends State<NewAlbumsPage>
    with RemoteListLoading<NewAlbumsPage> {
  List<MusicPlatform> _platforms = const [];
  final RemoteLoadState<MusicPlatform, OnlineAlbumSummary> _state =
      RemoteLoadState<MusicPlatform, OnlineAlbumSummary>();
  bool _started = false;

  /// 首帧还没拿到平台清单 ⇒ 不能先渲染「没有平台」（那是误报，一闪而过也会被当成结论）。
  bool _loading = true;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    unawaited(_load());
  }

  Future<void> _load() async {
    final service = context.read<OnlineMusicService?>();
    final base = widget.platforms.isEmpty
        ? builtinMusicPlatforms
        : widget.platforms;
    final platforms = service == null
        ? const <MusicPlatform>[]
        : [
            for (final platform in base)
              if (service.capabilities.openableNewAlbumPlatforms.contains(
                platform,
              ))
                platform,
          ];
    if (!mounted) return;
    // 拿到平台清单就把加载态关掉 ⇒ 之后 `_platforms.isEmpty` 才是**真的**没有平台 ✓。
    setState(() {
      _platforms = platforms;
      _loading = false;
    });
    if (service == null) return;
    await Future.wait([
      for (final platform in platforms) _loadFor(service, platform),
    ]);
  }

  Future<void> _loadFor(
    OnlineMusicService service,
    MusicPlatform platform,
  ) => loadRemoteList(
    _state,
    platform,
    () => service.fetchNewAlbums(
      platform: platform,
      limit: widget.limit,
      offset: 0,
      cancelToken: newCancelToken(),
    ),
    fallback: '读取该平台新专辑失败',
  );

  Future<void> _retry(MusicPlatform platform) async {
    final service = context.read<OnlineMusicService?>();
    if (service == null) return;
    await _loadFor(service, platform);
  }

  @override
  Widget build(BuildContext context) {
    return PageScaffold(
      title: '新专辑',
      subtitle:
          '${_sourceLabel(_platforms)}· 每个平台分开显示，各 ${widget.limit} 项；点一张打开专辑页',
      actions: [
        IconButton.filledTonal(
          tooltip: '刷新',
          onPressed: () => unawaited(_load()),
          icon: const Icon(Symbols.refresh),
        ),
      ],
      body: _loading
          // 还在拿平台清单 ⇒ 先给加载态，**不要**先渲染"没有平台"（那是误报）。
          ? const PageLoadingIndicator()
          : _platforms.isEmpty
          ? const InlineEmptyHint(
              icon: Symbols.album,
              message: '当前没有能提供新专辑的平台：到「设置 → 在线音乐」里启用该能力后再来。',
            )
          : ListView(
              padding: const EdgeInsets.only(bottom: Spacing.bottomNav),
              children: [
                for (final platform in _platforms)
                  NewReleasePlatformGroup(
                    platform: platform,
                    isLoading: _state.isLoading(platform),
                    error: _state.error(platform),
                    onRetry: () => unawaited(_retry(platform)),
                    emptyMessage: '该平台今天没有新专辑',
                    emptyIcon: Symbols.album,
                    isEmpty: _state.items(platform).isEmpty,
                    children: [
                      for (final album in _state.items(platform))
                        OnlineAlbumRow(album: album),
                    ],
                  ),
              ],
            ),
    );
  }
}

/// 新歌列表页。
class NewSongsPage extends StatefulWidget {
  const NewSongsPage({super.key, this.platforms = const [], this.limit = 30});

  final List<MusicPlatform> platforms;
  final int limit;

  @override
  State<NewSongsPage> createState() => _NewSongsPageState();
}

class _NewSongsPageState extends State<NewSongsPage>
    with RemoteListLoading<NewSongsPage> {
  List<MusicPlatform> _platforms = const [];
  final RemoteLoadState<MusicPlatform, MusicTrack> _state =
      RemoteLoadState<MusicPlatform, MusicTrack>();
  bool _started = false;

  /// 首帧还没拿到平台清单 ⇒ 不能先渲染「没有平台」（那是误报，一闪而过也会被当成结论）。
  bool _loading = true;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    unawaited(_load());
  }

  Future<void> _load() async {
    final service = context.read<OnlineMusicService?>();
    final base = widget.platforms.isEmpty
        ? builtinMusicPlatforms
        : widget.platforms;
    final platforms = service == null
        ? const <MusicPlatform>[]
        : [
            for (final platform in base)
              if (service.capabilities.playableNewSongPlatforms.contains(
                platform,
              ))
                platform,
          ];
    if (!mounted) return;
    // 拿到平台清单就把加载态关掉 ⇒ 之后 `_platforms.isEmpty` 才是**真的**没有平台 ✓。
    setState(() {
      _platforms = platforms;
      _loading = false;
    });
    if (service == null) return;
    await Future.wait([
      for (final platform in platforms) _loadFor(service, platform),
    ]);
  }

  Future<void> _loadFor(
    OnlineMusicService service,
    MusicPlatform platform,
  ) => loadRemoteList(
    _state,
    platform,
    () => service.fetchNewSongs(
      platform: platform,
      limit: widget.limit,
      offset: 0,
      cancelToken: newCancelToken(),
    ),
    fallback: '读取该平台新歌失败',
  );

  Future<void> _retry(MusicPlatform platform) async {
    final service = context.read<OnlineMusicService?>();
    if (service == null) return;
    await _loadFor(service, platform);
  }

  Future<void> _play(Iterable<MusicTrack> tracks, MusicTrack track) =>
      playOnlineTrackSelection(
        context,
        OnlineTrackSelection.fromResultPage(
          tracks: tracks,
          selectedRef: track.ref,
        ),
      );

  @override
  Widget build(BuildContext context) {
    return PageScaffold(
      title: '新歌',
      subtitle:
          '${_sourceLabel(_platforms)}· 每个平台分开显示，各 ${widget.limit} 项；点一行即从该平台新歌开始播放',
      actions: [
        IconButton.filledTonal(
          tooltip: '刷新',
          onPressed: () => unawaited(_load()),
          icon: const Icon(Symbols.refresh),
        ),
      ],
      body: _loading
          // 还在拿平台清单 ⇒ 先给加载态，**不要**先渲染"没有平台"（那是误报）。
          ? const PageLoadingIndicator()
          : _platforms.isEmpty
          ? const InlineEmptyHint(
              icon: Symbols.music_note,
              message: '当前没有能播放新歌的平台：到「设置 → 在线音乐」里启用该能力后再来。',
            )
          : ListView(
              padding: const EdgeInsets.only(bottom: Spacing.bottomNav),
              children: [
                for (final platform in _platforms)
                  NewReleasePlatformGroup(
                    platform: platform,
                    isLoading: _state.isLoading(platform),
                    error: _state.error(platform),
                    onRetry: () => unawaited(_retry(platform)),
                    emptyMessage: '该平台今天没有新歌',
                    emptyIcon: Symbols.new_releases,
                    isEmpty: _state.items(platform).isEmpty,
                    children: [
                      for (final track in _state.items(platform))
                        OnlineTrackEntry(
                          track: track,
                          onTap: () => _play(_state.items(platform), track),
                        ),
                    ],
                  ),
              ],
            ),
    );
  }
}

/// 副标题的"来源"段：多平台列出来；一个都没有时写「各平台」。
String _sourceLabel(List<MusicPlatform> platforms) => platforms.isEmpty
    ? '来源：各平台'
    : '来源：${platforms.map(musicPlatformLabel).join(' / ')}';

/// 单个平台的这一组（加载 / 失败+重试 / **空** ⇒ 中性提示 ✓ —— 空不是失败 ✓）。
///
/// 两个落地页共用这一份 ✓（它们的三态必须一致，不然又会走偏）。
class NewReleasePlatformGroup extends StatelessWidget {
  const NewReleasePlatformGroup({
    super.key,
    required this.platform,
    required this.isLoading,
    required this.error,
    required this.onRetry,
    required this.emptyMessage,
    required this.emptyIcon,
    required this.isEmpty,
    required this.children,
  });

  final MusicPlatform platform;
  final bool isLoading;
  final String? error;
  final VoidCallback onRetry;
  final String emptyMessage;
  final IconData emptyIcon;
  final bool isEmpty;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
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
          if (isLoading)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: Spacing.lg),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (error case final message?)
            InlineFailureHint(message: message, onRetry: onRetry)
          else if (isEmpty)
            InlineEmptyHint(icon: emptyIcon, message: emptyMessage)
          else
            ...children,
        ],
      ),
    );
  }
}
