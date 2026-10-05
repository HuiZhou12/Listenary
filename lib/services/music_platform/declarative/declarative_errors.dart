/// 声明式执行过程中的受控错误。
///
/// 刻意只有少数几种：配置错误在**校验阶段**就该被挡下（见各 spec 的
/// `validationIssues`），这里的错误都是"运行时才知道"的情形。
library;

enum DeclarativeRequestErrorKind {
  /// 请求声明了认证，但该条目没有可用的凭据。
  missingCredential,

  /// 必填输入缺失（例如搜索没有 keyword）。
  missingRequiredInput,
}

final class DeclarativeRequestException implements Exception {
  const DeclarativeRequestException(this.kind, this.safeMessage);

  final DeclarativeRequestErrorKind kind;
  final String safeMessage;

  @override
  String toString() => 'DeclarativeRequestException(${kind.name})';
}

/// 响应无法按配置映射成 Domain Model。
final class DeclarativeMappingException implements Exception {
  const DeclarativeMappingException(this.reason);

  /// 供日志/界面定位原因的**非敏感**说明（不含响应体内容）。
  final String reason;

  @override
  String toString() => 'DeclarativeMappingException($reason)';
}
