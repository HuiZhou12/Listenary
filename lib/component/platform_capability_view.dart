import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:pure_music/core/design_tokens.dart';
import 'package:pure_music/services/music_platform/index.dart';

/// 平台状态里展示的能力清单。
///
/// 刻意**不引用配置层的能力枚举符号**（连注释里都不写出它的名字：依赖边界测试
/// 是纯文本扫描，见 `online_music_dependency_boundary_test`）。应用层不得依赖 Provider 层，
/// 而这里只需要"展示名 + 可用性判定"这两件事。
typedef CapabilityProbe =
    bool Function(OnlineMusicCapabilities capabilities, MusicPlatform platform);

/// 平台能力清单的**行**：展示名 + 可用性判定。
///
/// ⚠️ 顺序与能力枚举一致（搜索 / 歌单详情 / 歌单列表 / 歌单分类 / 榜单 / 新歌 / 歌词 / 播放解析），
/// 且**必须覆盖全部能力** —— P-45：这里曾长期是**手写的 5 行**，漏掉
/// 「歌单分类 / 榜单 / 新歌」，于是这三项在诊断视图里**根本看不到**（不是"未来风险"，
/// 而是当时的现状）。`test/component/platform_capability_view_test.dart` 里有一条
/// **跨层覆盖守卫**：行标签必须逐个等于能力枚举的标签，漏一项即变红。
const platformCapabilityRows =
    <({String label, CapabilityProbe available})>[
      (label: '搜索', available: _searchable),
      (label: '歌单详情', available: _playlistDetail),
      (label: '歌单列表', available: _playlistCollection),
      (label: '歌单分类', available: _playlistCategories),
      (label: '榜单', available: _chartList),
      (label: '新歌', available: _newSongs),
      (label: '艺人详情', available: _artist),
      (label: '专辑详情', available: _album),
      (label: '艺人专辑列表', available: _artistAlbums),
      (label: '艺人单曲列表', available: _artistSongs),
      (label: '新专辑', available: _newAlbums),
      (label: '歌词', available: _lyrics),
      (label: '播放解析', available: _resolvable),
    ];

bool _searchable(OnlineMusicCapabilities c, MusicPlatform p) =>
    c.searchablePlatforms.contains(p);

bool _playlistDetail(OnlineMusicCapabilities c, MusicPlatform p) =>
    c.playlistPlatforms.contains(p);

bool _playlistCollection(OnlineMusicCapabilities c, MusicPlatform p) =>
    c.playlistCollectionPlatforms.contains(p);

bool _playlistCategories(OnlineMusicCapabilities c, MusicPlatform p) =>
    c.playlistCategoryPlatforms.contains(p);

/// 艺人详情：能取"艺人 + 热门曲目"的平台（热门曲目要点得响 ⇒ 见 [OnlineMusicCapabilities]）。
bool _artist(OnlineMusicCapabilities c, MusicPlatform p) =>
    c.playableArtistPlatforms.contains(p);

/// 专辑详情：能取"专辑 + 曲目"的平台（同上，曲目也要点得响 ✓）。
bool _album(OnlineMusicCapabilities c, MusicPlatform p) =>
    c.playableAlbumPlatforms.contains(p);

/// 艺人专辑列表：**既列得出、又打得开专辑详情**的平台 ✓
///（列出来却打不开，比不显示更糟 ✗ —— 与榜单「能列 vs 能开」同一条判据 ✓）。
bool _artistAlbums(OnlineMusicCapabilities c, MusicPlatform p) =>
    c.openableArtistAlbumPlatforms.contains(p);

/// 艺人单曲列表：与「新歌」同一条判据 —— 曲目**点得响**才显示 ✓
///（列出一堆点不动的歌，比不显示更糟 ✗）。
bool _artistSongs(OnlineMusicCapabilities c, MusicPlatform p) =>
    c.playableArtistSongPlatforms.contains(p);

/// 新专辑：**既列得出、又打得开专辑详情**的平台 ✓（列出来打不开更糟 ✗）。
bool _newAlbums(OnlineMusicCapabilities c, MusicPlatform p) =>
    c.openableNewAlbumPlatforms.contains(p);

bool _chartList(OnlineMusicCapabilities c, MusicPlatform p) =>
    c.chartPlatforms.contains(p);

bool _newSongs(OnlineMusicCapabilities c, MusicPlatform p) =>
    c.newSongPlatforms.contains(p);

bool _lyrics(OnlineMusicCapabilities c, MusicPlatform p) =>
    c.lyricPlatforms.contains(p);

bool _resolvable(OnlineMusicCapabilities c, MusicPlatform p) =>
    c.resolvablePlatforms.contains(p);

/// **平台能力视图**：每个平台能做什么、不能做什么、为什么。
///
/// 它是**诊断信息**，不是内容 —— 因此默认**收起**，并且不应该占据页面首屏。
/// 主页与探索页都用它，所以它必须是公共组件而不是某一页的私有件。
class PlatformCapabilityView extends StatelessWidget {
  const PlatformCapabilityView({
    super.key,
    required this.capabilities,
    required this.onConfigure,
    this.initiallyExpanded = false,
  });

  final OnlineMusicCapabilities? capabilities;

  /// 点击"去配置"时的跳转（设置页）。
  final VoidCallback onConfigure;

  final bool initiallyExpanded;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      elevation: 0,
      color: scheme.surfaceContainerHighest.withValues(alpha: 0.35),
      shape: RoundedRectangleBorder(borderRadius: AppRadius.smCircular),
      child: Theme(
        // ExpansionTile 的默认分隔线会在卡内画出多余的横线。
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          initiallyExpanded: initiallyExpanded,
          shape: const Border(),
          collapsedShape: const Border(),
          tilePadding: const EdgeInsets.symmetric(horizontal: Spacing.md),
          childrenPadding: const EdgeInsets.fromLTRB(
            Spacing.md,
            0,
            Spacing.md,
            Spacing.md,
          ),
          leading: Icon(Symbols.tune, color: scheme.onSurfaceVariant),
          title: const Text('平台能力'),
          subtitle: Text(
            '每个平台能做什么；未配置的能力不会假装可用',
            style: TextStyle(
              color: scheme.onSurfaceVariant,
              fontSize: AppType.caption,
            ),
          ),
          children: [
            for (final platform in builtinMusicPlatforms)
              Padding(
                padding: const EdgeInsets.only(bottom: Spacing.sm),
                child: PlatformCapabilityTile(
                  platform: platform,
                  capabilities: capabilities,
                  onTap: onConfigure,
                ),
              ),
            if (capabilities == null)
              Row(
                children: [
                  Icon(
                    Symbols.info,
                    size: 16,
                    color: scheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: Spacing.sm),
                  Expanded(
                    child: Text(
                      '在线音乐服务尚未就绪，平台能力暂时不可用。',
                      style: TextStyle(color: scheme.onSurfaceVariant),
                    ),
                  ),
                ],
              ),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: onConfigure,
                child: const Text('去配置'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 单个平台的能力行：平台名 + 五项能力 chip +（若有）不可用原因。
class PlatformCapabilityTile extends StatelessWidget {
  const PlatformCapabilityTile({
    super.key,
    required this.platform,
    required this.capabilities,
    required this.onTap,
  });

  final MusicPlatform platform;
  final OnlineMusicCapabilities? capabilities;
  final VoidCallback onTap;

  bool _has(({String label, CapabilityProbe available}) row) {
    final value = capabilities;
    if (value == null) return false;
    return row.available(value, platform);
  }

  bool get _anyAvailable =>
      platformCapabilityRows.any(_has) ||
      (capabilities?.unavailableSearchReasonFor(platform) != null);

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final reason = capabilities?.unavailableSearchReasonFor(platform);
    return Material(
      type: MaterialType.transparency,
      borderRadius: AppRadius.smCircular,
      child: InkWell(
        borderRadius: AppRadius.smCircular,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: Spacing.sm,
            vertical: Spacing.sm,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text(
                    musicPlatformLabel(platform),
                    style: TextStyle(
                      fontWeight: AppType.weightMedium,
                      color: scheme.onSurface,
                    ),
                  ),
                  const SizedBox(width: Spacing.sm),
                  if (!_anyAvailable)
                    Text(
                      '未配置',
                      style: TextStyle(
                        color: scheme.onSurfaceVariant,
                        fontSize: AppType.caption,
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final row in platformCapabilityRows)
                    _CapabilityChip(label: row.label, available: _has(row)),
                ],
              ),
              if (reason != null) ...[
                const SizedBox(height: 6),
                Text(
                  reason,
                  style: TextStyle(
                    color: scheme.onSurfaceVariant,
                    fontSize: AppType.caption,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _CapabilityChip extends StatelessWidget {
  const _CapabilityChip({required this.label, required this.available});

  final String label;
  final bool available;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: Spacing.sm, vertical: 2),
      decoration: BoxDecoration(
        color: available
            ? scheme.primaryContainer.withValues(alpha: 0.7)
            : scheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: AppRadius.xsCircular,
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: AppType.caption,
          color: available
              ? scheme.onPrimaryContainer
              : scheme.onSurfaceVariant.withValues(alpha: 0.7),
        ),
      ),
    );
  }
}
