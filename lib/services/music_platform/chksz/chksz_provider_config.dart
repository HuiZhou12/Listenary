import 'package:pure_music/services/music_platform/provider/online_music_provider_settings.dart';

/// ChkSz Provider 的连接配置：base URL 与超时。
///
/// 默认值与既有线上行为一致；不同 Provider 条目可以各自持有自己的配置，
/// 因此 base URL 不再由编译期常量全局决定。
final class ChkszProviderConfig {
  const ChkszProviderConfig({
    this.baseUrl = defaultOnlineMusicBaseUrl,
    this.connectTimeout = defaultOnlineMusicConnectTimeout,
    this.sendTimeout = defaultOnlineMusicSendTimeout,
    this.receiveTimeout = defaultOnlineMusicReceiveTimeout,
  });

  static const defaults = ChkszProviderConfig();

  final String baseUrl;
  final Duration connectTimeout;
  final Duration sendTimeout;
  final Duration receiveTimeout;
}
