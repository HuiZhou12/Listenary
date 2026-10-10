/// **共享**的请求摘要与响应片段诊断（探测与试跑共用同一套脱敏）。
///
/// 为什么放在声明式层：探测（`provider_probe.dart`，声明式层）与试跑（设置控制器，
/// provider 层）都必须能生成"我到底发了什么 / 服务端回了什么"，而**脱敏只能有一份** ——
/// 两套脱敏实现正是 P-07 与 F0 反复强调的反模式（漏一处就等于泄漏）。
///
/// 层的方向：provider 层 → declarative 层（单向，不会成环）。
library;

import 'dart:convert';

import 'package:pure_music/services/music_platform/declarative/declarative_request_builder.dart';
import 'package:pure_music/services/music_platform/provider/online_music_header_migration.dart';

/// 敏感**参数名 / 请求头名 / JSON 键名**：这些名字的取值一律不进界面、不进日志。
///
/// ⚠️ 这只是一个**兜底白名单**（P-35 的教训）：白名单一定会漏（用户可以把认证参数
/// 起成任何名字），所以真正的判据是**值来源** —— 凭据来源的值由
/// [BuiltDeclarativeRequest.credentialHeaderNames] 与
/// [BuiltDeclarativeRequest.credentialQueryNames] 精确标出，
/// 不看名字就一律遮蔽。本名单只用于处理"来源未知"的响应体。
const sensitiveDiagnosticNamePattern =
    r'apikey|api[-_]?key|x-api-key|authorization|proxy-authorization|cookie|'
    r'set-cookie|token|access[-_]?token|refresh[-_]?token|id[-_]?token|x-token|'
    r'secret|appsecret|app[-_]?secret|appkey|app[-_]?key|password|passwd|pwd|'
    r'sign|signature|x-signature|x-sign|auth|key|csrf|xsrf|sid|session|sessionid|'
    r'jwt|qskey|pskey|qm_keyst|credential|h';

bool isSensitiveDiagnosticName(String name) => RegExp(
  '^($sensitiveDiagnosticNamePattern)\$',
  caseSensitive: false,
).hasMatch(name.trim());

/// 试跑结果里展示的**请求摘要**：方法 + 路径 + 参数名与值（敏感值脱敏）。
///
/// 未知服务无法自动探测时，"到底发了什么请求"是唯一的排查依据（W5），
/// 因此这里要把参数名与值都写出来。遮蔽判据有四条，**按可靠性排序**：
/// 1. **值来自凭据**（认证放置 / 敏感请求头的凭据引用 / 请求体认证）⇒ 一律 `[redacted]`（最可靠）；
/// 2. **值形态可疑**（`needs-user` 类：名字没命中、但值看起来像秘密）⇒ 也 `[redacted]`
///    （名字白名单对它们必然漏，而漏掉的后果是直接显示这个值）；
/// 3. 名字落在兜底名单里 ⇒ 也 `[redacted]`（覆盖"明文写死在配置里"的旧配置）；
/// 4. 请求体还有一条**额外的**保守规则：也按形态遮蔽（见下）。
String describeDeclarativeRequest(BuiltDeclarativeRequest request) {
  bool headerIsCredential(String name) {
    if (request.credentialHeaderNames.contains(name)) return true;
    if (isSensitiveDiagnosticName(name)) return true;
    // 只对**请求头**做形状判据：query 参数来自闭集输入（keyword/limit/…），
    // 按形状遮蔽会把用户自己搜的关键词也糊掉，得不偿失。
    return looksLikeSensitiveHeaderValue(request.headers[name] ?? '');
  }

  bool queryIsCredential(String name) =>
      request.credentialQueryNames.contains(name) ||
      isSensitiveDiagnosticName(name);

  // P-34：请求体与 query **不同**——body 字段的值可以来自配置里的**任意常量**
  // （`defaultValue` 由用户手写，不像 query 那样只有闭集运行时输入），
  // 所以这里连**形态**也判：宁可多遮一点，也不能把配置里写死的密钥显示出来。
  bool bodyIsCredential(String name, Object? value) =>
      request.credentialBodyNames.contains(name) ||
      isSensitiveDiagnosticName(name) ||
      looksLikeSensitiveHeaderValue(value is String ? value : '${value ?? ''}');

  final parts = <String>[
    for (final entry in request.query.entries)
      queryIsCredential(entry.key)
          ? '${entry.key}=[redacted]'
          : '${entry.key}=${entry.value}',
    for (final entry in request.headers.entries)
      headerIsCredential(entry.key)
          ? '${entry.key}: [redacted]'
          : '${entry.key}: ${entry.value}',
  ];
  final buffer = StringBuffer('${request.method} ${request.path}');
  if (parts.isNotEmpty) buffer.write(' · ${parts.join('&')}');
  final body = request.body;
  if (body != null) {
    // P-34：**逐字段**输出 —— POST 类能力的核心排查动作是"我配的字段名服务端到底认不认"，
    // 以前整块写成"已省略（可能含凭据）"，这件事在界面上根本做不了。
    final fields = <String>[];
    if (body is Map) {
      for (final entry in body.entries) {
        final name = '${entry.key}';
        fields.add(
          bodyIsCredential(name, entry.value)
              ? '$name=[redacted]'
              : '$name=${_diagnosticValueText(entry.value)}',
        );
      }
    }
    buffer.write(
      fields.isEmpty ? ' · 请求体：（空对象）' : ' · 请求体：${fields.join('&')}',
    );
  }
  return buffer.toString();
}

/// 摘要里单个值的字符上限（值来自输入或配置，长度不可控）。
const requestSummaryValueMaxChars = 200;

String _diagnosticValueText(Object? value) {
  if (value == null) return 'null';
  final text = value is String ? value : '$value';
  return text.length > requestSummaryValueMaxChars
      ? '${text.substring(0, requestSummaryValueMaxChars)}…'
      : text;
}

/// 结果区展示响应片段时的字符上限。
///
/// 结果区现在是限高可滚动的，所以这个上限只管"别把超大响应整个塞进内存/界面"，
/// 不影响正常阅读；超出时会明确写出完整长度。
const responsePreviewMaxChars = 20000;

/// 响应片段的**脱敏 + 格式化 + 截断**（探测与试跑共用）。
///
/// - 格式化：JSON 用 2 空格缩进，界面里才看得出层次（此前是压成一行的 `jsonEncode`）。
/// - 文本脱敏：同时覆盖查询串（`apikey=…`、`?h=…&sid=…`）、JSON 键值对（`"token":"…"`）
///   与**敏感请求头**（`Authorization: …`、`Cookie: …`，W5 补充）。
///   宁可多脱敏，也不要把签名串渲染到界面上。
/// - 截断：上限 [responsePreviewMaxChars]；超出时**明确写出完整长度**，
///   而不是让用户以为响应本来就只有这么长。
String? redactResponsePreview(Object? data) {
  if (data == null) return null;
  var text = _prettyJson(_redactStructured(data, 0));
  text = text.replaceAllMapped(
    RegExp(
      '\\b($sensitiveDiagnosticNamePattern)=[^&"\\s,}]+',
      caseSensitive: false,
    ),
    (match) => '${match.group(1)}=[redacted]',
  );
  // JSON 键值对：**字符串与非字符串值都要挡**（`"token": 123` / `"jwt": null`）。
  text = text.replaceAllMapped(
    RegExp(
      '"($sensitiveDiagnosticNamePattern)"\\s*:\\s*'
      '(?:"[^"]*"|[^,}\\]\\s][^,}\\]]*)',
      caseSensitive: false,
    ),
    (match) => '"${match.group(1)}":"[redacted]"',
  );
  // 请求/响应头形态：`Authorization: Bearer …` / `Cookie: a=b`。
  text = text.replaceAllMapped(
    RegExp(
      '^\\s*($sensitiveDiagnosticNamePattern)\\s*:\\s*.*\$',
      caseSensitive: false,
      multiLine: true,
    ),
    (match) => '${match.group(1)}: [redacted]',
  );
  if (text.length <= responsePreviewMaxChars) return text;
  return '${text.substring(0, responsePreviewMaxChars)}\n'
      '…（已截断展示：完整响应共 ${text.length} 字符）';
}

/// 逐层把敏感键的**值**换成 `[redacted]`。
///
/// [depth] 只是防御性上限：解码后的 JSON 不会有环，但预览不该被刻意做深的响应拖垮。
Object? _redactStructured(Object? data, int depth) {
  if (depth > 32) return '[redacted：层级过深]';
  if (data is Map) {
    return <String, Object?>{
      for (final entry in data.entries)
        '${entry.key}': isSensitiveDiagnosticName('${entry.key}')
            ? '[redacted]'
            : _redactStructured(entry.value, depth + 1),
    };
  }
  if (data is List) {
    return [for (final item in data) _redactStructured(item, depth + 1)];
  }
  return data;
}

String _prettyJson(Object? data) {
  if (data is String) return data;
  try {
    return const JsonEncoder.withIndent('  ').convert(data);
  } catch (_) {
    return '$data';
  }
}
