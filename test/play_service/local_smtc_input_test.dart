import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/native/rust/api/smtc_flutter.dart';
import 'package:pure_music/play_service/local_smtc_input.dart';

void main() {
  test('stores local metadata, timeline and state as one immutable input', () {
    const input = LocalSmtcInput(
      title: 'Title',
      artist: 'Artist',
      album: 'Album',
      durationMs: 180000,
      path: r'C:\Music\song.mp3',
      state: SMTCState.playing,
      positionMs: 12000,
    );

    expect(input.title, 'Title');
    expect(input.artist, 'Artist');
    expect(input.album, 'Album');
    expect(input.durationMs, 180000);
    expect(input.path, r'C:\Music\song.mp3');
    expect(input.state, SMTCState.playing);
    expect(input.positionMs, 12000);
  });

  test('equality includes all local SMTC fields', () {
    const first = LocalSmtcInput(
      title: 'Title',
      artist: 'Artist',
      album: 'Album',
      durationMs: 1000,
      path: r'C:\Music\song.mp3',
      state: SMTCState.paused,
      positionMs: 10,
    );
    const same = LocalSmtcInput(
      title: 'Title',
      artist: 'Artist',
      album: 'Album',
      durationMs: 1000,
      path: r'C:\Music\song.mp3',
      state: SMTCState.paused,
      positionMs: 10,
    );
    const changed = LocalSmtcInput(
      title: 'Title',
      artist: 'Artist',
      album: 'Album',
      durationMs: 1000,
      path: r'C:\Music\song.mp3',
      state: SMTCState.paused,
      positionMs: 11,
    );

    expect(first, same);
    expect(first.hashCode, same.hashCode);
    expect(first, isNot(changed));
  });
}
