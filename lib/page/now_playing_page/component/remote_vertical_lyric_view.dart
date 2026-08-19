import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:pure_music/core/enums.dart';
import 'package:pure_music/lyric/lyric.dart';
import 'package:pure_music/page/now_playing_page/component/lyric_stagger_motion.dart';
import 'package:pure_music/page/now_playing_page/component/lyric_view_controls.dart';
import 'package:pure_music/page/now_playing_page/component/lyrics_line_widget.dart';
import 'package:pure_music/play_service/remote_lyric_controller.dart';

class RemoteVerticalLyricView extends StatefulWidget {
  const RemoteVerticalLyricView({super.key});

  @override
  State<RemoteVerticalLyricView> createState() =>
      _RemoteVerticalLyricViewState();
}

class _RemoteVerticalLyricViewState extends State<RemoteVerticalLyricView> {
  static const _estimatedItemExtent = 82.0;
  final ScrollController _scrollController = ScrollController();
  final Map<int, GlobalKey> _lineKeys = {};
  RemoteLyricController? _controller;
  int? _lastLineIndex;
  Lyric? _lastLyric;
  int _jumpTriggerId = 0;
  double _jumpDeltaY = 0;

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
    if (!mounted) return;
    final snapshot = _controller!.value;
    final lyricChanged = !identical(snapshot.lyric, _lastLyric);
    final lineChanged = snapshot.currentLineIndex != _lastLineIndex;
    if (!lyricChanged && !lineChanged) return;
    final previousLineIndex = _lastLineIndex;
    _lastLyric = snapshot.lyric;
    _lastLineIndex = snapshot.currentLineIndex;
    if (!lyricChanged &&
        lineChanged &&
        previousLineIndex != null &&
        snapshot.currentLineIndex != null) {
      _jumpTriggerId++;
      _jumpDeltaY =
          ((snapshot.currentLineIndex! - previousLineIndex) *
                  _estimatedItemExtent)
              .clamp(-_estimatedItemExtent * 3, _estimatedItemExtent * 3);
    } else if (lyricChanged) {
      _lineKeys.clear();
      _jumpTriggerId = 0;
      _jumpDeltaY = 0;
    }
    if (lyricChanged || lineChanged) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToCurrent());
    }
    setState(() {});
  }

  void _scrollToCurrent() {
    if (!mounted || !_scrollController.hasClients) return;
    final index = _controller?.value.currentLineIndex;
    if (index == null) return;
    final lineContext = _lineKeys[index]?.currentContext;
    if (lineContext != null) {
      unawaited(
        Scrollable.ensureVisible(
          lineContext,
          alignment: 0.35,
          duration: const Duration(milliseconds: 420),
          curve: Curves.easeOutCubic,
        ),
      );
      return;
    }
    final viewport = _scrollController.position.viewportDimension;
    final target = (index * _estimatedItemExtent - viewport * 0.35).clamp(
      0.0,
      _scrollController.position.maxScrollExtent,
    );
    unawaited(
      _scrollController.animateTo(
        target,
        duration: const Duration(milliseconds: 420),
        curve: Curves.easeOutCubic,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final snapshot = _controller!.value;
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
      return const Center(child: Text('暂无歌词', style: TextStyle(fontSize: 22)));
    }

    return ListenableBuilder(
      listenable: LyricViewController.instance,
      builder: (context, _) {
        final config = LyricViewController.instance.renderConfig;
        final currentLineIndex = snapshot.currentLineIndex ?? 0;
        return ChangeNotifierProvider<LyricViewController>.value(
          value: LyricViewController.instance,
          child: ListView.builder(
            controller: _scrollController,
            padding: EdgeInsets.symmetric(
              vertical: MediaQuery.sizeOf(context).height * 0.12,
            ),
            itemCount: lyric.lines.length,
            itemBuilder: (context, index) {
              final distance = (index - currentLineIndex).abs();
              final opacity = distance == 0
                  ? 1.0
                  : pow(0.88, distance).toDouble().clamp(0.30, 0.90);
              final staggerDelay = config.enableStaggeredAnimation
                  ? config.staggerStyle == LyricStaggerStyle.spring
                        ? Duration(
                            milliseconds: lyricStaggerDelayMs(
                              itemIndex: index,
                              visibleStartIndex: max(0, currentLineIndex - 3),
                            ),
                          )
                        : Duration(
                            milliseconds:
                                (30 * (distance + 1) * (5 + distance) ~/ 5)
                                    .clamp(0, 600),
                          )
                  : Duration.zero;
              return SizedBox(
                key: _lineKeys[index] ??= GlobalKey(),
                child: LyricsLineWidget(
                  key: ValueKey(
                    'remote_lyric_line_${identityHashCode(lyric)}_$index',
                  ),
                  line: lyric.lines[index],
                  opacity: opacity,
                  distance: distance,
                  positionMs: snapshot.position?.inMilliseconds.toDouble(),
                  isHighlightActive: distance == 0,
                  staggerDelay: staggerDelay,
                  jumpTriggerId: _jumpTriggerId,
                  jumpDeltaY: _jumpDeltaY,
                ),
              );
            },
          ),
        );
      },
    );
  }

  @override
  void dispose() {
    _controller?.removeListener(_onLyricChanged);
    _scrollController.dispose();
    super.dispose();
  }
}
