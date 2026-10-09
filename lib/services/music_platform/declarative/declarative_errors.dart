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

  /// 请求头**已标记为敏感**，但仍带着明文值（未迁移）。
  ///
  /// 刻意与 [missingCredential] 分开：前者是"没配凭据"，这里是"配了明文秘密但
  /// 不允许发送"。运行期一律**明确失败且不发出任何请求**（F0 / §11.2）。
  sensitiveHeaderPlaintext,

  /// 请求头声明了**安全凭据引用**，但该槽位没有可用凭据（或根本没配引用）。
  ///
  /// 同上：绝不静默降级为空值或明文发送。
  sensitiveHeaderCredentialMissing,
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
