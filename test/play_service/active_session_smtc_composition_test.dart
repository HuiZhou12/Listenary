import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/native/rust/api/smtc_flutter.dart';
import 'package:pure_music/play_service/active_playback_session.dart';
import 'package:pure_music/play_service/active_session_smtc_composition.dart';
import 'package:pure_music/play_service/active_session_smtc_publisher.dart';
import 'package:pure_music/play_service/local_smtc_input.dart';
import 'package:pure_music/play_service/local_smtc_publisher.dart';
import 'package:pure_music/play_service/smtc_bridge.dart';

void main() {
  late _Harness harness;

  tearDown(() => harness.dispose());

  test('existing and duplicate local source notifications bind once', () {
    harness = _Harness(existingLocal: true);

    harness.handoff.publish(harness.localSource);

    expect(harness.localSource.bindCount, 1);
    expect(harness.handoff.listenerCount, 1);
  });

  test(
    'remote session owns display and suppresses local publisher events',
    () async {
      harness = _Harness(existingLocal: true);
      final remoteLease = harness.activeSession.switchTo(
        source: ActivePlaybackSessionSource.remote,
        queue: const [
          ActivePlaybackSessionItem(
            title: 'Remote title',
            artist: 'Remote artist',
          ),
        ],
        currentIndex: 0,
        state: ActivePlaybackSessionState.playing,
        controlInFlight: false,
        capabilities: ActivePlaybackSessionCapabilities.none,
      );
      await harness.composition.flush;

      await harness.localSource.publisher!.publish(_localInput);
      await harness.composition.flush;

      expect(harness.backend.displays, [
        const _Display(title: 'Remote title', artist: 'Remote artist'),
      ]);
      expect(harness.backend.states, [SMTCState.playing]);

      harness.activeSession.release(remoteLease);
      await harness.composition.flush;

      expect(harness.backend.clears, 1);
    },
  );

  test(
    'remote keep-alive and dispose use the same publisher lifecycle',
    () async {
      harness = _Harness(existingLocal: true);
      harness.activeSession.switchTo(
        source: ActivePlaybackSessionSource.remote,
        queue: const [
          ActivePlaybackSessionItem(
            title: 'Remote title',
            artist: 'Remote artist',
          ),
        ],
        currentIndex: 0,
        state: ActivePlaybackSessionState.paused,
        controlInFlight: false,
        capabilities: ActivePlaybackSessionCapabilities.none,
      );
      await harness.composition.flush;

      harness.remoteKeepAlive?.call();
      await harness.composition.flush;
      await harness.composition.dispose();

      expect(harness.backend.displays, hasLength(2));
      expect(harness.backend.clears, 1);
      expect(harness.localSource.clearCount, 1);
      expect(harness.handoff.listenerCount, 0);
      expect(harness.remoteKeepAlive, isNull);
    },
  );
}

final class _Harness {
  _Harness({bool existingLocal = false}) {
    if (existingLocal) {
      handoff.publish(localSource);
    }
    activePublisher = ActiveSessionSmtcPublisher(
      SmtcBridge.withBackend(backend),
    );
    localPublisher = ActiveSessionLocalSmtcPublisher(
      readSnapshot: () => activeSession.value,
      publishActiveSession: activePublisher.publish,
      publishActiveSessionPosition: activePublisher.publishLocalPosition,
    );
    composition = ActiveSessionSmtcComposition<_LocalSource>(
      activeSession: activeSession,
      publisher: activePublisher,
      localPublisher: localPublisher,
      addLocalSourceCreatedListener: handoff.addListener,
      removeLocalSourceCreatedListener: handoff.removeListener,
      attachLocalPublisher: (source, publisher) => source.bind(publisher),
      detachLocalPublisher: (source, publisher) => source.clear(publisher),
      bindRemoteKeepAlive: (publisher) => remoteKeepAlive = publisher,
      clearRemoteKeepAlive: (publisher) {
        if (identical(remoteKeepAlive, publisher)) {
          remoteKeepAlive = null;
        }
      },
    );
  }

  final activeSession = ActivePlaybackSession();
  final backend = _FakeSmtcBackend();
  final handoff = _LocalHandoff<_LocalSource>();
  final localSource = _LocalSource();
  late final ActiveSessionSmtcPublisher activePublisher;
  late final ActiveSessionLocalSmtcPublisher localPublisher;
  late final ActiveSessionSmtcComposition<_LocalSource> composition;
  void Function()? remoteKeepAlive;

  Future<void> dispose() async {
    await composition.dispose();
    activeSession.dispose();
  }
}

final class _LocalHandoff<T extends Object> {
  final Set<LocalSmtcSourceCreatedListener<T>> _listeners = {};
  T? _existing;

  int get listenerCount => _listeners.length;

  void addListener(LocalSmtcSourceCreatedListener<T> listener) {
    if (!_listeners.add(listener)) return;
    final existing = _existing;
    if (existing != null) {
      listener(existing);
    }
  }

  void removeListener(LocalSmtcSourceCreatedListener<T> listener) {
    _listeners.remove(listener);
  }

  void publish(T source) {
    _existing = source;
    for (final listener in List.of(_listeners)) {
      listener(source);
    }
  }
}

final class _LocalSource {
  LocalSmtcPublisher? publisher;
  int bindCount = 0;
  int clearCount = 0;

  void bind(LocalSmtcPublisher value) {
    bindCount++;
    publisher = value;
  }

  void clear(LocalSmtcPublisher value) {
    if (identical(publisher, value)) {
      clearCount++;
      publisher = null;
    }
  }
}

final class _FakeSmtcBackend implements SmtcBackend {
  final displays = <_Display>[];
  final states = <SMTCState>[];
  int clears = 0;

  @override
  Stream<SMTCControlEvent> get controlEvents => const Stream.empty();

  @override
  Stream<int> get positionChangeEvents => const Stream.empty();

  @override
  Future<void> clearDisplay() async {
    clears++;
  }

  @override
  Future<void> close() async {}

  @override
  Future<void> refreshDisplay() async {}

  @override
  Future<void> updateDisplay({
    required String title,
    required String artist,
    required String album,
    required int duration,
    required String path,
  }) async {
    displays.add(
      _Display(
        title: title,
        artist: artist,
        album: album,
        duration: duration,
        path: path,
      ),
    );
  }

  @override
  Future<void> updateState(SMTCState state) async {
    states.add(state);
  }

  @override
  Future<void> updateTimeProperties(int progress) async {}
}

final class _Display {
  const _Display({
    required this.title,
    required this.artist,
    this.album = '',
    this.duration = 0,
    this.path = '',
  });

  final String title;
  final String artist;
  final String album;
  final int duration;
  final String path;

  @override
  bool operator ==(Object other) =>
      other is _Display &&
      title == other.title &&
      artist == other.artist &&
      album == other.album &&
      duration == other.duration &&
      path == other.path;

  @override
  int get hashCode => Object.hash(title, artist, album, duration, path);
}

const _localInput = LocalSmtcInput(
  title: 'Local title',
  artist: 'Local artist',
  album: 'Local album',
  durationMs: 180000,
  path: r'C:\Music\local.flac',
  state: SMTCState.playing,
  positionMs: 1000,
);
