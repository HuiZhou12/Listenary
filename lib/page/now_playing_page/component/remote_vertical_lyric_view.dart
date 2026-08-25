import 'dart:async';
import 'dart:math' show max, pow, sin;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:provider/provider.dart';
import 'package:pure_music/core/enums.dart';
import 'package:pure_music/lyric/lyric.dart';
import 'package:pure_music/lyric/lyric_timing.dart';
import 'package:pure_music/page/now_playing_page/component/collapsible_lyric_controls.dart';
import 'package:pure_music/page/now_playing_page/component/lyric_stagger_motion.dart';
import 'package:pure_music/page/now_playing_page/component/lyric_view_controls.dart';
import 'package:pure_music/page/now_playing_page/component/lyric_viewport_strategy.dart';
import 'package:pure_music/page/now_playing_page/component/lyrics_line_widget.dart';
import 'package:pure_music/page/now_playing_page/component/value_transition.dart';
import 'package:pure_music/page/now_playing_page/component/vertical_lyric_view.dart'
    show alwaysShowLyricViewControls;
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
    with TickerProviderStateMixin, AutomaticKeepAliveClientMixin {
  static const _estimatedItemExtent = 82.0;

  final ScrollController _scrollController = ScrollController();
  final LyricUserScrollTracker _userScrollTracker = LyricUserScrollTracker();
  final Map<int, GlobalKey> _lineKeys = {};
  RemoteLyricController? _controller;
  Timer? _resumeFollowTimer;
  _RemoteLyricScrollState _scrollState = _RemoteLyricScrollState.idle;
  int? _lastLineIndex;
  Lyric? _lastLyric;
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
    final controller = context.read<RemoteLyricController>();
    if (identical(controller, _controller)) return;
    _controller?.removeListener(_onLyricChanged);
    _controller = controller..addListener(_onLyricChanged);
    _onLyricChanged();
  }

  void _onLyricChanged() {
    if (!mounted || _controller == null) return;
    final snapshot = _controller!.value;
    final lyricChanged = !identical(snapshot.lyric, _lastLyric);
    final lineChanged = snapshot.currentLineIndex != _lastLineIndex;
    if (!lyricChanged && !lineChanged) return;

    final previousLineIndex = _lastLineIndex;
    _lastLyric = snapshot.lyric;
    _lastLineIndex = snapshot.currentLineIndex;
    if (lyricChanged) {
      _lineKeys.clear();
      _jumpTriggerId = 0;
      _jumpDeltaY = 0;
      _staggerVisibleStartIndex = 0;
    } else if (lineChanged &&
        previousLineIndex != null &&
        snapshot.currentLineIndex != null) {
      _jumpTriggerId++;
      _jumpDeltaY =
          ((snapshot.currentLineIndex! - previousLineIndex) *
                  _estimatedItemExtent)
              .clamp(-_estimatedItemExtent * 3, _estimatedItemExtent * 3);
      _staggerVisibleStartIndex = max(0, snapshot.currentLineIndex! - 3);
    }

    if (lyricChanged || lineChanged) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _scrollState == _RemoteLyricScrollState.userDragging) {
          return;
        }
        _scrollToCurrent();
      });
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
            _scrollToCurrent();
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

  void _scrollToCurrent() {
    if (!mounted || !_scrollController.hasClients) return;
    final index = _controller?.value.currentLineIndex;
    final lyric = _controller?.value.lyric;
    if (index == null || lyric == null || lyric.lines.isEmpty) return;

    final lineContext = _lineKeys[index]?.currentContext;
    final distance = (index - (_lastLineIndex ?? index)).abs();
    final duration = _scrollDurationForDistance(
      (distance * _estimatedItemExtent).toDouble(),
    );
    _setScrollState(_RemoteLyricScrollState.programScrolling);
    if (lineContext != null) {
      final target = RenderAbstractViewport.of(lineContext.findRenderObject()!)
          .getOffsetToReveal(
            lineContext.findRenderObject()!,
            widget.currentLineAlignment,
          );
      _animateTo(target.offset, duration: duration);
      return;
    }

    final viewport = _scrollController.position.viewportDimension;
    final topPadding = widget.centerVertically
        ? viewport / 2.0
        : widget.enableEdgeSpacer
        ? viewport
        : viewport * widget.currentLineAlignment;
    final target =
        (topPadding +
                index * _estimatedItemExtent +
                _estimatedItemExtent / 2.0 -
                viewport * widget.currentLineAlignment)
            .clamp(0.0, _scrollController.position.maxScrollExtent);
    _animateTo(target, duration: duration);
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
                  final currentLineIndex =
                      snapshot.currentLineIndex ?? update.primaryIndex;
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
    );
  }

  @override
  void dispose() {
    _resumeFollowTimer?.cancel();
    _stopScrollTicker();
    _controller?.removeListener(_onLyricChanged);
    _scrollController.dispose();
    super.dispose();
  }
}
