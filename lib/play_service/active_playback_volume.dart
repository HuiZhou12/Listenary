import 'package:flutter/foundation.dart';

typedef ActiveVolumeSetter = void Function(double volume);

final class ActivePlaybackVolumeRouter<T> extends ValueNotifier<double> {
  ActivePlaybackVolumeRouter({
    required double initialVolume,
    required bool Function() isRemoteActive,
    required bool Function() hasLocalSession,
    required T? Function() localTarget,
    required void Function(T target, double volume) setLocalVolume,
    required ActiveVolumeSetter persistRemoteVolume,
  }) : _isRemoteActive = isRemoteActive,
       _hasLocalSession = hasLocalSession,
       _localTarget = localTarget,
       _setLocalVolume = setLocalVolume,
       _persistRemoteVolume = persistRemoteVolume,
       super(initialVolume.clamp(0.0, 1.0));

  final bool Function() _isRemoteActive;
  final bool Function() _hasLocalSession;
  final T? Function() _localTarget;
  final void Function(T target, double volume) _setLocalVolume;
  final ActiveVolumeSetter _persistRemoteVolume;
  ActiveVolumeSetter? _remoteSetter;

  bool get canSetVolume => _isRemoteActive()
      ? _remoteSetter != null
      : _hasLocalSession() && _localTarget() != null;

  void bindRemote(ActiveVolumeSetter setter) {
    _remoteSetter = setter;
  }

  void clearRemote() {
    _remoteSetter = null;
  }

  bool setVolume(double volume) {
    final next = volume.clamp(0.0, 1.0);
    if (_isRemoteActive()) {
      final setter = _remoteSetter;
      if (setter == null) return false;
      setter(next);
      _persistRemoteVolume(next);
      value = next;
      return true;
    }

    if (!_hasLocalSession()) return false;
    final target = _localTarget();
    if (target == null) return false;
    _setLocalVolume(target, next);
    value = next;
    return true;
  }
}
