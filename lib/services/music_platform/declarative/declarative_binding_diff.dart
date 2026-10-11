/// 两份**声明式绑定**之间的可读差异（F3-5a / Spec §9.3）。
///
/// 用途只有一个：探测给出"建议配置"时，**先让用户看清改了什么**，再由用户决定是否应用。
/// 旧行为是探测成功后**静默覆盖**用户正在编辑的内容 —— 这正是 P-20 的教训
///（破坏性操作必须可见、可拒绝）。
///
/// 纯函数：不读配置、不写配置，只比较两份 spec，因此可以单独下断言。
library;

import 'package:pure_music/services/music_platform/provider/online_music_binding.dart';
import 'package:pure_music/services/music_platform/provider/online_music_json_path.dart';
import 'package:pure_music/services/music_platform/provider/online_music_request_spec.dart';

/// 差异说明（**逐行可读**）；两份完全相同时返回空列表。
List<String> describeDeclarativeBindingDiff({
  required OnlineMusicDeclarativeCapabilityBinding current,
  required OnlineMusicDeclarativeCapabilityBinding next,
}) {
  if (current == next) return const [];
  final lines = <String>[];

  // ---- 请求 ----
  final a = current.request;
  final b = next.request;
  if (a.verb != b.verb) {
    lines.add('请求方法：${a.verb.name} → ${b.verb.name}');
  }
  if (a.path != b.path) {
    lines.add('请求路径：${a.path} → ${b.path}');
  }
  final aQuery = [for (final entry in a.query) entry.name];
  final bQuery = [for (final entry in b.query) entry.name];
  if (!_sameList(aQuery, bQuery)) {
    lines.add('查询参数：${_listText(aQuery)} → ${_listText(bQuery)}');
  }
  final aHeaders = [for (final header in a.headers) header.name];
  final bHeaders = [for (final header in b.headers) header.name];
  if (!_sameList(aHeaders, bHeaders)) {
    lines.add('请求头：${_listText(aHeaders)} → ${_listText(bHeaders)}');
  }
  final aSensitive = {
    for (final header in a.headers)
      if (header.sensitive) header.name,
  };
  final bSensitive = {
    for (final header in b.headers)
      if (header.sensitive) header.name,
  };
  if (!_sameSet(aSensitive, bSensitive)) {
    // 敏感标记单独说：它决定"要不要走安全凭据引用"，比名字变化更要紧。
    lines.add(
      '标记为敏感的请求头：${_listText(aSensitive.toList())} → '
      '${_listText(bSensitive.toList())}',
    );
  }
  final aBody = a.body;
  final bBody = b.body;
  if ((aBody == null) != (bBody == null)) {
    lines.add(
      bBody == null
          ? '请求体：移除'
          : '请求体：新增（${bBody.isForm ? 'form' : 'json'}，'
                '${bBody.fields.length} 个字段）',
    );
  } else if (aBody != null && bBody != null && aBody != bBody) {
    lines.add(
      '请求体：${aBody.isForm ? 'form' : 'json'} '
      '${aBody.fields.length} → ${bBody.fields.length} 个字段',
    );
  }
  if (a.auth.runtimeType != b.auth.runtimeType) {
    lines.add('认证放置：${_authLabel(a.auth)} → ${_authLabel(b.auth)}');
  }

  // ---- 响应 ----
  final ar = current.response;
  final br = next.response;
  if (_pathText(ar.listPath) != _pathText(br.listPath)) {
    lines.add('列表路径：${_pathText(ar.listPath)} → ${_pathText(br.listPath)}');
  }
  if (_pathText(ar.fieldsRootPath) != _pathText(br.fieldsRootPath)) {
    lines.add(
      '字段根路径：${_pathText(ar.fieldsRootPath)} → '
      '${_pathText(br.fieldsRootPath)}',
    );
  }
  if (_pathText(ar.totalPath) != _pathText(br.totalPath)) {
    lines.add('总数路径：${_pathText(ar.totalPath)} → ${_pathText(br.totalPath)}');
  }
  if (_pathText(ar.nextCursorPath) != _pathText(br.nextCursorPath)) {
    lines.add(
      '游标路径：${_pathText(ar.nextCursorPath)} → '
      '${_pathText(br.nextCursorPath)}',
    );
  }
  if (ar.pagination.kind != br.pagination.kind) {
    lines.add('分页方式：${ar.pagination.kind.name} → ${br.pagination.kind.name}');
  }
  if (!_sameList(ar.success.okStatusCodes, br.success.okStatusCodes)) {
    lines.add(
      '成功状态码：${_listText(ar.success.okStatusCodes.map((c) => '$c').toList())}'
      ' → ${_listText(br.success.okStatusCodes.map((c) => '$c').toList())}',
    );
  }
  if (ar.success.allOf.length != br.success.allOf.length) {
    lines.add(
      '成功判定条件：${ar.success.allOf.length} 条 → ${br.success.allOf.length} 条',
    );
  }
  final aKeys = ar.fields.keys.toSet();
  final bKeys = br.fields.keys.toSet();
  final added = [for (final key in bKeys.difference(aKeys)) key.name];
  final removed = [for (final key in aKeys.difference(bKeys)) key.name];
  final changed = [
    for (final key in aKeys.intersection(bKeys))
      if (ar.fields[key] != br.fields[key]) key.name,
  ];
  if (added.isNotEmpty) lines.add('新增字段映射：${_listText(added)}');
  if (removed.isNotEmpty) lines.add('移除字段映射：${_listText(removed)}');
  if (changed.isNotEmpty) lines.add('修改字段映射：${_listText(changed)}');

  // 兜底：`==` 说"不同"但我们没能说出具体差异时，**如实说明**，
  // 而不是给一个空列表让用户以为"没有变化"。
  if (lines.isEmpty) {
    lines.add('两份配置存在差异，但差异不在已覆盖的字段里；请用 JSON 视图逐项对比');
  }
  return List.unmodifiable(lines);
}

bool _sameList<T>(List<T> a, List<T> b) {
  if (a.length != b.length) return false;
  for (var index = 0; index < a.length; index++) {
    if (a[index] != b[index]) return false;
  }
  return true;
}

bool _sameSet<T>(Set<T> a, Set<T> b) =>
    a.length == b.length && a.containsAll(b);

String _listText(List<String> values) =>
    values.isEmpty ? '（无）' : values.join('、');

String _pathText(JsonPath? path) => path?.source ?? '（未设置）';

String _authLabel(OnlineMusicAuthPlacement auth) => switch (auth) {
  OnlineMusicNoAuthPlacement() => '无',
  OnlineMusicQueryAuthPlacement(:final parameterName) => '查询参数 $parameterName',
  OnlineMusicHeaderAuthPlacement(:final headerName) => '请求头 $headerName',
  OnlineMusicBodyAuthPlacement(:final fieldName) => '请求体字段 $fieldName',
};
