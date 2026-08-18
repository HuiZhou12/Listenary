import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:pure_music/core/enums.dart';
import 'package:pure_music/lyric/lyric.dart';
import 'package:pure_music/page/now_playing_page/component/lyric_view_controls.dart';
import 'package:pure_music/play_service/remote_lyric_controller.dart';

class RemoteVerticalLyricView extends StatefulWidget {
  const RemoteVerticalLyricView({super.key});

  @override
  State<RemoteVerticalLyricView> createState() =>
      _RemoteVerticalLyricViewState();
}

class _RemoteVerticalLyricViewState extends State<RemoteVerticalLyricView> {
  static const _itemExtent = 124.0;
  final ScrollController _scrollController = ScrollController();
  RemoteLyricController? _controller;
  int? _lastLineIndex;
  Lyric? _lastLyric;

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
    _lastLyric = snapshot.lyric;
    _lastLineIndex = snapshot.currentLineIndex;
    if (lyricChanged || lineChanged) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToCurrent());
    }
    setState(() {});
  }

  void _scrollToCurrent() {
    if (!mounted || !_scrollController.hasClients) return;
    final index = _controller?.value.currentLineIndex;
    if (index == null) return;
    final viewport = _scrollController.position.viewportDimension;
    final target = (index * _itemExtent - viewport * 0.35).clamp(
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
        return ListView.builder(
          controller: _scrollController,
          itemExtent: _itemExtent,
          padding: EdgeInsets.symmetric(
            vertical: MediaQuery.sizeOf(context).height * 0.12,
          ),
          itemCount: lyric.lines.length,
          itemBuilder: (context, index) => _RemoteLyricLine(
            line: lyric.lines[index],
            active: index == snapshot.currentLineIndex,
            alignment: config.textAlign,
            showTranslation: config.showTranslation,
            showRoman: config.showRoman,
            fontSize: config.baseFontSize,
            translationFontSize: config.translationBaseFontSize,
            fontWeight: config.discreteFontWeight(),
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

class _RemoteLyricLine extends StatelessWidget {
  const _RemoteLyricLine({
    required this.line,
    required this.active,
    required this.alignment,
    required this.showTranslation,
    required this.showRoman,
    required this.fontSize,
    required this.translationFontSize,
    required this.fontWeight,
  });

  final LyricLine line;
  final bool active;
  final LyricTextAlign alignment;
  final bool showTranslation;
  final bool showRoman;
  final double fontSize;
  final double translationFontSize;
  final FontWeight fontWeight;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textAlign = switch (alignment) {
      LyricTextAlign.left => TextAlign.left,
      LyricTextAlign.center => TextAlign.center,
      LyricTextAlign.right => TextAlign.right,
    };
    final crossAxisAlignment = switch (alignment) {
      LyricTextAlign.left => CrossAxisAlignment.start,
      LyricTextAlign.center => CrossAxisAlignment.center,
      LyricTextAlign.right => CrossAxisAlignment.end,
    };
    final content = remoteLyricLineContent(line);
    return AnimatedOpacity(
      duration: const Duration(milliseconds: 260),
      opacity: active ? 1 : 0.48,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: crossAxisAlignment,
          children: [
            AnimatedDefaultTextStyle(
              duration: const Duration(milliseconds: 260),
              style: TextStyle(
                color: active ? scheme.onSurface : scheme.onSurfaceVariant,
                fontSize: active ? fontSize : fontSize * 0.86,
                fontWeight: active ? fontWeight : FontWeight.w500,
                height: 1.2,
              ),
              textAlign: textAlign,
              child: Text(
                content,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (showTranslation && line.translation?.isNotEmpty == true)
              Text(
                line.translation!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: textAlign,
                style: TextStyle(
                  color: scheme.onSurfaceVariant,
                  fontSize: translationFontSize,
                ),
              ),
            if (showRoman && line.romanLyric?.isNotEmpty == true)
              Text(
                line.romanLyric!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: textAlign,
                style: TextStyle(
                  color: scheme.onSurfaceVariant,
                  fontSize: translationFontSize,
                ),
              ),
          ],
        ),
      ),
    );
  }
}
