/// ChkSz Provider 的连接配置：base URL 与超时。
///
/// 默认值与既有线上行为一致；不同 Provider 条目可以各自持有自己的配置，
/// 因此 base URL 不再由编译期常量全局决定。
final class ChkszProviderConfig {
  const ChkszProviderConfig({
    this.baseUrl = defaultChkszBaseUrl,
    this.connectTimeout = defaultChkszConnectTimeout,
    this.sendTimeout = defaultChkszSendTimeout,
    this.receiveTimeout = defaultChkszReceiveTimeout,
  });

  static const defaults = ChkszProviderConfig();

  final String baseUrl;
  final Duration connectTimeout;
  final Duration sendTimeout;
  final Duration receiveTimeout;
}

const defaultChkszBaseUrl = 'https://api.chksz.com';
const defaultChkszConnectTimeout = Duration(seconds: 8);
const defaultChkszSendTimeout = Duration(seconds: 8);
const defaultChkszReceiveTimeout = Duration(seconds: 10);

/// 只接受 http/https 且带 host 的绝对地址；其余一律回落默认值。
String normalizeChkszBaseUrl(Object? value) {
  if (value is! String) return defaultChkszBaseUrl;
  final normalized = value.trim();
  if (normalized.isEmpty) return defaultChkszBaseUrl;
  final uri = Uri.tryParse(normalized);
  if (uri == null) return defaultChkszBaseUrl;
  if (uri.scheme != 'http' && uri.scheme != 'https') return defaultChkszBaseUrl;
  if (uri.host.isEmpty) return defaultChkszBaseUrl;
  return normalized;
}

/// 非正数或不可解析的值回落默认超时。
Duration normalizeChkszTimeout(
  Object? value, {
  required Duration defaultValue,
}) {
  final milliseconds = switch (value) {
    int() => value,
    num() => value.isFinite ? value.toInt() : null,
    String() => int.tryParse(value.trim()),
    _ => null,
  };
  if (milliseconds == null || milliseconds <= 0) return defaultValue;
  return Duration(milliseconds: milliseconds);
}
