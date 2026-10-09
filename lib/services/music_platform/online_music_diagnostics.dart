import 'package:pure_music/services/music_platform/models/music_models.dart';
import 'package:pure_music/services/music_platform/online_music_error.dart';
import 'package:pure_music/services/music_platform/provider/online_music_capability.dart';
import 'package:pure_music/services/music_platform/provider/online_music_route_diagnostics.dart';

/// 错误分类的界面标签（诊断视图用）。
///
/// 与 `declarativeTestFailureLabel`（试跑那一套更粗的词表）不同：这里就是**统一分类**
/// 自己的名字，因此诊断里看到的词与运行期判定的是同一个词（P-16 之后的单一事实源）。
String onlineMusicErrorKindLabel(OnlineMusicErrorKind kind) => switch (kind) {
  OnlineMusicErrorKind.badRequest => '请求参数无效',
  OnlineMusicErrorKind.notConfigured => '缺少/无效凭据',
  OnlineMusicErrorKind.quotaExhausted => '额度用尽',
  OnlineMusicErrorKind.forbidden => '被拒绝',
  OnlineMusicErrorKind.notFound => '资源不存在',
  OnlineMusicErrorKind.rateLimited => '被限流',
  OnlineMusicErrorKind.unavailable => '服务暂不可用',
  OnlineMusicErrorKind.businessFailure => '业务失败',
  OnlineMusicErrorKind.invalidResponse => '响应无法识别',
  OnlineMusicErrorKind.endpointMismatch => '接口定义不匹配',
  OnlineMusicErrorKind.cancelled => '已取消',
  OnlineMusicErrorKind.network => '网络',
  OnlineMusicErrorKind.unknown => '未知',
};

/// 诊断视图用的**一行**记录（P-29）。
///
/// 刻意只带**已经本地化、已经脱敏**的字符串：
/// - 应用层（`lib/page`、`lib/component`）不得引用 Provider 层的配置/实现符号
///   （`online_music_dependency_boundary_test` 是纯文本扫描），因此诊断数据在
///   **服务层**就把平台名、能力名、错误类别拼成人类可读的行；
/// - 记录里**只有 providerId 与错误类别**，不含请求头、查询串、响应片段或凭据
///   （Spec §6.4 `:205` 的数据形状 + §6.5 `:227` 的脱敏要求）。
final class OnlineMusicDiagnosticsEntry {
  const OnlineMusicDiagnosticsEntry({
    required this.platformLabel,
    required this.capabilityLabel,
    required this.attempts,
    this.winnerProviderId,
  });

  final String platformLabel;
  final String capabilityLabel;

  /// 按尝试顺序的失败项，形如 `chksz（网络）`。
  final List<String> attempts;

  /// 实际成功的 Provider id；全部失败或未回退时为 null。
  final String? winnerProviderId;

  bool get didFallback => attempts.isNotEmpty;

  /// 单行摘要：`网易云/搜索：chksz（网络） → qq（成功）`。
  String get summary =>
      '$platformLabel/$capabilityLabel：'
      '${attempts.isEmpty ? '首次命中' : attempts.join(' → ')}'
      '${winnerProviderId == null ? '' : ' → $winnerProviderId（成功）'}';
}

/// 诊断数据的**只读出口**（P-29）。
///
/// 为什么不直接往 [OnlineMusicService] 加成员：Dart 的 `implements` **不继承实现**，
/// 现有 10 个测试替身只实现 `OnlineMusicService`，加一个成员就会让它们全部编译失败。
/// 因此诊断单独成为一个窄接口，由**实现了两者的那个类**顺带暴露，
/// 消费者（设置页）通过运行时 `is` 检查取用 —— 拿不到就说明这一版没有诊断可用。
abstract interface class OnlineMusicDiagnosticsSource {
  /// 最近的路由记录（**新的在前**），已本地化、已脱敏。
  List<OnlineMusicDiagnosticsEntry> get routeDiagnostics;
}

/// 把路由记录转成诊断行（服务层内部使用）。
List<OnlineMusicDiagnosticsEntry> buildOnlineMusicDiagnostics(
  List<OnlineMusicRouteRecord> records,
) => [
  for (final record in records)
    OnlineMusicDiagnosticsEntry(
      platformLabel: musicPlatformLabel(record.platform),
      capabilityLabel: onlineMusicCapabilityLabel(record.capability),
      attempts: [
        for (final attempt in record.attempts)
          '${attempt.providerId}（${onlineMusicErrorKindLabel(attempt.kind)}）',
      ],
      winnerProviderId: record.winnerProviderId,
    ),
];
