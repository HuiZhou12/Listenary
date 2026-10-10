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

  /// 参数绑定自身不成立：**既没有取值来源也没有固定值**，或者**两者同时给了**。
  ///
  /// F4-S1（P-08 / D1:A）：正常路径在保存与试跑校验（`validationIssues`）就被拦下，
  /// 这里是运行期兜底 —— 绝不"静默取其一"，也绝不悄悄少发一个参数。
  invalidParameterBinding,

  /// F4-S8（P-65）：**认证注入与声明的参数同名** —— 以前会**静默覆盖**用户声明的参数
  /// （凭据写进同名键，用户配置的值被悄悄丢掉）。按裁定**一律报错**，不静默取其一。
  authParameterConflict,

  /// F4-S8：**请求头的值包含非 ASCII 字符**。
  ///
  /// HTTP 头只能放 ASCII；真实环境实测：把中文关键词当动态头值时传输层直接抛错，
  /// 用户只看到"失败"、看不出原因 ⇒ 这里**明确报错**并给出去处。
  invalidHeaderValue,
}

final class DeclarativeRequestException implements Exception {
  const DeclarativeRequestException(this.kind, this.safeMessage);

  final DeclarativeRequestErrorKind kind;
  final String safeMessage;

  @override
  String toString() => 'DeclarativeRequestException(${kind.name})';
}

/// F4-S8：响应体**不是结构化 JSON**（对象 / 数组）时的明确说明；结构化时返回 `null`。
///
/// 用途：以前这种情况会被笼统报成"字段映射不完整：列表路径没有取到数组"，
/// 让人以为该去补字段配置 —— 真实原因往往是**对方返回的根本不是 JSON**
/// （HTML 错误页 / 纯文本），应该明确说成"接口定义与实际返回不匹配"
/// （失败大类 `responseFormat` / `endpointMismatch`）。
///
/// 只描述**粗略类型**，绝不带响应内容（可能含敏感信息）。
String? nonStructuredResponseReason(Object? body) {
  if (body is Map || body is List) return null;
  final what = switch (body) {
    null => '空响应',
    String() => '收到的是纯文本',
    _ => '收到的是非结构化数据',
  };
  return '响应不是 JSON（$what）：接口定义与实际返回不匹配';
}

/// 响应无法按配置映射成 Domain Model。
final class DeclarativeMappingException implements Exception {
  const DeclarativeMappingException(this.reason);

  /// 供日志/界面定位原因的**非敏感**说明（不含响应体内容）。
  final String reason;

  @override
  String toString() => 'DeclarativeMappingException($reason)';
}
