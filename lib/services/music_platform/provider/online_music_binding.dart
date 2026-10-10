/// 一个能力的绑定形态（闭集，不做第四种）。
///
/// 三种形态对应三类差异：
/// - [OnlineMusicBuiltinCapabilityBinding]：协议语义复杂到必须写代码（ChkSz）；
/// - [OnlineMusicDeclarativeCapabilityBinding]：REST + JSON 的常规映射，纯配置；
/// - [OnlineMusicUnsupportedCapabilityBinding]：「这个能力就是没有」，是一等公民。
library;

import 'package:pure_music/services/music_platform/provider/online_music_capability.dart';
import 'package:pure_music/services/music_platform/provider/online_music_request_spec.dart';
import 'package:pure_music/services/music_platform/provider/online_music_response_spec.dart';

/// 内置实现标识：ChkSz 协议。
const builtinOnlineMusicChkszId = 'chksz';

/// 已知的内置实现标识；其它值一律视为无效配置（显式拒绝，不静默降级）。
const supportedBuiltinOnlineMusicIds = {builtinOnlineMusicChkszId};

/// 内置实现（ChkSz）**真正实现**的能力集合。
///
/// 这是"旧版条目（没有 `capabilities` 键）应当声明什么能力"的**唯一事实源**。
///
/// **为什么需要它（P-19）**：旧实现让旧条目对**任意**能力都返回内置实现，
/// 于是设置页的平台卡声称该条目支持 8 个能力，而运行时只服务这 4 个
/// （`chksz_online_music_provider.dart` 的 `_defaultPlatforms`）——
/// 用户在平台卡里选到那 4 项之外时，拿到的是一条**静默的 `unavailable`**：
/// 界面说"能"，运行时说"不能"，而没有任何地方解释这个矛盾。
///
/// 它必须与运行时一致：`test/services/music_platform/online_music_default_compat_test.dart`
/// 里有一条**跨层一致性断言**盯着这件事（声明侧 == 运行时侧），
/// 这里少写一项、或运行时多写一项，都会让该测试变红。
const builtinOnlineMusicCapabilities = {
  OnlineMusicCapability.search,
  OnlineMusicCapability.playlist,
  OnlineMusicCapability.lyric,
  OnlineMusicCapability.stream,
};

sealed class OnlineMusicCapabilityBinding {
  const OnlineMusicCapabilityBinding();

  Map<String, dynamic> toJson();

  List<String> validationIssues(OnlineMusicCapability capability);

  static OnlineMusicCapabilityBinding fromJson(Object? value) {
    if (value == null) return const OnlineMusicUnsupportedCapabilityBinding();
    if (value is! Map) throw const FormatException('能力绑定必须是对象');
    final kind = value['kind'];
    return switch (kind) {
      'builtin' => OnlineMusicBuiltinCapabilityBinding.fromJson(value),
      'http' => OnlineMusicDeclarativeCapabilityBinding.fromJson(value),
      'unsupported' => const OnlineMusicUnsupportedCapabilityBinding(),
      _ => throw FormatException('能力绑定类型无效：$kind'),
    };
  }
}

/// 走代码实现。
final class OnlineMusicBuiltinCapabilityBinding
    extends OnlineMusicCapabilityBinding {
  const OnlineMusicBuiltinCapabilityBinding([this.builtinId = builtinOnlineMusicChkszId]);

  final String builtinId;

  @override
  Map<String, dynamic> toJson() => {'kind': 'builtin', 'builtin': builtinId};

  static OnlineMusicBuiltinCapabilityBinding fromJson(Map<Object?, Object?> map) {
    final id = map['builtin'];
    if (id is! String || !supportedBuiltinOnlineMusicIds.contains(id)) {
      throw FormatException('内置实现标识无效：$id');
    }
    return OnlineMusicBuiltinCapabilityBinding(id);
  }

  @override
  List<String> validationIssues(OnlineMusicCapability capability) => const [];

  @override
  bool operator ==(Object other) =>
      other is OnlineMusicBuiltinCapabilityBinding && other.builtinId == builtinId;

  @override
  int get hashCode => builtinId.hashCode;

  @override
  String toString() => 'Builtin($builtinId)';
}

/// 纯声明式：通用 HTTP Executor + 映射引擎。
final class OnlineMusicDeclarativeCapabilityBinding
    extends OnlineMusicCapabilityBinding {
  const OnlineMusicDeclarativeCapabilityBinding({
    required this.request,
    required this.response,
  });

  final OnlineMusicRequestSpec request;
  final OnlineMusicResponseSpec response;

  @override
  Map<String, dynamic> toJson() => {
    'kind': 'http',
    'request': request.toJson(),
    'response': response.toJson(),
  };

  static OnlineMusicDeclarativeCapabilityBinding fromJson(
    Map<Object?, Object?> map,
  ) {
    return OnlineMusicDeclarativeCapabilityBinding(
      request: OnlineMusicRequestSpec.fromJson(map['request']),
      response: OnlineMusicResponseSpec.fromJson(map['response']),
    );
  }

  @override
  List<String> validationIssues(OnlineMusicCapability capability) => [
    ...request.validationIssues(),
    ...response.validationIssues(capability),
  ];

  @override
  bool operator ==(Object other) =>
      other is OnlineMusicDeclarativeCapabilityBinding &&
      other.request == request &&
      other.response == response;

  @override
  int get hashCode => Object.hash(request, response);

  @override
  String toString() => 'Declarative(${request.verb.name} ${request.path})';
}

/// 明确不支持：上层会把它解释成 `unavailable`，而不是伪装成支持。
final class OnlineMusicUnsupportedCapabilityBinding
    extends OnlineMusicCapabilityBinding {
  const OnlineMusicUnsupportedCapabilityBinding();

  @override
  Map<String, dynamic> toJson() => const {'kind': 'unsupported'};

  @override
  List<String> validationIssues(OnlineMusicCapability capability) => [
    '${capability.name} 能力尚未配置，因此会被标记为不支持',
  ];

  @override
  bool operator ==(Object other) =>
      other is OnlineMusicUnsupportedCapabilityBinding;

  @override
  int get hashCode => 0;

  @override
  String toString() => 'Unsupported';
}
