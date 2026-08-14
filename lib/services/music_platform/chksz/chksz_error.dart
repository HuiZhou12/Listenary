import 'package:pure_music/core/utils.dart';

enum ChkszErrorKind {
  badRequest,
  unauthorized,
  quotaExhausted,
  forbidden,
  notFound,
  rateLimited,
  unavailable,
  businessFailure,
  invalidResponse,
  cancelled,
  network,
  unknown,
}

final class ChkszException implements Exception {
  const ChkszException({
    required this.kind,
    required this.safeMessage,
    this.statusCode,
    this.retryAfter,
  });

  final ChkszErrorKind kind;
  final String safeMessage;
  final int? statusCode;
  final Duration? retryAfter;

  factory ChkszException.cancelled() => const ChkszException(
    kind: ChkszErrorKind.cancelled,
    safeMessage: '请求已取消',
  );

  factory ChkszException.network() => const ChkszException(
    kind: ChkszErrorKind.network,
    safeMessage: '网络请求失败，请稍后重试',
  );

  factory ChkszException.fromResponse({
    required int statusCode,
    required Object? data,
    Duration? retryAfter,
  }) {
    final message = chkszSafeBusinessMessage(data);
    final kind = switch (statusCode) {
      400 => ChkszErrorKind.badRequest,
      401 => ChkszErrorKind.unauthorized,
      402 => ChkszErrorKind.quotaExhausted,
      403 => ChkszErrorKind.forbidden,
      404 => ChkszErrorKind.notFound,
      429 => ChkszErrorKind.rateLimited,
      503 => ChkszErrorKind.unavailable,
      _ => ChkszErrorKind.unknown,
    };
    final fallback = switch (kind) {
      ChkszErrorKind.badRequest => '请求参数无效',
      ChkszErrorKind.unauthorized => 'API Key 缺失、无效或登录已失效',
      ChkszErrorKind.quotaExhausted => '免费和付费额度均已用尽',
      ChkszErrorKind.forbidden => '请求被拒绝',
      ChkszErrorKind.notFound => '接口或资源不存在',
      ChkszErrorKind.rateLimited => '请求过于频繁，请稍后重试',
      ChkszErrorKind.unavailable => '音乐服务暂不可用',
      _ => '音乐服务请求失败',
    };
    return ChkszException(
      kind: kind,
      safeMessage: message == null ? fallback : '$fallback：$message',
      statusCode: statusCode,
      retryAfter: retryAfter,
    );
  }

  factory ChkszException.businessFailure(Object? data) {
    final message = chkszSafeBusinessMessage(data);
    return ChkszException(
      kind: ChkszErrorKind.businessFailure,
      safeMessage: message == null ? '业务请求失败' : '业务请求失败：$message',
    );
  }

  @override
  String toString() => 'ChkszException($kind, $safeMessage)';
}

String? chkszSafeBusinessMessage(Object? data) {
  if (data is! Map) return null;
  final raw = data['msg'];
  if (raw is! String || raw.trim().isEmpty) return null;
  return redactDiagnosticData(raw.trim());
}
