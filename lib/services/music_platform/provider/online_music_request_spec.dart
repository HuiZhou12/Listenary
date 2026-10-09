/// 声明式请求模型。
///
/// 设计原则：**参数名自由、来源封闭**。用户可以任意改目标参数名（ChkSz 用 `keyword`、
/// MSAPI 用 `keywords`），但「这个参数从哪来」只能是 [OnlineMusicInputSource] 里的闭集取值，
/// 因此这套配置永远长不成一门脚本语言。
library;

enum OnlineMusicHttpVerb { get, post }

/// 业务输入来源（闭集）。这是能力的输入契约，用户不能发明新的来源。
enum OnlineMusicInputSource {
  keyword,
  limit,
  offset,
  page,
  cursor,
  trackId,
  playlistId,

  /// 歌单分类（`playlistCollection` 的可选筛选条件）。
  ///
  /// 取值是**该平台自己的分类标识**：网易云实测用分类名（`/top/playlist?cat=华语`），
  /// 所以界面必须把平台返回的分类 id 原样回传，不能自己拼。
  categoryId,
  quality,
}

/// 一个可映射参数的来源说明。
final class OnlineMusicParamBinding {
  const OnlineMusicParamBinding({
    required this.name,
    required this.source,
    this.required = false,
    this.defaultValue,
  });

  final String name;
  final OnlineMusicInputSource source;

  /// 输入缺失时是否算配置错误（否则用 [defaultValue] / 直接省略）。
  final bool required;

  /// 仅支持 String / num / bool；输入缺失时使用。
  final Object? defaultValue;

  Map<String, dynamic> toJson() => {
    'name': name,
    'source': source.name,
    'required': required,
    if (defaultValue != null) 'default': defaultValue,
  };

  static OnlineMusicParamBinding fromJson(Object? value) {
    final map = _requireMap(value, 'query/body 参数');
    return OnlineMusicParamBinding(
      name: _requireText(map['name'], 'query/body 参数名'),
      source: _requireEnum(
        map['source'],
        OnlineMusicInputSource.values,
        'query/body 参数来源',
      ),
      required: map['required'] == true,
      defaultValue: _optionalScalar(map['default'], 'query/body 参数默认值'),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is OnlineMusicParamBinding &&
      other.name == name &&
      other.source == source &&
      other.required == required &&
      other.defaultValue == defaultValue;

  @override
  int get hashCode => Object.hash(name, source, required, defaultValue);

  @override
  String toString() => '$name<-${source.name}';
}

/// 常量请求头（不支持动态值：时间戳/签名属于"需要代码实现"的边界）。
final class OnlineMusicHeaderSpec {
  const OnlineMusicHeaderSpec({
    required this.name,
    required this.value,
    this.sensitive = false,
  });

  final String name;
  final String value;

  /// 是否**明确标记为敏感**（F0 / 决策 A）。
  ///
  /// 标记后该请求头**必须**走安全凭据存储与引用流程：用明文 [value] 保存会被
  /// `validationIssues` 拒绝（保存时拒绝，见用户 2026-10-09 裁定），
  /// 运行期也不得以明文发送。
  ///
  /// **缺省 `false`，且为 `false` 时不写盘** ⇒ 旧配置往返后语义与字节都不变。
  final bool sensitive;

  Map<String, dynamic> toJson() => {
    'name': name,
    'value': value,
    if (sensitive) 'sensitive': true,
  };

  static OnlineMusicHeaderSpec fromJson(Object? value) {
    final map = _requireMap(value, '请求头');
    return OnlineMusicHeaderSpec(
      name: _requireText(map['name'], '请求头名称'),
      value: map['value'] == null ? '' : '${map['value']}',
      sensitive: map['sensitive'] == true,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is OnlineMusicHeaderSpec &&
      other.name == name &&
      other.value == value &&
      other.sensitive == sensitive;

  @override
  int get hashCode => Object.hash(name, value, sensitive);
}

/// 请求体：扁平 JSON 或 form-urlencoded，字段同样来自闭集输入。
final class OnlineMusicRequestBodySpec {
  const OnlineMusicRequestBodySpec({
    this.isForm = false,
    this.fields = const [],
  });

  final bool isForm;
  final List<OnlineMusicParamBinding> fields;

  Map<String, dynamic> toJson() => {
    'kind': isForm ? 'form' : 'json',
    'fields': [for (final field in fields) field.toJson()],
  };

  static OnlineMusicRequestBodySpec fromJson(Object? value) {
    final map = _requireMap(value, '请求体');
    final kind = map['kind'] == null
        ? 'json'
        : _requireText(map['kind'], '请求体类型');
    if (kind != 'json' && kind != 'form') {
      throw FormatException('请求体类型只支持 json / form，收到 "$kind"');
    }
    return OnlineMusicRequestBodySpec(
      isForm: kind == 'form',
      fields: _requireList(
        map['fields'],
        '请求体字段',
      ).map(OnlineMusicParamBinding.fromJson).toList(growable: false),
    );
  }
}

/// 认证放置方式（闭集）。凭据值仍按 Provider 级槽位解析。
sealed class OnlineMusicAuthPlacement {
  const OnlineMusicAuthPlacement();

  Map<String, dynamic> toJson();

  static OnlineMusicAuthPlacement fromJson(Object? value) {
    if (value == null) return const OnlineMusicNoAuthPlacement();
    final map = _requireMap(value, '认证配置');
    final kind = _requireText(map['kind'], '认证类型');
    return switch (kind) {
      'none' => const OnlineMusicNoAuthPlacement(),
      'query' => OnlineMusicQueryAuthPlacement(
        parameterName: _requireText(map['name'], '认证查询参数名'),
      ),
      'header' => OnlineMusicHeaderAuthPlacement(
        headerName: _requireText(map['name'], '认证请求头名'),
        prefix: map['prefix'] == null ? null : '${map['prefix']}',
      ),
      'body' => OnlineMusicBodyAuthPlacement(
        fieldName: _requireText(map['name'], '认证请求体字段名'),
      ),
      _ => throw FormatException('认证类型只支持 none/query/header/body，收到 "$kind"'),
    };
  }
}

final class OnlineMusicNoAuthPlacement extends OnlineMusicAuthPlacement {
  const OnlineMusicNoAuthPlacement();

  @override
  Map<String, dynamic> toJson() => const {'kind': 'none'};

  @override
  bool operator ==(Object other) => other is OnlineMusicNoAuthPlacement;

  @override
  int get hashCode => 0;
}

final class OnlineMusicQueryAuthPlacement extends OnlineMusicAuthPlacement {
  const OnlineMusicQueryAuthPlacement({required this.parameterName});

  final String parameterName;

  @override
  Map<String, dynamic> toJson() => {'kind': 'query', 'name': parameterName};

  @override
  bool operator ==(Object other) =>
      other is OnlineMusicQueryAuthPlacement &&
      other.parameterName == parameterName;

  @override
  int get hashCode => parameterName.hashCode;
}

final class OnlineMusicHeaderAuthPlacement extends OnlineMusicAuthPlacement {
  const OnlineMusicHeaderAuthPlacement({required this.headerName, this.prefix});

  final String headerName;

  /// 例如 `Bearer `；null 表示直接放裸值。
  final String? prefix;

  @override
  Map<String, dynamic> toJson() => {
    'kind': 'header',
    'name': headerName,
    if (prefix != null) 'prefix': prefix,
  };

  @override
  bool operator ==(Object other) =>
      other is OnlineMusicHeaderAuthPlacement &&
      other.headerName == headerName &&
      other.prefix == prefix;

  @override
  int get hashCode => Object.hash(headerName, prefix);
}

final class OnlineMusicBodyAuthPlacement extends OnlineMusicAuthPlacement {
  const OnlineMusicBodyAuthPlacement({required this.fieldName});

  final String fieldName;

  @override
  Map<String, dynamic> toJson() => {'kind': 'body', 'name': fieldName};

  @override
  bool operator ==(Object other) =>
      other is OnlineMusicBodyAuthPlacement && other.fieldName == fieldName;

  @override
  int get hashCode => fieldName.hashCode;
}

final class OnlineMusicRequestSpec {
  const OnlineMusicRequestSpec({
    this.verb = OnlineMusicHttpVerb.get,
    required this.path,
    this.query = const [],
    this.headers = const [],
    this.body,
    this.auth = const OnlineMusicNoAuthPlacement(),
  });

  final OnlineMusicHttpVerb verb;

  /// 相对 baseUrl 的路径；支持 `{trackId}` 这类占位，占位名只能取输入来源。
  final String path;

  final List<OnlineMusicParamBinding> query;
  final List<OnlineMusicHeaderSpec> headers;
  final OnlineMusicRequestBodySpec? body;
  final OnlineMusicAuthPlacement auth;

  Map<String, dynamic> toJson() => {
    'verb': verb.name,
    'path': path,
    'query': [for (final entry in query) entry.toJson()],
    'headers': [for (final header in headers) header.toJson()],
    if (body != null) 'body': body!.toJson(),
    'auth': auth.toJson(),
  };

  static OnlineMusicRequestSpec fromJson(Object? value) {
    final map = _requireMap(value, '请求配置');
    return OnlineMusicRequestSpec(
      verb: _requireEnum(map['verb'], OnlineMusicHttpVerb.values, 'HTTP 方法'),
      path: _requireText(map['path'], '请求路径'),
      query: _optionalList(
        map['query'],
      ).map(OnlineMusicParamBinding.fromJson).toList(growable: false),
      headers: _optionalList(
        map['headers'],
      ).map(OnlineMusicHeaderSpec.fromJson).toList(growable: false),
      body: map['body'] == null
          ? null
          : OnlineMusicRequestBodySpec.fromJson(map['body']),
      auth: OnlineMusicAuthPlacement.fromJson(map['auth']),
    );
  }

  /// 配置校验：返回人类可读的问题列表；空列表表示可用。
  List<String> validationIssues() {
    final issues = <String>[];
    final trimmed = path.trim();
    if (trimmed.isEmpty) {
      issues.add('请求路径不能为空');
    } else {
      if (trimmed.contains('://')) issues.add('请求路径必须是相对 baseUrl 的相对路径');
      if (trimmed.contains('?') || trimmed.contains('#')) {
        issues.add('请求路径不能带查询串或锚点，请把它们写成 query 参数');
      }
      for (final placeholder in _placeholders(trimmed)) {
        if (!OnlineMusicInputSource.values.any((s) => s.name == placeholder)) {
          issues.add('路径占位 {$placeholder} 不是受支持的输入来源');
        }
      }
    }
    final names = <String>{};
    for (final entry in query) {
      if (entry.name.trim().isEmpty) {
        issues.add('查询参数名不能为空');
      } else if (!names.add(entry.name)) {
        issues.add('查询参数 ${entry.name} 重复');
      }
    }
    for (final header in headers) {
      if (header.name.trim().isEmpty) issues.add('请求头名称不能为空');
      // F0 / 决策 A（用户 2026-10-09 裁定"保存时拒绝"）：
      // 明确标记为敏感的请求头**不得**以明文值保存；它必须改走安全凭据引用。
      if (header.sensitive && header.value.trim().isNotEmpty) {
        issues.add(
          '请求头 ${header.name} 已标记为敏感，不能以明文值保存；'
          '请改用安全凭据引用',
        );
      }
    }
    if (body != null) {
      if (verb != OnlineMusicHttpVerb.post) {
        issues.add('只有 POST 才能带请求体');
      }
      final bodyNames = <String>{};
      for (final field in body!.fields) {
        if (field.name.trim().isEmpty) {
          issues.add('请求体字段名不能为空');
        } else if (!bodyNames.add(field.name)) {
          issues.add('请求体字段 ${field.name} 重复');
        }
      }
    }
    switch (auth) {
      case OnlineMusicNoAuthPlacement():
        break;
      case OnlineMusicQueryAuthPlacement(:final parameterName):
        if (parameterName.trim().isEmpty) issues.add('认证查询参数名不能为空');
      case OnlineMusicHeaderAuthPlacement(:final headerName):
        if (headerName.trim().isEmpty) issues.add('认证请求头名不能为空');
      case OnlineMusicBodyAuthPlacement(:final fieldName):
        if (fieldName.trim().isEmpty) issues.add('认证请求体字段名不能为空');
        if (verb != OnlineMusicHttpVerb.post) {
          issues.add('认证放在请求体时必须是 POST');
        }
    }
    return issues;
  }

  @override
  bool operator ==(Object other) =>
      other is OnlineMusicRequestSpec &&
      other.verb == verb &&
      other.path == path &&
      _listEquals(other.query, query) &&
      _listEquals(other.headers, headers) &&
      _sameBody(other.body, body) &&
      other.auth == auth;

  @override
  int get hashCode => Object.hash(
    verb,
    path,
    Object.hashAll(query),
    Object.hashAll(headers),
    body?.isForm,
    Object.hashAll(body?.fields ?? const []),
    auth,
  );

  @override
  String toString() =>
      'OnlineMusicRequestSpec(${verb.name.toUpperCase()} $path, ${query.length} query, ${headers.length} headers)';
}

bool _sameBody(OnlineMusicRequestBodySpec? a, OnlineMusicRequestBodySpec? b) {
  if (a == null || b == null) return a == b;
  return a.isForm == b.isForm && _listEquals(a.fields, b.fields);
}

List<String> _placeholders(String path) {
  return RegExp(
    r'\{([A-Za-z0-9_]+)\}',
  ).allMatches(path).map((match) => match.group(1)!).toList(growable: false);
}

Map<Object?, Object?> _requireMap(Object? value, String label) {
  if (value is Map) return value;
  throw FormatException('$label 必须是对象');
}

List<Object?> _requireList(Object? value, String label) {
  if (value is List) return value;
  throw FormatException('$label 必须是数组');
}

List<Object?> _optionalList(Object? value) =>
    value == null ? const [] : _requireList(value, '列表字段');

String _requireText(Object? value, String label) {
  if (value is! String || value.trim().isEmpty) {
    throw FormatException('$label 必须是非空字符串');
  }
  return value.trim();
}

T _requireEnum<T extends Enum>(Object? value, List<T> values, String label) {
  if (value is String) {
    for (final candidate in values) {
      if (candidate.name == value) return candidate;
    }
  }
  throw FormatException('$label 取值无效：$value');
}

Object? _optionalScalar(Object? value, String label) {
  if (value == null) return null;
  if (value is String || value is num || value is bool) return value;
  throw FormatException('$label 只支持字符串、数字或布尔值');
}

bool _listEquals<T>(List<T> a, List<T> b) {
  if (a.length != b.length) return false;
  for (var index = 0; index < a.length; index++) {
    if (a[index] != b[index]) return false;
  }
  return true;
}
