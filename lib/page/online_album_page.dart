import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';
import 'package:pure_music/component/content_section.dart';
import 'package:pure_music/component/online_search_launcher.dart';
import 'package:pure_music/component/online_track_entry.dart';
import 'package:pure_music/component/remote_media_cover.dart';
import 'package:pure_music/core/design_tokens.dart';
import 'package:pure_music/page/page_scaffold.dart';
import 'package:pure_music/services/music_platform/index.dart';

/// **在线专辑页**（`album` 能力，2026-10-12 新增）。
///
/// 与参考产品的专辑页对齐的一点：专辑曲目是**有顺序**的 ⇒ **列出序号** ✓
/// （行组件的 `leadingIndex` 正是为此准备的；普通歌单/收藏列表则**不给**序号 ✓）。
///
/// 三态如实区分（与 Home/Explore/艺人页同一条纪律）：
/// - **失败** ⇒ 可读错误 + 重试；
/// - **空**（这张专辑确实没有曲目）⇒ 中性提示、**不给重试**；
/// - 加载中先用调用方给的专辑名占位（不白屏 ✓）。
///
/// **两个"曲目数"不混为一谈** ✓：平台在响应里标注的 `size` 与**实际取到的曲目条数**可能不同；
/// 界面默认显示**实际条数**（我们真的拿到的 ✓），只有两者**不一致**时才把平台标注也说出来 ✓。
class OnlineAlbumPage extends StatefulWidget {
  const OnlineAlbumPage({
    super.key,
    required this.platform,
    required this.albumId,
    this.initialName,
  });

  final MusicPlatform platform;

  /// 平台自己的专辑 id（**来自请求输入** ✓）。
  final String albumId;

  /// 从曲目行跳进来时已知的专辑名：先渲染它，避免加载期间白屏 ✓。
  final String? initialName;

  @override
  State<OnlineAlbumPage> createState() => _OnlineAlbumPageState();
}

class _OnlineAlbumPageState extends State<OnlineAlbumPage> {
  OnlineAlbum? _album;
  String? _error;
  bool _loading = true;
  bool _started = false;
  OnlineMusicCancelToken? _token;

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
    super.dispose();
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
    try {
      final album = await service.fetchAlbum(
        platform: widget.platform,
        albumId: widget.albumId,
        cancelToken: token,
      );
      if (!mounted || token.isCancelled) return;
      setState(() {
        _album = album;
        _loading = false;
      });
    } on Object catch (error) {
      if (!mounted || token.isCancelled) return;
      setState(() {
        _loading = false;
        _error = error is OnlineMusicException
            ? error.safeMessage
            : '读取专辑详情失败';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final album = _album;
    final title = album?.name ?? widget.initialName ?? '专辑';
    final platformName = musicPlatformLabel(widget.platform);
    final source = '来源：$platformName';

    if (_error case final message?) {
      return PageScaffold(
        title: title,
        subtitle: source,
        actions: [
          IconButton(
            tooltip: '刷新',
            onPressed: _load,
            icon: const Icon(Symbols.refresh),
          ),
        ],
        body: InlineFailureHint(message: message, onRetry: _load),
      );
    }
    if (_loading || album == null) {
      return PageScaffold(
        title: title,
        subtitle: source,
        actions: const [],
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    // 平台标注的曲目数只在**与实际条数不一致**时说，避免把两个数混成一个 ✓。
    final declared = album.trackCount;
    final actual = album.tracks.length;
    final mismatch = declared != null && declared != actual;

    return PageScaffold(
      title: title,
      subtitle: '$source · $actual 首曲目',
      actions: [
        IconButton(
          tooltip: '刷新',
          onPressed: _load,
          icon: const Icon(Symbols.refresh),
        ),
      ],
      body: ListView(
        padding: const EdgeInsets.only(bottom: Spacing.bottomNav),
        children: [
          _AlbumHeader(album: album, platformName: platformName),
          if (mismatch) ...[
            const SizedBox(height: Spacing.sm),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  Symbols.info,
                  size: 18,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: Spacing.sm),
                Expanded(
                  child: Text(
                    '平台标注这张专辑有 $declared 首，本次实际取到 $actual 首'
                    '（以实际取到的为准 ✓）。',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                      fontSize: AppType.body,
                    ),
                  ),
                ),
              ],
            ),
          ],
          const SizedBox(height: Spacing.lg),
          ContentSection(
            title: '曲目',
            subtitle: '专辑曲目**有顺序** ⇒ 行首给序号；点一行即从这张专辑开始播放',
            child: album.tracks.isEmpty
                // **空是合法的**（专辑可能确实没有曲目）⇒ 中性提示、**不给重试** ✓。
                ? const InlineEmptyHint(
                    icon: Symbols.music_off,
                    message: '这张专辑暂时没有曲目。',
                  )
                : Column(
                    children: [
                      for (var i = 0; i < album.tracks.length; i++)
                        OnlineTrackEntry(
                          track: album.tracks[i],
                          // 专辑曲目是**有序集合** ⇒ 给出序号 ✓（与参考产品一致）。
                          leadingIndex: i + 1,
                          onTap: () => _play(album, album.tracks[i]),
                        ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  Future<void> _play(OnlineAlbum album, MusicTrack track) =>
      playOnlineTrackSelection(
        context,
        OnlineTrackSelection.fromResultPage(
          tracks: album.tracks,
          selectedRef: track.ref,
        ),
      );
}

/// 专辑头部：封面 + 名字 + 专辑艺人（缺一不可地"有什么说什么" ✓）。
class _AlbumHeader extends StatelessWidget {
  const _AlbumHeader({required this.album, required this.platformName});

  final OnlineAlbum album;
  final String platformName;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final artist = album.artist?.trim();
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: AppRadius.mdCircular,
          child: SizedBox.square(
            dimension: 128,
            child: RemoteMediaCover(
              coverUri: album.coverUri,
              placeholder: ColoredBox(
                color: scheme.surfaceContainerHighest,
                child: Icon(
                  Symbols.album,
                  color: scheme.onSurfaceVariant,
                ),
              ),
              cacheWidth: 256,
              cacheHeight: 256,
            ),
          ),
        ),
        const SizedBox(width: Spacing.lg),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                album.name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: AppType.hero,
                  fontWeight: AppType.weightSemibold,
                ),
              ),
              if (artist != null && artist.isNotEmpty) ...[
                const SizedBox(height: Spacing.xs),
                Text(
                  artist,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: scheme.onSurface,
                    fontSize: AppType.subtitle,
                  ),
                ),
              ],
              const SizedBox(height: Spacing.xs),
              Text(
                platformName,
                style: TextStyle(
                  color: scheme.onSurfaceVariant,
                  fontSize: AppType.caption,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
