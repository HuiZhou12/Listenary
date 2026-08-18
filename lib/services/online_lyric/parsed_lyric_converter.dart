import 'package:pure_music/core/settings.dart';
import 'package:pure_music/core/utils.dart' as utils;
import 'package:pure_music/lyric/exclude_data.dart';
import 'package:pure_music/lyric/lrc.dart';
import 'package:pure_music/lyric/lyric.dart';
import 'package:pure_music/lyric/lyric_stripper.dart';
import 'package:pure_music/lyric/qrc.dart';
import 'package:pure_music/services/online_lyric/models/lyric_entry.dart'
    hide LyricFormat;

Lyric? parsedLyricToLyric(ParsedLyricResult parsed, {String? rawText}) {
  utils.logger.i(
    '[parsedToLyric] hasWordByWord=${parsed.hasWordByWord} '
    'format=${parsed.format.name} lines=${parsed.lines.length}',
  );
  if (parsed.hasWordByWord) {
    final syncLines = <SyncLyricLine>[];
    for (final entry in parsed.lines) {
      final lineContent = entry.content;
      if (lineContent.isNotEmpty && LrcLine.isLyricMetadataLine(lineContent)) {
        continue;
      }

      if (entry.words != null && entry.words!.isNotEmpty) {
        final words = entry.words!
            .map((word) => SyncLyricWord(word.start, word.length, word.content))
            .toList();
        final length = entry.nextTime - entry.start;
        syncLines.add(
          SyncLyricLine(entry.start, length, words, entry.translation)
            ..romanLyric = entry.romanization,
        );
      } else {
        final length = entry.nextTime - entry.start;
        if (entry.content.isEmpty) {
          syncLines.add(SyncLyricLine(entry.start, length, []));
        } else {
          syncLines.add(
            SyncLyricLine(entry.start, length, [
              SyncLyricWord(entry.start, length, entry.content),
            ], entry.translation)..romanLyric = entry.romanization,
          );
        }
      }
    }
    return stripOnlineLyricMetadata(Qrc(syncLines, LyricFormat.local, rawText));
  }

  final unsyncLines = <LrcLine>[];
  for (var index = 0; index < parsed.lines.length; index++) {
    final entry = parsed.lines[index];
    if (entry.content.isNotEmpty &&
        LrcLine.isLyricMetadataLine(entry.content)) {
      continue;
    }

    final line = LrcLine(
      entry.start,
      entry.content,
      requiredIsBlank: entry.content.isEmpty,
      translation: entry.translation,
    )..romanLyric = entry.romanization;
    if (entry.content.isEmpty) {
      line.length = entry.nextTime - entry.start;
    } else if (index < parsed.lines.length - 1) {
      line.length = parsed.lines[index + 1].start - entry.start;
    } else {
      line.length = entry.nextTime - entry.start;
    }
    unsyncLines.add(line);
  }
  return stripOnlineLyricMetadata(Lrc(unsyncLines, LyricFormat.web, rawText));
}

Lyric stripOnlineLyricMetadata(Lyric lyric) {
  if (lyric.lines.isEmpty || AppSettings.instance.keepLyricMetadata) {
    return lyric;
  }
  final options = StripOptions(
    keywords: defaultExcludeKeywords,
    regexes: defaultExcludeRegexes
        .map((pattern) => RegExp(pattern, caseSensitive: false))
        .toList(),
    softRegexes: defaultExcludeSoftRegexes
        .map((pattern) => RegExp(pattern, caseSensitive: false))
        .toList(),
  );
  final filtered = stripLyricMetadata(lyric.lines, options);
  if (!identical(lyric.lines, filtered)) {
    lyric.lines
      ..clear()
      ..addAll(filtered);
  }
  return lyric;
}
