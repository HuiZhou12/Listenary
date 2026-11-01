import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/native/bass/bass_player.dart';
import 'package:pure_music/play_service/local_playback_backend.dart';

/// 本地播放后端级测试。
///
/// 目标（open issue 1.3「先补后端级测试」）：在不加载 bass.dll、不接触音频
/// 设备的前提下，固定 `LocalPlaybackBackend` 的转发契约。假 driver 只记录
/// 调用与返回值，因此这里断言的是**解耦边界**，不是 BASS 行为。
void main() {
  late _FakeLocalPlaybackDriver driver;
  late BassLocalPlaybackBackend backend;

  setUp(() {
    driver = _FakeLocalPlaybackDriver();
    backend = BassLocalPlaybackBackend(driver: driver);
  });

  tearDown(() async {
    await driver.closeStreams();
  });

  group('streams and state', () {
    test('exposes driver streams without buffering or copying', () async {
      final states = <PlayerState>[];
      final positions = <double>[];
      final frames = <Float32List>[];
      final stateSub = backend.playerStateStream.listen(states.add);
      final positionSub = backend.positionStream.listen(positions.add);
      final spectrumSub = backend.spectrumStream.listen(frames.add);
      final frame = Float32List.fromList([0.1, 0.2, 0.3, 0.4]);

      driver.emitState(PlayerState.playing);
      driver.emitPosition(12.5);
      driver.emitSpectrum(frame);
      await pumpEventQueue();

      expect(states, [PlayerState.playing]);
      expect(positions, [12.5]);
      expect(frames, hasLength(1));
      // 同一实例：与远程后端一致，不做深拷贝。
      expect(frames.single, same(frame));

      await stateSub.cancel();
      await positionSub.cancel();
      await spectrumSub.cancel();
    });

    test('reads driver state and read-only scalars on demand', () {
      driver.stateValue = PlayerState.paused;
      driver.lengthValue = 185.25;
      driver.positionValue = 42.5;
      driver.volumeDspValue = 0.75;
      driver.isBassFxLoadedValue = true;
      driver.debugStateLineValue = 'exclusive=false handle=7';
      driver.wasapiExclusiveValue = true;
      driver.spectrumUpdateModeValue = SpectrumUpdateMode.hz60;

      expect(backend.playerState, PlayerState.paused);
      expect(backend.length, 185.25);
      expect(backend.position, 42.5);
      expect(backend.volumeDsp, 0.75);
      expect(backend.isBassFxLoaded, isTrue);
      expect(backend.debugStateLine, 'exclusive=false handle=7');
      expect(backend.wasapiExclusive, isTrue);
      expect(backend.spectrumUpdateMode, SpectrumUpdateMode.hz60);
    });

    test('routes the exclusive mode callback to the driver', () {
      var received = <bool>[];
      backend.onExclusiveModeChanged = received.add;

      driver.wasapiExclusiveValue = true;
      driver.emitExclusiveModeChanged(true);
      driver.emitExclusiveModeChanged(false);

      expect(received, [true, false]);
    });

    test('clearing the exclusive callback stops delivery', () {
      var received = <bool>[];
      backend.onExclusiveModeChanged = received.add;
      backend.onExclusiveModeChanged = null;

      driver.emitExclusiveModeChanged(true);

      expect(received, isEmpty);
    });
  });

  group('transport controls', () {
    test('open forwards the path and does not start playback', () {
      backend.open(r'C:\Music\title.flac');

      // 与既有 BassPlayer.setSource 一致：只换源，不自动 start。
      expect(driver.openedPaths, [r'C:\Music\title.flac']);
      expect(driver.startCount, 0);
    });

    test('start, pause and seek forward verbatim', () {
      backend.start();
      backend.pause();
      backend.seek(91.25);

      expect(driver.startCount, 1);
      expect(driver.pauseCount, 1);
      expect(driver.seekValues, [91.25]);
    });

    test(
      'dispose forwards exactly once and is not idempotent-guarded here',
      () {
        backend.dispose();

        // 幂等由 BassPlayer.free 自身承担；端口不做二次包装。
        expect(driver.freeCount, 1);
      },
    );

    test('does not swallow driver exceptions', () {
      driver.startError = StateError('bass device lost');
      driver.seekError = const FormatException('handle is not a valid channel');

      expect(() => backend.start(), throwsStateError);
      expect(() => backend.seek(1), throwsFormatException);
    });
  });

  group('equalizer, volume and tone', () {
    test('routes equalizer and volume calls to the driver', () {
      backend.setEQ(3, 4.5);
      backend.refreshEQ();
      backend.setVolumeDsp(0.375);

      expect(driver.eqCalls, [(band: 3, gain: 4.5)]);
      expect(driver.refreshEQCount, 1);
      expect(driver.volumeDspValues, [0.375]);
    });

    test('reads eq gains as the driver value', () {
      driver.eqGainsValue = const [1.0, -2.0, 3.5];

      expect(backend.eqGains, const [1.0, -2.0, 3.5]);
    });

    test('routes pitch, rate and spectrum update mode', () {
      backend.setPitch(-2.5);
      backend.setRate(1.25);
      backend.setSpectrumUpdateMode(SpectrumUpdateMode.hz120);

      expect(driver.pitchValues, [-2.5]);
      expect(driver.rateValues, [1.25]);
      expect(driver.spectrumUpdateModes, [SpectrumUpdateMode.hz120]);
    });

    test('round-trips the replay gain value including clearing it', () {
      backend.replayGainDb = -7.5;
      expect(driver.replayGainDbValue, -7.5);
      expect(backend.replayGainDb, -7.5);

      backend.replayGainDb = null;
      expect(driver.replayGainDbValue, isNull);
      expect(backend.replayGainDb, isNull);
    });

    test('returns the driver exclusive-mode decision unchanged', () {
      driver.exclusiveResult = false;

      expect(backend.useExclusiveMode(true), isFalse);
      expect(driver.exclusiveRequests, [true]);
    });
  });
}

final class _FakeLocalPlaybackDriver implements LocalPlaybackDriver {
  final _states = StreamController<PlayerState>.broadcast();
  final _positions = StreamController<double>.broadcast();
  final _spectrum = StreamController<Float32List>.broadcast();

  void Function(bool exclusive)? _exclusiveHandler;

  PlayerState stateValue = PlayerState.stopped;
  double lengthValue = 1.0;
  double positionValue = 0.0;
  double volumeDspValue = 0.0;
  bool isBassFxLoadedValue = false;
  String debugStateLineValue = '';
  bool wasapiExclusiveValue = false;
  SpectrumUpdateMode spectrumUpdateModeValue = SpectrumUpdateMode.auto;
  List<double> eqGainsValue = const [];
  double? replayGainDbValue;
  bool exclusiveResult = true;

  final openedPaths = <String>[];
  final seekValues = <double>[];
  final volumeDspValues = <double>[];
  final pitchValues = <double>[];
  final rateValues = <double>[];
  final spectrumUpdateModes = <SpectrumUpdateMode>[];
  final exclusiveRequests = <bool>[];
  final eqCalls = <({int band, double gain})>[];
  int startCount = 0;
  int pauseCount = 0;
  int refreshEQCount = 0;
  int freeCount = 0;

  Object? startError;
  Object? seekError;

  @override
  Stream<PlayerState> get playerStateStream => _states.stream;

  @override
  Stream<double> get positionStream => _positions.stream;

  @override
  Stream<Float32List> get spectrumStream => _spectrum.stream;

  @override
  PlayerState get playerState => stateValue;

  @override
  bool get isBassFxLoaded => isBassFxLoadedValue;

  @override
  String get debugStateLine => debugStateLineValue;

  @override
  bool get wasapiExclusive => wasapiExclusiveValue;

  @override
  set onExclusiveModeChanged(void Function(bool exclusive)? handler) {
    _exclusiveHandler = handler;
  }

  @override
  double? get replayGainDb => replayGainDbValue;

  @override
  set replayGainDb(double? value) {
    replayGainDbValue = value;
  }

  @override
  List<double> get eqGains => eqGainsValue;

  @override
  SpectrumUpdateMode get spectrumUpdateMode => spectrumUpdateModeValue;

  @override
  void setSpectrumUpdateMode(SpectrumUpdateMode mode) {
    spectrumUpdateModeValue = mode;
    spectrumUpdateModes.add(mode);
  }

  @override
  double get length => lengthValue;

  @override
  double get position => positionValue;

  @override
  double get volumeDsp => volumeDspValue;

  @override
  void setVolumeDsp(double volume) {
    volumeDspValue = volume;
    volumeDspValues.add(volume);
  }

  @override
  void setEQ(int band, double gain) {
    eqCalls.add((band: band, gain: gain));
  }

  @override
  void refreshEQ() {
    refreshEQCount++;
  }

  @override
  void setPitch(double pitch) {
    pitchValues.add(pitch);
  }

  @override
  void setRate(double rate) {
    rateValues.add(rate);
  }

  @override
  bool useExclusiveMode(bool exclusive) {
    exclusiveRequests.add(exclusive);
    return exclusiveResult;
  }

  @override
  void setSource(String path) {
    openedPaths.add(path);
  }

  @override
  void start() {
    startCount++;
    final error = startError;
    if (error != null) throw error;
  }

  @override
  void pause() {
    pauseCount++;
  }

  @override
  void seek(double position) {
    seekValues.add(position);
    final error = seekError;
    if (error != null) throw error;
  }

  @override
  void free() {
    freeCount++;
  }

  void emitState(PlayerState value) {
    stateValue = value;
    _states.add(value);
  }

  void emitPosition(double value) {
    _positions.add(value);
  }

  void emitSpectrum(Float32List value) {
    _spectrum.add(value);
  }

  void emitExclusiveModeChanged(bool exclusive) {
    wasapiExclusiveValue = exclusive;
    _exclusiveHandler?.call(exclusive);
  }

  Future<void> closeStreams() async {
    await _states.close();
    await _positions.close();
    await _spectrum.close();
  }
}
