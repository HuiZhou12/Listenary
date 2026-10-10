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

/// 这次 HTTP 失败发生在**哪一类 Provider** 上（P-16：决定 404 的归属）。
enum OnlineMusicErrorOrigin {
  /// 内置实现：请求路径由**代码**拥有 ⇒ 404 就是"资源不存在"（Spec §6.5）。
  builtin,

  /// 声明式实现：请求路径由**用户配置** ⇒ 404 是"接口定义对不上服务端"。
  declarative,
}

/// **唯一**的「HTTP 状态码 → 错误分类」表（P-16）。
///
/// 为什么要收敛到一处：此前有三张表（内置的 `ChkszException.fromResponse`、
/// 声明式的 `_errorKindForStatus`、试跑的 `classifyUnsuccessfulTestResponse`），
/// 同一件事在三层得出**不同结论** —— 例如同一个 404：内置说"资源不存在"、
/// 声明式说"业务失败"、试跑说"HTTP"。用户按其中一句去排查就永远找不到真正原因。
///
/// 收敛后的口径（与 Spec §6.3 回退表 / §6.5 分类表逐行一致）：
/// | 状态 | 分类 | 可换 Provider |
/// |---|---|---|
/// | 400 | `badRequest` | 否 |
/// | 401 | `notConfigured`（凭据缺失/无效 ⇒ 换一个是合理出路） | **是** |
/// | 402 | `quotaExhausted` | **是** |
/// | 403 | `forbidden` | 否 |
/// | 404 + **内置** | `notFound` | 否 |
/// | 404 + **声明式** | `endpointMismatch`（路径是用户配的） | 否 |
/// | 429 | `rateLimited` | **是** |
/// | ≥500 | `unavailable` | **是** |
/// | 其余（405/418/…） | `unknown` | 否 |
///
/// [readableJson] 只在**成功判定未通过**那条路径上有意义：声明式 Provider 拿到
/// 不可读（非对象/数组）的响应 ⇒ 同样是"接口定义对不上服务端"（Spec §6.5）。
OnlineMusicErrorKind classifyHttpStatus(
  int statusCode, {
  required OnlineMusicErrorOrigin origin,
  bool readableJson = true,
}) {
  if (origin == OnlineMusicErrorOrigin.declarative &&
      (statusCode == 404 || !readableJson)) {
    return OnlineMusicErrorKind.endpointMismatch;
  }
  return switch (statusCode) {
    400 => OnlineMusicErrorKind.badRequest,
    401 => OnlineMusicErrorKind.notConfigured,
    402 => OnlineMusicErrorKind.quotaExhausted,
    403 => OnlineMusicErrorKind.forbidden,
    404 => OnlineMusicErrorKind.notFound,
    429 => OnlineMusicErrorKind.rateLimited,
    >= 500 => OnlineMusicErrorKind.unavailable,
    _ => OnlineMusicErrorKind.unknown,
  };
}

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
