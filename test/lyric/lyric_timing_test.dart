import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/lyric/lrc.dart';
import 'package:pure_music/lyric/lyric.dart';
import 'package:pure_music/lyric/lyric_timing.dart';
import 'package:pure_music/lyric/ttml.dart';

void main() {
  test('ordinary lines switch at their line start', () {
    final lyric = Lrc([
      LrcLine(const Duration(seconds: 1), 'one', requiredIsBlank: false),
      LrcLine(const Duration(seconds: 5), 'two', requiredIsBlank: false),
    ], LyricFormat.local);

    expect(lyricLineSwitchStartsFor(lyric), [1000, 5000]);
    expect(lyricLineIndexAt(lyric, const Duration(milliseconds: 4999)), 0);
    expect(lyricLineIndexAt(lyric, const Duration(seconds: 5)), 1);
  });

  test('word lines switch 320ms early', () {
    final lyric = Lyric([
      SyncLyricLine(const Duration(seconds: 1), const Duration(seconds: 2), [
        SyncLyricWord(
          const Duration(seconds: 1),
          const Duration(milliseconds: 500),
          'one',
        ),
      ]),
      SyncLyricLine(const Duration(seconds: 4), const Duration(seconds: 2), [
        SyncLyricWord(
          const Duration(seconds: 4),
          const Duration(milliseconds: 500),
          'two',
        ),
      ]),
    ]);

    expect(lyricLineSwitchStartsFor(lyric), [1000, 3680]);
    expect(lyricLineIndexAt(lyric, const Duration(milliseconds: 3679)), 0);
    expect(lyricLineIndexAt(lyric, const Duration(milliseconds: 3680)), 1);
  });

  test('single-word line does not switch before its actual end', () {
    final lyric = Lyric([
      SyncLyricLine(const Duration(seconds: 1), const Duration(seconds: 2), [
        SyncLyricWord(
          const Duration(seconds: 1),
          const Duration(seconds: 3),
          'one',
        ),
      ]),
      SyncLyricLine(const Duration(seconds: 4), const Duration(seconds: 2), [
        SyncLyricWord(
          const Duration(seconds: 4),
          const Duration(milliseconds: 500),
          'two',
        ),
      ]),
    ]);

    expect(lyricLineSwitchStartsFor(lyric), [1000, 4000]);
  });

  test('short blank lines resolve to the nearest renderable line', () {
    final lyric = Lrc([
      LrcLine(const Duration(seconds: 1), 'one', requiredIsBlank: false),
      LrcLine(const Duration(seconds: 2), '', requiredIsBlank: true)
        ..length = const Duration(seconds: 1),
      LrcLine(const Duration(seconds: 5), 'two', requiredIsBlank: false),
    ], LyricFormat.local);

    expect(lyricLineIndexAt(lyric, const Duration(seconds: 2)), 0);
    expect(lyricLineIndexAt(lyric, const Duration(seconds: 3)), 0);
    expect(lyricLineIndexAt(lyric, const Duration(seconds: 5)), 2);
  });

  test('provides active parallel lines for the shared lyric view', () {
    final lyric = Ttml([
      SyncLyricLine(const Duration(seconds: 1), const Duration(seconds: 3), [
        SyncLyricWord(
          const Duration(seconds: 1),
          const Duration(seconds: 3),
          'one',
        ),
      ]),
      SyncLyricLine(
        const Duration(milliseconds: 2500),
        const Duration(seconds: 3),
        [
          SyncLyricWord(
            const Duration(milliseconds: 2500),
            const Duration(seconds: 3),
            'two',
          ),
        ],
      ),
    ]);

    final update = lyricLineUpdateAt(lyric, const Duration(milliseconds: 2600));
    expect(update.primaryIndex, 1);
    expect(update.activeIndices, [0, 1]);
    expect(update.layoutIndices, [0, 1]);
  });

  test('TTML overlapping word lines keep their parallel group', () {
    final lyric = Ttml([
      SyncLyricLine(const Duration(seconds: 1), const Duration(seconds: 3), [
        SyncLyricWord(
          const Duration(seconds: 1),
          const Duration(seconds: 3),
          'one',
        ),
      ]),
      SyncLyricLine(
        const Duration(milliseconds: 2500),
        const Duration(seconds: 3),
        [
          SyncLyricWord(
            const Duration(milliseconds: 2500),
            const Duration(seconds: 3),
            'two',
          ),
        ],
      ),
    ]);

    expect(lyricLineSwitchStartsFor(lyric), [1000, 2500]);
    expect(lyricLineIndexAt(lyric, const Duration(milliseconds: 2600)), 1);
  });
}
