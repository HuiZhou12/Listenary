import 'dart:async';

import 'package:provider/provider.dart';
import 'package:pure_music/core/design_tokens.dart';
import 'package:pure_music/core/enums.dart';
import 'package:pure_music/core/route_visibility.dart';
import 'package:pure_music/core/settings.dart';
import 'package:pure_music/lyric/lrc.dart';
import 'package:pure_music/lyric/lyric.dart';
import 'package:pure_music/page/now_playing_page/component/lyric_view_controls.dart';
import 'package:pure_music/page/now_playing_page/component/lyric_view_tile.dart';
import 'package:pure_music/play_service/play_service.dart';
import 'package:pure_music/play_service/active_playback_session.dart';
import 'package:pure_music/play_service/remote_lyric_controller.dart';
import 'package:flutter/material.dart';

class HorizontalLyricView extends StatelessWidget {
  final bool compact;
  const HorizontalLyricView({super.key, this.compact = false});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final usesRemoteMedia = context.select<ActivePlaybackSession, bool>(
      (session) => session.value.source == ActivePlaybackSessionSource.remote,
    );

    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.secondaryContainer,
        borderRadius: AppRadius.mdCircular,
      ),
      child: usesRemoteMedia
          ? const _RemoteLyricHorizontalScrollArea()
          : ListenableBuilder(
              listenable: Listenable.merge([
                PlayService.instance.lyricService,
                LyricViewController.instance,
              ]),
              builder: (context, _) => FutureBuilder(
                key: ValueKey(
                  PlayService.instance.lyricService.currLyricFuture,
                ),
                future: PlayService.instance.lyricService.currLyricFuture,
                builder: (context, snapshot) {
                  if (snapshot.data == null) {
                    return Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16.0),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          '快来播放音乐吧~',
                          style: TextStyle(color: scheme.onSecondaryContainer),
                        ),
                      ),
                    );
                  }

                  return _LyricHorizontalScrollArea(snapshot.data!, compact);
                },
              ),
            ),
    );
  }
}

Widget _buildTopBarLyricTextTransition({
  required String currentContent,
  required String previousContent,
  required AnimationController? controller,
  required ColorScheme scheme,
}) {
  Widget buildText(String content) => Text(
    content,
    maxLines: 1,
    softWrap: false,
    style: TextStyle(color: scheme.onSecondaryContainer),
  );

  if (controller == null || previousContent.isEmpty) {
    return buildText(currentContent);
  }
  final animation = AppSettings.instance.topBarLyricAnimation;
  return ClipRect(
    child: LayoutBuilder(
      builder: (context, constraints) {
        final height = constraints.maxHeight;
        return AnimatedBuilder(
          animation: controller,
          builder: (context, _) {
            final curve = animation == TopBarLyricAnimation.fade
                ? Curves.easeInOutCubic
                : Curves.easeOutCubic;
            final progress = curve.transform(controller.value);

            Widget buildLayer(String content, bool previous) {
              Widget child = buildText(content);
              final opacity = previous ? 1.0 - progress : progress;
              switch (animation) {
                case TopBarLyricAnimation.slideUp:
                  child = Transform.translate(
                    offset: Offset(
                      0,
                      previous ? -progress * height : (1 - progress) * height,
                    ),
                    child: Opacity(opacity: opacity, child: child),
                  );
                case TopBarLyricAnimation.slideDown:
                  child = Transform.translate(
                    offset: Offset(
                      0,
                      previous ? progress * height : -(1 - progress) * height,
                    ),
                    child: Opacity(opacity: opacity, child: child),
                  );
                case TopBarLyricAnimation.fade:
                  child = Opacity(opacity: opacity, child: child);
                case TopBarLyricAnimation.absorb:
                  child = Transform.scale(
                    scale: opacity.clamp(0.01, 1.0),
                    child: Opacity(opacity: opacity, child: child),
                  );
                case TopBarLyricAnimation.slideLeft:
                  child = FractionalTranslation(
                    translation: Offset(previous ? -progress : 1 - progress, 0),
                    child: Opacity(opacity: opacity, child: child),
                  );
                case TopBarLyricAnimation.slideRight:
                  child = FractionalTranslation(
                    translation: Offset(previous ? progress : progress - 1, 0),
                    child: Opacity(opacity: opacity, child: child),
                  );
              }
              return child;
            }

            return Stack(
              children: [
                buildLayer(previousContent, true),
                buildLayer(currentContent, false),
              ],
            );
          },
        );
      },
    ),
  );
}

class _RemoteLyricHorizontalScrollArea extends StatefulWidget {
  const _RemoteLyricHorizontalScrollArea();

  @override
  State<_RemoteLyricHorizontalScrollArea> createState() =>
      _RemoteLyricHorizontalScrollAreaState();
}

class _RemoteLyricHorizontalScrollAreaState
    extends State<_RemoteLyricHorizontalScrollArea>
    with SingleTickerProviderStateMixin {
  final ScrollController _scrollController = ScrollController();
  RemoteLyricController? _controller;
  Object? _lastRef;
  int? _lastLineIndex;
  String _content = '暂无歌词';
  String _previousContent = '';
  AnimationController? _transitionController;
  int _scrollRevision = 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final controller = context.read<RemoteLyricController>();
    if (identical(controller, _controller)) return;
    _controller?.removeListener(_onLyricChanged);
    _controller = controller..addListener(_onLyricChanged);
    _lastRef = null;
    _lastLineIndex = null;
    _onLyricChanged();
  }

  void _onLyricChanged() {
    if (!mounted) return;
    final snapshot = _controller!.value;
    final line = snapshot.currentLine;
    final nextContent = line == null ? '暂无歌词' : _contentForLine(line);
    final lineChanged =
        snapshot.ref != _lastRef || snapshot.currentLineIndex != _lastLineIndex;
    if (!lineChanged && nextContent == _content) return;
    _lastRef = snapshot.ref;
    _lastLineIndex = snapshot.currentLineIndex;
    setState(() {
      if (_content.isNotEmpty && nextContent.isNotEmpty) {
        _previousContent = _content;
        _transitionController?.dispose();
        _transitionController = AnimationController(
          vsync: this,
          duration: const Duration(milliseconds: 500),
        );
        _transitionController!.addStatusListener((status) {
          if (status == AnimationStatus.completed && mounted) {
            setState(() {
              _previousContent = '';
              _transitionController?.dispose();
              _transitionController = null;
            });
          }
        });
        _transitionController!.forward();
      } else {
        _previousContent = '';
      }
      _content = nextContent;
    });
    if (lineChanged) {
      final revision = ++_scrollRevision;
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _startScroll(revision, line, snapshot.position),
      );
    }
  }

  String _contentForLine(LyricLine line) {
    final content = remoteLyricLineContent(line);
    final translation = line.translation;
    if (translation == null || translation.isEmpty) return content;
    return '$content\u2503$translation';
  }

  void _startScroll(int revision, LyricLine? line, Duration? position) {
    if (!mounted || revision != _scrollRevision) return;
    if (!_scrollController.hasClients) return;
    _scrollController.jumpTo(0);
    final extent = _scrollController.position.maxScrollExtent;
    if (line == null || extent <= 0) return;
    final elapsed = (position ?? line.start) - line.start;
    final remaining = line.length - elapsed - const Duration(milliseconds: 600);
    if (remaining <= Duration.zero) return;
    Timer(const Duration(milliseconds: 300), () {
      if (!mounted || revision != _scrollRevision) return;
      if (!_scrollController.hasClients) return;
      unawaited(
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: remaining,
          curve: Curves.easeOutQuart,
        ),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16.0),
      child: Align(
        alignment: Alignment.centerLeft,
        child: ScrollConfiguration(
          behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
          child: SingleChildScrollView(
            controller: _scrollController,
            scrollDirection: Axis.horizontal,
            child: _buildTopBarLyricTextTransition(
              currentContent: _content,
              previousContent: _previousContent,
              controller: _transitionController,
              scheme: scheme,
            ),
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _controller?.removeListener(_onLyricChanged);
    _transitionController?.dispose();
    _scrollController.dispose();
    super.dispose();
  }
}

class _LyricHorizontalScrollArea extends StatefulWidget {
  const _LyricHorizontalScrollArea(this.lyric, [this.compact = false]);

  final Lyric lyric;
  final bool compact;

  @override
  State<_LyricHorizontalScrollArea> createState() =>
      _LyricHorizontalScrollAreaState();
}

class _LyricHorizontalScrollAreaState extends State<_LyricHorizontalScrollArea>
    with SingleTickerProviderStateMixin, RouteAware {
  /// 停留300ms后启动，提前300ms滚动到底
  final waitFor = const Duration(milliseconds: 300);
  final scrollController = ScrollController();
  final playbackService = PlayService.instance.playbackService;
  final lyricService = PlayService.instance.lyricService;
  late StreamSubscription lyricLineStreamSubscription;
  late final VoidCallback _playbackResyncListener;
  Timer? _positionResyncTimer;
  Timer? _positionResyncStopTimer;
  PageRoute<dynamic>? _route;
  int _scrollToken = 0;
  int _lastPositionResyncMs = 0;
  int _currentLineIndex = -1;
  int _positionResyncExtensionCount = 0;
  static const int _maxPositionResyncExtensions = 5;

  var currContent = 'Enjoy Music';
  String _prevContent = '';
  AnimationController? _slideController;
  bool _isTransition = false;
  LrcLine? _transitionLrcLine;
  SyncLyricLine? _transitionSyncLine;

  static bool _isTransitionLine(LyricLine line) {
    if (line is LrcLine) {
      return line.isBlank &&
          line.length > const Duration(seconds: 3) &&
          line.start == Duration.zero;
    }
    if (line is SyncLyricLine) {
      return line.words.isEmpty && line.length > const Duration(seconds: 3);
    }
    return false;
  }

  void _setContent(LyricLine line) {
    if (_isTransitionLine(line)) {
      _isTransition = true;
      _transitionLrcLine = line is LrcLine ? line : null;
      _transitionSyncLine = line is SyncLyricLine ? line : null;
      currContent = '';
    } else {
      final newContent = switch (line) {
        LrcLine l =>
          l.translation == null
              ? l.content
              : '${l.content}\u2503${l.translation}',
        SyncLyricLine s =>
          s.translation == null
              ? s.content
              : '${s.content}\u2503${s.translation}',
        _ => '',
      };
      if (newContent == currContent && !_isTransition) return;
      _isTransition = false;
      _transitionLrcLine = null;
      _transitionSyncLine = null;
      if (currContent.isNotEmpty && newContent.isNotEmpty) {
        _prevContent = currContent;
        currContent = newContent;
        _slideController?.dispose();
        _slideController = AnimationController(
          vsync: this,
          duration: const Duration(milliseconds: 500),
        );
        _slideController!.addStatusListener((status) {
          if (status == AnimationStatus.completed && mounted) {
            setState(() {
              _prevContent = '';
              _slideController?.dispose();
              _slideController = null;
            });
          }
        });
        _slideController!.forward();
      } else {
        _prevContent = '';
        currContent = newContent;
      }
    }
  }

  Widget _buildTextArea(ColorScheme scheme) {
    return _buildTopBarLyricTextTransition(
      currentContent: currContent,
      previousContent: _prevContent,
      controller: _slideController,
      scheme: scheme,
    );
  }

  bool _isLineHidden(LyricLine line) {
    if (line is SyncLyricLine) {
      return line.words.isEmpty && line.length <= const Duration(seconds: 3);
    }
    if (line is LrcLine) {
      return line.isBlank &&
          (line.length <= const Duration(seconds: 3) ||
              line.start > Duration.zero);
    }
    return false;
  }

  int? _nearestRenderableLineIndex(
    int lineIndex, {
    bool preferForward = false,
  }) {
    final lines = widget.lyric.lines;
    if (lines.isEmpty) return null;
    final clamped = lineIndex.clamp(0, lines.length - 1).toInt();
    if (!_isLineHidden(lines[clamped])) return clamped;
    if (preferForward) {
      for (int i = clamped + 1; i < lines.length; i++) {
        if (!_isLineHidden(lines[i])) return i;
      }
      for (int i = clamped - 1; i >= 0; i--) {
        if (!_isLineHidden(lines[i])) return i;
      }
    } else {
      for (int i = clamped - 1; i >= 0; i--) {
        if (!_isLineHidden(lines[i])) return i;
      }
      for (int i = clamped + 1; i < lines.length; i++) {
        if (!_isLineHidden(lines[i])) return i;
      }
    }
    return null;
  }

  void _syncToPlaybackPosition({bool preferUpcoming = true}) {
    if (!mounted) return;
    final update = lyricService.lineUpdateForLyric(
      widget.lyric,
      playbackService.position,
    );
    if (update == null) {
      lyricService.forceEmitCurrentLine();
      return;
    }
    _applyLyricLineUpdate(update, preferForward: preferUpcoming);
  }

  void _startPositionResyncWindow() {
    _positionResyncTimer ??= Timer.periodic(
      const Duration(milliseconds: 250),
      (_) => _resyncFromPositionTick(playbackService.position),
    );
    _positionResyncStopTimer?.cancel();
    _positionResyncStopTimer = Timer(const Duration(seconds: 4), () {
      _positionResyncTimer?.cancel();
      _positionResyncTimer = null;
      _positionResyncStopTimer = null;
      if (mounted &&
          _positionResyncExtensionCount < _maxPositionResyncExtensions) {
        _positionResyncExtensionCount++;
        _startPositionResyncWindow();
      }
    });
  }

  void _resyncFromPositionTick(double position) {
    if (!mounted || widget.lyric.lines.isEmpty) return;
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    if (nowMs - _lastPositionResyncMs < 200) return;
    _lastPositionResyncMs = nowMs;
    final update = lyricService.lineUpdateForLyric(widget.lyric, position);
    if (update == null) return;
    final nextLine = _nearestRenderableLineIndex(update.primaryIndex);
    if (nextLine == null) return;
    if (nextLine == _currentLineIndex) return;
    _applyLyricLineUpdate(update);
  }

  void _applyLyricLineUpdate(
    LyricLineUpdate update, {
    bool preferForward = false,
  }) {
    final lineIndex = _nearestRenderableLineIndex(
      update.primaryIndex,
      preferForward: preferForward,
    );
    if (lineIndex == null || !mounted) return;
    final currLine = widget.lyric.lines[lineIndex];
    _currentLineIndex = lineIndex;

    _scrollToken += 1;
    final token = _scrollToken;

    setState(() {
      _setContent(currLine);
    });

    late final Duration lastTime;
    if (currLine is LrcLine) {
      lastTime = currLine.length - waitFor - waitFor;
    } else if (currLine is SyncLyricLine) {
      lastTime = currLine.length - waitFor - waitFor;
    } else {
      lastTime = Duration.zero;
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (!scrollController.hasClients) return;

      scrollController.animateTo(
        0,
        duration: const Duration(milliseconds: 140),
        curve: Curves.easeOutCubic,
      );
      if (scrollController.position.maxScrollExtent > 0) {
        if (lastTime.isNegative) return;

        Future.delayed(waitFor, () {
          if (!mounted) return;
          if (!scrollController.hasClients) return;
          if (token != _scrollToken) return;

          scrollController.animateTo(
            scrollController.position.maxScrollExtent,
            duration: lastTime,
            curve: Curves.easeOutQuart,
          );
        });
      }
    });
  }

  @override
  void initState() {
    super.initState();
    final currentLine = lyricService.lineUpdateForLyric(
      widget.lyric,
      playbackService.position,
    );
    final lineIndex = currentLine == null
        ? null
        : _nearestRenderableLineIndex(currentLine.primaryIndex);
    if (lineIndex != null) {
      _currentLineIndex = lineIndex;
      _setContent(widget.lyric.lines[lineIndex]);
    } else if (widget.lyric.lines.isNotEmpty) {
      _currentLineIndex = 0;
      _setContent(widget.lyric.lines.first);
    }

    lyricLineStreamSubscription = lyricService.lyricLineStream.listen((_) {
      _syncToPlaybackPosition(preferUpcoming: false);
    });
    _playbackResyncListener = _queuePlaybackResync;
    playbackService.positionSyncNotifier.addListener(_playbackResyncListener);
    _startPositionResyncWindow();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _syncToPlaybackPosition(preferUpcoming: true);
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (_route == route) return;
    final oldRoute = _route;
    if (oldRoute != null) {
      routeVisibilityObserver.unsubscribe(this);
    }
    _route = route is PageRoute<dynamic> ? route : null;
    final pageRoute = _route;
    if (pageRoute != null) {
      routeVisibilityObserver.subscribe(this, pageRoute);
    }
  }

  void _syncWhenRouteVisible() {
    if (!mounted) return;
    lyricService.forceEmitCurrentLine();
    _startPositionResyncWindow();
    _syncToPlaybackPosition(preferUpcoming: true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _syncToPlaybackPosition(preferUpcoming: true);
    });
  }

  void _queuePlaybackResync() {
    if (!mounted) return;
    _startPositionResyncWindow();
    _syncToPlaybackPosition(preferUpcoming: true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _syncToPlaybackPosition(preferUpcoming: true);
    });
  }

  @override
  void didPush() {
    _syncWhenRouteVisible();
  }

  @override
  void didPopNext() {
    _syncWhenRouteVisible();
  }

  @override
  void activate() {
    super.activate();
    _startPositionResyncWindow();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _syncToPlaybackPosition(preferUpcoming: true);
    });
  }

  @override
  void didUpdateWidget(covariant _LyricHorizontalScrollArea oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.lyric != widget.lyric) {
      _scrollToken = 0;
      _slideController?.dispose();
      _slideController = null;
      _prevContent = '';
      _startPositionResyncWindow();
      if (widget.lyric.lines.isNotEmpty) {
        setState(() {
          final currentLine = lyricService.lineUpdateForLyric(
            widget.lyric,
            playbackService.position,
          );
          final lineIndex = currentLine == null
              ? null
              : _nearestRenderableLineIndex(currentLine.primaryIndex);
          _currentLineIndex = lineIndex ?? 0;
          _setContent(
            lineIndex == null
                ? widget.lyric.lines.first
                : widget.lyric.lines[lineIndex],
          );
        });
      }
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _syncToPlaybackPosition(preferUpcoming: true);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return ListenableBuilder(
      listenable: LyricViewController.instance,
      builder: (context, _) {
        if (_isTransition) {
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8.0),
            child: Align(
              alignment: Alignment.centerLeft,
              child: LyricTransitionTile(
                lrcLine: _transitionLrcLine,
                syncLine: _transitionSyncLine,
                enableBreathing: false,
                compact: true,
                useMaterialYouColor:
                    AppSettings.instance.useMaterialYouForTransition,
              ),
            ),
          );
        }

        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12.0),
          child: ScrollConfiguration(
            behavior: ScrollConfiguration.of(
              context,
            ).copyWith(scrollbars: false),
            child: SingleChildScrollView(
              controller: scrollController,
              scrollDirection: Axis.horizontal,
              child: Align(
                alignment: Alignment.centerLeft,
                child: _buildTextArea(scheme),
              ),
            ),
          ),
        );
      },
    );
  }

  @override
  void dispose() {
    _slideController?.dispose();
    routeVisibilityObserver.unsubscribe(this);
    lyricLineStreamSubscription.cancel();
    playbackService.positionSyncNotifier.removeListener(
      _playbackResyncListener,
    );
    _positionResyncTimer?.cancel();
    _positionResyncStopTimer?.cancel();
    scrollController.dispose();
    super.dispose();
  }
}
