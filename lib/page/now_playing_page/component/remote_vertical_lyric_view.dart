// ignore_for_file: invalid_use_of_visible_for_testing_member

import 'dart:async';
import 'dart:math' show max, pow, sin;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:provider/provider.dart';
import 'package:pure_music/core/enums.dart';
import 'package:pure_music/core/route_visibility.dart';
import 'package:pure_music/lyric/lrc.dart';
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
  /// 首次进入 / 回到播放页（以及切歌后歌词刚就绪）时的定位标志。
  /// 对照本地视图 `vertical_lyric_view.dart` 的 `_needsInitialScroll`：
  /// 这段时间内的定位一律零时长跳变，不能播滚动动画，
  /// 否则会先动画到一个估算位置、再动画矫正一次，肉眼可见地「重新对准」。
  bool _needsInitialScroll = false;
  Lyric? _renderLineLyric;
  final Map<int, LyricLine> _renderLines = {};
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
    // 回页定位一律零时长跳变（对照本地 `_syncWhenRouteVisible()` →
    // `_syncToPlaybackPosition(duration: Duration.zero)`）。
    _needsInitialScroll = true;
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
      // 换歌词/切歌：渲染行缓存随歌词一起失效（`_renderLineFor` 另有同源兜底判断）。
      _renderLineLyric = snapshot.lyric;
      _renderLines.clear();
      _jumpTriggerId = 0;
      _jumpDeltaY = 0;
      _staggerVisibleStartIndex = 0;
      // 切歌后歌词刚就绪时列表是从头/旧位置重建的，直接跳到当前行
      // （对照本地：换歌词走 `_syncToPlaybackPosition(duration: Duration.zero)`）。
      _needsInitialScroll = true;
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
      // 用户接手滚动后，后续跟随恢复走正常动画，不再用首次定位的跳变。
      _needsInitialScroll = false;
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
  ///
  /// 首次定位（[_needsInitialScroll]）期间 **一律零时长跳变**，不播滚动动画：
  /// 对照本地 `_syncWhenRouteVisible()` → `_syncToPlaybackPosition(duration: Duration.zero)`。
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
      final lines = lyric.lines;
      if (index < 0 ||
          index >= lines.length ||
          lyricLineIsFilteredBlank(lines[index])) {
        // 该行本身不渲染（空白行没有行 widget），估算一次即可，不进入重试。
        _pendingScrollRetries = 0;
        if (!_scrollController.hasClients) {
          _scheduleScrollRetry();
          return;
        }
        if (_needsInitialScroll ||
            _scrollState != _RemoteLyricScrollState.programScrolling) {
          _scrollToCurrent(immediate: _needsInitialScroll);
        }
        // 空白行永远不会构建出行 widget，精确目标不可得，首次定位到此为止。
        _needsInitialScroll = false;
        return;
      }
      if (_revealOffsetForLine(index) != null) {
        // 当前行已构建：精确 reveal（已对齐时不会产生位移，幂等）。
        // 首次定位用零时长直接跳到精确偏移，之后恢复播放中的平滑跟随。
        _pendingScrollRetries = 0;
        if (!_scrollController.hasClients) {
          // 视图还没挂到滚动控制器上，下一帧再对齐，保持首次定位的跳变模式。
          _scheduleScrollRetry();
          return;
        }
        _scrollToCurrent(immediate: _needsInitialScroll);
        _needsInitialScroll = false;
        return;
      }
      // 当前行还没构建：先按已构建行实测出的目标「引导」到大致位置，
      // 让当前行进入 ListView 的构建范围，下一帧再对齐到精确偏移。
      // 首次定位时这一步是零时长跳变，不会呈现为可见的滚动动画；
      // 其余情况保持原有的动画滚动。
      // （非首次定位时，滚动动画进行中不重复发起，避免每帧重启动画；
      // 估算已到位也不重复发起。）
      if (_scrollController.hasClients &&
          (_needsInitialScroll ||
              _scrollState != _RemoteLyricScrollState.programScrolling) &&
          (_estimatedScrollOffsetForLine(index) - _scrollController.offset)
                  .abs() >
              1.0) {
        _scrollToCurrent(immediate: _needsInitialScroll);
      }
      _scheduleScrollRetry();
    });
  }

  void _scheduleScrollRetry() {
    if (_pendingScrollRetries >= _maxPendingScrollRetries) {
      _pendingScrollRetries = 0;
      // 重试用尽仍未拿到精确目标：放弃首次定位的跳变模式，交回正常跟随。
      _needsInitialScroll = false;
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

  /// 把视口对齐到当前行。
  ///
  /// [immediate] 为 true 时用零时长跳变（`_animateTo` 会在时长 ≤16ms 时直接 jump），
  /// 用于首次进入 / 回到播放页 / 切歌后的定位；其余情况保持原有的 440~600ms 平滑跟随。
  /// 目标行已构建时用 `getOffsetToReveal` 的精确偏移；未构建时退回行高估算
  /// （估算只用于把当前行「引导」进构建范围，调用方会用 [immediate] 保证它不表现为动画）。
  void _scrollToCurrent({bool immediate = false}) {
    if (!mounted || !_scrollController.hasClients) return;
    final snapshot = _controller?.value;
    if (snapshot == null) return;
    final index = _displayIndex(snapshot);
    final lyric = snapshot.lyric;
    if (lyric == null || lyric.lines.isEmpty) return;

    final distance = (index - (_lastLineIndex ?? index)).abs();
    final duration = immediate
        ? Duration.zero
        : _scrollDurationForDistance(
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

  /// 取某一行交给 [LyricsLineWidget] 的渲染对象。
  ///
  /// 在线歌词源只给行级时间戳时（普通 LRC → [LrcLine]），行内没有逐词时间，
  /// painter 的 LRC 分支只会「整行直接点亮」，没有扫词推进；
  /// 而本地对同类数据的做法是给整行合成了一个覆盖全行的单词
  /// （见 `lyric_format.dart` 的 `_parseBasicLrc` 与 `matcher.dart` 的酷狗同步歌词分支），
  /// 于是当前行会按行内进度逐字扫过高亮。
  /// 这里对在线歌词做同样的事，让在线普通 LRC 与本地观感一致。
  ///
  /// 只替换交给行组件的**渲染对象**，不改动 `lyric.lines`：
  /// 行号、原文/翻译/罗马音分组语义、逐行 seek 与行切换时间轴都不变。
  /// 转换结果按行缓存，避免每帧新建对象导致行高缓存与 painter 反复失效。
  LyricLine _renderLineFor(Lyric lyric, int index) {
    if (!identical(_renderLineLyric, lyric)) {
      _renderLineLyric = lyric;
      _renderLines.clear();
    }
    final cached = _renderLines[index];
    if (cached != null) return cached;
    final converted =
        _convertLrcLineForLineProgress(lyric, index) ?? lyric.lines[index];
    _renderLines[index] = converted;
    return converted;
  }

  /// 无逐词时间的普通 LRC 行 → 只有一个「整行单词」的同步行；不能安全转换时返回 null。
  SyncLyricLine? _convertLrcLineForLineProgress(Lyric lyric, int index) {
    final line = lyric.lines[index];
    if (line is! LrcLine) return null;
    // 元数据行有独立样式（painter 的 `isMetadata` 分支），保持原样。
    if (line.isMetadata) return null;
    final content = line.content;
    if (content.isEmpty) return null;
    // 多翻译用 ┃ 嵌在正文里，只有 LRC 绘制分支会拆开它，保持原样。
    if (content.contains('\u2503')) return null;
    var length = line.length;
    if (length <= Duration.zero) {
      // 行时长缺失时用后面的行起点兜底（与 LRC 解析器的行时长规则一致）。
      for (var next = index + 1; next < lyric.lines.length; next++) {
        final gap = lyric.lines[next].start - line.start;
        if (gap > Duration.zero) {
          length = gap;
          break;
        }
      }
    }
    // 仍然拿不到正的行时长就不转换：单词时长为 0 时扫词进度会瞬间到 1，
    // 观感和现在的整行点亮没有区别。
    if (length <= Duration.zero) return null;
    return SyncLyricLine(
      line.start,
      length,
      [SyncLyricWord(line.start, length, content)],
      line.translation,
    )..romanLyric = line.romanLyric;
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
                                    // 在线普通 LRC（无逐词时间）用「整行单词」渲染，
                                    // 让当前行也有行内扫词推进，与本地观感一致。
                                    line: _renderLineFor(lyric, index),
                                    opacity: opacity,
                                    distance: distance,
                                    positionMs: position.inMilliseconds
                                        .toDouble(),
                                    // 在线播放位置来自远程时间线，不能用本地 BASS 位置，
                                    // 因此保持外部位置（内部进度 ticker 关闭），
                                    // 扫词由上层每 50ms 推进的快照位置驱动。
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
