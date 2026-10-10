/// 一次"配置验证"（试跑 / 探测）的**可信度三态**（D-F3-3）。
///
/// 为什么需要它：以前只有"成功 / 失败"两态，于是**空结果**（合法空歌单、空榜单、
/// 纯音乐没有歌词）只能二选一 —— 要么被写成"成功"（假阳性：没能证明任何东西），
/// 要么被写成"映射失败"（冤枉：配置可能是对的）。这两种写法都会把用户引到错的方向。
///
/// 三态的分界（与用户裁定的口径逐条对应）：
/// 1. [verified] **已验证可用**：响应结构、必填字段与映射都满足该能力的验证条件；
/// 2. [unconfirmed] **未能确认**：请求完成了，但结果为空或证据不足；
/// 3. [failed] **验证失败**：存在明确的网络 / HTTP / 认证 / 业务 / 响应格式 / 映射错误。
///
/// 放在声明式层：探测（`provider_probe.dart`）与试跑（设置控制器）必须用**同一套词表**，
/// 否则同一个结果在两处会得到两种说法（这正是 P-26/P-16 反复出现的形态）。
library;

enum DeclarativeVerificationConfidence {
  /// 响应结构、必填字段与映射都满足该能力的验证条件 —— 这份配置**被证明可用**。
  verified,

  /// 请求完成了，但结果为空或证据不足 —— **无法证明**这份配置可用。
  ///
  /// ⚠️ 它既不是成功（空列表没有证明任何东西），也不是失败
  /// （可能只是合法空结果）。界面上必须与这两者都区分开。
  unconfirmed,

  /// 存在明确的网络 / HTTP / 认证 / 业务 / 响应格式 / 映射错误。
  failed,
}

String declarativeVerificationConfidenceLabel(
  DeclarativeVerificationConfidence confidence,
) => switch (confidence) {
  DeclarativeVerificationConfidence.verified => '已验证可用',
  DeclarativeVerificationConfidence.unconfirmed => '未能确认',
  DeclarativeVerificationConfidence.failed => '验证失败',
};
