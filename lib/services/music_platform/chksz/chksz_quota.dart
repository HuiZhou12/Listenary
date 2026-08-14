final class ChkszQuotaSnapshot {
  const ChkszQuotaSnapshot({
    this.rateLimit,
    this.freeRemaining,
    this.paidRemaining,
  });

  final int? rateLimit;
  final int? freeRemaining;
  final int? paidRemaining;

  bool get hasData =>
      rateLimit != null || freeRemaining != null || paidRemaining != null;

  factory ChkszQuotaSnapshot.fromHeaders(Map<String, List<String>> headers) {
    return ChkszQuotaSnapshot(
      rateLimit: _nonNegativeHeaderInt(headers, 'X-RateLimit-Limit'),
      freeRemaining: _nonNegativeHeaderInt(headers, 'X-Quota-Free-Remaining'),
      paidRemaining: _nonNegativeHeaderInt(headers, 'X-Quota-Paid-Remaining'),
    );
  }
}

String? chkszHeaderValue(Map<String, List<String>> headers, String name) {
  for (final entry in headers.entries) {
    if (entry.key.toLowerCase() != name.toLowerCase()) continue;
    return entry.value.isEmpty ? null : entry.value.first.trim();
  }
  return null;
}

int? _nonNegativeHeaderInt(Map<String, List<String>> headers, String name) {
  final value = int.tryParse(chkszHeaderValue(headers, name) ?? '');
  return value != null && value >= 0 ? value : null;
}
