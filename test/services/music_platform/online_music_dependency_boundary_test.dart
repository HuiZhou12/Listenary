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

/// 本文件第二个测试冻结的 `lib/core` ↔ `lib/services` **直接 import 边**基线。
///
/// 这些是 HEAD 上**既已存在**的边，不是"正确依赖方向"的声明：项目没有
/// 成文的分层方向规定，目录层面存在环（3 条 core→services 与 8 条
/// services→core 并存）。本测试只检测基线**增删**；任何变动都需要显式评审，
/// 不得为了"让测试变绿"而直接改这里。
const _baselineCoreToServicesEdges = <String>[
  'lib/core/matcher.dart -> lib/services/online_lyric/api/net_lyric_api.dart',
  'lib/core/matcher.dart -> lib/services/online_lyric/parsed_lyric_converter.dart',
  'lib/core/preference.dart -> lib/services/music_platform/index.dart',
];

const _baselineServicesToCoreEdges = <String>[
  'lib/services/music_platform/chksz/chksz_error.dart -> lib/core/utils.dart',
  'lib/services/music_platform/chksz/chksz_online_music_provider.dart -> lib/core/preference.dart',
  'lib/services/music_platform/provider/online_music_provider_settings.dart -> lib/core/preference.dart',
  'lib/services/music_platform/provider/online_music_provider_settings_controller.dart -> lib/core/preference.dart',
  'lib/services/music_platform/provider/online_music_provider_settings_controller.dart -> lib/core/settings.dart',
  'lib/services/online_lyric/api/net_lyric_api.dart -> lib/core/settings.dart',
  'lib/services/online_lyric/parsed_lyric_converter.dart -> lib/core/settings.dart',
  'lib/services/online_lyric/parsed_lyric_converter.dart -> lib/core/utils.dart',
];

/// 本测试的**能力边界**（不得表述为已保证依赖方向）：
/// - 首个测试是**纯文本匹配**，不解析 import 图 ⇒ 传递依赖（`A → B → provider/`）
///   无法发现；
/// - 第二个测试基于 import 指令词法扫描（剥离行/块注释、保留字符串内容），
///   只冻结 core↔services 的**直接边**，同样**不**发现传递依赖，
///   也不验证运行时或语义上的方向；
/// - `lib/main.dart`、`lib/entry.dart` 是**组合根**：第二个测试扫描整个 `lib/`，
///   但没有排除它们，只是 core↔services 边必须有一个端点落在两目录内，
///   组合根因此不会成为这类边；
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

  test('core/services direct import edges match the frozen baseline', () {
    final edges = <String>[];

    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final sourcePath = _normalizePath(entity.path);
      if (sourcePath == null) continue;
      edges.addAll(_crossLayerEdges(sourcePath, entity.readAsStringSync()));
    }

    final coreToServices =
        edges.where((edge) => edge.startsWith('lib/core/')).toList()..sort();
    final servicesToCore = edges
        .where((edge) => edge.startsWith('lib/services/'))
        .toList()
      ..sort();

    expect(
      coreToServices,
      _baselineCoreToServicesEdges,
      reason: 'lib/core → lib/services 的直接 import 边已偏离冻结基线。\n'
          '实际：$coreToServices\n'
          '若确有需要新增/删除跨层边，请先显式评审并同步更新 allowlist，'
          '不要仅为让测试变绿而改基线。',
    );
    expect(
      servicesToCore,
      _baselineServicesToCoreEdges,
      reason: 'lib/services → lib/core 的直接 import 边已偏离冻结基线。\n'
          '实际：$servicesToCore\n'
          '若确有需要新增/删除跨层边，请先显式评审并同步更新 allowlist，'
          '不要仅为让测试变绿而改基线。',
    );
  });

  test('F1: multiple and comment-prefixed import directives are collected', () {
    const source = '''
/* prefix */ import 'package:pure_music/core/a.dart';
import 'package:pure_music/services/b.dart'; import 'package:pure_music/services/c.dart' as c;
''';
    expect(
      _crossLayerEdges('lib/core/fixture.dart', source),
      [
        'lib/core/fixture.dart -> lib/services/b.dart',
        'lib/core/fixture.dart -> lib/services/c.dart',
      ],
    );
  });

  test('F2: import-looking text in comments or strings is ignored', () {
    const source = r'''
// import 'package:pure_music/services/line_comment.dart';
/* block comment
import 'package:pure_music/services/block_comment.dart';
*/
/* prefix import 'package:pure_music/services/block_prefix.dart'; */
const note = "import 'package:pure_music/services/in_double_quote.dart';";
const rawNote = r'import "package:pure_music/services/in_raw_string.dart";';
import 'package:pure_music/services/real.dart';
''';
    expect(
      _crossLayerEdges('lib/core/fixture.dart', source),
      ['lib/core/fixture.dart -> lib/services/real.dart'],
    );
  });

  test('F3: root-escaping and absolute paths are ignored', () {
    const source = '''
import '../../../../outside.dart';
import '/absolute.dart';
import 'file:///absolute.dart';
import '../../services/relative.dart';
import 'package:pure_music/services/real.dart';
''';
    expect(
      _crossLayerEdges('lib/core/deep/fixture.dart', source),
      [
        'lib/core/deep/fixture.dart -> lib/services/real.dart',
        'lib/core/deep/fixture.dart -> lib/services/relative.dart',
      ],
    );
  });
}

/// 计算单个源文件的 core↔services 直接 import 边（用于主检查与 fixture 单测）。
List<String> _crossLayerEdges(String sourcePath, String source) {
  final sourceIsCore = sourcePath.startsWith('lib/core/');
  final sourceIsServices = sourcePath.startsWith('lib/services/');
  if (!sourceIsCore && !sourceIsServices) return const [];

  final edges = <String>[];
  for (final uri in _importUris(source)) {
    final targetPath = _resolveImport(sourcePath, uri);
    if (targetPath == null) continue;
    final targetIsCore = targetPath.startsWith('lib/core/');
    final targetIsServices = targetPath.startsWith('lib/services/');
    if ((sourceIsCore && targetIsServices) ||
        (sourceIsServices && targetIsCore)) {
      edges.add('$sourcePath -> $targetPath');
    }
  }
  edges.sort();
  return edges;
}

/// 收集全部 import 指令中的 URI 字符串（含条件导入的多候选形式）。
///
/// 先做最小词法扫描：忽略行/块注释（块注释支持嵌套），跳过字符串字面量，
/// 因此同一行多条 import 与注释后的 import 都能识别，而注释/字符串里的
/// “import” 文本不会被误计。不解析 export、插值表达式或语义。
List<String> _importUris(String source) {
  final uris = <String>[];
  var i = 0;
  while (i < source.length) {
    final char = source[i];
    final next = i + 1 < source.length ? source[i + 1] : '';
    if (char == '/' && next == '/') {
      i = _skipLineComment(source, i + 2);
      continue;
    }
    if (char == '/' && next == '*') {
      i = _skipBlockComment(source, i);
      continue;
    }
    if (_isQuote(char)) {
      i = _scanString(source, i).end;
      continue;
    }
    if (_isIdentifierStart(char)) {
      final start = i;
      i++;
      while (i < source.length && _isIdentifierPart(source[i])) {
        i++;
      }
      if (source.substring(start, i) == 'import') {
        final directive = _scanDirective(source, i);
        if (directive != null) {
          uris.addAll(directive.uris);
          i = directive.end;
        }
      }
      continue;
    }
    i++;
  }
  return uris;
}

class _DirectiveScan {
  const _DirectiveScan(this.uris, this.end);

  final List<String> uris;
  final int end;
}

class _StringScan {
  const _StringScan(this.value, this.end);

  final String value;
  final int end;
}

/// 从 `import` 关键字之后扫描到分号，收集其中的字符串字面量。
_DirectiveScan? _scanDirective(String source, int start) {
  final uris = <String>[];
  var i = start;
  while (i < source.length) {
    final char = source[i];
    final next = i + 1 < source.length ? source[i + 1] : '';
    if (char == ';') {
      return uris.isEmpty ? null : _DirectiveScan(uris, i + 1);
    }
    if (char == '/' && next == '/') {
      i = _skipLineComment(source, i + 2);
      continue;
    }
    if (char == '/' && next == '*') {
      i = _skipBlockComment(source, i);
      continue;
    }
    if (_isQuote(char)) {
      final string = _scanString(source, i);
      uris.add(string.value);
      i = string.end;
      continue;
    }
    i++;
  }
  return null;
}

/// 读取一个字符串字面量；支持 raw 前缀与三引号，普通字符串处理转义。
_StringScan _scanString(String source, int start) {
  final quote = source[start];
  final raw = start > 0 &&
      (source[start - 1] == 'r' || source[start - 1] == 'R') &&
      (start < 2 || !_isIdentifierPart(source[start - 2]));
  final triple = start + 2 < source.length &&
      source[start + 1] == quote &&
      source[start + 2] == quote;
  var i = start + (triple ? 3 : 1);
  final value = StringBuffer();

  while (i < source.length) {
    final char = source[i];
    if (!raw && char == '\\' && i + 1 < source.length) {
      value.write(source[i + 1]);
      i += 2;
      continue;
    }
    if (triple) {
      if (char == quote &&
          i + 2 < source.length &&
          source[i + 1] == quote &&
          source[i + 2] == quote) {
        return _StringScan(value.toString(), i + 3);
      }
    } else if (char == quote) {
      return _StringScan(value.toString(), i + 1);
    }
    value.write(char);
    i++;
  }
  return _StringScan(value.toString(), i);
}

int _skipLineComment(String source, int start) {
  var i = start;
  while (i < source.length && source[i] != '\n' && source[i] != '\r') {
    i++;
  }
  return i;
}

/// `start` 指向 `/*`；Dart 块注释可嵌套。
int _skipBlockComment(String source, int start) {
  var depth = 0;
  var i = start;
  while (i < source.length) {
    if (source.startsWith('/*', i)) {
      depth++;
      i += 2;
    } else if (source.startsWith('*/', i)) {
      depth--;
      i += 2;
      if (depth == 0) return i;
    } else {
      i++;
    }
  }
  return i;
}

bool _isQuote(String char) => char == "'" || char == '"';

bool _isIdentifierStart(String char) {
  final code = char.codeUnitAt(0);
  return char == '_' ||
      char == r'$' ||
      (code >= 65 && code <= 90) ||
      (code >= 97 && code <= 122);
}

bool _isIdentifierPart(String char) {
  final code = char.codeUnitAt(0);
  return _isIdentifierStart(char) || (code >= 48 && code <= 57);
}

/// 把 import URI 解析为仓库内 `lib/...` 路径；本包之外、绝对路径或越根路径
/// 返回 `null`。
String? _resolveImport(String sourcePath, String uri) {
  const packagePrefix = 'package:pure_music/';
  if (uri.startsWith(packagePrefix)) {
    return _normalizePath('lib/${uri.substring(packagePrefix.length)}');
  }
  if (uri.startsWith('dart:') || uri.startsWith('package:')) return null;
  if (uri.startsWith('/')) return null;
  final parsed = Uri.tryParse(uri);
  if (parsed == null || parsed.hasScheme) return null;
  final sourceDir = sourcePath.split('/')..removeLast();
  return _normalizePath('${sourceDir.join('/')}/$uri');
}

/// 统一为 `/` 分隔、无 `.`/`..` 的相对仓库路径；越过仓库根时返回 `null`。
String? _normalizePath(String path) {
  final parts = <String>[];
  for (final part in path.replaceAll('\\', '/').split('/')) {
    if (part.isEmpty || part == '.') continue;
    if (part == '..') {
      if (parts.isEmpty) return null;
      parts.removeLast();
      continue;
    }
    parts.add(part);
  }
  return parts.isEmpty ? null : parts.join('/');
}
