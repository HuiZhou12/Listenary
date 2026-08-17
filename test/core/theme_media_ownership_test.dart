import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/core/theme.dart';

void main() {
  test('remote ownership rejects local theme writes until released', () {
    final ownership = LocalMediaThemeOwnership();

    expect(ownership.allowsLocalMediaWrites, isTrue);
    expect(ownership.setSuppressed(true), isTrue);
    expect(ownership.allowsLocalMediaWrites, isFalse);
    expect(ownership.setSuppressed(true), isFalse);
    expect(ownership.setSuppressed(false), isTrue);
    expect(ownership.allowsLocalMediaWrites, isTrue);
  });
}
