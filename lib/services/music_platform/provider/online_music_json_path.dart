/// 受限 JSON 路径：只支持 `a.b[0].c` 与 `a.b[*].c`。
///
/// 这是声明式映射里唯一的"寻址语言"，刻意不做表达式、函数或过滤：
/// 键、下标、数组投影三种片段就已经覆盖了音乐 API 的常见形状。
sealed class JsonPathSegment {
  const JsonPathSegment();
}

final class JsonPathKey extends JsonPathSegment {
  const JsonPathKey(this.key);

  final String key;
}

final class JsonPathIndex extends JsonPathSegment {
  const JsonPathIndex(this.index);

  final int index;
}

/// `[*]`：把后续片段投影到数组的每个元素上。
final class JsonPathProject extends JsonPathSegment {
  const JsonPathProject();
}

final class JsonPath {
  const JsonPath._(this.segments, this.source);

  final List<JsonPathSegment> segments;

  /// 原始写法，用于展示与写回配置。
  final String source;

  static final _keyPattern = RegExp(r'^[A-Za-z0-9_\-]+$');

  /// 解析失败返回 null（调用方决定是回落还是报错）。
  static JsonPath? tryParse(String source) {
    final raw = source.trim();
    if (raw.isEmpty) return null;
    final segments = <JsonPathSegment>[];
    for (final token in raw.split('.')) {
      if (token.isEmpty) return null;
      final bracketStart = token.indexOf('[');
      final key = bracketStart < 0 ? token : token.substring(0, bracketStart);
      if (!_keyPattern.hasMatch(key)) return null;
      segments.add(JsonPathKey(key));
      if (bracketStart < 0) continue;
      var rest = token.substring(bracketStart);
      while (rest.isNotEmpty) {
        final match = RegExp(r'^\[(\*|\d+)\]').firstMatch(rest);
        if (match == null) return null;
        final body = match.group(1)!;
        segments.add(
          body == '*' ? const JsonPathProject() : JsonPathIndex(int.parse(body)),
        );
        rest = rest.substring(match.end);
      }
    }
    return JsonPath._(List.unmodifiable(segments), raw);
  }

  /// 读取路径上的值。
  ///
  /// - 单值路径返回该值；
  /// - 路径里含 `[*]`（或某一步产生多个节点）时返回 `List<Object?>`；
  /// - 任何一步落空都返回 null（不抛异常——缺失是正常情况，"必填"由 FieldSpec 判定）。
  Object? read(Object? root) {
    var current = <Object?>[root];
    for (final segment in segments) {
      final next = <Object?>[];
      for (final node in current) {
        switch (segment) {
          case JsonPathKey(:final key):
            if (node is Map) {
              final value = node[key];
              if (value != null) next.add(value);
            }
          case JsonPathIndex(:final index):
            if (node is List && index >= 0 && index < node.length) {
              next.add(node[index]);
            }
          case JsonPathProject():
            if (node is List) next.addAll(node);
        }
      }
      if (next.isEmpty) return null;
      current = next;
    }
    return current.length == 1 ? current.first : current;
  }

  /// 是否含投影片段；用于区分"单值字段"与"列表字段"。
  bool get projects => segments.any((segment) => segment is JsonPathProject);

  @override
  bool operator ==(Object other) =>
      other is JsonPath && other.source == source;

  @override
  int get hashCode => source.hashCode;

  @override
  String toString() => source;
}
