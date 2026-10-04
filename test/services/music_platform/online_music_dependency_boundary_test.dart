import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('application layers do not import provider implementation types', () {
    const roots = ['lib/page', 'lib/component', 'lib/play_service'];
    final violations = <String>[];
    for (final root in roots) {
      for (final entity in Directory(root).listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        final source = entity.readAsStringSync();
        if (source.contains('services/music_platform/chksz/') ||
            source.contains('services/music_platform/adapters/') ||
            source.contains('services/music_platform/provider/') ||
            RegExp(
              r'\b(?:ChkszRuntime|ChkszException|ChkszCancelToken|NeteaseAdapter'
              r'|OnlineMusicProvider|OnlineMusicProviderRegistry'
              r'|CompositeOnlineMusicService|OnlineMusicCapability'
              r'|OnlineMusicProviderAuth)\b',
            ).hasMatch(source)) {
          violations.add(entity.path);
        }
      }
    }
    expect(violations, isEmpty, reason: violations.join('\n'));
  });
}
