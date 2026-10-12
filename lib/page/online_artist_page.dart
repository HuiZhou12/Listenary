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
    final subtitle = artist == null
        ? musicPlatformLabel(widget.platform)
        : '${musicPlatformLabel(widget.platform)} · ${artist.hotSongs.length} 首热门曲目';

    if (_error case final message?) {
      return PageScaffold(
        title: title,
        subtitle: '来源：${musicPlatformLabel(widget.platform)}',
        actions: [IconButton(tooltip: '刷新', onPressed: _load, icon: const Icon(Symbols.refresh))],
        body: InlineFailureHint(message: message, onRetry: _load),
      );
    }
    if (_loading || artist == null) {
      return PageScaffold(
        title: title,
        subtitle: '来源：${musicPlatformLabel(widget.platform)}',
        actions: const [],
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    return PageScaffold(
      title: title,
      subtitle: subtitle,
      actions: [
        IconButton(tooltip: '刷新', onPressed: _load, icon: const Icon(Symbols.refresh)),
      ],
      body: ListView(
        padding: const EdgeInsets.only(bottom: Spacing.bottomNav),
        children: [
          _ArtistHeader(artist: artist),
          const SizedBox(height: Spacing.lg),
          ContentSection(
            title: '热门歌曲',
            subtitle: '来自${musicPlatformLabel(artist.platform)}；点一行即从该艺人的热门歌曲开始播放',
            child: artist.hotSongs.isEmpty
                // **空是合法的**（艺人可能确实没有热门曲目）⇒ 中性提示、**不给重试** ✓。
                ? const InlineEmptyHint(
                    icon: Symbols.music_off,
                    message: '该艺人暂时没有热门曲目。',
                  )
                : Column(
                    children: [
                      for (final track in artist.hotSongs)
                        OnlineTrackEntry(
                          track: track,
                          onTap: () => _play(artist, track),
                        ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  Future<void> _play(OnlineArtist artist, MusicTrack track) =>
      playOnlineTrackSelection(
        context,
        OnlineTrackSelection.fromResultPage(
          tracks: artist.hotSongs,
          selectedRef: track.ref,
        ),
      );
}

/// 艺人头部：头像 + 名字 + 简介（简介为空时整块不占位 ✓）。
class _ArtistHeader extends StatelessWidget {
  const _ArtistHeader({required this.artist});

  final OnlineArtist artist;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final description = artist.description?.trim();
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: AppRadius.mdCircular,
          child: SizedBox.square(
            dimension: 96,
            child: RemoteMediaCover(
              coverUri: artist.avatarUri,
              placeholder: ColoredBox(
                color: scheme.surfaceContainerHighest,
                child: Icon(
                  Symbols.artist,
                  color: scheme.onSurfaceVariant,
                ),
              ),
              cacheWidth: 192,
              cacheHeight: 192,
            ),
          ),
        ),
        const SizedBox(width: Spacing.lg),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                artist.name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: AppType.hero,
                  fontWeight: AppType.weightSemibold,
                ),
              ),
              const SizedBox(height: Spacing.xs),
              Text(
                musicPlatformLabel(artist.platform),
                style: TextStyle(
                  color: scheme.onSurfaceVariant,
                  fontSize: AppType.caption,
                ),
              ),
              if (description != null && description.isNotEmpty) ...[
                const SizedBox(height: Spacing.sm),
                Text(
                  description,
                  maxLines: 6,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: scheme.onSurfaceVariant,
                    fontSize: AppType.body,
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}
