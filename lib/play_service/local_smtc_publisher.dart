import 'package:pure_music/play_service/active_playback_session.dart';
import 'package:pure_music/play_service/local_smtc_input.dart';

typedef ActiveSessionSmtcPublish =
    Future<void> Function(
      ActivePlaybackSessionSnapshot snapshot, {
      LocalSmtcInput? localInput,
    });
typedef ActiveSessionSmtcPositionPublish =
    Future<void> Function(
      ActivePlaybackSessionSnapshot snapshot,
      int positionMs,
    );
typedef ActivePlaybackSessionSnapshotReader =
    ActivePlaybackSessionSnapshot Function();

abstract interface class LocalSmtcPublisher {
  Future<void> publish(LocalSmtcInput input);
  Future<void> publishPosition(int positionMs);
  Future<void> clearDisplay();
}

final class ActiveSessionLocalSmtcPublisher implements LocalSmtcPublisher {
  const ActiveSessionLocalSmtcPublisher({
    required ActiveSessionSmtcPublish publishActiveSession,
    required ActiveSessionSmtcPositionPublish publishActiveSessionPosition,
    required ActivePlaybackSessionSnapshotReader readSnapshot,
  }) : _publishActiveSession = publishActiveSession,
       _publishActiveSessionPosition = publishActiveSessionPosition,
       _readSnapshot = readSnapshot;

  final ActiveSessionSmtcPublish _publishActiveSession;
  final ActiveSessionSmtcPositionPublish _publishActiveSessionPosition;
  final ActivePlaybackSessionSnapshotReader _readSnapshot;

  @override
  Future<void> publish(LocalSmtcInput input) {
    final snapshot = _readSnapshot();
    if (snapshot.source != ActivePlaybackSessionSource.local) {
      return Future<void>.value();
    }
    return _publishActiveSession(snapshot, localInput: input);
  }

  @override
  Future<void> publishPosition(int positionMs) {
    final snapshot = _readSnapshot();
    if (snapshot.source != ActivePlaybackSessionSource.local) {
      return Future<void>.value();
    }
    return _publishActiveSessionPosition(snapshot, positionMs);
  }

  @override
  Future<void> clearDisplay() {
    final snapshot = _readSnapshot();
    if (snapshot.source != ActivePlaybackSessionSource.inactive) {
      return Future<void>.value();
    }
    return _publishActiveSession(snapshot);
  }
}

final class LocalSmtcPublisherSlot {
  LocalSmtcPublisherSlot([LocalSmtcPublisher? publisher])
    : _publisher = publisher;

  LocalSmtcPublisher? _publisher;

  LocalSmtcPublisher? get publisher => _publisher;

  void bind(LocalSmtcPublisher publisher) {
    _publisher = publisher;
  }

  void clear(LocalSmtcPublisher publisher) {
    if (identical(_publisher, publisher)) {
      _publisher = null;
    }
  }

  Future<void> publish(LocalSmtcInput input) {
    return _publisher?.publish(input) ?? Future<void>.value();
  }

  Future<void> publishPosition(int positionMs) {
    return _publisher?.publishPosition(positionMs) ?? Future<void>.value();
  }

  Future<void> clearDisplay() {
    return _publisher?.clearDisplay() ?? Future<void>.value();
  }
}
