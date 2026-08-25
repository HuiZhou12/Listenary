import 'dart:math' show max, min;

import 'package:pure_music/lyric/lrc.dart';
import 'package:pure_music/lyric/lyric.dart';
import 'package:pure_music/lyric/ttml.dart' show Ttml;

const int lyricWordPreSwitchMs = 320;

class _ParallelLyricGroup {
  const _ParallelLyricGroup(this.members, this.endMs);

  final List<int> members;
  final int endMs;
}

int _lineRenderStartMs(LyricLine line) {
  if (line is SyncLyricLine && line.words.isNotEmpty) {
    return line.words.first.start.inMilliseconds;
  }
  return line.start.inMilliseconds;
}

int _lineRenderEndMs(Lyric lyric, LyricLine line) {
  var end = line.start.inMilliseconds + line.length.inMilliseconds;
  if (line is SyncLyricLine && line.words.isNotEmpty) {
    final lastWord = line.words.last;
    final wordEnd =
        lastWord.start.inMilliseconds + lastWord.length.inMilliseconds;
    if (lyric is! Ttml) return wordEnd;
    end = max(end, wordEnd);
  }
  if (lyric is Ttml && line is SyncLyricLine) {
    if (line.bgEnd != null) end = max(end, line.bgEnd!.inMilliseconds);
    if (line.bgWords.isNotEmpty) {
      final lastBgWord = line.bgWords.last;
      end = max(
        end,
        lastBgWord.start.inMilliseconds + lastBgWord.length.inMilliseconds,
      );
    }
  }
  return end;
}

List<_ParallelLyricGroup> _buildParallelLyricGroups({
  required Lyric lyric,
  required List<int> lineStartMs,
  required List<int> lineEndMs,
}) {
  if (lyric is! Ttml || lineStartMs.length < 2 || lineEndMs.length < 2) {
    return const [];
  }
  final groups = <_ParallelLyricGroup>[];
  var members = <int>[0];
  var sharedStart = lineStartMs.first;
  var sharedEnd = lineEndMs.first;
  var groupEnd = lineEndMs.first;
  for (var i = 1; i < lyric.lines.length; i++) {
    final start = lineStartMs[i];
    final end = lineEndMs[i];
    final overlap = min(sharedEnd, end) - max(sharedStart, start);
    if (overlap > lyricWordPreSwitchMs) {
      members.add(i);
      sharedStart = max(sharedStart, start);
      sharedEnd = min(sharedEnd, end);
      groupEnd = max(groupEnd, end);
      continue;
    }
    if (members.length > 1) {
      groups.add(_ParallelLyricGroup(List.unmodifiable(members), groupEnd));
    }
    members = <int>[i];
    sharedStart = start;
    sharedEnd = end;
    groupEnd = end;
  }
  if (members.length > 1) {
    groups.add(_ParallelLyricGroup(List.unmodifiable(members), groupEnd));
  }
  return groups;
}

int lyricLineSwitchStartMs({
  required int previousSwitchStartMs,
  required int previousLineEndMs,
  required int nextLineStartMs,
  required bool preserveSingleWordTiming,
}) {
  var switchStart = max(
    previousSwitchStartMs,
    nextLineStartMs - lyricWordPreSwitchMs,
  );
  if (preserveSingleWordTiming) {
    switchStart = max(switchStart, min(previousLineEndMs, nextLineStartMs));
  }
  return switchStart;
}

List<int> lyricLineRenderStartsFor(Lyric lyric) =>
    lyric.lines.map(_lineRenderStartMs).toList(growable: false);

List<int> lyricLineRenderEndsFor(Lyric lyric) => lyric.lines
    .map((line) => _lineRenderEndMs(lyric, line))
    .toList(growable: false);

List<int> lyricLineSwitchStartsFor(Lyric lyric) {
  final starts = lyricLineRenderStartsFor(lyric);
  final ends = lyricLineRenderEndsFor(lyric);
  final switches = List<int>.of(starts);
  final groupsByLine = <int, _ParallelLyricGroup>{};
  for (final group in _buildParallelLyricGroups(
    lyric: lyric,
    lineStartMs: starts,
    lineEndMs: ends,
  )) {
    for (final member in group.members) {
      groupsByLine[member] = group;
    }
  }
  for (var i = 1; i < lyric.lines.length; i++) {
    final previousGroup = groupsByLine[i - 1];
    if (previousGroup != null && identical(previousGroup, groupsByLine[i])) {
      continue;
    }
    final line = lyric.lines[i];
    if (line is! SyncLyricLine || line.words.isEmpty) continue;
    final previousLine = lyric.lines[i - 1];
    switches[i] = lyricLineSwitchStartMs(
      previousSwitchStartMs: previousGroup?.endMs ?? switches[i - 1],
      previousLineEndMs: ends[i - 1],
      nextLineStartMs: starts[i],
      preserveSingleWordTiming:
          lyric is! Ttml &&
          previousLine is SyncLyricLine &&
          previousLine.words.length == 1,
    );
  }
  return switches;
}

bool lyricLineIsFilteredBlank(LyricLine line) {
  if (line is SyncLyricLine) {
    return line.words.isEmpty && line.length <= const Duration(seconds: 3);
  }
  if (line is LrcLine) {
    return line.isBlank &&
        (line.length <= const Duration(seconds: 3) ||
            line.start > Duration.zero);
  }
  return false;
}

int? lyricLineIndexAt(Lyric lyric, Duration position) {
  if (lyric.lines.isEmpty) return null;
  final starts = lyricLineSwitchStartsFor(lyric);
  final positionMs = position.inMilliseconds;
  var result = 0;
  for (var i = 0; i < starts.length; i++) {
    if (starts[i] > positionMs) break;
    result = i;
  }
  if (!lyricLineIsFilteredBlank(lyric.lines[result])) return result;
  for (var i = result - 1; i >= 0; i--) {
    if (!lyricLineIsFilteredBlank(lyric.lines[i])) return i;
  }
  for (var i = result + 1; i < lyric.lines.length; i++) {
    if (!lyricLineIsFilteredBlank(lyric.lines[i])) return i;
  }
  return result;
}

LyricLineUpdate lyricLineUpdateAt(Lyric lyric, Duration position) {
  if (lyric.lines.isEmpty) {
    return const LyricLineUpdate(primaryIndex: 0, activeIndices: []);
  }
  final positionMs = position.inMilliseconds;
  final starts = lyricLineRenderStartsFor(lyric);
  final ends = lyricLineRenderEndsFor(lyric);
  final primary = lyricLineIndexAt(lyric, position) ?? 0;
  final active = <int>[];
  if (lyric is Ttml) {
    for (var i = 0; i < lyric.lines.length; i++) {
      if (positionMs >= starts[i] && positionMs < ends[i]) active.add(i);
    }
  } else if (!lyricLineIsFilteredBlank(lyric.lines[primary])) {
    active.add(primary);
  }

  final layout = active.toSet();
  final groups = _buildParallelLyricGroups(
    lyric: lyric,
    lineStartMs: starts,
    lineEndMs: ends,
  );
  for (final group in groups) {
    if (!group.members.contains(primary) || positionMs >= group.endMs) {
      continue;
    }
    for (final member in group.members) {
      if (starts[member] - positionMs <= lyricWordPreSwitchMs) {
        layout.add(member);
      }
    }
    break;
  }
  return LyricLineUpdate(
    primaryIndex: primary,
    activeIndices: List.unmodifiable(active),
    layoutIndices: (layout.toList()..sort()).toList(growable: false),
  );
}

int? lyricHighlightDeadlineMsForLine(Lyric lyric, int lineIndex) {
  if (lineIndex < 0 || lineIndex >= lyric.lines.length) return null;
  final line = lyric.lines[lineIndex];
  if (lyric is! Ttml && line is SyncLyricLine && line.words.length == 1) {
    return null;
  }

  final starts = lyricLineRenderStartsFor(lyric);
  final ends = lyricLineRenderEndsFor(lyric);
  _ParallelLyricGroup? group;
  for (final candidate in _buildParallelLyricGroups(
    lyric: lyric,
    lineStartMs: starts,
    lineEndMs: ends,
  )) {
    if (candidate.members.contains(lineIndex)) {
      group = candidate;
      break;
    }
  }
  for (var i = lineIndex + 1; i < lyric.lines.length; i++) {
    if (group?.members.contains(i) == true ||
        lyricLineIsFilteredBlank(lyric.lines[i])) {
      continue;
    }
    final next = lyric.lines[i];
    return next is SyncLyricLine && next.words.isNotEmpty
        ? (group == null
              ? starts[i] - lyricWordPreSwitchMs
              : max(group.endMs, starts[i] - lyricWordPreSwitchMs))
        : starts[i];
  }
  return null;
}
