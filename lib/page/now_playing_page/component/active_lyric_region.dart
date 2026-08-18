import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:pure_music/page/now_playing_page/component/remote_vertical_lyric_view.dart';
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

    return const RemoteVerticalLyricView();
  }
}
