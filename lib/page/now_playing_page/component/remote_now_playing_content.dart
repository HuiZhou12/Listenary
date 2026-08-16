import 'dart:math';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:pure_music/core/design_tokens.dart';
import 'package:pure_music/play_service/active_playback_session.dart';

class RemoteNowPlayingContent extends StatelessWidget {
  const RemoteNowPlayingContent({
    super.key,
    required this.snapshot,
    required this.queue,
    required this.immersive,
    required this.onPrevious,
    required this.onPlay,
    required this.onPause,
    required this.onNext,
  });

  final ActivePlaybackSessionSnapshot snapshot;
  final Widget queue;
  final bool immersive;
  final VoidCallback onPrevious;
  final VoidCallback onPlay;
  final VoidCallback onPause;
  final VoidCallback onNext;

  @override
  Widget build(BuildContext context) {
    assert(snapshot.source == ActivePlaybackSessionSource.remote);
    return LayoutBuilder(
      builder: (context, constraints) {
        final landscape = constraints.maxWidth >= 720;
        final content = immersive
            ? Center(child: _RemoteNowPlayingInfo(snapshot: snapshot))
            : landscape
            ? Row(
                children: [
                  Expanded(
                    child: Center(
                      child: _RemoteNowPlayingInfo(snapshot: snapshot),
                    ),
                  ),
                  Expanded(child: queue),
                ],
              )
            : Column(
                children: [
                  Expanded(
                    flex: 4,
                    child: Center(
                      child: _RemoteNowPlayingInfo(snapshot: snapshot),
                    ),
                  ),
                  Expanded(flex: 6, child: queue),
                ],
              );

        return Padding(
          padding: const EdgeInsets.fromLTRB(24, 16, 24, 12),
          child: Column(
            children: [
              Expanded(child: content),
              const SizedBox(height: 8),
              _RemotePlaybackControls(
                snapshot: snapshot,
                onPrevious: onPrevious,
                onPlay: onPlay,
                onPause: onPause,
                onNext: onNext,
              ),
            ],
          ),
        );
      },
    );
  }
}

class _RemoteNowPlayingInfo extends StatelessWidget {
  const _RemoteNowPlayingInfo({required this.snapshot});

  final ActivePlaybackSessionSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final item = snapshot.currentItem;
    return LayoutBuilder(
      builder: (context, constraints) {
        final available = min(constraints.maxWidth, constraints.maxHeight);
        final coverSize = min(280.0, max(72.0, available * 0.58));
        final textWidth = min(constraints.maxWidth, max(coverSize, 240.0));
        return FittedBox(
          fit: BoxFit.scaleDown,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                key: const Key('remote-now-playing-placeholder'),
                width: coverSize,
                height: coverSize,
                child: Center(
                  child: Icon(
                    Symbols.music_note,
                    size: coverSize * 0.42,
                    color: scheme.onSurface.withValues(alpha: 0.24),
                  ),
                ),
              ),
              const SizedBox(height: 24),
              SizedBox(
                width: textWidth,
                child: Text(
                  item?.title ?? 'Pure Music',
                  key: const Key('remote-now-playing-title'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: scheme.onSurface,
                    fontSize: 24,
                    fontWeight: AppType.weightBold,
                  ),
                ),
              ),
              const SizedBox(height: 8),
              SizedBox(
                width: textWidth,
                child: Text(
                  item?.artist ?? '',
                  key: const Key('remote-now-playing-artist'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: scheme.onSurface.withValues(alpha: 0.7),
                    fontSize: 16,
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _RemotePlaybackControls extends StatelessWidget {
  const _RemotePlaybackControls({
    required this.snapshot,
    required this.onPrevious,
    required this.onPlay,
    required this.onPause,
    required this.onNext,
  });

  final ActivePlaybackSessionSnapshot snapshot;
  final VoidCallback onPrevious;
  final VoidCallback onPlay;
  final VoidCallback onPause;
  final VoidCallback onNext;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final capabilities = snapshot.capabilities;
    final busy = snapshot.controlInFlight;
    final isPlaying = snapshot.state == ActivePlaybackSessionState.playing;
    final canToggle =
        !busy &&
        (isPlaying ? capabilities.canPause : capabilities.canPlay) &&
        (snapshot.state == ActivePlaybackSessionState.playing ||
            snapshot.state == ActivePlaybackSessionState.paused);

    return SizedBox(
      height: 56,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          IconButton(
            key: const Key('remote-now-playing-previous'),
            tooltip: capabilities.canPrevious ? '上一曲' : '已经是第一曲',
            onPressed: !busy && capabilities.canPrevious ? onPrevious : null,
            icon: const Icon(Symbols.skip_previous, fill: 1),
            iconSize: 28,
          ),
          const SizedBox(width: 16),
          IconButton(
            key: const Key('remote-now-playing-toggle'),
            tooltip: canToggle ? (isPlaying ? '暂停' : '播放') : '暂不可控制',
            onPressed: canToggle ? (isPlaying ? onPause : onPlay) : null,
            icon: Icon(isPlaying ? Symbols.pause : Symbols.play_arrow, fill: 1),
            iconSize: 36,
            color: scheme.primary,
          ),
          const SizedBox(width: 16),
          IconButton(
            key: const Key('remote-now-playing-next'),
            tooltip: capabilities.canNext ? '下一曲' : '已经是最后一曲',
            onPressed: !busy && capabilities.canNext ? onNext : null,
            icon: const Icon(Symbols.skip_next, fill: 1),
            iconSize: 28,
          ),
        ],
      ),
    );
  }
}
