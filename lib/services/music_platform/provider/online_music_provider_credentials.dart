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
