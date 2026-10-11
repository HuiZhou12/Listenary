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

/// 一次"配置验证"的**四个阶段**（F3-1 / Spec §9.3、§13.4.2）。
///
/// 为什么要把阶段与置信度**分开**：三态只回答"这份配置被证明可用了吗"，
/// 不回答"**走到哪一步失败的**"。以前只有单个数（`score`），于是
/// "配置写错没发出去"、"连不上"、"服务端判失败"、"映射不全"会塌缩成同一句话，
/// 用户不知道该改哪里（P-07 / P-16 / P-45 的共同形态）。
enum DeclarativeVerificationStage {
  /// ① 配置自洽：校验是否为空（含敏感头、认证矛盾、参数绑定）。
  config,

  /// ② 传输：是否真的发出、HTTP 状态、超时 / DNS / 连接 / TLS / 取消。
  transport,

  /// ③ 判定：`success` 谓词（状态码 + `allOf`）是否成立（含"响应不可读"）。
  judgement,

  /// ④ 映射：`listPath` / 字段根路径 / 必需字段 / 分页是否读得出。
  mapping,
}

/// 单个阶段的状态（F3-1）。
///
/// [notRun] 是本片新增的关键区分：**前序阶段已经失败 ⇒ 它根本没轮到**。
/// 把它报成"失败"等于谎称我们试过（与 `ProviderProbeStatus.notAttempted` 同一教训）。
enum DeclarativeVerificationStageStatus {
  passed,
  failed,

  /// 没轮到（前序已失败 / 整个探测未被尝试）。
  notRun,

  /// 该阶段不适用（例如没有可判定的谓词）。
  notEvaluable,
}

String declarativeVerificationStageLabel(DeclarativeVerificationStage stage) =>
    switch (stage) {
      DeclarativeVerificationStage.config => '配置',
      DeclarativeVerificationStage.transport => '传输',
      DeclarativeVerificationStage.judgement => '判定',
      DeclarativeVerificationStage.mapping => '映射',
    };

String declarativeVerificationStageStatusLabel(
  DeclarativeVerificationStageStatus status,
) => switch (status) {
  DeclarativeVerificationStageStatus.passed => '通过',
  DeclarativeVerificationStageStatus.failed => '失败',
  DeclarativeVerificationStageStatus.notRun => '未运行',
  DeclarativeVerificationStageStatus.notEvaluable => '不适用',
};
