import 'package:pure_music/services/music_platform/provider/online_music_request_spec.dart';

/// 按**凭据引用**（槽位名）读写凭据。
///
/// 界面用它来配置任意条目——包括刚新增、尚未组装成运行中 Provider 的条目，
/// 因此不需要先重启。引用只是槽位名，任何实现都不得返回或记录凭据值本身。
abstract interface class OnlineMusicCredentialAccess {
  String get credentialDisplayName;

  String get inputHint;

  bool isValidFormat(String value);

  Future<bool> isConfigured(String reference);

  Future<void> save(String reference, String value);

  Future<void> clear(String reference);
}

/// 按引用**读取凭据值**，供发起请求时注入。
///
/// 与 [OnlineMusicCredentialAccess] 分开是刻意的：设置界面只用前者（它拿不到凭据值），
/// 只有真正要发请求的执行者才需要后者。
abstract interface class OnlineMusicCredentialReader {
  Future<String?> readCredential(String reference);
}

/// 读取一份请求声明里**逐请求头**引用的凭据值（F0 / Spec §3）。
///
/// 只为声明了 `credentialReference` 的请求头读取；同一引用只读一次
/// （多个能力指向同一槽位是 Spec §3 允许的**显式**共享）。
///
/// 刻意**不吞异常**：存储读取失败与"槽位是空的"是两件事，只有后者才该被报成
/// "没有可用凭据"。空值同样视为"没有" —— 请求构造层会据此明确失败，
/// 而不是发出一个空的敏感请求头。
Future<Map<String, String>> readHeaderCredentialValues({
  required OnlineMusicRequestSpec spec,
  required OnlineMusicCredentialReader reader,
}) async {
  final references = <String>{
    for (final header in spec.headers)
      if (header.credentialReference != null) header.credentialReference!,
  };
  if (references.isEmpty) return const {};
  final values = <String, String>{};
  for (final reference in references) {
    final value = await reader.readCredential(reference);
    if (value != null && value.isNotEmpty) values[reference] = value;
  }
  return values;
}
