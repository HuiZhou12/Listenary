// ignore_for_file: invalid_use_of_visible_for_testing_member

import 'dart:async';
import 'dart:math' show max, pow, sin;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:provider/provider.dart';
import 'package:pure_music/core/enums.dart';
import 'package:pure_music/core/route_visibility.dart';
import 'package:pure_music/lyric/lyric.dart';
import 'package:pure_music/lyric/lyric_timing.dart';
import 'package:pure_music/page/now_playing_page/component/collapsible_lyric_controls.dart';
import 'package:pure_music/page/now_playing_page/component/lyric_stagger_motion.dart';
import 'package:pure_music/page/now_playing_page/component/lyric_view_controls.dart';
import 'package:pure_music/page/now_playing_page/component/lyric_viewport_strategy.dart';
import 'package:pure_music/page/now_playing_page/component/lyrics_line_widget.dart';
import 'package:pure_music/page/now_playing_page/component/value_transition.dart';
import 'package:pure_music/page/now_playing_page/component/vertical_lyric_view.dart'
    show alwaysShowLyricViewControls, lyricDisplayPrimaryIndex;
import 'package:pure_music/play_service/play_service.dart';
import 'package:pure_music/play_service/remote_lyric_controller.dart';

const _remoteOpacityBase = 0.88;
const _remoteOpacityMinClamp = 0.30;
const _remoteOpacityMaxClamp = 0.90;
const _remoteStaggerMaxMs = 600;
const _remoteShaderFadeInWithBlur = 0.05;
const _remoteShaderFadeOutWithBlur = 0.80;
const _remoteShaderFadeInWithoutBlur = 0.05;
const _remoteShaderFadeOutWithoutBlur = 0.95;

enum _RemoteLyricScrollState { idle, userDragging, programScrolling }

class RemoteVerticalLyricView extends StatefulWidget {
  const RemoteVerticalLyricView({
    super.key,
    this.showControls = true,
    this.centerVertically = true,
    this.currentLineAlignment = 0.35,
    this.enableEdgeSpacer = false,
  });

  final bool showControls;
  final bool centerVertically;
  final double currentLineAlignment;
  final bool enableEdgeSpacer;

  @override
  State<RemoteVerticalLyricView> createState() =>
      _RemoteVerticalLyricViewState();
}

class _RemoteVerticalLyricViewState extends State<RemoteVerticalLyricView>
    with TickerProviderStateMixin, AutomaticKeepAliveClientMixin, RouteAware {
  static const _estimatedItemExtent = 82.0;

  final ScrollController _scrollController = ScrollController();
  final LyricUserScrollTracker _userScrollTracker = LyricUserScrollTracker();
  final Map<int, GlobalKey> _lineKeys = {};
  RemoteLyricController? _controller;
  PageRoute<dynamic>? _route;
  Timer? _resumeFollowTimer;
  _RemoteLyricScrollState _scrollState = _RemoteLyricScrollState.idle;
  int? _lastLineIndex;
  Lyric? _lastLyric;
  /// 回到播放页/首次定位时当前行往往还没构建（也还没有可用的精确滚动目标），
  /// 需要跨帧重试直到能精确命中当前行。
  /// 对照本地视图 `vertical_lyric_view.dart` 的 `_pendingScrollRetries` 机制。
  int _pendingScrollRetries = 0;
  static const int _maxPendingScrollRetries = 90;
  int _jumpTriggerId = 0;
  double _jumpDeltaY = 0;
  int _staggerVisibleStartIndex = 0;
  late final ValueTransition<double> _scrollTransition;
  Ticker? _scrollTicker;
  bool _scrollTickerActive = false;
  Duration _lastScrollTickElapsed = Duration.zero;

  bool _isHovered = false;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _scrollTransition = ValueTransition<double>(
      begin: 0,
      interpolator: lyricSmoothTransitionInterpolator,
      duration: lyricSmoothTransitionDuration,
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (_route != route) {
      final oldRoute = _route;
      if (oldRoute != null) routeVisibilityObserver.unsubscribe(this);
      _route = route is PageRoute<dynamic> ? route : null;
      final pageRoute = _route;
      if (pageRoute != null) routeVisibilityObserver.subscribe(this, pageRoute);
    }
    final controller = context.read<RemoteLyricController>();
    if (identical(controller, _controller)) return;
    _controller?.removeListener(_onLyricChanged);
    _controller = controller..addListener(_onLyricChanged);
    _onLyricChanged();
  }

  int _displayIndex(RemoteLyricSnapshot snapshot) {
    final lyric = snapshot.lyric;
    if (lyric == null || lyric.lines.isEmpty) return 0;
    final update = lyricLineUpdateAt(lyric, snapshot.position ?? Duration.zero);
    return lyricDisplayPrimaryIndex(
      fallbackPrimaryIndex: snapshot.currentLineIndex ?? update.primaryIndex,
      lineCount: lyric.lines.length,
      groupedLines: update.layoutIndices.toSet(),
    );
  }

  void _syncWhenRouteVisible() {
    // 用户正在手动拖动歌词时不抢滚动（保留既有保护）。
    if (!mounted || _scrollState == _RemoteLyricScrollState.userDragging) {
      return;
    }
    // 回到播放页时播放页整棵子树会被重建（路由 `maintainState: false`），
    // 歌词 ListView 从偏移 0 重新开始，必须强制把视口重新拉回当前行。
    // 对照本地视图 `_syncWhenRouteVisible()`：重置跟随/拖动状态、清掉行跳变动画，
    // 再按「强制定位 + 跨帧重试」的方式重新定位。
    _resumeFollowTimer?.cancel();
    _resumeFollowTimer = null;
    _userScrollTracker.end();
    setState(() {
      _jumpDeltaY = 0;
      _jumpTriggerId++;
    });
    _requestScrollToCurrent();
  }

  @override
  void didPush() => _syncWhenRouteVisible();

  @override
  void didPopNext() => _syncWhenRouteVisible();

  void _onLyricChanged() {
    if (!mounted || _controller == null) return;
    final snapshot = _controller!.value;
    final displayIndex = _displayIndex(snapshot);
    final lyricChanged = !identical(snapshot.lyric, _lastLyric);
    final lineChanged = displayIndex != _lastLineIndex;
    if (!lyricChanged && !lineChanged) return;

    final previousLineIndex = _lastLineIndex;
    _lastLyric = snapshot.lyric;
    _lastLineIndex = displayIndex;
    if (lyricChanged) {
      _lineKeys.clear();
      _jumpTriggerId = 0;
      _jumpDeltaY = 0;
      _staggerVisibleStartIndex = 0;
    } else if (lineChanged && previousLineIndex != null) {
      _jumpTriggerId++;
      _jumpDeltaY = ((displayIndex - previousLineIndex) * _estimatedItemExtent)
          .clamp(-_estimatedItemExtent * 3, _estimatedItemExtent * 3);
      _staggerVisibleStartIndex = max(0, displayIndex - 3);
    }

    if (lyricChanged || lineChanged) {
      // 换成 `_requestScrollToCurrent()`：行刚变化/歌词刚就绪时目标行可能还没构建，
      // 需要跨帧重试到能精确命中（与回页定位同一套机制）。
      _requestScrollToCurrent();
    }
    setState(() {});
  }

  void _handleScrollNotification(ScrollNotification notification) {
    if (notification is ScrollStartNotification &&
        notification.dragDetails != null) {
      _resumeFollowTimer?.cancel();
      _resumeFollowTimer = null;
      _setScrollState(
        _userScrollTracker.start() == LyricUserScrollPhase.started
            ? _RemoteLyricScrollState.userDragging
            : _scrollState,
      );
    } else if (notification is ScrollUpdateNotification &&
        notification.dragDetails != null) {
      _setScrollState(_RemoteLyricScrollState.userDragging);
      _userScrollTracker.update();
    } else if (notification is ScrollEndNotification) {
      if (_userScrollTracker.end() != LyricUserScrollPhase.ignored) {
        _resumeFollowTimer?.cancel();
        _resumeFollowTimer = Timer(
          LyricViewController.instance.renderConfig.userScrollHoldDuration,
          () {
            if (!mounted) return;
            _setScrollState(_RemoteLyricScrollState.idle);
            _requestScrollToCurrent();
          },
        );
      }
    }
  }

  void _setScrollState(_RemoteLyricScrollState state) {
    if (_scrollState == state || !mounted) return;
    setState(() => _scrollState = state);
  }

  void _startScrollTicker() {
    if (_scrollTickerActive) return;
    _scrollTicker?.dispose();
    _lastScrollTickElapsed = Duration.zero;
    _scrollTicker = createTicker(_onScrollTick)..start();
    _scrollTickerActive = true;
  }

  void _stopScrollTicker() {
    _scrollTicker?.stop();
    _scrollTicker?.dispose();
    _scrollTicker = null;
    _scrollTickerActive = false;
  }

  void _onScrollTick(Duration elapsed) {
    if (!mounted || !_scrollController.hasClients) return;
    final delta = elapsed - _lastScrollTickElapsed;
    _lastScrollTickElapsed = elapsed;
    _scrollTransition.update(delta);
    final target = _scrollTransition.value.clamp(
      _scrollController.position.minScrollExtent,
      _scrollController.position.maxScrollExtent,
    );
    _scrollController.jumpTo(target);
    if (!_scrollTransition.isActive) {
      _stopScrollTicker();
      if (_scrollState == _RemoteLyricScrollState.programScrolling) {
        _setScrollState(_RemoteLyricScrollState.idle);
      }
    }
  }

  static double _sineOutInterpolator(double t, double start, double end) {
    return start + (end - start) * sin(t * 3.141592653589793 / 2);
  }

  static Duration _scrollDurationForDistance(double distance) {
    return Duration(
      milliseconds: (440 + (distance / 1200).clamp(0.0, 1.0) * 160)
          .round()
          .clamp(440, 600),
    );
  }

  void _animateTo(double target, {Duration? duration, bool stagger = false}) {
    if (!_scrollController.hasClients) return;
    final minExtent = _scrollController.position.minScrollExtent;
    final maxExtent = _scrollController.position.maxScrollExtent;
    final to = target.clamp(minExtent, maxExtent);
    final from = _scrollController.offset;
    final distance = (to - from).abs();
    if (distance < 0.5 || (duration != null && duration.inMilliseconds <= 16)) {
      _scrollController.jumpTo(to);
      _scrollTransition.jumpTo(to);
      _stopScrollTicker();
      if (_scrollState == _RemoteLyricScrollState.programScrolling) {
        _setScrollState(_RemoteLyricScrollState.idle);
      }
      return;
    }

    final config = LyricViewController.instance.renderConfig;
    _scrollTransition
      ..begin = from
      ..interpolator = config.staggerStyle == LyricStaggerStyle.smooth
          ? lyricSmoothTransitionInterpolator
          : _sineOutInterpolator
      ..duration = duration ?? _scrollDurationForDistance(distance)
      ..start(to);
    if (stagger) {
      _jumpDeltaY = to - from;
      _jumpTriggerId++;
      _scrollController.jumpTo(to);
      _scrollTransition.jumpTo(to);
      _stopScrollTicker();
      return;
    }
    _startScrollTicker();
  }

  /// 请求把视口重新定位到当前行。
  ///
  /// 回页/首次定位时当前行的行 widget 往往还没构建，`_lineKeys[index]` 取不到
  /// 精确滚动目标，只能退回到行高估算；而估算一旦与真实行高不符就会停在错误位置。
  /// 因此这里在后续帧里持续尝试，直到当前行已构建、能拿到精确 reveal 目标为止。
  void _requestScrollToCurrent() {
    if (!mounted) return;
    _pendingScrollRetries = 0;
    _scheduleScrollStep();
  }

  void _scheduleScrollStep() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_scrollState == _RemoteLyricScrollState.userDragging) {
        _pendingScrollRetries = 0;
        return;
      }
      final snapshot = _controller?.value;
      final lyric = snapshot?.lyric;
      if (snapshot == null || lyric == null || lyric.lines.isEmpty) {
        _scheduleScrollRetry();
        return;
      }
      final index = _displayIndex(snapshot);
      // 该行本身不渲染（空白行没有行 widget），估算一次即可，不进入重试。
      final lines = lyric.lines;
      if (index < 0 ||
          index >= lines.length ||
          lyricLineIsFilteredBlank(lines[index])) {
        _pendingScrollRetries = 0;
        if (_scrollController.hasClients &&
            _scrollState != _RemoteLyricScrollState.programScrolling) {
          _scrollToCurrent();
        }
        return;
      }
      if (_revealOffsetForLine(index) != null) {
        // 当前行已构建：精确 reveal（已对齐时不会产生位移，幂等）。
        _pendingScrollRetries = 0;
        _scrollToCurrent();
        return;
      }
      // 当前行还没构建：先按已构建行实测出的目标滚过去，
      // 等这次滚动结束、当前行进入构建范围后再精确对齐。
      // （滚动动画进行中不重复发起，避免每帧重启动画；估算已到位也不重复发起。）
      if (_scrollController.hasClients &&
          _scrollState != _RemoteLyricScrollState.programScrolling &&
          (_estimatedScrollOffsetForLine(index) - _scrollController.offset)
                  .abs() >
              1.0) {
        _scrollToCurrent();
      }
      _scheduleScrollRetry();
    });
  }

  void _scheduleScrollRetry() {
    if (_pendingScrollRetries >= _maxPendingScrollRetries) {
      _pendingScrollRetries = 0;
      return;
    }
    _pendingScrollRetries++;
    _scheduleScrollStep();
  }

  /// 当前行已构建时，返回把它对齐到 [RemoteVerticalLyricView.currentLineAlignment]
  /// 所需的滚动偏移；未构建时返回 null。
  double? _revealOffsetForLine(int index) {
    final lineContext = _lineKeys[index]?.currentContext;
    if (lineContext == null) return null;
    final renderObject = lineContext.findRenderObject();
    if (renderObject == null || !renderObject.attached) return null;
    return RenderAbstractViewport.of(
      renderObject,
    ).getOffsetToReveal(renderObject, widget.currentLineAlignment).offset;
  }

  /// 当前行还没构建时的估算滚动目标。
  ///
  /// 固定 [_estimatedItemExtent] 与实际行高（翻译/罗马音并列时差异很大）并不相符，
  /// 所以优先用已构建行之间的**实测**像素间距外推：两行的 `getOffsetToReveal` 之差
  /// 即真实行高；再取离目标行最近的已构建行作锚点，锚点自带列表 padding 与对齐信息。
  double _estimatedScrollOffsetForLine(int index) {
    final position = _scrollController.position;
    final viewport = position.viewportDimension;
    final alignment = widget.currentLineAlignment;

    final builtIndices = <int>[];
    for (final entry in _lineKeys.entries) {
      if (_revealOffsetForLine(entry.key) != null) builtIndices.add(entry.key);
    }
    builtIndices.sort();

    var extent = _estimatedItemExtent;
    if (builtIndices.isNotEmpty) {
      final firstIndex = builtIndices.first;
      final lastIndex = builtIndices.last;
      if (lastIndex > firstIndex) {
        final measured =
            (_revealOffsetForLine(lastIndex)! -
                _revealOffsetForLine(firstIndex)!) /
            (lastIndex - firstIndex);
        if (measured.isFinite && measured > 1.0) extent = measured;
      }

      // 取离目标行最近的已构建行作锚点：锚点自带列表 padding 与对齐信息，
      // 只需再按实测行高外推差值，比固定行高估算准确得多。
      var anchorIndex = firstIndex;
      var bestDistance = (anchorIndex - index).abs();
      for (final built in builtIndices) {
        final distance = (built - index).abs();
        if (distance < bestDistance) {
          bestDistance = distance;
          anchorIndex = built;
        }
      }
      final anchorOffset = _revealOffsetForLine(anchorIndex);
      if (anchorOffset != null) {
        return (anchorOffset + (index - anchorIndex) * extent).clamp(
          position.minScrollExtent,
          position.maxScrollExtent,
        );
      }
    }

    // 一行都没构建时退回固定行高估算（与 ListView 的 padding 保持一致）。
    final topPadding = widget.centerVertically
        ? viewport / 2.0
        : widget.enableEdgeSpacer
        ? viewport
        : viewport * alignment;
    final target =
        topPadding + index * extent + extent / 2.0 - viewport * alignment;
    return target.clamp(position.minScrollExtent, position.maxScrollExtent);
  }

  void _scrollToCurrent() {
    if (!mounted || !_scrollController.hasClients) return;
    final snapshot = _controller?.value;
    if (snapshot == null) return;
    final index = _displayIndex(snapshot);
    final lyric = snapshot.lyric;
    if (lyric == null || lyric.lines.isEmpty) return;

    final distance = (index - (_lastLineIndex ?? index)).abs();
    final duration = _scrollDurationForDistance(
      (distance * _estimatedItemExtent).toDouble(),
    );
    _setScrollState(_RemoteLyricScrollState.programScrolling);
    final revealOffset = _revealOffsetForLine(index);
    if (revealOffset != null) {
      _animateTo(revealOffset, duration: duration);
      return;
    }
    _animateTo(_estimatedScrollOffsetForLine(index), duration: duration);
  }

  bool _hasBackgroundVocal(LyricLine line) {
    if (line is! SyncLyricLine) return false;
    return line.bgText?.isNotEmpty == true ||
        (LyricViewController.instance.renderConfig.showRoman &&
            line.bg?.romanLyric?.isNotEmpty == true) ||
        line.bgTranslation?.isNotEmpty == true ||
        line.bgWords.isNotEmpty;
  }

  void _seekToLine(LyricLine line) {
    if (!PlayService.instance.canSeekFromUi) return;
    PlayService.instance.seekFromUi(line.start.inMilliseconds / 1000.0);
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final controller = _controller;
    if (controller == null) return const SizedBox.shrink();

    return MouseRegion(
      onEnter: (_) {
        if (mounted) setState(() => _isHovered = true);
      },
      onExit: (_) {
        if (mounted) setState(() => _isHovered = false);
      },
      child: Material(
        type: MaterialType.transparency,
        child: ScrollConfiguration(
          behavior: const ScrollBehavior().copyWith(scrollbars: false),
          child: ChangeNotifierProvider<LyricViewController>.value(
            value: LyricViewController.instance,
            child: Stack(
            children: [
              ListenableBuilder(
                listenable: Listenable.merge([
                  controller,
                  LyricViewController.instance,
                ]),
                builder: (context, _) {
                  final snapshot = controller.value;
                  if (snapshot.status == RemoteLyricStatus.loading) {
                    return const Center(
                      child: SizedBox.square(
                        dimension: 24,
                        child: CircularProgressIndicator(),
                      ),
                    );
                  }
                  final lyric = snapshot.lyric;
                  if (lyric == null || lyric.isEmpty) {
                    return const Center(
                      child: Text('暂无歌词', style: TextStyle(fontSize: 22)),
                    );
                  }

                  final position = snapshot.position ?? Duration.zero;
                  final update = lyricLineUpdateAt(lyric, position);
                  final currentLineIndex = _displayIndex(snapshot);
                  final groupIndices = update.layoutIndices.toSet();
                  final freezeParallelGroup = groupIndices.length > 1;

                  return LayoutBuilder(
                    builder: (context, constraints) {
                      final viewportHeight = constraints.maxHeight;
                      final spacerHeight = viewportHeight / 2.0;
                      final extraTopPadding = widget.enableEdgeSpacer
                          ? viewportHeight
                          : 0.0;
                      final extraBottomPadding = widget.enableEdgeSpacer
                          ? viewportHeight
                          : 0.0;
                      final alignTopPadding =
                          (!widget.centerVertically && !widget.enableEdgeSpacer)
                          ? viewportHeight * widget.currentLineAlignment
                          : 0.0;
                      final alignBottomPadding =
                          (!widget.centerVertically && !widget.enableEdgeSpacer)
                          ? viewportHeight * (1.0 - widget.currentLineAlignment)
                          : 0.0;
                      final renderConfig =
                          LyricViewController.instance.renderConfig;
                      final viewportStrategy = LyricViewportStrategy(
                        leadingLines: renderConfig.viewportLeadingLines,
                        trailingLines: renderConfig.viewportTrailingLines,
                        overscanScreens: renderConfig.viewportOverscanScreens,
                        userScrollHoldDuration:
                            renderConfig.userScrollHoldDuration,
                      );
                      final extraFadeIn = renderConfig.enableBlur
                          ? _remoteShaderFadeInWithBlur
                          : _remoteShaderFadeInWithoutBlur;
                      final extraFadeOut = renderConfig.enableBlur
                          ? _remoteShaderFadeOutWithBlur
                          : _remoteShaderFadeOutWithoutBlur;

                      return RepaintBoundary(
                        child: NotificationListener<ScrollNotification>(
                          onNotification: (notification) {
                            _handleScrollNotification(notification);
                            return false;
                          },
                          child: ShaderMask(
                            shaderCallback: (bounds) => LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: const [
                                Colors.transparent,
                                Colors.black,
                                Colors.black,
                                Colors.transparent,
                              ],
                              stops: [0.0, extraFadeIn, extraFadeOut, 1.0],
                            ).createShader(bounds),
                            blendMode: BlendMode.dstIn,
                            child: ListView.builder(
                              controller: _scrollController,
                              addAutomaticKeepAlives: true,
                              addRepaintBoundaries: true,
                              scrollCacheExtent: ScrollCacheExtent.pixels(
                                viewportStrategy.cacheExtent(viewportHeight),
                              ),
                              padding: EdgeInsets.only(
                                top:
                                    (widget.centerVertically
                                        ? spacerHeight
                                        : 0) +
                                    extraTopPadding +
                                    alignTopPadding,
                                bottom:
                                    (widget.centerVertically
                                        ? spacerHeight
                                        : 0) +
                                    extraBottomPadding +
                                    alignBottomPadding,
                              ),
                              itemCount: lyric.lines.length,
                              itemBuilder: (context, index) {
                                final line = lyric.lines[index];
                                if (lyricLineIsFilteredBlank(line)) {
                                  return const SizedBox.shrink();
                                }

                                final distance = (index - currentLineIndex)
                                    .abs();
                                final isGroupLine = groupIndices.contains(
                                  index,
                                );
                                final opacity = distance == 0 || isGroupLine
                                    ? 1.0
                                    : pow(
                                        _remoteOpacityBase,
                                        distance,
                                      ).toDouble().clamp(
                                        _remoteOpacityMinClamp,
                                        _remoteOpacityMaxClamp,
                                      );
                                final staggerDelay =
                                    renderConfig.enableStaggeredAnimation
                                    ? renderConfig.staggerStyle ==
                                              LyricStaggerStyle.spring
                                          ? Duration(
                                              milliseconds: lyricStaggerDelayMs(
                                                itemIndex: index,
                                                visibleStartIndex:
                                                    _staggerVisibleStartIndex,
                                              ),
                                            )
                                          : Duration(
                                              milliseconds:
                                                  (30 *
                                                          (distance + 1) *
                                                          (5 + distance) ~/
                                                          5)
                                                      .clamp(
                                                        0,
                                                        _remoteStaggerMaxMs,
                                                      ),
                                            )
                                    : Duration.zero;

                                return SizedBox(
                                  key: _lineKeys[index] ??= GlobalKey(),
                                  child: LyricsLineWidget(
                                    key: ValueKey(
                                      'remote_lyric_line_${identityHashCode(lyric)}_$index',
                                    ),
                                    line: line,
                                    opacity: opacity,
                                    distance: distance,
                                    positionMs: position.inMilliseconds
                                        .toDouble(),
                                    usesExternalPosition: true,
                                    isHighlightActive: isGroupLine,
                                    accelerateTailHighlight: false,
                                    lineOffsetY: 0,
                                    staggerDelay: staggerDelay,
                                    jumpTriggerId: _jumpTriggerId,
                                    jumpDeltaY: _jumpDeltaY,
                                    isUserScrolling:
                                        _scrollState ==
                                        _RemoteLyricScrollState.userDragging,
                                    freezeHeight:
                                        freezeParallelGroup && isGroupLine,
                                    reserveBackgroundVocalHeight:
                                        (index == currentLineIndex ||
                                            isGroupLine) &&
                                        line is SyncLyricLine &&
                                        _hasBackgroundVocal(line),
                                    highlightDeadlineMs:
                                        lyricHighlightDeadlineMsForLine(
                                          lyric,
                                          index,
                                        )?.toDouble(),
                                    onTap: PlayService.instance.canSeekFromUi
                                        ? () => _seekToLine(line)
                                        : null,
                                  ),
                                );
                              },
                            ),
                          ),
                        ),
                      );
                    },
                  );
                },
              ),
              if (widget.showControls &&
                  (_isHovered || alwaysShowLyricViewControls))
                const Align(
                  alignment: Alignment.bottomRight,
                  child: CollapsibleLyricControls(),
                ),
            ],
          ),
        ),
      ),
    ),
  );
  }

  @override
  void dispose() {
    _resumeFollowTimer?.cancel();
    _stopScrollTicker();
    if (_route != null) routeVisibilityObserver.unsubscribe(this);
    _controller?.removeListener(_onLyricChanged);
    _scrollController.dispose();
    super.dispose();
  }
}
