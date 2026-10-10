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
    this.identity,
    required this.capability,
    required this.attempts,
    this.winnerProviderId,
    this.qualityDeclarerProviderId,
  });

  final MusicPlatform platform;

  /// F5-P-39（P2）：该条路由的**平台身份**（内置平台为 builtin(platform)）。
  /// 自定义平台靠它区分：只比较枚举会让所有自定义平台串成同一条。
  final PlatformIdentity? identity;
  final OnlineMusicCapability capability;

  /// 按尝试顺序记录的失败项；最后一项之后若成功，则 [winnerProviderId] 非空。
  final List<OnlineMusicRouteAttempt> attempts;

  /// 实际成功的 Provider；全部失败或未回退时为 null。
  final String? winnerProviderId;

  /// 该平台**档位清单/文案的声明者**（P-56）。
  ///
  /// 正常情况下等于 [winnerProviderId]（候选里的第一个就是服务者）。
  /// **只在回落导致二者分叉时**才有值：UI 展示的档位来自声明者，而真正收到请求、
  /// 并按**自己**的声明做档位转换的是 winner ⇒ 这件事必须可见，否则用户会看到
  /// 一份与实际请求值对不上的档位清单（且没有任何线索）。
  final String? qualityDeclarerProviderId;

  /// 档位声明者与服务者是否**不是**同一个（P-56 要如实说出来的那种情况）。
  bool get qualityDeclarerDiffers =>
      qualityDeclarerProviderId != null &&
      winnerProviderId != null &&
      qualityDeclarerProviderId != winnerProviderId;

  bool get didFallback => attempts.isNotEmpty;

  @override
  String toString() =>
      '${platform.name}/${capability.name}: '
      '${attempts.isEmpty ? '首次命中' : attempts.join(' → ')}'
      '${winnerProviderId == null ? '' : ' → ${winnerProviderId!}(成功)'}'
      '${qualityDeclarerDiffers ? ' [档位声明来自 ${qualityDeclarerProviderId!}]' : ''}';
}
