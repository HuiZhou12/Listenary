import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 应用层不得依赖 Provider 的**实现**。
///
/// 两类受限例外：
/// - 设置页的在线音乐配置面板：职责就是编辑 Provider 配置，允许引用 `provider/`
///   层的配置契约，但仍禁止引用任何 ChkSz 实现类型；
/// - `lib/core/preference.dart`：把 `OnlineMusicSettings` 作为**应用偏好状态**读写。
///   这是基线 HEAD 上**既已存在**的依赖（当时 import 的是 `provider/` 深路径），
///   不是本次新增的分层依据。
const _configurationPanelPaths = {
  'lib/page/settings_page/online_music_settings.dart',
  'lib/page/settings_page/online_music_capability_editor.dart',
};

/// 任何文件（含配置面板）出现即失败。
final _implementationSymbols = RegExp(
  r'\b(?:ChkszRuntime|ChkszException|ChkszCancelToken|ChkszNeteaseCodec'
  r'|ChkszOnlineMusicProvider|ChkszCredentialAccess|ChkszClient'
  r'|OnlineMusicProviderRegistry|CompositeOnlineMusicService'
  r'|OnlineMusicProviderAuth|OnlineMusicAuthResolver'
  r'|MusicCatalogService|NeteaseStreamResolver)\b',
);

/// 允许提及 `OnlineMusicSettings` 的**非面板**文件（**仅此一个**）。
///
/// ⚠️ 这是**接受的现存债务**，不是分层正确性的证明：
/// `lib/core` → `lib/services` 是**向上**依赖，而 `lib/services` 已有 8 条向下依赖
/// （如 `services/online_lyric/api/net_lyric_api.dart` → `core/settings.dart`），
/// 目录层面因此存在环。项目目前**没有**成文的分层方向规定
/// （`references/architecture.md` 只定义职责与"页面不直连"）。
///
/// 本集合只豁免**符号提及**，不豁免深路径：这里的消费者仍必须走公开端口
/// `services/music_platform/index.dart`。新增消费者需要显式批准，不得自行加入。
const _configContractConsumers = {
  'lib/core/preference.dart',
};

/// Provider 层**内部**的配置符号；除 [_configurationPanelPaths] 与
/// [_configContractConsumers] 外，任何文件提及即失败。
final _configurationSymbols = RegExp(
  r'\b(?:OnlineMusicSettings|OnlineMusicProviderDefinition'
  r'|OnlineMusicCapability|OnlineMusicProviderSettingsController'
  r'|OnlineMusicCredentialAccess)\b',
);

/// 纳入检查的应用层目录。
///
/// `lib/core`、`lib/library` 与外围同一标准：任一判据命中即失败。
/// 此前只查 `lib/page`、`lib/component`、`lib/play_service`，于是
/// `lib/core/preference.dart` 直连 `provider/` 深路径长期落在扫描范围之外。
const _applicationRoots = [
  'lib/page',
  'lib/component',
  'lib/play_service',
  'lib/core',
  'lib/library',
];

/// 本测试的**能力边界**（不得表述为已保证依赖方向）：
/// - 它是**纯文本匹配**，不解析 import 图 ⇒ 传递依赖（`A → B → provider/`）无法发现；
/// - 它验证的是"导入路径与符号文本符合约定"，**不验证依赖方向**；
/// - `lib/main.dart`、`lib/entry.dart` 是**组合根**，本来就要构造具体实现，
///   未纳入；纳入前需要先定义"组合根允许引用什么"的规则；
/// - `services/music_platform/declarative/` 的深路径**未**被路径判据覆盖
///   （设置页的探测计划对话框引用它）。收口它需要一次显式的契约设计，
///   而不是把它加进豁免名单。

void main() {
  test('application layers do not import provider implementation types', () {
    final violations = <String>[];
    for (final root in _applicationRoots) {
      for (final entity in Directory(root).listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        final source = entity.readAsStringSync();
        final path = entity.path.replaceAll(r'\', '/');
        final isConfigurationPanel = _configurationPanelPaths.contains(path);
        final mayUseConfigContract = _configContractConsumers.contains(path);
        final banned =
            source.contains('services/music_platform/chksz/') ||
            _implementationSymbols.hasMatch(source) ||
            (!isConfigurationPanel &&
                (source.contains('services/music_platform/provider/') ||
                    (!mayUseConfigContract &&
                        _configurationSymbols.hasMatch(source))));
        if (banned) violations.add(entity.path);
      }
    }
    expect(violations, isEmpty, reason: violations.join('\n'));
  });
}
