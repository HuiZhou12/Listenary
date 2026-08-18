enum OnlineMusicErrorKind {
  badRequest,
  notConfigured,
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

final class OnlineMusicException implements Exception {
  const OnlineMusicException({
    required this.kind,
    required this.safeMessage,
    this.retryAfter,
  });

  final OnlineMusicErrorKind kind;
  final String safeMessage;
  final Duration? retryAfter;

  @override
  String toString() => 'OnlineMusicException(${kind.name}, $safeMessage)';
}
