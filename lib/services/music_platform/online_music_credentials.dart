enum OnlineMusicCredentialOperation { read, save, clear }

final class OnlineMusicCredentialException implements Exception {
  const OnlineMusicCredentialException({
    required this.operation,
    required this.safeMessage,
  });

  final OnlineMusicCredentialOperation operation;
  final String safeMessage;

  @override
  String toString() =>
      'OnlineMusicCredentialException(${operation.name}, $safeMessage)';
}

abstract interface class OnlineMusicCredentialController {
  String get providerDisplayName;
  String get credentialDisplayName;
  String get inputHint;

  bool isCredentialFormatValid(String value);

  Future<bool> isConfigured();

  Future<void> saveCredential(String value);

  Future<void> clearCredential();
}
