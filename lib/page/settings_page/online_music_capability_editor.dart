import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:pure_music/component/settings_tile.dart';
import 'package:pure_music/core/design_tokens.dart';
import 'package:pure_music/core/hotkeys.dart';
import 'package:pure_music/services/music_platform/declarative/declarative_verification.dart';
import 'package:pure_music/services/music_platform/declarative/provider_probe.dart';
import 'package:pure_music/services/music_platform/online_music_credentials.dart';
import 'package:pure_music/services/music_platform/online_music_diagnostics.dart';
import 'package:pure_music/services/music_platform/provider/online_music_binding.dart';
import 'package:pure_music/services/music_platform/provider/online_music_capability.dart';
import 'package:pure_music/services/music_platform/provider/online_music_header_slot.dart';
import 'package:pure_music/services/music_platform/provider/online_music_json_path.dart';
import 'package:pure_music/services/music_platform/provider/online_music_provider_settings.dart';
import 'package:pure_music/services/music_platform/provider/online_music_provider_settings_controller.dart';
import 'package:pure_music/services/music_platform/provider/online_music_request_spec.dart';
import 'package:pure_music/services/music_platform/provider/online_music_response_spec.dart';

/// 能力列表：四个能力各自的状态 + 一键按 ChkSz 兼容方式填充。
class OnlineMusicCapabilitiesDialog extends StatelessWidget {
  const OnlineMusicCapabilitiesDialog({
    super.key,
    required this.definition,
    required this.onEditCapability,
    required this.onFillChkszCompatible,
  });

  final OnlineMusicProviderDefinition definition;
  final void Function(OnlineMusicCapability capability) onEditCapability;
  final VoidCallback onFillChkszCompatible;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('能力配置 · ${definition.label}'),
      content: SizedBox(
        width: 520,
        // 能力数量会随平台能力增长（当前 8 个）。这里必须**可滚动 + 有高度上限**：
        // 否则矮窗口下超出的能力会被裁掉、**根本点不到**（用户已报告过）。
        // 滚动条按仓库既有约定关掉（滚轮/触控板照常可用；歌词视图用的也是这一写法）。
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * 0.6,
          ),
          child: ScrollConfiguration(
            behavior: ScrollConfiguration.of(
              context,
            ).copyWith(scrollbars: false),
            child: ListView(
              shrinkWrap: true,
              padding: EdgeInsets.zero,
              children: [
                for (final capability in OnlineMusicCapability.values) ...[
                  SettingsTile(
                    description: capabilityLabel(capability),
                    subtitle: _describe(capability),
                    action: FilledButton.icon(
                      onPressed: () => onEditCapability(capability),
                      icon: const Icon(Symbols.tune),
                      label: const Text('配置'),
                    ),
                  ),
                  const SizedBox(height: 12),
                ],
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: onFillChkszCompatible,
                    icon: const Icon(Symbols.auto_fix_high),
                    label: const Text('一键按 ChkSz 兼容方式填充'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('关闭'),
        ),
      ],
    );
  }

  String _describe(OnlineMusicCapability capability) {
    final binding = definition.bindingFor(capability);
    return switch (binding) {
      OnlineMusicBuiltinCapabilityBinding() => '内置实现（${binding.builtinId}）',
      OnlineMusicDeclarativeCapabilityBinding() =>
        '声明式：${binding.request.verb.name.toUpperCase()} ${binding.request.path}',
      OnlineMusicUnsupportedCapabilityBinding() => '未配置 → 该能力不可用',
    };
  }
}

/// 单个能力的配置表单（+ JSON 高级视图 + 探测/试跑）。
class OnlineMusicCapabilityEditorDialog extends StatefulWidget {
  const OnlineMusicCapabilityEditorDialog({
    super.key,
    required this.definition,
    required this.capability,
    required this.initialBinding,
    required this.onProbe,
    required this.onTest,
    required this.onIsCredentialConfigured,
    required this.onSaveCredential,
  });

  final OnlineMusicProviderDefinition definition;
  final OnlineMusicCapability capability;
  final OnlineMusicCapabilityBinding initialBinding;

  /// 探测整个服务（仅 search 提供）。
  final Future<ProviderProbeReport> Function() onProbe;

  /// 用**当前编辑中的**绑定试跑一次；[inputs] 是**用户给的**真实输入（P-49）。
  final Future<DeclarativeCapabilityTestResult> Function(
    OnlineMusicDeclarativeCapabilityBinding binding,
    DeclarativeTestInputs inputs,
  )
  onTest;

  /// 某个凭据槽位当前是否已有凭据（只回答"有/没有"，绝不返回值）。
  final Future<bool> Function(String reference) onIsCredentialConfigured;

  /// 把凭据值写进安全槽位。
  ///
  /// 界面**只**通过它写入秘密：值不会进入绑定/草稿，也不会出现在 JSON 视图里。
  final Future<void> Function(String reference, String value) onSaveCredential;

  @override
  State<OnlineMusicCapabilityEditorDialog> createState() =>
      _OnlineMusicCapabilityEditorDialogState();
}

class _OnlineMusicCapabilityEditorDialogState
    extends State<OnlineMusicCapabilityEditorDialog> {
  late OnlineMusicDeclarativeCapabilityBinding _binding;
  late TextEditingController _path;
  late TextEditingController _fieldsRoot;
  late TextEditingController _listPath;
  late TextEditingController _totalPath;
  late TextEditingController _nextCursor;
  late TextEditingController _statusCodes;
  final _queryRows = <_ParamRow>[];

  /// 请求体字段（P-21）；与查询参数共用 [_ParamRow]（模型里就是同一个类型）。
  final _bodyRows = <_ParamRow>[];

  /// 是否带请求体。显式表达"有 body 但字段为空"（POST 会发 `{}`）与"没有 body"
  /// （不发 body）这两种**线上行为不同**的形状，不靠"有没有行"去猜。
  bool _bodyPresent = false;

  /// 请求体是 JSON 还是 form-urlencoded。
  bool _bodyIsForm = false;
  final _headerRows = <_HeaderRow>[];
  final _predicateRows = <_PredicateRow>[];
  final Map<OnlineMusicDomainField, _FieldRow> _fieldRows = {};
  late TextEditingController _authName;
  late TextEditingController _authPrefix;
  late OnlineMusicAuthPlacement _authPlacement;
  late TextEditingController _json;
  late OnlineMusicHttpVerb _verb;
  final _testTrackId = TextEditingController();
  // P-49：关键词与每页数量也由用户给（以前分别写死成探测常量与 1/30）。
  final _testKeyword = TextEditingController();
  final _testLimit = TextEditingController();

  bool _showJson = false;
  bool _bound = false;
  bool _busy = false;

  /// 最近一次 试跑 / 探测 / 校验 的**单行**状态。固定高度槽位，内容变化不引起布局位移。
  String? _resultHeadline;
  bool? _resultOk;

  /// 结果详情：只读、可滚动、可复制。长错误、映射摘要与原始响应都放在这里，
  /// 不再用不限行数的裸 Text 铺在对话框里。
  final _resultController = TextEditingController();

  /// `_collect()` 收集过程中发现的、无法解释成有效配置的输入。
  final List<String> _collectErrors = [];

  void _setResult({required String headline, bool? ok, String? detail}) {
    if (!mounted) return;
    setState(() {
      _busy = false;
      _resultHeadline = headline;
      _resultOk = ok;
      _resultController.text = detail ?? '';
    });
  }

  bool get _isSearch => widget.capability == OnlineMusicCapability.search;

  @override
  void initState() {
    super.initState();
    final initial = widget.initialBinding;
    _binding = initial is OnlineMusicDeclarativeCapabilityBinding
        ? initial
        : _emptyBinding();
    _loadFromBinding(_binding);
    _json = TextEditingController(text: _jsonPreview());
    // 首帧之后再查凭据槽位状态（读取是异步的，且不阻塞对话框弹出）。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _refreshHeaderCredentialStates();
    });
  }

  @override
  void dispose() {
    _path.dispose();
    _fieldsRoot.dispose();
    _listPath.dispose();
    _totalPath.dispose();
    _nextCursor.dispose();
    _statusCodes.dispose();
    _authName.dispose();
    _authPrefix.dispose();
    _json.dispose();
    _resultController.dispose();
    _testTrackId.dispose();
    _testKeyword.dispose();
    _testLimit.dispose();
    for (final row in _queryRows) {
      row.dispose();
    }
    for (final row in _bodyRows) {
      row.dispose();
    }
    for (final row in _headerRows) {
      row.dispose();
    }
    for (final row in _predicateRows) {
      row.dispose();
    }
    for (final row in _fieldRows.values) {
      row.dispose();
    }
    super.dispose();
  }

  OnlineMusicDeclarativeCapabilityBinding _emptyBinding() =>
      OnlineMusicDeclarativeCapabilityBinding(
        request: const OnlineMusicRequestSpec(path: '/'),
        response: OnlineMusicResponseSpec(
          // 空表单的**起手路径**：按能力给"最可能要填的那一个"一个值，另一个留空。
          // **不显示出来的字段一律不写**（否则会留下用户看不见的死配置，反模式 7）。
          listPath: switch (widget.capability) {
            OnlineMusicCapability.search ||
            OnlineMusicCapability.playlistCollection ||
            OnlineMusicCapability.playlistCategories ||
            OnlineMusicCapability.chartList ||
            OnlineMusicCapability.newSongs => JsonPath.tryParse('data'),
            OnlineMusicCapability.playlist ||
            OnlineMusicCapability.lyric ||
            OnlineMusicCapability.stream => null,
          },
          fieldsRootPath: switch (widget.capability) {
            OnlineMusicCapability.playlist ||
            OnlineMusicCapability.lyric ||
            OnlineMusicCapability.stream => JsonPath.tryParse('data'),
            OnlineMusicCapability.search ||
            OnlineMusicCapability.playlistCollection ||
            OnlineMusicCapability.playlistCategories ||
            OnlineMusicCapability.chartList ||
            OnlineMusicCapability.newSongs => null,
          },
        ),
      );

  void _loadFromBinding(OnlineMusicDeclarativeCapabilityBinding binding) {
    // F3-S5（P-25）：`_binding` 是**单一事实源** —— 表单行、JSON 视图
    //（`_jsonPreview()` = `_binding.toJson()`）与 `_collect()`（分页等**没有**表单行的字段
    // 直接取自 `_binding`）都必须从同一份绑定出发。
    //
    // 以前这里只回填表单行、**不**更新 `_binding`，于是"探测初稿"之后：
    // JSON 视图仍是旧绑定（在空编辑器里就是空绑定），而初稿里的**分页**会在保存时丢失
    // —— 两条路径（应用初稿 / 应用 JSON）行为不一致。
    _binding = binding;
    // 重载（应用 JSON / 探测初稿）时先释放上一批标量控制器，避免泄漏。
    if (_bound) {
      _path.dispose();
      _fieldsRoot.dispose();
      _listPath.dispose();
      _totalPath.dispose();
      _nextCursor.dispose();
      _statusCodes.dispose();
      _authName.dispose();
      _authPrefix.dispose();
    }
    _bound = true;
    _verb = binding.request.verb;
    _path = TextEditingController(text: binding.request.path);
    _fieldsRoot = TextEditingController(
      text: binding.response.fieldsRootPath?.source ?? '',
    );
    _listPath = TextEditingController(
      text: binding.response.listPath?.source ?? '',
    );
    _totalPath = TextEditingController(
      text: binding.response.totalPath?.source ?? '',
    );
    _nextCursor = TextEditingController(
      text: binding.response.nextCursorPath?.source ?? '',
    );
    _statusCodes = TextEditingController(
      text: binding.response.success.okStatusCodes.join(','),
    );
    for (final row in _queryRows) {
      row.dispose();
    }
    _queryRows
      ..clear()
      ..addAll(binding.request.query.map(_ParamRow.from));
    // 请求体（P-21）：以前整块都不可编辑（`body: _binding.request.body` 原样抄），
    // POST 类能力只能走 JSON 视图。这里把"有没有请求体 / JSON 还是表单 / 字段"都做成控件。
    final body = binding.request.body;
    _bodyPresent = body != null;
    _bodyIsForm = body?.isForm ?? false;
    for (final row in _bodyRows) {
      row.dispose();
    }
    _bodyRows
      ..clear()
      ..addAll(body?.fields.map(_ParamRow.from) ?? const []);
    for (final row in _headerRows) {
      row.dispose();
    }
    _headerRows
      ..clear()
      ..addAll(
        binding.request.headers.map(
          (header) => _HeaderRow.from(
            header,
            // 敏感头的槽位名**默认派生**（`<标识>/<能力>/<归一化头名>`），
            // 用户仍可在行内改成别的槽位以实现显式共享。
            derivedReference: _derivedReferenceFor(header.name),
          ),
        ),
      );
    for (final row in _predicateRows) {
      row.dispose();
    }
    _predicateRows
      ..clear()
      ..addAll(binding.response.success.allOf.map(_PredicateRow.from));
    for (final row in _fieldRows.values) {
      row.dispose();
    }
    _fieldRows.clear();
    for (final field in domainFieldsFor(widget.capability)) {
      _fieldRows[field] = _FieldRow.from(field, binding.response.fields[field]);
    }
    _authPlacement = binding.request.auth;
    final (name, prefix) = switch (_authPlacement) {
      OnlineMusicQueryAuthPlacement(:final parameterName) => (
        parameterName,
        '',
      ),
      OnlineMusicHeaderAuthPlacement(:final headerName, :final prefix) => (
        headerName,
        prefix ?? '',
      ),
      OnlineMusicBodyAuthPlacement(:final fieldName) => (fieldName, ''),
      OnlineMusicNoAuthPlacement() => ('', ''),
    };
    _authName = TextEditingController(text: name);
    _authPrefix = TextEditingController(text: prefix);
    _showJson = false;
  }

  /// JSON 视图也做缩进，便于看出请求 / 响应 / 字段映射的层次。
  /// 解析侧用 `jsonDecode`，缩进不影响「应用 JSON」。
  String _jsonPreview() =>
      const JsonEncoder.withIndent('  ').convert(_binding.toJson());

  /// 把当前表单收集成一个绑定（供试跑/保存/JSON 预览用）。
  OnlineMusicDeclarativeCapabilityBinding _collect() {
    final query = [
      for (final row in _queryRows)
        if (row.name.text.trim().isNotEmpty) _paramBindingOf(row),
    ];
    // 请求体（P-21）：有行 ⇒ 按表单重建；一行都没有 ⇒ **保留原有形状**
    // （"没有 body" 与 "有 body 但字段为空" 在 POST 上是两条不同的线上行为：
    // 前者不发 body、后者发 `{}`），所以用 [_bodyPresent] 显式表达，不靠"有没有行"猜。
    final body = !_bodyPresent
        ? null
        : OnlineMusicRequestBodySpec(
            isForm: _bodyIsForm,
            fields: [
              for (final row in _bodyRows)
                if (row.name.text.trim().isNotEmpty) _paramBindingOf(row),
            ],
          );
    final headers = [
      for (final row in _headerRows)
        if (row.name.text.trim().isNotEmpty) _headerSpecOf(row),
    ];
    final predicates = <OnlineMusicSuccessPredicate>[];
    _collectErrors.clear();
    for (final row in _predicateRows) {
      final raw = row.path.text.trim();
      if (raw.isEmpty) continue;
      final path = JsonPath.tryParse(raw);
      if (path == null) {
        // §6：越界配置必须显式拒绝，不能悄悄换成别的路径。
        _collectErrors.add('成功判定路径「$raw」写法无效');
        continue;
      }
      predicates.add(
        OnlineMusicSuccessPredicate(
          path: path,
          op: row.op,
          value: row.value.text.trim().isEmpty
              ? null
              : _coerce(row.value.text.trim()),
        ),
      );
    }
    final fields = <OnlineMusicDomainField, OnlineMusicFieldSpec>{};
    for (final entry in _fieldRows.entries) {
      if (!entry.value.enabled) continue;
      final paths = <JsonPath>[];
      for (final raw in entry.value.paths.text.split(',')) {
        final candidate = raw.trim();
        if (candidate.isEmpty) continue;
        final path = JsonPath.tryParse(candidate);
        if (path == null) {
          _collectErrors.add('字段 ${entry.key.name} 的路径「$candidate」写法无效');
          continue;
        }
        paths.add(path);
      }
      if (paths.isEmpty) continue;
      fields[entry.key] = OnlineMusicFieldSpec(
        candidates: paths,
        transform: entry.value.transform,
        // P-31：必填只有**一个**事实源 —— 能力级的 `requiredFieldsFor`（保存与试跑都按它校验，
        // 界面上的"（必填）"也取自它）。字段级 `required` 只是随配置往返的镜像，
        // 这里按同一判据写，免得把"界面标必填、文件里写 false"的矛盾状态又保存回去。
        required: requiredFieldsFor(widget.capability).contains(entry.key),
      );
    }
    final auth = switch (_authPlacement) {
      OnlineMusicNoAuthPlacement() => const OnlineMusicNoAuthPlacement(),
      OnlineMusicQueryAuthPlacement() => OnlineMusicQueryAuthPlacement(
        parameterName: _authName.text.trim(),
      ),
      OnlineMusicHeaderAuthPlacement() => OnlineMusicHeaderAuthPlacement(
        headerName: _authName.text.trim(),
        prefix: _authPrefix.text.isEmpty ? null : _authPrefix.text,
      ),
      OnlineMusicBodyAuthPlacement() => OnlineMusicBodyAuthPlacement(
        fieldName: _authName.text.trim(),
      ),
    };
    return OnlineMusicDeclarativeCapabilityBinding(
      request: OnlineMusicRequestSpec(
        verb: _verb,
        path: _path.text.trim(),
        query: query,
        headers: headers,
        // P-21：请求体以前是 `_binding.request.body` 原样抄（表单改不了）。
        body: body,
        auth: auth,
      ),
      response: OnlineMusicResponseSpec(
        success: OnlineMusicSuccessSpec(
          okStatusCodes: _statusCodes.text
              .split(',')
              .map((entry) => int.tryParse(entry.trim()))
              .whereType<int>()
              .toList(),
          allOf: predicates,
        ),
        // **两条路径都按用户实际输入写**（P-01）。此前按 `_isSearch` 二选一，
        // 于是非搜索能力**永远写不出 `listPath`**（校验必然报"必须配置列表路径"），
        // 而歌单详情又**永远写不出曲目数组路径**（曲目恒空）。
        // 空输入 → null（不写死配置）；已配置但当前能力不显示该字段时也原样保留，
        // 编辑既有配置不丢字段。
        listPath: JsonPath.tryParse(_listPath.text.trim()),
        fieldsRootPath: JsonPath.tryParse(_fieldsRoot.text.trim()),
        totalPath: JsonPath.tryParse(_totalPath.text.trim()),
        nextCursorPath: JsonPath.tryParse(_nextCursor.text.trim()),
        fields: fields,
        pagination: _binding.response.pagination,
      ),
    );
  }

  /// 该请求头默认的凭据槽位名（F0 / Spec §3，稳定可重放）。
  String _derivedReferenceFor(String headerName) => onlineMusicHeaderSlotName(
    providerId: widget.definition.id,
    capability: widget.capability,
    headerName: headerName,
  );

  /// 切换「敏感」；首次标记时补一个派生槽位名，避免留下"没有引用的敏感头"。
  void _toggleSensitive(_HeaderRow row) {
    setState(() {
      row.sensitive = !row.sensitive;
      if (row.sensitive) {
        // F4-S2（P-09）：敏感头**不能**来自输入 —— 勾上敏感就退回"值 / 引用"模式。
        row.source = null;
        if (row.reference.text.trim().isEmpty) {
          row.reference.text = _derivedReferenceFor(row.name.text.trim());
        }
      }
      row.referenceConfigured = null;
    });
    if (row.sensitive) unawaited(_refreshHeaderCredentialStates());
  }

  /// 行内引用框为空时回落到派生槽位名，避免用户留下一个"没有引用的敏感头"。
  String _referenceOf(_HeaderRow row) {
    final typed = row.reference.text.trim();
    return typed.isEmpty ? _derivedReferenceFor(row.name.text.trim()) : typed;
  }

  /// 把一行参数收成 [OnlineMusicParamBinding]（**查询参数与请求体字段共用**）。
  ///
  /// `defaultValue` 的**类型**要保住（P-21）：以前统一按字符串回写，
  /// 于是 `default: 30` 保存一次就变成 `"30"`。线上取值不受影响
  /// （`_stringify` 把两者都渲染成 `30`），但配置该保持它原来的样子。
  /// 还原顺序：整数 → 小数 → 布尔 → 字符串（与成功判定里 `_coerce` 的口径一致）。
  OnlineMusicParamBinding _paramBindingOf(_ParamRow row) {
    final constant = row.value.text.trim();
    return OnlineMusicParamBinding(
      name: row.name.text.trim(),
      // F4-S1（P-08 / D1:A）：来源与固定值**互斥** ——
      // 固定值模式下**只**写 value，绝不两个都写（否则保存会被校验拦下）。
      source: row.source,
      value: row.usesConstant && constant.isNotEmpty ? constant : null,
      required: row.required,
      defaultValue: _coerceDefaultValue(row.defaultValue.text),
    );
  }

  Object? _coerceDefaultValue(String raw) {
    final text = raw.trim();
    if (text.isEmpty) return null;
    final asInt = int.tryParse(text);
    if (asInt != null) return asInt;
    final asDouble = double.tryParse(text);
    if (asDouble != null) return asDouble;
    if (text == 'true') return true;
    if (text == 'false') return false;
    return text;
  }

  /// 把一行表单收集成请求头声明。
  ///
  /// **敏感头不会把明文落盘**：这里仍然带上 `value`（因为**绝不静默丢弃**用户已经填好的
  /// 秘密），拦截发生在保存校验那一层 —— `sensitive + 明文` 会被 `validationIssues`
  /// 拒绝（`请求头 X 已有凭据引用，明文值必须清空`），因此**写不进配置**。
  /// 换句话说：不是"在这里把值清空"，而是"这个状态**不许保存**"。
  OnlineMusicHeaderSpec _headerSpecOf(_HeaderRow row) {
    final name = row.name.text.trim();
    final source = row.source;
    if (source != null) {
      // F4-S2（P-09）：**动态头** —— 值来自闭集输入；固定值必须清空（两者互斥）。
      return OnlineMusicHeaderSpec(name: name, value: '', source: source);
    }
    if (!row.sensitive) {
      return OnlineMusicHeaderSpec(name: name, value: row.value.text);
    }
    return OnlineMusicHeaderSpec(
      name: name,
      value: row.value.text,
      sensitive: true,
      credentialReference: _referenceOf(row),
    );
  }

  /// 查询每个敏感头引用的槽位当前是否已有凭据（只用于显示"已配置/未配置"）。
  Future<void> _refreshHeaderCredentialStates() async {
    final rows = [
      for (final row in _headerRows)
        if (row.sensitive) row,
    ];
    if (rows.isEmpty) return;
    final states = <_HeaderRow, bool>{};
    for (final row in rows) {
      try {
        states[row] = await widget.onIsCredentialConfigured(_referenceOf(row));
      } catch (_) {
        // 读不出来就显示"未知"，不假装"已配置"。
      }
    }
    if (!mounted) return;
    setState(() {
      for (final entry in states.entries) {
        entry.key.referenceConfigured = entry.value;
      }
    });
  }

  Object _coerce(String raw) {
    final asInt = int.tryParse(raw);
    if (asInt != null) return asInt;
    if (raw == 'true') return true;
    if (raw == 'false') return false;
    return raw;
  }

  Future<void> _runProbe() async {
    setState(() {
      _busy = true;
      // 进行中先清空上一次结果，避免旧标题/旧详情被误读成本次结果。
      _resultHeadline = null;
      _resultOk = null;
      _resultController.clear();
    });
    try {
      final report = await widget.onProbe();
      if (!mounted) return;
      // F0-3：整个探测被拦下（服务地址非法）时**不能**说"候选都没通过"——
      // 那意味着"我们试过了"，而事实是一个请求都没发。
      final blocked = report.blockedReason;
      if (blocked != null) {
        setState(() {
          _busy = false;
          _resultOk = false;
          _resultHeadline = '无法探测';
          _resultController.text = blocked;
        });
        return;
      }
      final detail = StringBuffer();
      for (final outcome in report.outcomes) {
        // F3-S1：三种情形必须**分开说** ——「未尝试」「没发出去（配置问题）」与
        // 「试过但失败」。把它们渲染成同一句"候选未通过"，就是在谎称"我们试过了"。
        if (outcome.status == ProviderProbeStatus.notAttempted) {
          detail.writeln(
            '· ${outcome.label}（${outcome.candidateId}）：'
            '${outcome.notAttemptedReason ?? '未尝试'}',
          );
          continue;
        }
        final kind = outcome.failureKind;
        detail.writeln(
          // F3-S3（D-F3-1 第 3 条）：**来源与能力必须写在结论旁边** ——
          // "探测成功"本身不说明什么，得说清验的是"谁的哪个能力"。
          // F3-S6（D-F3-3）：结论用**三态词表**（与试跑同一套），不再只报"得分 N"
          //（那既读不出"能不能用"，也读不出"没确认"）。
          '· ${outcome.sourceLabel}（${outcome.candidateId}）：'
          '${outcome.status == ProviderProbeStatus.notSent ? '请求未发出（配置问题）' : declarativeVerificationConfidenceLabel(outcome.confidence)}'
          '${outcome.statusCode == null ? '' : ' · HTTP ${outcome.statusCode}'}'
          // 用户裁定第 2 条：单位随能力不同（首曲目 / 个歌单 / 个分类 / 个榜单），
          // 不再一律说"首"。
          '${outcome.mappedItemCount > 0 ? ' · 解析出 ${outcome.mappedItemCount} ${outcome.mappedUnit ?? '项'}' : ''}'
          '${outcome.needsAuthentication ? ' · 需要认证' : ''}'
          '${kind == null ? '' : ' · ${onlineMusicErrorKindLabel(kind)}'}',
        );
        // F3-1：**卡在哪一阶段**（配置 / 传输 / 判定 / 映射）。
        // 以前四种完全不同的原因会塌缩成同一句"候选未通过"，用户不知道该改哪里。
        final failedStage = outcome.firstFailedStage;
        if (failedStage != null) {
          detail.writeln(
            '    卡在：${declarativeVerificationStageLabel(failedStage)}'
            '（${declarativeVerificationStageStatusLabel(outcome.stageStatus(failedStage))}）'
            '${failedStage == DeclarativeVerificationStage.config ? ' · 未发出任何请求' : ''}',
          );
        }
        if (outcome.failureReason != null) {
          detail.writeln('    ${outcome.failureReason}');
        }
        // D-F3-2 第 4 条：**明确标记待补配置的凭据项**（而不是让用户自己猜）。
        if (outcome.credentialMissingForAuth) {
          detail.writeln(
            '    ⚠️ 待补配置：该条目的 Key（配置后重新探测；'
            '本次探测**没有**携带凭据，因此结论只是"未确认"）',
          );
        }
        // P-07：摘要与片段（都已脱敏）—— 失败时它们才是唯一的排查依据。
        final summary = outcome.requestSummary;
        if (summary != null) detail.writeln('    请求：$summary');
        final preview = outcome.responsePreview;
        if (preview != null) {
          const previewLimit = 400;
          detail.writeln(
            '    响应：${preview.length > previewLimit ? '${preview.substring(0, previewLimit)}…' : preview}',
          );
        }
      }
      setState(() {
        _busy = false;
        _resultOk = report.hasDraft;
        _resultHeadline = report.hasDraft
            // D-F3-5 第 6 条：一次探测只证明**这个候选的这个能力**，所以标题也要说清
            // 验的是谁、哪个能力（"探测成功"本身不成立）。D-F3-1 第 3 条：来源不得混淆。
            ? '已由「${_probeSourceLabelOf(report)}」生成可编辑初稿'
            // D-F3-2：这次没带凭据、候选又声明了认证 ⇒ **不算"未通过"，更不算成功**，
            // 而是"未确认：认证条件未满足"。把它写成"均未通过"同样是撒谎。
            : report.anyNeedsAuthentication
            ? '未确认：需要该条目的 Key（配置后重新探测）'
            : '没有候选可用（${report.outcomes.length} 个候选均未通过）';
        _resultController.text = detail.toString().trimRight();
        if (report.hasDraft) {
          _loadFromBinding(report.draft!);
          _json.text = _jsonPreview();
        }
      });
      if (report.hasDraft) unawaited(_refreshHeaderCredentialStates());
    } catch (_) {
      _setResult(headline: '探测失败（网络或服务不可达）', ok: false);
    }
  }

  /// 探测初稿的**来源与能力**（D-F3-1 第 3 条「不得混淆来源」/ D-F3-5 第 6 条
  /// 「结论必须注明实际验证的候选来源和能力」）。
  String _probeSourceLabelOf(ProviderProbeReport report) {
    final source = report.draftSource;
    final capability = report.draftCapability;
    final id = report.draftTemplateId ?? '未知候选';
    if (source == null || capability == null) return id;
    return '${providerProbeCandidateSourceLabel(source)}'
        '（${onlineMusicCapabilityLabel(capability)}）· $id';
  }

  Future<void> _runTest() async {
    final binding = _collect();
    final issues = [
      ..._collectErrors,
      ...binding.validationIssues(widget.capability),
    ];
    if (issues.isNotEmpty) {
      _setResult(headline: '无法试跑：配置还不完整', ok: false, detail: issues.join('\n'));
      return;
    }
    setState(() {
      _busy = true;
      // 进行中先清空上一次结果，避免旧标题/旧详情被误读成本次结果。
      _resultHeadline = null;
      _resultOk = null;
      _resultController.clear();
    });
    try {
      // P-49：把**用户填的**真实输入按能力送到正确的入口 ——
      // 以前无论填什么都当 trackId 传（搜索的关键词因此永远用不上）。
      final idText = _testTrackId.text.trim();
      final keywordText = _testKeyword.text.trim();
      final fields = testInputFieldsFor(widget.capability);
      final inputs = (
        keyword: fields.keyword && keywordText.isNotEmpty ? keywordText : null,
        limit: fields.limit ? int.tryParse(_testLimit.text.trim()) : null,
        trackId:
            fields.id && widget.capability != OnlineMusicCapability.playlist
            ? (idText.isEmpty ? null : idText)
            : null,
        playlistId:
            fields.id && widget.capability == OnlineMusicCapability.playlist
            ? (idText.isEmpty ? null : idText)
            : null,
      );
      final result = await widget.onTest(binding, inputs);
      if (!mounted) return;
      final detail = StringBuffer();
      // W5：先写"实际发了什么请求" —— 未知服务无法自动探测时，这是唯一的排查依据。
      if (result.requestSummary != null) {
        detail.writeln('请求：${result.requestSummary}');
      }
      if (result.mappedSummary != null) {
        detail.writeln('映射结果：${result.mappedSummary}');
      }
      if (result.failureReason != null) {
        final kind = result.failureKind;
        detail.writeln(
          '失败原因${kind == null ? '' : '（${declarativeTestFailureLabel(kind)}）'}：'
          '${result.failureReason}',
        );
      }
      if (result.responsePreview != null) {
        detail
          ..writeln('原始响应（已脱敏并截断）：')
          ..writeln(result.responsePreview);
      }
      final suffix = result.statusCode == null
          ? ''
          : ' · HTTP ${result.statusCode}';
      final kindSuffix = result.failureKind == null
          ? ''
          : ' · ${declarativeTestFailureLabel(result.failureKind!)}';
      // F3-S6（D-F3-3）：标题必须对应**真实判定状态** ——
      // 「未能确认」（响应有效但没有可验证的数据）既不能渲染成成功，
      // 也不能渲染成失败/网络故障；中间态用中性色（`ok: null`）。
      final confidence = result.confidence;
      final headline = switch (confidence) {
        DeclarativeVerificationConfidence.verified => '试跑成功',
        DeclarativeVerificationConfidence.unconfirmed => '未能确认',
        DeclarativeVerificationConfidence.failed => '试跑失败',
      };
      _setResult(
        headline: '$headline$suffix$kindSuffix',
        ok: switch (confidence) {
          DeclarativeVerificationConfidence.verified => true,
          DeclarativeVerificationConfidence.unconfirmed => null,
          DeclarativeVerificationConfidence.failed => false,
        },
        detail: detail.toString().trimRight(),
      );
    } catch (_) {
      _setResult(headline: '试跑失败（网络或服务不可达）', ok: false);
    }
  }

  void _applyJson() {
    try {
      final parsed = OnlineMusicCapabilityBinding.fromJson(
        jsonDecode(_json.text),
      );
      if (parsed is! OnlineMusicDeclarativeCapabilityBinding) {
        _setResult(headline: 'JSON 不是声明式（http）绑定', ok: false);
        return;
      }
      final issues = parsed.validationIssues(widget.capability);
      setState(() {
        _binding = parsed;
        _loadFromBinding(parsed);
        _json.text = _jsonPreview();
      });
      unawaited(_refreshHeaderCredentialStates());
      _setResult(
        headline: issues.isEmpty ? '已应用 JSON' : '已应用 JSON，但有配置问题',
        ok: issues.isEmpty,
        detail: issues.join('\n'),
      );
    } catch (error) {
      _setResult(headline: 'JSON 解析失败', ok: false, detail: '$error');
    }
  }

  void _submit() {
    final binding = _collect();
    final issues = [
      ..._collectErrors,
      ...binding.validationIssues(widget.capability),
    ];
    if (issues.isNotEmpty) {
      _setResult(headline: '无法保存：配置还不完整', ok: false, detail: issues.join('\n'));
      return;
    }
    Navigator.of(context).pop(binding);
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    // 与项目其它设置对话框一致：按窗口算尺寸，窄窗口也放得下（不再固定 720×560）。
    // 上限是偏好尺寸，下限随窗口收缩（insetPadding 两侧各 24）：
    // 小窗口下宁可对话框变小，也不要它超出屏幕导致内容够不到。
    final width = (size.width - 48.0).clamp(200.0, 880.0).toDouble();
    final height = (size.height - 48.0).clamp(200.0, 720.0).toDouble();
    final resultHeight = (height * 0.24).clamp(72.0, 168.0).toDouble();

    return Dialog(
      insetPadding: const EdgeInsets.symmetric(
        horizontal: 24.0,
        vertical: 24.0,
      ),
      shape: RoundedRectangleBorder(borderRadius: AppRadius.mdCircular),
      child: SizedBox(
        width: width,
        height: height,
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _DialogHeader(
                // P-64：标题用**展示名**（`label` 优先 displayName，缺省回落到 id），
                // 与设置页列表里的称呼保持一致；不再在用户可见文案里混用内部 id。
                title:
                    '${capabilityLabel(widget.capability)} · ${widget.definition.label}',
                subtitle: _showJson
                    ? 'JSON 高级视图（与表单共享同一份校验）'
                    // P-64：这里以前对**所有非搜索能力**都写"声明式播放解析"。
                    // 现在按能力取名，于是歌单详情/歌单列表/榜单…各自说对了自己是什么。
                    : '声明式${capabilityLabel(widget.capability)}：请求与响应映射都可以在这里改',
              ),
              const SizedBox(height: 12.0),
              _ResultArea(
                height: resultHeight,
                headline: _resultHeadline,
                ok: _resultOk,
                busy: _busy,
                controller: _resultController,
                hint: _showJson
                    ? '点「应用 JSON」检查这份配置。'
                    : '点「试跑」检查这份配置；映射结果与原始响应会显示在这里。',
              ),
              const SizedBox(height: 12.0),
              Expanded(child: _showJson ? _buildJsonView() : _buildForm()),
              const SizedBox(height: 16.0),
              OverflowBar(
                alignment: MainAxisAlignment.end,
                spacing: 8.0,
                overflowSpacing: 8.0,
                children: [
                  TextButton.icon(
                    onPressed: () => setState(() => _showJson = !_showJson),
                    icon: Icon(_showJson ? Symbols.list : Symbols.data_object),
                    label: Text(_showJson ? '表单' : 'JSON'),
                  ),
                  if (_showJson)
                    TextButton(
                      onPressed: _applyJson,
                      child: const Text('应用 JSON'),
                    ),
                  if (_isSearch)
                    TextButton.icon(
                      onPressed: _busy ? null : _runProbe,
                      icon: const Icon(Symbols.radar),
                      label: const Text('探测该服务'),
                    ),
                  TextButton.icon(
                    onPressed: _busy ? null : _runTest,
                    icon: const Icon(Symbols.play_arrow),
                    label: const Text('试跑'),
                  ),
                  TextButton(
                    onPressed: _busy ? null : () => Navigator.of(context).pop(),
                    child: const Text('取消'),
                  ),
                  FilledButton.icon(
                    onPressed: _busy ? null : _submit,
                    icon: const Icon(Symbols.check),
                    label: const Text('保存'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildJsonView() {
    final scheme = Theme.of(context).colorScheme;
    return Focus(
      onFocusChange: HotkeysHelper.onFocusChanges,
      child: TextField(
        controller: _json,
        expands: true,
        maxLines: null,
        textAlignVertical: TextAlignVertical.top,
        style: TextStyle(
          fontFamily: 'monospace',
          fontSize: AppType.caption,
          color: scheme.onSurfaceVariant,
        ),
        decoration: const InputDecoration(
          border: OutlineInputBorder(),
          hintText: '能力绑定的 JSON',
        ),
      ),
    );
  }

  Widget _buildForm() {
    final pathFields = responsePathFieldsFor(widget.capability);
    final testId = testIdFieldFor(widget.capability);
    final testInputs = testInputFieldsFor(widget.capability);
    return ListView(
      key: capabilityFormKey,
      padding: EdgeInsets.zero,
      children: [
        const _SectionTitle('请求'),
        SettingsTile(
          description: '请求方法',
          action: SegmentedButton<OnlineMusicHttpVerb>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: OnlineMusicHttpVerb.get, label: Text('GET')),
              ButtonSegment(
                value: OnlineMusicHttpVerb.post,
                label: Text('POST'),
              ),
            ],
            selected: {_verb},
            onSelectionChanged: (selection) =>
                setState(() => _verb = selection.first),
          ),
        ),
        const SizedBox(height: 12),
        _textRow('请求路径（相对 baseUrl，可用 {trackId}）', _path),
        for (var index = 0; index < _queryRows.length; index++)
          _queryRow(index),
        _addRowButton(
          '加查询参数',
          () => setState(
            // 默认来源按**当前能力**决定（P-23）：在歌单详情里新增的参数默认是
            // 「歌单 ID」而不是「搜索关键词」。
            () => _queryRows.add(
              _ParamRow.empty(defaultInputSourceFor(widget.capability)),
            ),
          ),
        ),
        const SizedBox(height: 16),
        // 请求体（P-21）：这条链路以前完全不可编辑（整块 `body` 原样抄），
        // POST 类能力只能走 JSON 视图。现在三段都可控：有没有请求体 / JSON 还是表单 / 字段。
        const _SectionTitle('请求体'),
        SettingsTile(
          description: '带请求体',
          subtitle: _verb == OnlineMusicHttpVerb.post
              ? 'POST 请求会带上下面这些字段'
              : '当前是 GET：只有切换到 POST 才能带请求体（保存时会被校验拦下）',
          action: Checkbox(
            value: _bodyPresent,
            visualDensity: VisualDensity.compact,
            onChanged: (value) => setState(() => _bodyPresent = value ?? false),
          ),
        ),
        if (_bodyPresent) ...[
          const SizedBox(height: 8),
          SettingsTile(
            description: '请求体格式',
            subtitle: _bodyIsForm
                ? 'form-urlencoded：字段以键值对表单提交'
                : 'JSON：字段以 JSON 对象提交',
            action: SegmentedButton<bool>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(value: false, label: Text('JSON')),
                ButtonSegment(value: true, label: Text('表单')),
              ],
              selected: {_bodyIsForm},
              onSelectionChanged: (selection) =>
                  setState(() => _bodyIsForm = selection.first),
            ),
          ),
          const SizedBox(height: 8),
          for (var index = 0; index < _bodyRows.length; index++)
            _paramRow(index, _bodyRows),
          _addRowButton(
            '加请求体字段',
            () => setState(
              () => _bodyRows.add(
                _ParamRow.empty(defaultInputSourceFor(widget.capability)),
              ),
            ),
          ),
        ],
        const SizedBox(height: 8),
        SettingsTile(
          description: '认证方式',
          subtitle: '凭据值由该条目的凭据槽位提供，不写进配置',
          action: SegmentedButton<OnlineMusicAuthKind>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: OnlineMusicAuthKind.none, label: Text('无')),
              ButtonSegment(
                value: OnlineMusicAuthKind.query,
                label: Text('查询串'),
              ),
              ButtonSegment(
                value: OnlineMusicAuthKind.header,
                label: Text('请求头'),
              ),
              ButtonSegment(
                value: OnlineMusicAuthKind.body,
                label: Text('请求体'),
              ),
            ],
            selected: {_authKindOf(_authPlacement)},
            onSelectionChanged: (selection) => setState(() {
              _authPlacement = switch (selection.first) {
                OnlineMusicAuthKind.none => const OnlineMusicNoAuthPlacement(),
                OnlineMusicAuthKind.query => OnlineMusicQueryAuthPlacement(
                  parameterName: _authName.text.trim().isEmpty
                      ? 'apikey'
                      : _authName.text.trim(),
                ),
                OnlineMusicAuthKind.header => OnlineMusicHeaderAuthPlacement(
                  headerName: _authName.text.trim().isEmpty
                      ? 'Authorization'
                      : _authName.text.trim(),
                  prefix: _authPrefix.text.isEmpty ? null : _authPrefix.text,
                ),
                OnlineMusicAuthKind.body => OnlineMusicBodyAuthPlacement(
                  fieldName: _authName.text.trim().isEmpty
                      ? 'key'
                      : _authName.text.trim(),
                ),
              };
            }),
          ),
        ),
        if (_authKindOf(_authPlacement) != OnlineMusicAuthKind.none) ...[
          const SizedBox(height: 8),
          _textRow('认证参数名', _authName),
          if (_authKindOf(_authPlacement) == OnlineMusicAuthKind.header)
            _textRow('认证前缀（如 "Bearer "）', _authPrefix),
        ],
        // P-36：两层「认证」的事实会矛盾 —— 能力级说"要注入认证"，条目级说"不需要 Key"。
        // 这种组合能一路保存，却在运行期以「缺少凭据」失败（还会被回退白名单静默换个
        // Provider 掩盖）。这里在**动手时就**说清，而不是等运行期报错。
        if (_authKindOf(_authPlacement) != OnlineMusicAuthKind.none &&
            !widget.definition.requiresCredential)
          const Padding(
            padding: EdgeInsets.only(top: 8.0),
            child: _Hint(
              '⚠️ 这条能力声明了认证，但该条目当前设为「不需要 Key」'
              '⇒ 运行期会因缺少凭据失败。请到「设置 → 在线音乐 → 服务提供商」'
              '把该条目改成「需要 Key」，或把这里的认证改回「无」。',
            ),
          ),
        const SizedBox(height: 12),
        for (var index = 0; index < _headerRows.length; index++)
          _headerRow(index),
        _addRowButton(
          '加请求头',
          () => setState(() => _headerRows.add(_HeaderRow.empty())),
        ),
        const SizedBox(height: 16),
        const _SectionTitle('响应'),
        _textRow('成功状态码（逗号分隔，留空 = 2xx）', _statusCodes),
        for (var index = 0; index < _predicateRows.length; index++)
          _predicateRow(index),
        _addRowButton(
          '加成功判定',
          () => setState(() => _predicateRows.add(_PredicateRow.empty())),
        ),
        const SizedBox(height: 12),
        // 显示哪几个路径字段**由能力决定**（P-01，穷举 switch：漏改能力即编译失败）。
        // 此前写成 `_isSearch ? 列表路径 : 字段根路径` 的互斥二选一，于是
        // 歌单列表/分类/榜单/新歌**没有入口写 `列表路径`**（它们恰恰只需要它），
        // 而歌单详情**没有入口写曲目数组**（元数据与曲目在两个不同路径上）。
        if (pathFields.listPath && pathFields.fieldsRootPath)
          const Padding(
            padding: EdgeInsets.only(bottom: 8.0),
            child: _Hint(
              '歌单详情有两个位置：元数据在「字段根路径」，曲目数组在「列表路径」'
              '（例如字段根路径=playlist、列表路径=playlist.tracks）。',
            ),
          ),
        if (pathFields.listPath) _textRow('列表路径（如 data.songs）', _listPath),
        if (pathFields.fieldsRootPath) _textRow('字段根路径（如 data）', _fieldsRoot),
        _textRow('总数路径（可选）', _totalPath),
        _textRow('游标路径（可选）', _nextCursor),
        // F4-S9/收口：分页控件仍**刻意不给**（「分页类型 / 默认每页数量」在配置里原样保留，
        // 但没有可编辑项 —— 做成可点却无效果的选项是反模式 7）。
        // 说明必须与**当前事实**一致（F4-S3 起 `offset`/`limit`/`page` 已经真的进请求）：
        const Padding(
          padding: EdgeInsets.only(bottom: 8.0),
          child: _Hint(
            '分页：按每页数量与偏移量分页的接口现在真的会生效'
            '（「偏移量 / 每页数量」会写进请求，页码由这两者推算）；'
            '「分页类型 / 默认每页数量」仍然没有可编辑项，配置里怎么写的就怎么保留。'
            '使用「游标」分页的接口暂不支持：试跑或运行时会明确报错，不会悄悄当成第一页。'
            '⚠️ 没配「总数路径」时，无法可靠判断"是否还有更多" —— 搜索结果里的'
            '「加载更多」不会出现（配好总数路径即可）。',
          ),
        ),
        const SizedBox(height: 16),
        const _SectionTitle('字段映射'),
        const Padding(
          padding: EdgeInsets.only(bottom: 8.0),
          // F4-S9（D4 边界）：把"支持范围"写在用户看得见的地方 ——
          // 空值与缺失同义、转换是闭集；选错转换**不会静默返回空值**，试跑会明确报错。
          child: _Hint(
            '勾选后该字段才会写进配置；候选路径按顺序取第一个存在的。'
            '空值与「键不存在」同义；转换只有每行下拉里的那几种 —— '
            '选错转换会在试跑时明确报错，不会静默变成空值。',
          ),
        ),
        for (final field in domainFieldsFor(widget.capability))
          _fieldRow(field, _fieldRows[field]!),
        const SizedBox(height: 12.0),
        const _SectionTitle('试跑'),
        // P-49：**搜索也有输入框**（以前整个"试跑"区块对搜索直接隐藏，关键词只能写死）。
        if (testInputs.keyword) _textRow('试跑用的关键词', _testKeyword),
        if (testInputs.limit) _textRow('试跑用的每页数量', _testLimit),
        if (testInputs.id)
          _textRow(testId.label, _testTrackId)
        else if (!testInputs.keyword && !testInputs.limit)
          // 兜底说明：正常不会走到（可试跑的能力至少有一种输入），
          // 但"新增能力漏改"时界面上仍要说明清楚，而不是一片空白。
          const Padding(
            padding: EdgeInsets.only(bottom: 8.0),
            child: _Hint('这个能力不需要额外输入：试跑会直接请求一次。'),
          ),
      ],
    );
  }

  /// 表单里的单行文本字段：与项目其它设置对话框一致（不用 dense 装饰），
  /// 并通知全局快捷键让位给输入（house 惯例，`HotkeysHelper`）。
  Widget _field(TextEditingController controller, String label) => Focus(
    onFocusChange: HotkeysHelper.onFocusChanges,
    child: TextField(
      controller: controller,
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
      ),
    ),
  );

  Widget _textRow(String label, TextEditingController controller) => Padding(
    padding: const EdgeInsets.only(bottom: 12.0),
    child: _field(controller, label),
  );

  Widget _addRowButton(String label, VoidCallback onPressed) => Align(
    alignment: Alignment.centerLeft,
    child: TextButton.icon(
      onPressed: onPressed,
      icon: const Icon(Symbols.add),
      label: Text(label),
    ),
  );

  /// 一行查询参数。
  Widget _queryRow(int index) => _paramRow(index, _queryRows);

  /// 一行参数（**查询参数与请求体字段共用**，模型里就是同一个类型）。
  ///
  /// P-21：以前这里只有"名字 + 取值来源"，`required` 与 `default` 虽然被模型带进带出，
  /// 却**没有任何控件**（用户在界面里根本改不了，且 `default` 保存一次还会丢类型）。
  /// 现在每一项都有一行控件：必填勾选框 + 默认值。
  Widget _paramRow(int index, List<_ParamRow> rows) {
    final row = rows[index];
    return Padding(
      padding: const EdgeInsets.only(bottom: 8.0),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final compact = constraints.maxWidth < 560.0;
          final nameField = _field(row.name, '参数名');
          // F4-S1（P-08 / D1:A）：取值要么来自闭集来源，要么是**写死的固定值**，两者互斥。
          final usesConstant = row.usesConstant;
          final constantToggle = Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Checkbox(
                value: usesConstant,
                visualDensity: VisualDensity.compact,
                onChanged: (value) => setState(() {
                  // 切到固定值 ⇒ 清空来源；切回来源 ⇒ 给一个与当前能力相关的默认来源（P-23）。
                  row.source = (value ?? false)
                      ? null
                      : defaultInputSourceFor(widget.capability);
                }),
              ),
              const Text('固定值'),
            ],
          );
          final sourceField = usesConstant
              ? _field(row.value, '固定值（写死，例如 30）')
              : _EnumMenuField<OnlineMusicInputSource>(
                  label: '取值来源',
                  value: row.source ?? defaultInputSourceFor(widget.capability),
                  options: OnlineMusicInputSource.values,
                  labelOf: inputSourceLabel,
                  // P-64：不再把英文枚举名当副标题露出来（它是**内部细节**）。
                  // 要和 JSON 视图对照时，JSON 视图里本来就是原始枚举名。
                  onChanged: (value) => setState(() => row.source = value),
                );
          final removeButton = IconButton(
            tooltip: '删除这一行',
            onPressed: () => setState(() => rows.removeAt(index).dispose()),
            icon: const Icon(Symbols.remove_circle),
          );
          final requiredToggle = Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Checkbox(
                value: row.required,
                visualDensity: VisualDensity.compact,
                onChanged: (value) =>
                    setState(() => row.required = value ?? false),
              ),
              const Text('必填'),
            ],
          );
          final defaultField = _field(row.defaultValue, '默认值（可留空）');
          final extrasBody = usesConstant
              ? const Padding(
                  padding: EdgeInsets.only(top: 8.0),
                  child: _Hint('固定值由你自己写死、一定会有值，因此「必填 / 默认值」在这里不起作用。'),
                )
              : compact
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const SizedBox(height: 8.0),
                    defaultField,
                    Align(
                      alignment: Alignment.centerLeft,
                      child: requiredToggle,
                    ),
                  ],
                )
              : Row(
                  children: [
                    const SizedBox(width: 44.0),
                    requiredToggle,
                    const SizedBox(width: 12.0),
                    Expanded(child: defaultField),
                  ],
                );
          final extras = Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 8.0, left: 8.0),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: constantToggle,
                ),
              ),
              extrasBody,
            ],
          );
          final head = compact
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    nameField,
                    const SizedBox(height: 8.0),
                    Row(
                      children: [
                        Expanded(child: sourceField),
                        removeButton,
                      ],
                    ),
                  ],
                )
              : Row(
                  children: [
                    Expanded(flex: 3, child: nameField),
                    const SizedBox(width: 12.0),
                    Expanded(flex: 3, child: sourceField),
                    removeButton,
                  ],
                );
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [head, extras],
          );
        },
      ),
    );
  }

  /// 一行请求头。标记敏感后，「值」入口换成**凭据引用**（F0-4 / Spec §11.1）：
  /// 秘密由「填写凭据」写进系统凭据管理器，配置里只留引用，界面一律遮蔽。
  Widget _headerRow(int index) {
    final row = _headerRows[index];
    final scheme = Theme.of(context).colorScheme;
    final nameField = _field(row.name, '请求头名');
    final valueField = _field(row.value, '值');
    final referenceField = _field(row.reference, '凭据引用（槽位名）');
    final removeButton = IconButton(
      tooltip: '删除这一行',
      onPressed: () => setState(() => _headerRows.removeAt(index).dispose()),
      icon: const Icon(Symbols.remove_circle),
    );
    final sensitiveToggle = InkWell(
      onTap: () => _toggleSensitive(row),
      borderRadius: BorderRadius.circular(6.0),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4.0),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 勾选框本身不接收点击：整个标签区（含文字）一起切换，
            // 免得出现"点文字没反应、只有点小方块才行"这种只有开发者知道的差异。
            IgnorePointer(
              child: Checkbox(
                value: row.sensitive,
                visualDensity: VisualDensity.compact,
                onChanged: (_) {},
              ),
            ),
            const Text('敏感'),
          ],
        ),
      ),
    );

    // F4-S2（P-09）：**非敏感**头可以让值来自闭集输入（动态头）。
    // 敏感头**没有**这个选项 —— 那等于把凭据放进普通输入通道。
    final inputToggle = InkWell(
      onTap: () => setState(() {
        row.source = row.source == null
            ? defaultInputSourceFor(widget.capability)
            : null;
      }),
      borderRadius: BorderRadius.circular(6.0),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4.0),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IgnorePointer(
              child: Checkbox(
                value: row.source != null,
                visualDensity: VisualDensity.compact,
                onChanged: (_) {},
              ),
            ),
            const Text('来自输入'),
          ],
        ),
      ),
    );
    final headerSourceField = _EnumMenuField<OnlineMusicInputSource>(
      label: '取值来源',
      value: row.source ?? defaultInputSourceFor(widget.capability),
      options: OnlineMusicInputSource.values,
      labelOf: inputSourceLabel,
      onChanged: (value) => setState(() => row.source = value),
    );
    final entryField = row.source == null ? valueField : headerSourceField;

    if (!row.sensitive) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 8.0),
        child: LayoutBuilder(
          builder: (context, constraints) {
            if (constraints.maxWidth < 560.0) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  nameField,
                  const SizedBox(height: 8.0),
                  entryField,
                  Row(
                    children: [
                      sensitiveToggle,
                      inputToggle,
                      const Spacer(),
                      removeButton,
                    ],
                  ),
                ],
              );
            }
            return Row(
              children: [
                Expanded(child: nameField),
                const SizedBox(width: 12.0),
                Expanded(child: entryField),
                const SizedBox(width: 4.0),
                sensitiveToggle,
                inputToggle,
                removeButton,
              ],
            );
          },
        ),
      );
    }

    // 敏感：值入口改为凭据引用 + 状态 + 填写入口；明文（若有）绝不静默丢弃。
    final configured = row.referenceConfigured;
    final statusText = switch (configured) {
      true => '凭据已配置',
      false => '凭据未配置：需先填写凭据',
      null => '凭据状态读取中…',
    };
    final statusColor = configured == false
        ? scheme.error
        : scheme.onSurfaceVariant;
    final credentialActions = Row(
      children: [
        Icon(
          configured == true ? Symbols.check_circle : Symbols.key,
          size: 16.0,
          color: statusColor,
        ),
        const SizedBox(width: 6.0),
        Expanded(
          child: Text(
            statusText,
            style: TextStyle(fontSize: AppType.caption, color: statusColor),
          ),
        ),
        TextButton(
          onPressed: () => _editHeaderCredential(row),
          child: Text(configured == true ? '更新凭据' : '填写凭据'),
        ),
      ],
    );
    final plaintextWarning = row.value.text.trim().isEmpty
        ? null
        : Row(
            children: [
              Icon(Symbols.error, size: 16.0, color: scheme.error),
              const SizedBox(width: 6.0),
              Expanded(
                child: Text(
                  '这一行仍有明文值，保存会被拒绝：请先用「检查并迁移」把它写进安全凭据，'
                  '或显式清空它。',
                  style: TextStyle(
                    fontSize: AppType.caption,
                    color: scheme.error,
                  ),
                ),
              ),
              TextButton(
                onPressed: () => setState(() => row.value.clear()),
                child: const Text('清空明文值'),
              ),
            ],
          );

    return Padding(
      padding: const EdgeInsets.only(bottom: 12.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const _Hint(
            '敏感请求头不写进配置：值保存在系统凭据管理器，配置里只留一个「凭据引用」；'
            '引用默认按 标识/能力/请求头名 派生，也可以手改成别的槽位（多个能力共享同一凭据）。',
          ),
          const SizedBox(height: 8.0),
          // F4-S9（P-12 / D3 边界）：把"不支持什么"明确写出来 ——
          // 而且这些写法**不会被静默忽略**（保存或试跑会明确报错）。
          const _Hint(
            '只支持静态认证值（固定值或凭据引用）：自动登录、Cookie 生命周期、动态签名、'
            '令牌刷新一概不支持；请求头值只能是 ASCII。'
            '不支持的写法不会被静默忽略 —— 保存或试跑时会明确报错。',
          ),
          const SizedBox(height: 8.0),
          LayoutBuilder(
            builder: (context, constraints) {
              if (constraints.maxWidth < 560.0) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    nameField,
                    const SizedBox(height: 8.0),
                    referenceField,
                    Row(
                      children: [sensitiveToggle, const Spacer(), removeButton],
                    ),
                  ],
                );
              }
              return Row(
                children: [
                  Expanded(child: nameField),
                  const SizedBox(width: 12.0),
                  Expanded(child: referenceField),
                  const SizedBox(width: 4.0),
                  sensitiveToggle,
                  removeButton,
                ],
              );
            },
          ),
          const SizedBox(height: 4.0),
          credentialActions,
          ?plaintextWarning,
        ],
      ),
    );
  }

  /// 打开"填写凭据"对话框；值只进安全槽位，绝不进入绑定/草稿/JSON 视图。
  Future<void> _editHeaderCredential(_HeaderRow row) async {
    final reference = _referenceOf(row);
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => _HeaderCredentialDialog(
        reference: reference,
        headerName: row.name.text.trim(),
        onSubmit: (value) => widget.onSaveCredential(reference, value),
      ),
    );
    if (saved != true || !mounted) return;
    await _refreshHeaderCredentialStates();
  }

  Widget _predicateRow(int index) {
    final row = _predicateRows[index];
    return Padding(
      padding: const EdgeInsets.only(bottom: 8.0),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final compact = constraints.maxWidth < 560.0;
          final pathField = _field(row.path, '路径（如 code）');
          final opField = _EnumMenuField<OnlineMusicPredicateOp>(
            label: '判定方式',
            value: row.op,
            options: OnlineMusicPredicateOp.values,
            onChanged: (value) => setState(() => row.op = value),
          );
          final valueField = _field(row.value, '值');
          final removeButton = IconButton(
            tooltip: '删除这一行',
            onPressed: () =>
                setState(() => _predicateRows.removeAt(index).dispose()),
            icon: const Icon(Symbols.remove_circle),
          );
          if (compact) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                pathField,
                const SizedBox(height: 8.0),
                opField,
                const SizedBox(height: 8.0),
                valueField,
                Align(alignment: Alignment.centerRight, child: removeButton),
              ],
            );
          }
          return Row(
            children: [
              Expanded(flex: 3, child: pathField),
              const SizedBox(width: 12.0),
              Expanded(flex: 2, child: opField),
              const SizedBox(width: 12.0),
              Expanded(flex: 2, child: valueField),
              removeButton,
            ],
          );
        },
      ),
    );
  }

  Widget _fieldRow(OnlineMusicDomainField field, _FieldRow row) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12.0),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final scheme = Theme.of(context).colorScheme;
          final compact = constraints.maxWidth < 640.0;
          final header = Row(
            children: [
              Checkbox(
                value: row.enabled,
                visualDensity: VisualDensity.compact,
                onChanged: (value) =>
                    setState(() => row.enabled = value ?? false),
              ),
              Expanded(
                child: Text(
                  domainFieldLabel(
                    field,
                    required: requiredFieldsFor(
                      widget.capability,
                    ).contains(field),
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: row.enabled
                        ? scheme.onSurface
                        : scheme.onSurfaceVariant,
                    fontSize: AppType.body,
                    fontWeight: AppType.weightSemibold,
                  ),
                ),
              ),
            ],
          );
          final pathsField = _field(row.paths, '候选路径（逗号分隔，按序取第一个存在的）');
          final transformField = _EnumMenuField<OnlineMusicFieldTransform>(
            label: '类型转换',
            value: row.transform,
            options: _transformChoicesFor(field),
            labelOf: transformLabel,
            // P-64：同样不再露英文枚举名（原来这里的注释说"便于与 JSON 视图对照"，
            // 但取值来源那一处本来就没有这句注释，两处口径不一致；统一按"内部细节不露出"
            // 处理，对照 JSON 时看 JSON 视图即可）。
            onChanged: (value) => setState(() => row.transform = value),
          );
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              header,
              const SizedBox(height: 4.0),
              if (compact) ...[
                pathsField,
                const SizedBox(height: 8.0),
                transformField,
              ] else
                Row(
                  children: [
                    Expanded(flex: 3, child: pathsField),
                    const SizedBox(width: 12.0),
                    Expanded(flex: 2, child: transformField),
                  ],
                ),
            ],
          );
        },
      ),
    );
  }

  /// 该字段**可选的**类型转换。
  ///
  /// P-30：表由映射层的读取器契约**派生**、必然覆盖全部字段 ⇒ 以前那个
  /// "未列出就给出全部 9 项"的兜底是**缺陷通道**（例如封面字段被兜底成 `asString`，
  /// 而映射只认 `Uri` ⇒ 封面恒 null）。这里直接取派生表，不再有兜底。
  List<OnlineMusicFieldTransform> _transformChoicesFor(
    OnlineMusicDomainField field,
  ) => expectedFieldKinds[field]!.toList();
}

enum OnlineMusicAuthKind { none, query, header, body }

OnlineMusicAuthKind _authKindOf(OnlineMusicAuthPlacement placement) =>
    switch (placement) {
      OnlineMusicNoAuthPlacement() => OnlineMusicAuthKind.none,
      OnlineMusicQueryAuthPlacement() => OnlineMusicAuthKind.query,
      OnlineMusicHeaderAuthPlacement() => OnlineMusicAuthKind.header,
      OnlineMusicBodyAuthPlacement() => OnlineMusicAuthKind.body,
    };

/// 字段的界面标签：只影响展示，不参与任何映射。
const _domainFieldLabels = <OnlineMusicDomainField, String>{
  OnlineMusicDomainField.trackId: '曲目 ID',
  OnlineMusicDomainField.title: '标题',
  OnlineMusicDomainField.artists: '艺术家',
  OnlineMusicDomainField.album: '专辑',
  OnlineMusicDomainField.coverUri: '封面地址',
  OnlineMusicDomainField.duration: '时长',
  OnlineMusicDomainField.playlistId: '歌单 ID',
  OnlineMusicDomainField.playlistName: '歌单名称',
  OnlineMusicDomainField.playlistCoverUri: '歌单封面',
  OnlineMusicDomainField.playlistCreator: '歌单创建者',
  OnlineMusicDomainField.playlistTrackCount: '歌单曲目数',
  // P-64：这四项以前缺失 ⇒ 「歌单分类」的字段行标题会显示英文枚举名
  // （categoryId / categoryName / categoryCount），歌单列表/榜单会显示
  // playlistUpdateFrequency。
  OnlineMusicDomainField.playlistUpdateFrequency: '更新频率',
  OnlineMusicDomainField.categoryId: '分类 ID',
  OnlineMusicDomainField.categoryName: '分类名',
  OnlineMusicDomainField.categoryCount: '分类内歌单数',
  OnlineMusicDomainField.lyricOriginal: '原文歌词',
  OnlineMusicDomainField.lyricTranslation: '翻译歌词',
  OnlineMusicDomainField.lyricRomanization: '罗马音歌词',
  OnlineMusicDomainField.streamUrl: '播放地址',
  OnlineMusicDomainField.streamQuality: '音质',
  // 这两个字段**必须把单位写进标签**（与"时长（毫秒）"/"时长（秒）"同一套口径）：
  // 实测同一件事在不同平台上是不同的量 ——
  // `streamBitrate`：网易云 `br` 是 **bps**（实测 128008 ≈ 128 kbps）；
  // `streamExpiresAt`：映射层按**绝对时间戳·秒**解析，而网易云的 `expi` 是
  // **"还有多少秒"（实测 1200）**，不是时间戳 —— 直接映射会得到 1970 年 ⇒ **误判为"已过期"**。
  OnlineMusicDomainField.streamBitrate: '码率（bps，如 128000）',
  OnlineMusicDomainField.streamExpiresAt: '有效期（绝对时间戳·秒，如 1765000000）',
};

/// 字段的界面标签。「必填」标记由**该能力真实的校验集合**决定，
/// 不在标签表里写死——同一个字段在不同能力下的必填性不同。
///
/// ⚠️ 标签表必须**覆盖全部枚举值**（P-64）：兜底是 `?? field.name`，漏一个就会把
/// 英文枚举名渲染成**字段行标题**。`test/page/settings_page/online_music_settings_test.dart`
/// 里有一条**穷举守卫**逐值断言"标签不等于枚举名"，漏了就会变红。
String domainFieldLabel(OnlineMusicDomainField field, {bool required = false}) {
  final base = _domainFieldLabels[field] ?? field.name;
  return required ? '$base（必填）' : base;
}

/// 该能力在表单里需要哪几个**响应路径**字段（P-01）。
///
/// 为什么必须按能力区分（而不是"搜索用列表路径、其余用字段根路径"的互斥二选一）：
/// - `search`：字段相对**列表项**解析 ⇒ 只要 `listPath`；
/// - `playlistCollection` / `playlistCategories` / `chartList` / `newSongs`：
///   拿到的是一个数组、元素自带全部元数据 ⇒ **只要 `listPath`**（校验也要求它）
///   —— 旧表单对这四个**根本没有写 `listPath` 的入口**，于是它们存不下也试不了；
/// - `playlist`：元数据在 `fieldsRootPath`、曲目数组在 `listPath` ⇒ **两个都要**
///   （网易云实测配方：`fieldsRoot=playlist`、`listPath=playlist.tracks`）
///   —— 旧表单只给字段根路径，于是曲目**恒空**而试跑还报"成功"；
/// - `lyric` / `stream`：字段相对响应体（或其子对象）解析 ⇒ 只要 `fieldsRootPath`。
///
/// 穷举 switch：新增能力漏改即**编译失败**（反模式 5）。
({bool listPath, bool fieldsRootPath}) responsePathFieldsFor(
  OnlineMusicCapability capability,
) => switch (capability) {
  OnlineMusicCapability.search => (listPath: true, fieldsRootPath: false),
  OnlineMusicCapability.playlist => (listPath: true, fieldsRootPath: true),
  OnlineMusicCapability.playlistCollection ||
  OnlineMusicCapability.playlistCategories ||
  OnlineMusicCapability.chartList ||
  OnlineMusicCapability.newSongs => (listPath: true, fieldsRootPath: false),
  OnlineMusicCapability.lyric ||
  OnlineMusicCapability.stream => (listPath: false, fieldsRootPath: true),
};

/// 新增**参数行**的默认取值来源（P-23）。
///
/// 为什么要按能力区分：同一个「加参数」按钮在 8 个能力下语义完全不同 ——
/// 播放解析 / 歌词最可能要填曲目 ID，歌单详情要歌单 ID，搜索才是关键词；
/// 集合类能力（歌单列表 / 分类 / 榜单 / 新歌）最可能要填 `limit`（见真实配方
/// `docs/dev/netease-bindings/playlistCollection.json` 的 `cat/limit/offset`）。
///
/// 此前一律默认「搜索关键词」⇒ 在歌单详情里新增的参数会**静默把搜索关键词
/// 当成歌单 ID 发出去**（值来源错了却没有任何提示）。
///
/// 用**穷举 switch**（漏掉能力 ⇒ 编译失败），不用 if 链、不查表。
OnlineMusicInputSource defaultInputSourceFor(
  OnlineMusicCapability capability,
) => switch (capability) {
  OnlineMusicCapability.search => OnlineMusicInputSource.keyword,
  OnlineMusicCapability.playlist => OnlineMusicInputSource.playlistId,
  OnlineMusicCapability.lyric ||
  OnlineMusicCapability.stream => OnlineMusicInputSource.trackId,
  OnlineMusicCapability.playlistCollection ||
  OnlineMusicCapability.playlistCategories ||
  OnlineMusicCapability.chartList ||
  OnlineMusicCapability.newSongs => OnlineMusicInputSource.limit,
};

/// 试跑要用的**真实输入**（P-49）：由编辑器按能力决定填哪些，控制器只看值。
///
/// 每个字段为 null 表示"用户没给" ⇒ 控制器回落到既有默认值（默认行为不变）。
typedef DeclarativeTestInputs = ({
  String? keyword,
  int? limit,
  String? trackId,
  String? playlistId,
});

/// 试跑需要的**真实输入**（P-49）：关键词 / 每页数量 / 额外 ID。
///
/// 以前试跑把关键词写死成探测用的常量、把数量写死成 1（搜索）/ 30（新歌），
/// 界面上**根本没有**输入关键词的地方 ⇒ 用户无法用自己的词验证配置。
///
/// 穷举 switch：新增能力漏改即**编译失败**。
({bool keyword, bool limit, bool id, String idLabel}) testInputFieldsFor(
  OnlineMusicCapability capability,
) => switch (capability) {
  // 搜索：关键词 + 每页数量。
  OnlineMusicCapability.search => (
    keyword: true,
    limit: true,
    id: false,
    idLabel: '',
  ),
  // 这四个能力一次请求拿一个数组：最可能用到的是每页数量，不需要额外 ID。
  OnlineMusicCapability.playlistCollection ||
  OnlineMusicCapability.playlistCategories ||
  OnlineMusicCapability.chartList ||
  OnlineMusicCapability.newSongs => (
    keyword: false,
    limit: true,
    id: false,
    idLabel: '',
  ),
  OnlineMusicCapability.playlist => (
    keyword: false,
    limit: false,
    id: true,
    idLabel: '试跑用的歌单 ID',
  ),
  OnlineMusicCapability.lyric || OnlineMusicCapability.stream => (
    keyword: false,
    limit: false,
    id: true,
    idLabel: '试跑用的曲目 ID',
  ),
};

/// 试跑是否需要"额外 ID"输入，以及那个 ID 是什么（P-64）。
///
/// 旧写法只对 `playlistCollection` 特判，于是**歌单分类 / 榜单 / 新歌**也显示
/// 一个用不到的 ID 输入框；而歌单详情与播放解析的输入**含义不同**（歌单 ID vs 曲目 ID），
/// 却共用一句「试跑用的 ID（曲目 / 歌单）」。
///
/// 现在它**派生**自 [testInputFieldsFor] —— 两处口径不会分叉。
({bool needed, String label}) testIdFieldFor(OnlineMusicCapability capability) {
  final fields = testInputFieldsFor(capability);
  return (needed: fields.id, label: fields.idLabel);
}

/// 查询参数取值来源的界面标签。
///
/// ⚠️ 必须**覆盖全部枚举值**（P-64）：漏一个就会在界面上露出英文枚举名
/// （`inputSourceLabel` 的兜底是 `?? source.name`）。
/// `test/page/settings_page/online_music_settings_test.dart` 里有一条
/// **穷举守卫**逐值断言"标签不等于枚举名"，漏了就会变红。
const _inputSourceLabels = <OnlineMusicInputSource, String>{
  OnlineMusicInputSource.keyword: '搜索关键词',
  OnlineMusicInputSource.limit: '每页数量',
  OnlineMusicInputSource.offset: '偏移量',
  OnlineMusicInputSource.page: '页码',
  OnlineMusicInputSource.cursor: '游标',
  OnlineMusicInputSource.trackId: '曲目 ID',
  OnlineMusicInputSource.playlistId: '歌单 ID',
  // P-64：这一项以前缺失 ⇒ 「歌单分类」能力里选它时菜单显示英文 `categoryId`。
  OnlineMusicInputSource.categoryId: '歌单分类',
  OnlineMusicInputSource.quality: '音质',
};

String inputSourceLabel(OnlineMusicInputSource source) =>
    _inputSourceLabels[source] ?? source.name;

/// 类型转换的界面标签；菜单里同时显示原始枚举名，便于与 JSON 视图对照。
const _transformLabels = <OnlineMusicFieldTransform, String>{
  OnlineMusicFieldTransform.asString: '文本',
  OnlineMusicFieldTransform.asInt: '整数',
  OnlineMusicFieldTransform.asUri: '链接',
  OnlineMusicFieldTransform.asHttpsUri: 'HTTPS 链接',
  OnlineMusicFieldTransform.asDurationMs: '时长（毫秒）',
  OnlineMusicFieldTransform.asDurationSeconds: '时长（秒）',
  OnlineMusicFieldTransform.asSingleStringList: '单个字符串 → 列表',
  OnlineMusicFieldTransform.asStringList: '字符串列表',
  OnlineMusicFieldTransform.asBool: '布尔值',
};

String transformLabel(OnlineMusicFieldTransform transform) =>
    _transformLabels[transform] ?? transform.name;

String capabilityLabel(OnlineMusicCapability capability) =>
    onlineMusicCapabilityLabel(capability);

/// 对话框标题头：与项目其它设置对话框一致（标题 + 一行说明）。
class _DialogHeader extends StatelessWidget {
  const _DialogHeader({required this.title, required this.subtitle});

  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: scheme.onSurface,
            fontSize: AppType.sectionTitle,
            fontWeight: AppType.weightBold,
          ),
        ),
        const SizedBox(height: 4.0),
        Text(
          subtitle,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: scheme.onSurfaceVariant,
            fontSize: AppType.caption,
          ),
        ),
      ],
    );
  }
}

/// 试跑 / 探测结果区。
///
/// 结构要点（对应上一轮验收的 UI 问题 1）：
/// - **固定高度**：不参与表单的布局竞争，长结果不会把表单挤崩；
/// - 状态行高度固定，文案变化不引起位移；
/// - 详情在只读、可滚动的文本框里（项目展示日志的既有做法），可复制、可看全；
/// - 底部操作栏在滚动区之外，不会因为结果变长而消失。
class _ResultArea extends StatelessWidget {
  const _ResultArea({
    required this.height,
    required this.headline,
    required this.ok,
    required this.busy,
    required this.controller,
    required this.hint,
  });

  final double height;
  final String? headline;
  final bool? ok;
  final bool busy;
  final TextEditingController controller;
  final String hint;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = switch (ok) {
      true => scheme.primary,
      false => scheme.error,
      null => scheme.onSurfaceVariant,
    };
    final icon = switch (ok) {
      true => Symbols.check_circle,
      false => Symbols.error,
      null => Symbols.info,
    };
    return SizedBox(
      height: height,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            height: 22.0,
            child: Row(
              children: [
                if (busy)
                  const SizedBox(
                    width: 14.0,
                    height: 14.0,
                    child: CircularProgressIndicator(strokeWidth: 2.0),
                  )
                else
                  Icon(icon, size: 16.0, color: color),
                const SizedBox(width: 8.0),
                Expanded(
                  child: Text(
                    headline ?? (busy ? '正在请求…' : '尚未试跑'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: color,
                      fontSize: AppType.caption,
                      fontWeight: AppType.weightSemibold,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 6.0),
          Expanded(
            child: Focus(
              onFocusChange: HotkeysHelper.onFocusChanges,
              child: TextField(
                controller: controller,
                readOnly: true,
                expands: true,
                maxLines: null,
                textAlignVertical: TextAlignVertical.top,
                style: TextStyle(
                  fontSize: AppType.caption,
                  fontFamily: 'monospace',
                  color: scheme.onSurfaceVariant,
                ),
                decoration: InputDecoration(
                  border: const OutlineInputBorder(),
                  contentPadding: const EdgeInsets.all(10.0),
                  hintText: hint,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 能力配置表单滚动区的 key：供测试与辅助定位「表单」这一处滚动区。
@visibleForTesting
const capabilityFormKey = ValueKey<String>('onlineMusicCapabilityForm');

/// 高基数枚举选择。
///
/// 项目既有做法是 `MenuAnchor`（全仓 18 处）；分段按钮只适合 2–5 个短选项，
/// 选项一多就只能靠横向滚动条。这里用 `InputDecorator` 让它与相邻文本框同高同款。
class _EnumMenuField<T> extends StatelessWidget {
  const _EnumMenuField({
    required this.label,
    required this.value,
    required this.options,
    required this.onChanged,
    this.labelOf,
    this.sublabelOf,
  });

  final String label;
  final T value;
  final List<T> options;
  final ValueChanged<T> onChanged;
  final String Function(T value)? labelOf;
  final String Function(T value)? sublabelOf;

  String _textOf(T item) => labelOf?.call(item) ?? '$item';

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return MenuAnchor(
      style: MenuStyle(
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(borderRadius: AppRadius.mdCircular),
        ),
      ),
      menuChildren: [
        for (final option in options)
          MenuItemButton(
            // 当前项也要保持「可用态」：用禁用态会被读成"这一项不可用"。
            // 选中当前项是幂等的，菜单会自动收起。
            onPressed: () => onChanged(option),
            leadingIcon: Icon(
              option == value ? Symbols.check : Symbols.radio_button_unchecked,
              size: 18.0,
              color: option == value ? scheme.primary : scheme.onSurfaceVariant,
            ),
            child: _MenuOptionLabel(
              text: _textOf(option),
              sublabel: sublabelOf?.call(option),
            ),
          ),
      ],
      builder: (context, controller, child) => Tooltip(
        message: sublabelOf == null
            ? '$label：${_textOf(value)}'
            : '$label：${_textOf(value)}（${sublabelOf!(value)}）',
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () =>
              controller.isOpen ? controller.close() : controller.open(),
          child: InputDecorator(
            isEmpty: false,
            decoration: InputDecoration(
              labelText: label,
              border: const OutlineInputBorder(),
              suffixIcon: const Icon(Symbols.arrow_drop_down),
            ),
            child: Text(
              _textOf(value),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
      ),
    );
  }
}

class _MenuOptionLabel extends StatelessWidget {
  const _MenuOptionLabel({required this.text, this.sublabel});

  final String text;
  final String? sublabel;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (sublabel == null) return Text(text);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(text),
        Text(
          sublabel!,
          style: TextStyle(
            color: scheme.onSurfaceVariant,
            fontSize: AppType.caption,
          ),
        ),
      ],
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12.0),
      child: Text(
        label,
        style: TextStyle(
          color: scheme.primary,
          fontSize: AppType.body,
          fontWeight: AppType.weightBold,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}

/// 「填写凭据」对话框：把秘密**只**写进安全槽位。
///
/// 它不返回、也不保存输入的值：值只经由 [onSubmit] 交给凭据访问层，
/// 因此不会进入能力绑定、编辑草稿或 JSON 视图（反模式 6：按值来源隔离）。
class _HeaderCredentialDialog extends StatefulWidget {
  const _HeaderCredentialDialog({
    required this.reference,
    required this.headerName,
    required this.onSubmit,
  });

  /// 目标槽位名（只是引用）。
  final String reference;

  /// 该凭据服务的请求头名，仅用于文案。
  final String headerName;

  final Future<void> Function(String value) onSubmit;

  @override
  State<_HeaderCredentialDialog> createState() =>
      _HeaderCredentialDialogState();
}

class _HeaderCredentialDialogState extends State<_HeaderCredentialDialog> {
  final _controller = TextEditingController();
  bool _obscure = true;
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_saving || _controller.text.trim().isEmpty) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.onSubmit(_controller.text);
      if (mounted) Navigator.of(context).pop(true);
    } catch (error) {
      // 保存失败必须**明确报错**：绝不能静默回退成明文（Spec §11.1 规则 3）。
      if (mounted) {
        setState(
          () => _error = error is OnlineMusicCredentialException
              ? error.safeMessage
              : '无法把凭据写入安全存储',
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('填写 ${widget.headerName} 的凭据'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const _Hint('值会写入系统凭据管理器，本机其余位置（配置、日志、界面）都不会保留它。'),
            const SizedBox(height: 12.0),
            Focus(
              onFocusChange: HotkeysHelper.onFocusChanges,
              child: TextField(
                controller: _controller,
                autofocus: true,
                enabled: !_saving,
                obscureText: _obscure,
                textInputAction: TextInputAction.done,
                onSubmitted: (_) => _submit(),
                onChanged: (_) => setState(() => _error = null),
                decoration: InputDecoration(
                  labelText: '凭据值',
                  // 槽位名不是秘密，可以显示，方便用户确认写到了哪一格。
                  helperText: '槽位：${widget.reference}',
                  errorText: _error,
                  suffixIcon: IconButton(
                    tooltip: _obscure ? '显示' : '隐藏',
                    onPressed: _saving
                        ? null
                        : () => setState(() => _obscure = !_obscure),
                    icon: Icon(
                      _obscure ? Symbols.visibility : Symbols.visibility_off,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _saving || _controller.text.trim().isEmpty
              ? null
              : _submit,
          child: Text(_saving ? '保存中' : '保存'),
        ),
      ],
    );
  }
}

/// 表单里的说明文字。
class _Hint extends StatelessWidget {
  const _Hint(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Text(
    text,
    style: TextStyle(
      color: Theme.of(context).colorScheme.onSurfaceVariant,
      fontSize: AppType.caption,
    ),
  );
}

class _ParamRow {
  _ParamRow(
    this.name,
    this.source,
    this.value,
    this.required,
    this.defaultValue,
  );

  factory _ParamRow.from(OnlineMusicParamBinding binding) => _ParamRow(
    TextEditingController(text: binding.name),
    binding.source,
    TextEditingController(text: binding.value ?? ''),
    binding.required,
    TextEditingController(text: binding.defaultValue?.toString() ?? ''),
  );

  /// 空行必须**显式**给出取值来源（由 [defaultInputSourceFor] 按当前能力决定），
  /// 不再有"默认就是搜索关键词"这种与能力无关的兜底（P-23）。
  factory _ParamRow.empty(OnlineMusicInputSource source) => _ParamRow(
    TextEditingController(),
    source,
    TextEditingController(),
    false,
    TextEditingController(),
  );

  final TextEditingController name;

  /// 取值来源（闭集）；**null 表示"固定值"模式**（F4-S1 / P-08 / D1:A）。
  OnlineMusicInputSource? source;

  /// 固定值输入框（**只在固定值模式下有意义**）。
  final TextEditingController value;

  /// 必填（P-21 起有控件，因此可变）。
  bool required;
  final TextEditingController defaultValue;

  /// 是否处于"固定值"模式（与 [source] 互斥）。
  bool get usesConstant => source == null;

  void dispose() {
    name.dispose();
    value.dispose();
    defaultValue.dispose();
  }
}

class _HeaderRow {
  _HeaderRow(
    this.name,
    this.value, {
    this.source,
    this.sensitive = false,
    String reference = '',
  }) : reference = TextEditingController(text: reference);

  /// [derivedReference] 只在**已标记敏感**时参与：它是该请求头按
  /// `<标识>/<能力>/<归一化头名>` 派生出的槽位名（F0 / Spec §3）。
  factory _HeaderRow.from(
    OnlineMusicHeaderSpec header, {
    required String derivedReference,
  }) => _HeaderRow(
    TextEditingController(text: header.name),
    TextEditingController(text: header.value),
    source: header.source,
    sensitive: header.sensitive,
    reference:
        header.credentialReference ??
        (header.sensitive ? derivedReference : ''),
  );

  factory _HeaderRow.empty() =>
      _HeaderRow(TextEditingController(), TextEditingController());

  final TextEditingController name;

  /// 明文值。标记敏感后它**不再写进配置**，但仍留在界面上 ——
  /// 绝不静默丢弃用户已经填好的秘密（要么迁移，要么由用户显式清空）。
  final TextEditingController value;

  /// 是否明确标记为敏感（F0-4 / 决策 A）。
  bool sensitive;

  /// 值是否**来自闭集输入**（动态头，F4-S2 / P-09）；`null` = 用固定值 / 凭据引用。
  OnlineMusicInputSource? source;

  /// 安全凭据**槽位名**（只是引用，不是值）；可编辑，以便多个能力显式共享凭据。
  final TextEditingController reference;

  /// 该引用对应的槽位当前是否有凭据（`null` = 还没查出来）。
  bool? referenceConfigured;

  void dispose() {
    name.dispose();
    value.dispose();
    reference.dispose();
  }
}

class _PredicateRow {
  _PredicateRow(this.path, this.op, this.value);

  factory _PredicateRow.from(OnlineMusicSuccessPredicate predicate) =>
      _PredicateRow(
        TextEditingController(text: predicate.path.source),
        predicate.op,
        TextEditingController(text: '${predicate.value ?? ''}'),
      );

  factory _PredicateRow.empty() => _PredicateRow(
    TextEditingController(),
    OnlineMusicPredicateOp.eq,
    TextEditingController(),
  );

  final TextEditingController path;
  OnlineMusicPredicateOp op;
  final TextEditingController value;

  void dispose() {
    path.dispose();
    value.dispose();
  }
}

class _FieldRow {
  _FieldRow(this.enabled, this.paths, this.transform, this.required);

  factory _FieldRow.from(
    OnlineMusicDomainField field,
    OnlineMusicFieldSpec? spec,
  ) => _FieldRow(
    spec != null,
    TextEditingController(
      text: spec?.candidates.map((path) => path.source).join(', ') ?? '',
    ),
    spec?.transform ?? _defaultTransformFor(field),
    spec?.required ?? false,
  );

  final TextEditingController paths;
  OnlineMusicFieldTransform transform;
  final bool required;

  /// 勾选后该字段才会写进配置。
  bool enabled;

  void dispose() => paths.dispose();
}

/// 该字段的**默认**类型转换（P-30）。
///
/// 取派生表的**第一项**，因此默认值总是"读取器真能消费"的那一个：
/// 封面/播放地址 ⇒ `asUri`、数量/时长 ⇒ `asInt`/`asDurationMs`、文本 ⇒ `asString`。
/// 以前对"未列出"的字段兜底成 `asString`（封面即因此**恒为 null**）。
OnlineMusicFieldTransform _defaultTransformFor(OnlineMusicDomainField field) =>
    expectedFieldKinds[field]!.first;
