// ignore_for_file: camel_case_types

import 'dart:ui';
import 'dart:math' as math;

import 'package:pure_music/core/design_tokens.dart';
import 'package:pure_music/core/preference.dart';
import 'package:pure_music/component/motion.dart';
import 'package:pure_music/component/responsive_builder.dart';
import 'package:pure_music/core/paths.dart' as app_paths;
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:material_symbols_icons/symbols.dart';

class DestinationDesc {
  final IconData icon;
  final String label;
  final String desPath;
  final int? startPageIndex;

  const DestinationDesc(
    this.icon,
    this.label,
    this.desPath, {
    this.startPageIndex,
  });
}

const destinations = <DestinationDesc>[
  DestinationDesc(Symbols.cloud, '在线音乐', app_paths.ONLINE_MUSIC_PAGE),
  DestinationDesc(
    Symbols.library_music,
    '音乐',
    app_paths.AUDIOS_PAGE,
    startPageIndex: 0,
  ),
  DestinationDesc(
    Symbols.artist,
    '艺术家',
    app_paths.ARTISTS_PAGE,
    startPageIndex: 1,
  ),
  DestinationDesc(
    Symbols.album,
    '专辑',
    app_paths.ALBUMS_PAGE,
    startPageIndex: 2,
  ),
  DestinationDesc(
    Symbols.folder,
    '文件夹',
    app_paths.FOLDERS_PAGE,
    startPageIndex: 3,
  ),
  DestinationDesc(
    Symbols.list,
    '歌单',
    app_paths.PLAYLISTS_PAGE,
    startPageIndex: 4,
  ),
  DestinationDesc(Symbols.bar_chart, '统计', app_paths.STATS_PAGE),
  DestinationDesc(Symbols.settings, '设置', app_paths.SETTINGS_PAGE),
];

class DestinationGroupDesc {
  final String label;
  final List<int> destinationIndices;

  const DestinationGroupDesc(this.label, this.destinationIndices);
}

const destinationGroups = <DestinationGroupDesc>[
  DestinationGroupDesc('在线音乐', [0]),
  DestinationGroupDesc('本地曲库', [1, 2, 3, 4]),
  DestinationGroupDesc('收藏与回顾', [5, 6]),
  DestinationGroupDesc('系统', [7]),
];

const double sideNavItemHeight = 54.0;
const double sideNavGroupHeaderHeight = Spacing.xl + Spacing.xs;

double sideNavGroupHeaderExtent(double expandedT) {
  return sideNavGroupHeaderHeight * expandedT.clamp(0.0, 1.0).toDouble();
}

int sideNavGroupCountBeforeDestination(int destinationIndex) {
  return destinationGroups
      .where((group) => group.destinationIndices.first <= destinationIndex)
      .length;
}

double sideNavDestinationTop(
  int destinationIndex, {
  required double expandedT,
}) {
  return destinationIndex * sideNavItemHeight +
      sideNavGroupCountBeforeDestination(destinationIndex) *
          sideNavGroupHeaderExtent(expandedT);
}

double sideNavDestinationOffset(
  double destinationIndex, {
  required double expandedT,
}) {
  final lowerIndex = destinationIndex
      .floor()
      .clamp(0, destinations.length - 1)
      .toInt();
  final upperIndex = destinationIndex
      .ceil()
      .clamp(0, destinations.length - 1)
      .toInt();
  final fraction = destinationIndex - lowerIndex;
  return lerpDouble(
        sideNavDestinationTop(lowerIndex, expandedT: expandedT),
        sideNavDestinationTop(upperIndex, expandedT: expandedT),
        fraction,
      ) ??
      0.0;
}

double sideNavContentHeight({required double expandedT}) {
  return destinations.length * sideNavItemHeight +
      destinationGroups.length * sideNavGroupHeaderExtent(expandedT);
}

class SideNav extends StatefulWidget {
  const SideNav({super.key, this.navigationShell, this.onExpandedChanged});

  final StatefulNavigationShell? navigationShell;
  final ValueChanged<bool>? onExpandedChanged;
  static const double collapsedWidth = 80.0;
  static const double expandedWidth = 240.0;

  @override
  State<SideNav> createState() => _SideNavState();
}

class _SideNavState extends State<SideNav> {
  final sidebarExpanded = ValueNotifier(AppPreference.instance.sidebarExpanded);
  static const double _collapsedWidth = SideNav.collapsedWidth;
  static const double _expandedWidth = SideNav.expandedWidth;
  static const double _itemHeight = sideNavItemHeight;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final navShell = widget.navigationShell;
    final selectedIndex =
        navShell?.currentIndex ??
        destinations.indexWhere(
          (d) => GoRouterState.of(context).uri.toString().startsWith(d.desPath),
        );

    void onDestinationSelected(int value) {
      final currentIndex = navShell?.currentIndex;
      if (currentIndex == value) return;

      final startPageIndex = destinations[value].startPageIndex;
      if (startPageIndex != null &&
          AppPreference.instance.startPage != startPageIndex) {
        AppPreference.instance.startPage = startPageIndex;
        AppPreference.instance.save();
      }

      if (navShell != null) {
        navShell.goBranch(value);
      } else {
        context.go(destinations[value].desPath);
      }

      var scaffold = Scaffold.of(context);
      if (scaffold.hasDrawer) scaffold.closeDrawer();
    }

    void onDestinationDoubleTap(int value) {
      if (selectedIndex != value) return;

      if (navShell != null) {
        navShell.goBranch(value, initialLocation: true);
      } else {
        context.go(destinations[value].desPath);
      }

      final scaffold = Scaffold.of(context);
      if (scaffold.hasDrawer) scaffold.closeDrawer();
    }

    void toggleSidebar() {
      final newVal = !sidebarExpanded.value;
      sidebarExpanded.value = newVal;
      widget.onExpandedChanged?.call(newVal);
      AppPreference.instance.sidebarExpanded = newVal;
      AppPreference.instance.save();
    }

    final isDrawer = Scaffold.maybeOf(context)?.hasDrawer ?? false;
    final VoidCallback onToggle = isDrawer
        ? () {
            final scaffold = Scaffold.of(context);
            if (scaffold.hasDrawer) scaffold.closeDrawer();
          }
        : toggleSidebar;

    return ResponsiveBuilder(
      builder: (context, screenType) {
        return LayoutBuilder(
          builder: (context, constraints) {
            final expandedWidth = isDrawer
                ? constraints.maxWidth
                : math.min(_expandedWidth, constraints.maxWidth);
            return ValueListenableBuilder(
              valueListenable: sidebarExpanded,
              builder: (context, expanded, _) {
                final effectiveExpanded = isDrawer || expanded;
                return _SmoothLargeSideNav(
                  isDrawer: isDrawer,
                  expanded: effectiveExpanded,
                  expandedWidth: expandedWidth,
                  colorScheme: scheme,
                  selectedIndex: selectedIndex,
                  onToggle: onToggle,
                  onSelect: onDestinationSelected,
                  onReturnHome: onDestinationDoubleTap,
                );
              },
            );
          },
        );
      },
    );
  }
}

class _SmoothLargeSideNav extends StatelessWidget {
  const _SmoothLargeSideNav({
    required this.isDrawer,
    required this.expanded,
    required this.expandedWidth,
    required this.colorScheme,
    required this.selectedIndex,
    required this.onToggle,
    required this.onSelect,
    required this.onReturnHome,
  });

  final bool isDrawer;
  final bool expanded;
  final double expandedWidth;
  final ColorScheme colorScheme;
  final int? selectedIndex;
  final VoidCallback onToggle;
  final void Function(int) onSelect;
  final void Function(int) onReturnHome;

  static const double _collapsedWidth = _SideNavState._collapsedWidth;
  static const double _itemHeight = _SideNavState._itemHeight;

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: TweenAnimationBuilder<double>(
        duration: MotionDuration.base,
        curve: MotionCurve.standard,
        tween: Tween(begin: 0.0, end: expanded ? 1.0 : 0.0),
        builder: (context, t, _) => _buildPanel(context, t),
      ),
    );
  }

  Widget _buildPanel(BuildContext context, double t) {
    final visibleWidth =
        (lerpDouble(_collapsedWidth, expandedWidth, t) ?? _collapsedWidth)
            .clamp(_collapsedWidth, expandedWidth);
    final itemWidth = math.max(0.0, visibleWidth - 16.0);
    final expandedVisual = t >= 0.5;
    final contentHeight = sideNavContentHeight(expandedT: t);
    return SizedBox(
      width: visibleWidth,
      height: double.infinity,
      child: Padding(
        padding: const EdgeInsets.all(8.0),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: colorScheme.surface,
            borderRadius: AppRadius.mdCircular,
          ),
          child: ClipRRect(
            borderRadius: AppRadius.mdCircular,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SizedBox(height: 12),
                _NavItem(
                  height: _itemHeight,
                  width: itemWidth,
                  icon: isDrawer
                      ? Symbols.close
                      : expandedVisual
                      ? Symbols.menu_open
                      : Symbols.menu,
                  label: isDrawer
                      ? '关闭'
                      : expandedVisual
                      ? '收起'
                      : '展开',
                  expandedT: t,
                  selected: false,
                  onTap: onToggle,
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    children: [
                      SizedBox(
                        height: contentHeight,
                        child: Stack(
                          children: [
                            if (selectedIndex != null && selectedIndex! >= 0)
                              TweenAnimationBuilder<double>(
                                duration:
                                    MediaQuery.disableAnimationsOf(context)
                                    ? Duration.zero
                                    : MotionDuration.fast,
                                curve: MotionCurve.entrance,
                                tween: Tween<double>(
                                  begin: sideNavDestinationOffset(
                                    selectedIndex!.toDouble(),
                                    expandedT: t,
                                  ),
                                  end: sideNavDestinationOffset(
                                    selectedIndex!.toDouble(),
                                    expandedT: t,
                                  ),
                                ),
                                builder: (context, offset, child) =>
                                    Transform.translate(
                                      offset: Offset(0, offset),
                                      child: child,
                                    ),
                                child: SizedBox(
                                  width: itemWidth,
                                  height: _itemHeight,
                                  child: DecoratedBox(
                                    decoration: BoxDecoration(
                                      color: colorScheme.secondaryContainer
                                          .withValues(alpha: 0.85),
                                      borderRadius: AppRadius.smCircular,
                                    ),
                                  ),
                                ),
                              ),
                            Column(
                              children: [
                                for (final group in destinationGroups) ...[
                                  _NavGroupHeader(
                                    label: group.label,
                                    height: sideNavGroupHeaderExtent(t),
                                    opacity: t,
                                  ),
                                  for (final i in group.destinationIndices)
                                    _NavItem(
                                      height: _itemHeight,
                                      width: itemWidth,
                                      icon: destinations[i].icon,
                                      label: destinations[i].label,
                                      expandedT: t,
                                      selected: selectedIndex == i,
                                      tooltip: expanded
                                          ? null
                                          : destinations[i].label,
                                      onTap: () {
                                        onSelect(i);
                                        final scaffold = Scaffold.of(context);
                                        if (scaffold.hasDrawer) {
                                          scaffold.closeDrawer();
                                        }
                                      },
                                      onDoubleTap: selectedIndex == i
                                          ? () => onReturnHome(i)
                                          : null,
                                    ),
                                ],
                              ],
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  const _NavItem({
    required this.height,
    required this.width,
    required this.icon,
    required this.label,
    required this.expandedT,
    required this.selected,
    required this.onTap,
    this.tooltip,
    this.onDoubleTap,
  });

  final double height;
  final double width;
  final IconData icon;
  final String label;
  final double expandedT;
  final bool selected;
  final VoidCallback onTap;
  final String? tooltip;
  final VoidCallback? onDoubleTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final fg = selected ? scheme.onSecondaryContainer : scheme.onSurface;
    final textOpacity = expandedT.clamp(0.0, 1.0);
    const iconSize = 24.0;
    const iconLeftPad = 20.0;
    const textLeftPad = 8.0;

    final item = Align(
      alignment: Alignment.centerLeft,
      child: SizedBox(
        width: width,
        height: height,
        child: Material(
          color: Colors.transparent,
          borderRadius: AppRadius.smCircular,
          child: InkWell(
            borderRadius: AppRadius.smCircular,
            onTap: onTap,
            onDoubleTap: onDoubleTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  const SizedBox(width: iconLeftPad),
                  SizedBox(
                    width: iconSize,
                    child: Icon(
                      icon,
                      size: iconSize,
                      color: fg.withValues(alpha: 0.90),
                    ),
                  ),
                  Expanded(
                    child: ClipRect(
                      child: Opacity(
                        opacity: textOpacity,
                        child: Padding(
                          padding: const EdgeInsets.only(left: textLeftPad),
                          child: Text(
                            label,
                            maxLines: 1,
                            overflow: TextOverflow.fade,
                            softWrap: false,
                            style: TextStyle(
                              color: fg,
                              fontSize: 14.5,
                              fontWeight: selected
                                  ? AppType.weightSemibold
                                  : AppType.weightMedium,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    if (tooltip == null) return item;
    return Tooltip(message: tooltip!, child: item);
  }
}

class _NavGroupHeader extends StatelessWidget {
  const _NavGroupHeader({
    required this.label,
    required this.height,
    required this.opacity,
  });

  final String label;
  final double height;
  final double opacity;

  @override
  Widget build(BuildContext context) {
    if (height <= 0 || opacity <= 0) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      height: height,
      child: ClipRect(
        child: Align(
          alignment: Alignment.centerLeft,
          child: Opacity(
            opacity: opacity,
            child: Padding(
              padding: const EdgeInsets.only(left: 20, right: 8),
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.fade,
                softWrap: false,
                style: TextStyle(
                  color: scheme.onSurfaceVariant,
                  fontSize: AppType.caption,
                  fontWeight: AppType.weightSemibold,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
