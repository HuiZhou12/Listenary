import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';
import 'package:pure_music/play_service/active_playback_session.dart';

class ActiveNowPlayingLyricRegion extends StatelessWidget {
  const ActiveNowPlayingLyricRegion({super.key, required this.localChild});

  final Widget localChild;

  @override
  Widget build(BuildContext context) {
    final usesRemoteMedia = context.select<ActivePlaybackSession, bool>(
      (session) =>
          session.value.source == ActivePlaybackSessionSource.remote,
    );
    if (!usesRemoteMedia) return localChild;

    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Symbols.lyrics,
            size: 36,
            color: scheme.onSurfaceVariant.withValues(alpha: 0.55),
          ),
          const SizedBox(height: 8),
          Text(
            '暂无歌词',
            style: TextStyle(
              color: scheme.onSurfaceVariant.withValues(alpha: 0.7),
            ),
          ),
        ],
      ),
    );
  }
}
