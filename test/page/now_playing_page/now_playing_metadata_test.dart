import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/native/bass/bass_player.dart';
import 'package:pure_music/page/now_playing_page/component/now_playing_background.dart';
import 'package:pure_music/page/now_playing_page/page.dart';
import 'package:pure_music/play_service/active_playback_session.dart';
import 'package:pure_music/play_service/remote_media_artwork.dart';

void main() {
  test('remote metadata replaces only local title and artist', () {
    final metadata = resolveNowPlayingMetadata(
      snapshot: _snapshot(
        source: ActivePlaybackSessionSource.remote,
        title: 'Remote title',
        artist: 'Remote artist',
      ),
      localTitle: 'A/Z',
      localArtist: 'Local artist',
    );

    expect(metadata.title, 'Remote title');
    expect(metadata.artist, 'Remote artist');
    expect(metadata.coverUri, Uri.parse('https://cover.invalid/remote.jpg'));
  });

  test('local metadata keeps the existing title and artist', () {
    final metadata = resolveNowPlayingMetadata(
      snapshot: _snapshot(source: ActivePlaybackSessionSource.local),
      localTitle: 'A/Z',
      localArtist: 'Local artist',
    );

    expect(metadata.title, 'A/Z');
    expect(metadata.artist, 'Local artist');
    expect(metadata.coverUri, isNull);
  });

  test('inactive metadata keeps existing defaults', () {
    final metadata = resolveNowPlayingMetadata(
      snapshot: ActivePlaybackSessionSnapshot.inactive(revision: 3),
      localTitle: null,
      localArtist: null,
    );

    expect(metadata.title, 'Pure Music');
    expect(metadata.artist, 'Enjoy Music');
    expect(metadata.coverUri, isNull);
  });

  test('remote background removes every local media input', () {
    final localInputs = NowPlayingBackgroundInputs(
      albumCoverBytes: Uint8List.fromList([1, 2, 3]),
      dominantColor: Colors.red,
      spectrumStream: const Stream.empty(),
      enableAnimation: true,
      isVisible: true,
      playerState: PlayerState.playing,
      audioReactiveFlow: true,
      preExtractedColors: const [Colors.red, Colors.blue],
    );

    final projection = resolveNowPlayingBackgroundInputs(
      snapshot: _snapshot(source: ActivePlaybackSessionSource.remote),
      localInputs: localInputs,
    );

    expect(projection.albumCoverBytes, isNull);
    expect(projection.dominantColor, isNull);
    expect(projection.spectrumStream, isNull);
    expect(projection.preExtractedColors, isEmpty);
    expect(projection.enableAnimation, isTrue);
    expect(projection.audioReactiveFlow, isFalse);
    expect(projection.playerState, PlayerState.playing);
    expect(projection.isVisible, isTrue);
  });

  test('remote background consumes the shared cover bytes and palette', () {
    final projection = resolveNowPlayingBackgroundInputs(
      snapshot: _snapshot(source: ActivePlaybackSessionSource.remote),
      localInputs: const NowPlayingBackgroundInputs(
        enableAnimation: true,
        isVisible: true,
        playerState: PlayerState.paused,
        audioReactiveFlow: true,
      ),
      remoteArtwork: RemoteMediaArtworkSnapshot.ready(
        revision: 1,
        bytes: Uint8List.fromList([1, 2, 3]),
        palette: const [Colors.red, Colors.blue],
      ),
    );

    expect(projection.albumCoverBytes, orderedEquals([1, 2, 3]));
    expect(projection.preExtractedColors, [Colors.red, Colors.blue]);
    expect(projection.dominantColor, Colors.red);
    expect(projection.spectrumStream, isNull);
    expect(projection.audioReactiveFlow, isFalse);
  });

  test('local and inactive backgrounds preserve the original inputs', () {
    const localInputs = NowPlayingBackgroundInputs(
      enableAnimation: true,
      isVisible: true,
      playerState: PlayerState.paused,
    );

    for (final snapshot in [
      _snapshot(source: ActivePlaybackSessionSource.local),
      ActivePlaybackSessionSnapshot.inactive(revision: 2),
    ]) {
      expect(
        resolveNowPlayingBackgroundInputs(
          snapshot: snapshot,
          localInputs: localInputs,
        ),
        same(localInputs),
      );
    }
  });
}

ActivePlaybackSessionSnapshot _snapshot({
  required ActivePlaybackSessionSource source,
  String title = 'Title',
  String artist = 'Artist',
}) {
  return ActivePlaybackSessionSnapshot.active(
    revision: 1,
    source: source,
    queue: [
      ActivePlaybackSessionItem(
        title: title,
        artist: artist,
        coverUri: source == ActivePlaybackSessionSource.remote
            ? Uri.parse('https://cover.invalid/remote.jpg')
            : null,
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
}
