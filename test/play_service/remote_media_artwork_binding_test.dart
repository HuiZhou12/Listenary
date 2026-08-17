import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/play_service/active_playback_session.dart';
import 'package:pure_music/play_service/remote_media_artwork.dart';
import 'package:pure_music/play_service/remote_media_artwork_binding.dart';

void main() {
  test(
    'remote artwork applies palette once and local restores its theme',
    () async {
      final activeSession = ActivePlaybackSession();
      final artwork = RemoteMediaArtworkController(
        load: (_) async => Uint8List.fromList([1, 2, 3]),
        extractPalette: (_) async => [Colors.orange, Colors.blue],
      );
      final applied = <List<Color>>[];
      var localRestores = 0;
      var configuredRestores = 0;
      final binding = RemoteMediaArtworkBinding(
        activeSession: activeSession,
        artwork: artwork,
        applyRemotePalette: (palette) => applied.add(palette),
        restoreLocalTheme: () => localRestores++,
        restoreConfiguredTheme: () => configuredRestores++,
      );
      addTearDown(() {
        binding.dispose();
        artwork.dispose();
        activeSession.dispose();
      });

      activeSession.switchTo(
        source: ActivePlaybackSessionSource.remote,
        queue: [
          ActivePlaybackSessionItem(
            title: 'Remote',
            artist: 'Artist',
            coverUri: Uri.parse('https://cover.invalid/remote.jpg'),
          ),
        ],
        currentIndex: 0,
        state: ActivePlaybackSessionState.playing,
        controlInFlight: false,
        capabilities: const ActivePlaybackSessionCapabilities(
          canPlay: false,
          canPause: true,
          canPrevious: false,
          canNext: false,
          canSeek: false,
        ),
      );
      await pumpEventQueue();

      expect(configuredRestores, 1);
      expect(applied, [
        [Colors.orange, Colors.blue],
      ]);

      activeSession.switchTo(
        source: ActivePlaybackSessionSource.local,
        queue: const [
          ActivePlaybackSessionItem(title: 'Local', artist: 'Artist'),
        ],
        currentIndex: 0,
        state: ActivePlaybackSessionState.paused,
        controlInFlight: false,
        capabilities: const ActivePlaybackSessionCapabilities(
          canPlay: true,
          canPause: false,
          canPrevious: false,
          canNext: false,
          canSeek: true,
        ),
      );

      expect(localRestores, 1);
      expect(artwork.value.status, RemoteMediaArtworkStatus.empty);
    },
  );

  test(
    'invalid remote cover keeps configured theme and never applies palette',
    () async {
      final activeSession = ActivePlaybackSession();
      final artwork = RemoteMediaArtworkController(
        load: (_) async => Uint8List.fromList([1]),
        extractPalette: (_) async => [Colors.red],
      );
      var applied = 0;
      var configuredRestores = 0;
      final binding = RemoteMediaArtworkBinding(
        activeSession: activeSession,
        artwork: artwork,
        applyRemotePalette: (_) => applied++,
        restoreLocalTheme: () {},
        restoreConfiguredTheme: () => configuredRestores++,
      );
      addTearDown(() {
        binding.dispose();
        artwork.dispose();
        activeSession.dispose();
      });

      activeSession.switchTo(
        source: ActivePlaybackSessionSource.remote,
        queue: const [
          ActivePlaybackSessionItem(title: 'Remote', artist: 'Artist'),
        ],
        currentIndex: 0,
        state: ActivePlaybackSessionState.opening,
        controlInFlight: false,
        capabilities: ActivePlaybackSessionCapabilities.none,
      );
      await pumpEventQueue();

      expect(configuredRestores, 1);
      expect(applied, 0);
      expect(artwork.value.status, RemoteMediaArtworkStatus.unavailable);
    },
  );
}
