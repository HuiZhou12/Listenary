import 'dart:async';
import 'dart:typed_data';

import 'package:pure_music/native/bass/bass_player.dart';

/// 本地播放的引擎缝（engine seam）。
///
/// 只有 `BassPlayerLocalPlaybackDriver` 在正式路径上实现它；测试用假实现
/// 替代真实 BASS 设备。成员命名与 [BassPlayer] 保持一致，**不**做语义归一
/// —— 归一（统一 `PlayerState` 与 `PlaybackBackendState`）属于后续阶段，
/// 会改变 `pausedDevice` 等状态的既有语义。
///
/// 与远程侧先例一致：`BassUrlPlaybackDriver` 是远程的引擎缝，
/// `BassUrlPlaybackBackend` 是服务端口实现。
abstract interface class LocalPlaybackDriver {
  Stream<PlayerState> get playerStateStream;

  Stream<double> get positionStream;

  Stream<Float32List> get spectrumStream;

  PlayerState get playerState;

  bool get isBassFxLoaded;

  String get debugStateLine;

  /// WASAPI 独占模式当前是否启用。
  bool get wasapiExclusive;

  /// 独占模式状态变化回调；`null` 表示不关心。
  set onExclusiveModeChanged(void Function(bool exclusive)? handler);

  double? get replayGainDb;

  set replayGainDb(double? value);

  List<double> get eqGains;

  SpectrumUpdateMode get spectrumUpdateMode;

  void setSpectrumUpdateMode(SpectrumUpdateMode mode);

  /// 当前音频长度（秒）。
  double get length;

  /// 当前播放位置（秒）。
  double get position;

  /// 解码音量（不影响 Windows 系统音量）。
  double get volumeDsp;

  void setVolumeDsp(double volume);

  void setEQ(int band, double gain);

  void refreshEQ();

  void setPitch(double pitch);

  void setRate(double rate);

  /// 切换 WASAPI 独占模式；返回切换后是否处于独占。
  bool useExclusiveMode(bool exclusive);

  /// 用本地文件路径替换当前音源（会释放旧流）。
  void setSource(String path);

  void start();

  void pause();

  void seek(double position);

  /// 释放全部引擎资源（BASS 库、流、StreamController）。
  void free();
}

/// [LocalPlaybackDriver] 的 BASS 实现。
///
/// 刻意保持极薄：不做状态映射、不做重试、不吞异常，以保证解耦前后
/// 行为逐字等价。真正的 BASS 细节仍在 [BassPlayer] 内。
final class BassPlayerLocalPlaybackDriver implements LocalPlaybackDriver {
  BassPlayerLocalPlaybackDriver({BassPlayer? player})
    : _player = player ?? BassPlayer();

  final BassPlayer _player;

  @override
  Stream<PlayerState> get playerStateStream => _player.playerStateStream;

  @override
  Stream<double> get positionStream => _player.positionStream;

  @override
  Stream<Float32List> get spectrumStream => _player.spectrumStream;

  @override
  PlayerState get playerState => _player.playerState;

  @override
  bool get isBassFxLoaded => _player.isBassFxLoaded;

  @override
  String get debugStateLine => _player.debugStateLine;

  @override
  bool get wasapiExclusive => _player.wasapiExclusive;

  @override
  set onExclusiveModeChanged(void Function(bool exclusive)? handler) {
    _player.onExclusiveModeChanged = handler;
  }

  @override
  double? get replayGainDb => _player.replayGainDb;

  @override
  set replayGainDb(double? value) {
    _player.replayGainDb = value;
  }

  @override
  List<double> get eqGains => _player.eqGains;

  @override
  SpectrumUpdateMode get spectrumUpdateMode => _player.spectrumUpdateMode;

  @override
  void setSpectrumUpdateMode(SpectrumUpdateMode mode) {
    _player.setSpectrumUpdateMode(mode);
  }

  @override
  double get length => _player.length;

  @override
  double get position => _player.position;

  @override
  double get volumeDsp => _player.volumeDsp;

  @override
  void setVolumeDsp(double volume) => _player.setVolumeDsp(volume);

  @override
  void setEQ(int band, double gain) => _player.setEQ(band, gain);

  @override
  void refreshEQ() => _player.refreshEQ();

  @override
  void setPitch(double pitch) => _player.setPitch(pitch);

  @override
  void setRate(double rate) => _player.setRate(rate);

  @override
  bool useExclusiveMode(bool exclusive) => _player.useExclusiveMode(exclusive);

  @override
  void setSource(String path) => _player.setSource(path);

  @override
  void start() => _player.start();

  @override
  void pause() => _player.pause();

  @override
  void seek(double position) => _player.seek(position);

  @override
  void free() => _player.free();
}

/// 本地播放的服务端口。
///
/// `PlaybackService` 与 `EqualizerService` 只依赖本接口，不再直接持有
/// `BassPlayer`。与 [LocalPlaybackDriver] 的差异只有两处，都是本地语义：
/// - `open(path)` 取代 `setSource(path)`，对应远程侧 `open(PlaybackSource)`；
/// - `dispose()` 取代 `free()`，对应远程侧 `dispose()`。
///
/// 其余成员与 driver 同名同签名是**有意**的：本地端口是引擎形状的，
/// 任何形状归一都会改变既有行为，属于 S3-3 的范围。
///
/// `dispose()` 保持同步：BASS 释放本身同步，改成 `Future` 会改变
/// `PlaybackService.close()` 的收尾顺序。
abstract interface class LocalPlaybackBackend {
  Stream<PlayerState> get playerStateStream;

  Stream<double> get positionStream;

  Stream<Float32List> get spectrumStream;

  PlayerState get playerState;

  bool get isBassFxLoaded;

  String get debugStateLine;

  bool get wasapiExclusive;

  set onExclusiveModeChanged(void Function(bool exclusive)? handler);

  double? get replayGainDb;

  set replayGainDb(double? value);

  List<double> get eqGains;

  SpectrumUpdateMode get spectrumUpdateMode;

  void setSpectrumUpdateMode(SpectrumUpdateMode mode);

  double get length;

  double get position;

  double get volumeDsp;

  void setVolumeDsp(double volume);

  void setEQ(int band, double gain);

  void refreshEQ();

  void setPitch(double pitch);

  void setRate(double rate);

  bool useExclusiveMode(bool exclusive);

  /// 打开本地文件音源；不做播放（与既有 `setSource` 一致，需另调 [start]）。
  void open(String path);

  void start();

  void pause();

  void seek(double position);

  /// 释放引擎资源。
  void dispose();
}

/// [LocalPlaybackBackend] 的 BASS 实现。
///
/// 当前是**薄适配**：26 个成员逐个转发到 [LocalPlaybackDriver]，不改状态、
/// 不吞异常、不加锁。价值在于把 `PlaybackService` 与 BASS 具体类型解耦，
/// 并提供可用假 driver 测的后端边界。
final class BassLocalPlaybackBackend implements LocalPlaybackBackend {
  BassLocalPlaybackBackend({LocalPlaybackDriver? driver})
    : _driver = driver ?? BassPlayerLocalPlaybackDriver();

  final LocalPlaybackDriver _driver;

  @override
  Stream<PlayerState> get playerStateStream => _driver.playerStateStream;

  @override
  Stream<double> get positionStream => _driver.positionStream;

  @override
  Stream<Float32List> get spectrumStream => _driver.spectrumStream;

  @override
  PlayerState get playerState => _driver.playerState;

  @override
  bool get isBassFxLoaded => _driver.isBassFxLoaded;

  @override
  String get debugStateLine => _driver.debugStateLine;

  @override
  bool get wasapiExclusive => _driver.wasapiExclusive;

  @override
  set onExclusiveModeChanged(void Function(bool exclusive)? handler) {
    _driver.onExclusiveModeChanged = handler;
  }

  @override
  double? get replayGainDb => _driver.replayGainDb;

  @override
  set replayGainDb(double? value) {
    _driver.replayGainDb = value;
  }

  @override
  List<double> get eqGains => _driver.eqGains;

  @override
  SpectrumUpdateMode get spectrumUpdateMode => _driver.spectrumUpdateMode;

  @override
  void setSpectrumUpdateMode(SpectrumUpdateMode mode) {
    _driver.setSpectrumUpdateMode(mode);
  }

  @override
  double get length => _driver.length;

  @override
  double get position => _driver.position;

  @override
  double get volumeDsp => _driver.volumeDsp;

  @override
  void setVolumeDsp(double volume) => _driver.setVolumeDsp(volume);

  @override
  void setEQ(int band, double gain) => _driver.setEQ(band, gain);

  @override
  void refreshEQ() => _driver.refreshEQ();

  @override
  void setPitch(double pitch) => _driver.setPitch(pitch);

  @override
  void setRate(double rate) => _driver.setRate(rate);

  @override
  bool useExclusiveMode(bool exclusive) => _driver.useExclusiveMode(exclusive);

  @override
  void open(String path) => _driver.setSource(path);

  @override
  void start() => _driver.start();

  @override
  void pause() => _driver.pause();

  @override
  void seek(double position) => _driver.seek(position);

  @override
  void dispose() => _driver.free();
}
