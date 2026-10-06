import 'package:pure_music/services/music_platform/models/music_models.dart';
import 'package:pure_music/services/music_platform/online_music_error.dart';
import 'package:pure_music/services/music_platform/provider/online_music_capability.dart';

/// 一次候选 Provider 的尝试记录。
///
/// 回退是**静默**的（D5b:B，不弹提示、不打断播放/搜索），但必须**可观测**：
/// 这里记录"试过谁、为什么失败"，供诊断视图与调试使用。
final class OnlineMusicRouteAttempt {
  const OnlineMusicRouteAttempt({required this.providerId, required this.kind});

  final String providerId;
  final OnlineMusicErrorKind kind;

  @override
  String toString() => '$providerId(${kind.name})';
}

/// 一次 `(platform, capability)` 分发的完整路由记录。
final class OnlineMusicRouteRecord {
  const OnlineMusicRouteRecord({
    required this.platform,
    required this.capability,
    required this.attempts,
    this.winnerProviderId,
  });

  final MusicPlatform platform;
  final OnlineMusicCapability capability;

  /// 按尝试顺序记录的失败项；最后一项之后若成功，则 [winnerProviderId] 非空。
  final List<OnlineMusicRouteAttempt> attempts;

  /// 实际成功的 Provider；全部失败或未回退时为 null。
  final String? winnerProviderId;

  bool get didFallback => attempts.isNotEmpty;

  @override
  String toString() =>
      '${platform.name}/${capability.name}: '
      '${attempts.isEmpty ? '首次命中' : attempts.join(' → ')}'
      '${winnerProviderId == null ? '' : ' → ${winnerProviderId!}(成功)'}';
}
