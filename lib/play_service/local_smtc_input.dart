import 'package:pure_music/native/rust/api/smtc_flutter.dart';

final class LocalSmtcInput {
  const LocalSmtcInput({
    required this.title,
    required this.artist,
    required this.album,
    required this.durationMs,
    required this.path,
    required this.state,
    required this.positionMs,
  });

  final String title;
  final String artist;
  final String album;
  final int durationMs;
  final String path;
  final SMTCState state;
  final int positionMs;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LocalSmtcInput &&
          title == other.title &&
          artist == other.artist &&
          album == other.album &&
          durationMs == other.durationMs &&
          path == other.path &&
          state == other.state &&
          positionMs == other.positionMs;

  @override
  int get hashCode =>
      Object.hash(title, artist, album, durationMs, path, state, positionMs);
}
