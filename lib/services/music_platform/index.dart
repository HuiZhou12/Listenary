export 'package:pure_music/services/music_platform/provider/online_music_provider_settings.dart' show platformLabelForIdentityOnly;
export 'package:pure_music/services/music_platform/provider/online_music_provider_settings.dart' show platformLabelForRef;
// `OnlineMusicSettings` 是应用层要**持有**的配置契约（`core/preference.dart` 把它当
// 偏好状态读写、`main.dart` 读它做装配）。在这里正式发布，应用层就不必再深入
// `provider/` 路径引用它 —— 架构边界测试因此可以把 `lib/core` 纳入检查，
// 而不必为它扩大任何豁免。
export 'package:pure_music/services/music_platform/provider/online_music_provider_settings.dart'
    show OnlineMusicSettings;
export 'models/music_models.dart';
export 'online_music_credentials.dart';
// P-29：诊断出口（窄接口 + 已本地化/已脱敏的 DTO）。应用层只读这些字符串，
// 不引用 Provider 层的实现符号。
export 'online_music_diagnostics.dart';
export 'online_music_error.dart';
export 'online_music_request.dart';
export 'online_music_service.dart';
export 'remote_stream_coordinator.dart';
