import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 应用层不得依赖 Provider 的**实现**。
///
/// 唯一的例外是设置页的在线音乐配置面板：它的职责就是编辑 Provider 配置，
/// 因此允许它引用 provider 层的**配置契约**（`OnlineMusicSettings` 等），
/// 但仍然禁止它引用任何 ChkSz 实现类型。
const _configurationPanelPath =
    'lib/page/settings_page/online_music_settings.dart';

final _implementationSymbols = RegExp(
  r'\b(?:ChkszRuntime|ChkszException|ChkszCancelToken|ChkszNeteaseCodec'
  r'|ChkszOnlineMusicProvider|ChkszCredentialAccess|ChkszClient'
  r'|OnlineMusicProviderRegistry|CompositeOnlineMusicService'
  r'|OnlineMusicProviderAuth|OnlineMusicAuthResolver'
  r'|MusicCatalogService|NeteaseStreamResolver)\b',
);

final _configurationSymbols = RegExp(
  r'\b(?:OnlineMusicSettings|OnlineMusicProviderDefinition'
  r'|OnlineMusicCapability|OnlineMusicProviderSettingsController'
  r'|OnlineMusicCredentialAccess)\b',
);

void main() {
  test('application layers do not import provider implementation types', () {
    const roots = ['lib/page', 'lib/component', 'lib/play_service'];
    final violations = <String>[];
    for (final root in roots) {
      for (final entity in Directory(root).listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        final source = entity.readAsStringSync();
        final path = entity.path.replaceAll(r'\', '/');
        final isConfigurationPanel = path == _configurationPanelPath;
        final banned =
            source.contains('services/music_platform/chksz/') ||
            _implementationSymbols.hasMatch(source) ||
            (!isConfigurationPanel &&
                (source.contains('services/music_platform/provider/') ||
                    _configurationSymbols.hasMatch(source)));
        if (banned) violations.add(entity.path);
      }
    }
    expect(violations, isEmpty, reason: violations.join('\n'));
  });
}
