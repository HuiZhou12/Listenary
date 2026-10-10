/// 受限 JSON 路径。
///
/// 语法（F4-S7 / P-41 起）：
/// - 裸键：`[A-Za-z0-9_-]+`，段之间用 `.`（例如 `data.songs`）；
/// - 下标 / 投影：`[0]` / `[*]`（例如 `a.b[0].c`、`a.b[*].name`）；
/// - **引号键**（放宽后新增）：键里含 `.`、中文或其它字符时写成
///   `["a.b"]` / `["中文"]`（也接受单引号 `['a.b']`；引号内 `\"` / `\\` 可转义）。
///
/// 刻意不做表达式、函数或过滤：键、下标、数组投影三种片段就已经覆盖了音乐 API 的常见形状。
/// 引号键**只**用于"键本身不可用裸键表达"的场合，裸键规则不变（老配置完全不受影响）。
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

  static final _bareKey = RegExp(r'[A-Za-z0-9_\-]+');
  static final _digits = RegExp(r'\d+');

  /// 解析失败返回 null（调用方决定是回落还是报错）。
  ///
  /// F4-S7（P-41）：解析器**引号感知** —— 引号内的 `.` 不再被当成分段符，
  /// 因此 `["a.b"]` / `["中文"]` 可以寻址以前根本表达不出来的键。
  static JsonPath? tryParse(String source) {
    final raw = source.trim();
    if (raw.isEmpty) return null;
    final segments = <JsonPathSegment>[];
    var index = 0;
    while (index < raw.length) {
      if (raw[index] == '[') {
        // 段首直接是方括号：只接受**引号键**（`[0]` / `[*]` 仍只作后缀，保持老语法不变）。
        final head = _parseBracket(raw, index);
        if (head == null || head.$1 is! JsonPathKey) return null;
        segments.add(head.$1);
        index = head.$2;
      } else {
        final match = _bareKey.matchAsPrefix(raw, index);
        if (match == null) return null;
        segments.add(JsonPathKey(match.group(0)!));
        index = match.end;
      }
      while (index < raw.length && raw[index] == '[') {
        final bracket = _parseBracket(raw, index);
        if (bracket == null) return null;
        segments.add(bracket.$1);
        index = bracket.$2;
      }
      if (index >= raw.length) break;
      if (raw[index] != '.') return null;
      index++;
      if (index >= raw.length) return null;
    }
    if (segments.isEmpty) return null;
    return JsonPath._(List.unmodifiable(segments), raw);
  }

  /// 解析一个方括号片段：`[0]` / `[*]` / `["键"]` / `['键']`。
  ///
  /// 返回 `(片段, 下一个位置)`；不合法返回 null。引号内只支持对**引号本身**与
  /// 反斜杠的转义（保持这门语言最小，不做通用转义表）。
  static (JsonPathSegment, int)? _parseBracket(String raw, int start) {
    var index = start + 1;
    if (index >= raw.length) return null;
    final first = raw[index];
    if (first == '*') {
      return index + 1 < raw.length && raw[index + 1] == ']'
          ? (const JsonPathProject(), index + 2)
          : null;
    }
    if (first == '"' || first == "'") {
      final quote = first;
      final buffer = StringBuffer();
      index++;
      while (index < raw.length) {
        final char = raw[index];
        if (char == r'\') {
          if (index + 1 >= raw.length) return null;
          final escaped = raw[index + 1];
          if (escaped != quote && escaped != r'\') return null;
          buffer.write(escaped);
          index += 2;
          continue;
        }
        if (char == quote) {
          index++;
          if (index >= raw.length || raw[index] != ']') return null;
          final key = buffer.toString();
          if (key.isEmpty) return null;
          return (JsonPathKey(key), index + 1);
        }
        buffer.write(char);
        index++;
      }
      return null;
    }
    final digits = _digits.matchAsPrefix(raw, index);
    if (digits == null) return null;
    index = digits.end;
    if (index >= raw.length || raw[index] != ']') return null;
    return (JsonPathIndex(int.parse(digits.group(0)!)), index + 1);
  }

  /// 读取路径上的值。
  ///
  /// - 路径里含 `[*]` 时**总是**返回 `List<Object?>`（哪怕只有一个元素或为空），
  ///   这样"投影路径 = 列表字段"是稳定的，不会因为样本里恰好只有一首歌而变形；
  /// - 不含投影时返回单个值；
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
      if (next.isEmpty) return projects ? const <Object?>[] : null;
      current = next;
    }
    if (projects) return current;
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
