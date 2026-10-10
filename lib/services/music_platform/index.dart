export 'package:pure_music/services/music_platform/provider/online_music_provider_settings.dart' show platformLabelForIdentityOnly;
export 'package:pure_music/services/music_platform/provider/online_music_provider_settings.dart' show platformLabelForRef;
export 'models/music_models.dart';
export 'online_music_credentials.dart';
// P-29：诊断出口（窄接口 + 已本地化/已脱敏的 DTO）。应用层只读这些字符串，
// 不引用 Provider 层的实现符号。
export 'online_music_diagnostics.dart';
export 'online_music_error.dart';
export 'online_music_request.dart';
export 'online_music_service.dart';
export 'remote_stream_coordinator.dart';
