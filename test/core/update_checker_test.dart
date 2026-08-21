import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/core/update_checker.dart';

void main() {
  group('compareSemVer', () {
    test('detects a higher remote version', () {
      expect(UpdateChecker.compareSemVer('v3.1.0', '3.0.0'), greaterThan(0));
      expect(UpdateChecker.compareSemVer('3.1.0', '3.0.0'), greaterThan(0));
    });

    test('treats equal versions and v-prefix as equal', () {
      expect(UpdateChecker.compareSemVer('v3.0.0', '3.0.0'), 0);
      expect(UpdateChecker.compareSemVer('3.0.0', '3.0.0'), 0);
    });

    test('detects a lower remote version', () {
      expect(UpdateChecker.compareSemVer('v2.9.0', '3.0.0'), lessThan(0));
    });
  });

  group('hasNewVersion', () {
    test('reports an update from 3.0.0 to 3.1.0', () {
      expect(UpdateChecker.hasNewVersion('v3.1.0', '3.0.0'), isTrue);
    });

    test('does not report an update for the current version', () {
      expect(UpdateChecker.hasNewVersion('v3.0.0', '3.0.0'), isFalse);
    });
  });
}
