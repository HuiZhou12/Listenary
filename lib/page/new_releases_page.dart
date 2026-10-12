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

/// **新发行**页（2026-10-12 新增 ✓）。
///
/// 依据：参考 Explore 第一个区块「新专辑与单曲」的「**更多**」指向一个落地页 ✓，
/// 其 H1 是「**专辑和单曲**」✓（`09-new-releases-albums-full.txt:49` ✓），
/// 内容是一张**很长的混合列表**（约 350+ 项 ✓），每项用「**单曲 • / 专辑 • / 迷你专辑 •**」自报家门 ✓。
///
/// 我们的做法（**与参考同类** ✓）：按平台分组，标题下先「**专辑**」再「**单曲**」——
/// 参考那张表是按发布日期混排的 ✗，而**我们没有"单曲发布日期"这个字段** ✗ ⇒
/// **不假装**能按日期混排 ✓，改用**明确的分组标签** ✓（界面上一眼能看出这是我们的分组 ✓）。
///
/// 参考页里**没有**「加载更多」按钮 ✓（素材可证 ✓）⇒ 我们也不给"加载更多"，
/// 只拉一页并**如实说明**这是首批 ✓（不让人以为这就是全部 ✓）。
class NewReleasesPage extends StatefulWidget {
  const NewReleasesPage({
    super.key,
    this.platforms = const [],
    this.limit = 30,
  });

  /// 要展示的平台（由 Explore 传入 ✓；为空时自行按能力推导 ✓）。
  final List<MusicPlatform> platforms;
  final int limit;

  @override
  State<NewReleasesPage> createState() => _NewReleasesPageState();
}

class _NewReleasesPageState extends State<NewReleasesPage>
    // 取消令牌与"取一次并如实记录"都由这个既有 mixin 提供 ✓（页面销毁时统一取消 ✓）。
    with RemoteListLoading<NewReleasesPage> {
  List<MusicPlatform> _albumPlatforms = const [];
  List<MusicPlatform> _songPlatforms = const [];

  final RemoteLoadState<MusicPlatform, OnlineAlbumSummary> _albumState =
      RemoteLoadState<MusicPlatform, OnlineAlbumSummary>();
  final RemoteLoadState<MusicPlatform, MusicTrack> _songState =
      RemoteLoadState<MusicPlatform, MusicTrack>();

  bool _started = false;

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
    final albumPlatforms = service == null
        ? const <MusicPlatform>[]
        : [
            for (final platform in base)
              if (service.capabilities.openableNewAlbumPlatforms.contains(
                platform,
              ))
                platform,
          ];
    final songPlatforms = service == null
        ? const <MusicPlatform>[]
        : [
            for (final platform in base)
              if (service.capabilities.playableNewSongPlatforms.contains(
                platform,
              ))
                platform,
          ];
    if (!mounted) return;
    setState(() {
      _albumPlatforms = albumPlatforms;
      _songPlatforms = songPlatforms;
    });
    if (service == null) return;
    await Future.wait([
      for (final platform in albumPlatforms) _loadAlbums(service, platform),
      for (final platform in songPlatforms) _loadSongs(service, platform),
    ]);
  }

  Future<void> _loadAlbums(
    OnlineMusicService service,
    MusicPlatform platform,
  ) => loadRemoteList(
    _albumState,
    platform,
    () => service.fetchNewAlbums(
      platform: platform,
      limit: widget.limit,
      offset: 0,
      cancelToken: newCancelToken(),
    ),
    fallback: '读取该平台新专辑失败',
  );

  Future<void> _loadSongs(
    OnlineMusicService service,
    MusicPlatform platform,
  ) => loadRemoteList(
    _songState,
    platform,
    () => service.fetchNewSongs(
      platform: platform,
      limit: widget.limit,
      offset: 0,
      cancelToken: newCancelToken(),
    ),
    fallback: '读取该平台新歌失败',
  );

  @override
  Widget build(BuildContext context) {
    final platformName = _albumPlatforms.isEmpty
        ? '各平台'
        : _albumPlatforms.map(musicPlatformLabel).join(' / ');
    return PageScaffold(
      title: '专辑和单曲',
      subtitle: '新发行 · 来源：$platformName · 每个平台各自加载，首批各 ${widget.limit} 项',
      actions: [
        IconButton(
          tooltip: '刷新',
          onPressed: () => unawaited(_load()),
          icon: const Icon(Symbols.refresh),
        ),
      ],
      body: ListView(
        padding: const EdgeInsets.only(bottom: Spacing.bottomNav),
        children: [
          _buildAlbums(),
          _buildSongs(),
        ],
      ),
    );
  }

  Widget _buildAlbums() {
    if (_albumPlatforms.isEmpty) return const SizedBox.shrink();
    return ContentSection(
      title: '新专辑',
      subtitle: '各平台最近发布的专辑；点一张打开专辑页',
      child: Column(
        children: [
          for (final platform in _albumPlatforms) _buildAlbumGroup(platform),
        ],
      ),
    );
  }

  Widget _buildAlbumGroup(MusicPlatform platform) {
    final scheme = Theme.of(context).colorScheme;
    final albums = _albumState.items(platform);
    return _PlatformGroup(
      platform: platform,
      scheme: scheme,
      isLoading: _albumState.isLoading(platform),
      error: _albumState.error(platform),
      onRetry: () => unawaited(_reloadAlbums(platform)),
      emptyMessage: '该平台没有返回新专辑。',
      isEmpty: albums.isEmpty,
      children: [for (final album in albums) OnlineAlbumRow(album: album)],
    );
  }

  Widget _buildSongs() {
    if (_songPlatforms.isEmpty) return const SizedBox.shrink();
    return ContentSection(
      title: '新歌',
      subtitle: '各平台最近发布的曲目；点一行即从该平台新歌开始播放',
      child: Column(
        children: [
          for (final platform in _songPlatforms) _buildSongGroup(platform),
        ],
      ),
    );
  }

  Widget _buildSongGroup(MusicPlatform platform) {
    final scheme = Theme.of(context).colorScheme;
    final tracks = _songState.items(platform);
    return _PlatformGroup(
      platform: platform,
      scheme: scheme,
      isLoading: _songState.isLoading(platform),
      error: _songState.error(platform),
      onRetry: () => unawaited(_reloadSongs(platform)),
      emptyMessage: '该平台没有返回新歌。',
      isEmpty: tracks.isEmpty,
      children: [
        for (final track in tracks)
          OnlineTrackEntry(
            track: track,
            onTap: () => _play(tracks, track),
          ),
      ],
    );
  }

  Future<void> _reloadAlbums(MusicPlatform platform) async {
    final service = context.read<OnlineMusicService?>();
    if (service == null) return;
    await _loadAlbums(service, platform);
  }

  Future<void> _reloadSongs(MusicPlatform platform) async {
    final service = context.read<OnlineMusicService?>();
    if (service == null) return;
    await _loadSongs(service, platform);
  }

  Future<void> _play(Iterable<MusicTrack> tracks, MusicTrack track) =>
      playOnlineTrackSelection(
        context,
        OnlineTrackSelection.fromResultPage(
          tracks: tracks,
          selectedRef: track.ref,
        ),
      );
}

/// 单个平台的这一组（加载 / 失败+重试 / **空** ⇒ 中性提示 ✓ —— 空不是失败 ✓）。
class _PlatformGroup extends StatelessWidget {
  const _PlatformGroup({
    required this.platform,
    required this.scheme,
    required this.isLoading,
    required this.error,
    required this.onRetry,
    required this.emptyMessage,
    required this.isEmpty,
    required this.children,
  });

  final MusicPlatform platform;
  final ColorScheme scheme;
  final bool isLoading;
  final String? error;
  final VoidCallback onRetry;
  final String emptyMessage;
  final bool isEmpty;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
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
            InlineEmptyHint(icon: Symbols.album, message: emptyMessage)
          else
            ...children,
        ],
      ),
    );
  }
}
