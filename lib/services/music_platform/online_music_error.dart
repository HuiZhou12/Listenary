enum OnlineMusicErrorKind {
  badRequest,
  notConfigured,
  quotaExhausted,
  forbidden,
  notFound,
  rateLimited,
  unavailable,
  businessFailure,
  invalidResponse,

  /// **接口定义 / 响应 schema 不匹配**（D15）。
  ///
  /// 与 [notFound] 的区别很重要：[notFound] 表示"这个资源确实不存在"，而本项表示
  /// "当前配置的接口对不上服务端返回" —— 例如声明式 Provider 的 Path / Response
  /// Mapping 配错、响应不是可读 JSON、缺少必填字段。对用户自配接口的场景必须如实
  /// 报"接口定义无法匹配响应"，不能伪装成普通的资源不存在。
  endpointMismatch,

  cancelled,
  network,
  unknown,
}

/// 该错误是否允许切换到**同平台的下一个候选 Provider**（Spec §6.3，fail-closed）。
///
/// 只有"Provider 级故障 / 缺少凭据 / 暂时没有余量"才换 Provider；
/// 内容语义类（资源不存在、业务失败）与配置类（接口定义不匹配、响应无法解析）
/// **一律不换** —— 换了要么掩盖配置错误，要么污染内容来源语义。
bool allowsProviderFallback(OnlineMusicErrorKind kind) => switch (kind) {
  OnlineMusicErrorKind.network ||
  OnlineMusicErrorKind.unavailable ||
  OnlineMusicErrorKind.notConfigured ||
  OnlineMusicErrorKind.quotaExhausted ||
  OnlineMusicErrorKind.rateLimited => true,
  _ => false,
};

final class OnlineMusicException implements Exception {
  const OnlineMusicException({
    required this.kind,
    required this.safeMessage,
    this.retryAfter,
  });

  final OnlineMusicErrorKind kind;
  final String safeMessage;
  final Duration? retryAfter;

  @override
  String toString() => 'OnlineMusicException(${kind.name}, $safeMessage)';
}
