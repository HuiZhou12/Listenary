/// 敏感请求头的**凭据槽位**命名与碰撞检测（F0 / Spec §3、§11.3）。
///
/// 槽位名形如 `<providerId>/<capability>/<normalizedHeaderName>`：
/// - 同名 header 在不同能力使用不同凭据时**不得相互覆盖**，所以能力段必须参与命名；
/// - `providerId` **原样保留**（不同条目必须落在不同槽位）；
/// - header 段强制归一化（小写、去空白、非字母数字归一为 `-`）。
///
/// **刻意不依赖 OS 的大小写语义**（未验证）：归一化全部在这一层完成，
/// 因此 Windows 凭据槽位的"存在即覆盖"语义不会替我们合并掉两个本该分开的槽位。
///
/// 值相同的判断一律**不作为**合并依据（Spec §3）：共享只能靠**显式引用**。
library;

import 'package:pure_music/services/music_platform/provider/online_music_capability.dart';

/// header 名归一化后的槽位段。
///
/// 规则（Spec §3 + §11.3 的碰撞要求）：
/// 1. 去首尾空白、转小写；
/// 2. 每个非 `[a-z0-9]` 字符归一为 `-`；
/// 3. 连续 `-` 压缩为一个、并去掉首尾 `-`（否则 `X-Token` 与 `x_token` 会归一成
///    两个不同的槽位，而 HTTP 头名本来就不区分这类写法 ⇒ 必须让它们碰撞并被拦下）。
///
/// 压缩是**保守方向**：多出来的碰撞只会导致"失败并报告"，不会导致静默覆盖。
String normalizeOnlineMusicHeaderSlotSegment(String headerName) {
  final lowered = headerName.trim().toLowerCase();
  final buffer = StringBuffer();
  for (final rune in lowered.runes) {
    final char = String.fromCharCode(rune);
    final isAsciiAlphanumeric =
        (char.codeUnitAt(0) >= 0x61 && char.codeUnitAt(0) <= 0x7a) ||
        (char.codeUnitAt(0) >= 0x30 && char.codeUnitAt(0) <= 0x39);
    buffer.write(isAsciiAlphanumeric ? char : '-');
  }
  return buffer
      .toString()
      .replaceAll(RegExp('-+'), '-')
      .replaceAll(RegExp(r'^-+|-+$'), '');
}

/// `providerId` 与能力段同样归一化：能力枚举名是 camelCase
/// （`playlistCollection` / `newSongs` …），**并不全小写**，
/// 槽位名保持全小写才与 Spec §3 的取值域一致，也避免大小写混用带来的歧义。
String _normalizeSlotSegment(String value) => value.trim().toLowerCase();

/// 敏感请求头的默认凭据槽位名。
///
/// 结果**稳定**：同样的 `(providerId, capability, headerName)` 永远得到同一个槽位名，
/// 因此迁移可以重放、可以幂等。
String onlineMusicHeaderSlotName({
  required String providerId,
  required OnlineMusicCapability capability,
  required String headerName,
}) =>
    '${_normalizeSlotSegment(providerId)}/'
    '${_normalizeSlotSegment(capability.name)}/'
    '${normalizeOnlineMusicHeaderSlotSegment(headerName)}';

/// 同一请求内**归一化后同名**的请求头分组（每组至少两个名字）。
///
/// Spec §11.3：归一化碰撞**必须失败并报告**，不得静默合并、也不得让其中一个槽位
/// 覆盖另一个。返回的每组只含**名称**（不含任何值）。
List<List<String>> onlineMusicHeaderNameCollisions(Iterable<String> headerNames) {
  final grouped = <String, List<String>>{};
  for (final name in headerNames) {
    final segment = normalizeOnlineMusicHeaderSlotSegment(name);
    if (segment.isEmpty) continue;
    (grouped[segment] ??= <String>[]).add(name);
  }
  return [
    for (final entry in grouped.entries)
      if (entry.value.length > 1) List<String>.unmodifiable(entry.value),
  ];
}
