import 'package:pure_music/play_service/active_playback_session.dart';
import 'package:pure_music/play_service/local_smtc_input.dart';

abstract interface class LocalSmtcPublisher {
  Future<void> publish(
    ActivePlaybackSessionSnapshot snapshot, {
    LocalSmtcInput? localInput,
  });
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
}
