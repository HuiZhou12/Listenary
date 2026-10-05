import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:pure_music/component/settings_tile.dart';
import 'package:pure_music/core/design_tokens.dart';
import 'package:pure_music/services/music_platform/declarative/provider_probe.dart';
import 'package:pure_music/services/music_platform/provider/online_music_binding.dart';
import 'package:pure_music/services/music_platform/provider/online_music_capability.dart';
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
      title: Text('能力配置 · ${definition.id}'),
      content: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final capability in OnlineMusicCapability.values) ...[
              SettingsTile(
                description: capabilityLabel(capability),
                subtitle: _describe(capability),
                action: FilledButton.icon(
                  onPressed: isPhaseTwo(capability)
                      ? null
                      : () => onEditCapability(capability),
                  icon: const Icon(Symbols.tune),
                  label: Text(isPhaseTwo(capability) ? '第二阶段' : '配置'),
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
  });

  final OnlineMusicProviderDefinition definition;
  final OnlineMusicCapability capability;
  final OnlineMusicCapabilityBinding initialBinding;

  /// 探测整个服务（仅 search 提供）。
  final Future<ProviderProbeReport> Function() onProbe;

  /// 用**当前编辑中的**绑定试跑一次；[trackId] 供播放解析试跑使用。
  final Future<DeclarativeCapabilityTestResult> Function(
    OnlineMusicDeclarativeCapabilityBinding binding,
    String? trackId,
  )
  onTest;

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
  final _headerRows = <_HeaderRow>[];
  final _predicateRows = <_PredicateRow>[];
  final Map<OnlineMusicDomainField, _FieldRow> _fieldRows = {};
  late TextEditingController _authName;
  late TextEditingController _authPrefix;
  late OnlineMusicAuthPlacement _authPlacement;
  late TextEditingController _json;
  late OnlineMusicHttpVerb _verb;
  final _testTrackId = TextEditingController();

  bool _showJson = false;
  bool _bound = false;
  String? _error;
  String? _notice;
  bool _busy = false;
  String? _lastTestSummary;
  String? _lastPreview;

  /// `_collect()` 收集过程中发现的、无法解释成有效配置的输入。
  final List<String> _collectErrors = [];

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
    _testTrackId.dispose();
    for (final row in _queryRows) {
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
          listPath: _isSearch ? JsonPath.tryParse('data') : null,
          fieldsRootPath: _isSearch ? null : JsonPath.tryParse('data'),
        ),
      );

  void _loadFromBinding(OnlineMusicDeclarativeCapabilityBinding binding) {
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
    for (final row in _headerRows) {
      row.dispose();
    }
    _headerRows
      ..clear()
      ..addAll(binding.request.headers.map(_HeaderRow.from));
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
      _fieldRows[field] = _FieldRow.from(
        field,
        binding.response.fields[field],
      );
    }
    _authPlacement = binding.request.auth;
    final (name, prefix) = switch (_authPlacement) {
      OnlineMusicQueryAuthPlacement(:final parameterName) => (parameterName, ''),
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

  String _jsonPreview() => jsonEncode(_binding.toJson());

  /// 把当前表单收集成一个绑定（供试跑/保存/JSON 预览用）。
  OnlineMusicDeclarativeCapabilityBinding _collect() {
    final query = [
      for (final row in _queryRows)
        if (row.name.text.trim().isNotEmpty)
          OnlineMusicParamBinding(
            name: row.name.text.trim(),
            source: row.source,
            required: row.required,
            defaultValue: row.defaultValue.text.trim().isEmpty
                ? null
                : row.defaultValue.text.trim(),
          ),
    ];
    final headers = [
      for (final row in _headerRows)
        if (row.name.text.trim().isNotEmpty)
          OnlineMusicHeaderSpec(
            name: row.name.text.trim(),
            value: row.value.text,
          ),
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
          _collectErrors.add(
            '字段 ${entry.key.name} 的路径「$candidate」写法无效',
          );
          continue;
        }
        paths.add(path);
      }
      if (paths.isEmpty) continue;
      fields[entry.key] = OnlineMusicFieldSpec(
        candidates: paths,
        transform: entry.value.transform,
        required: entry.value.required,
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
        body: _binding.request.body,
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
        listPath: _isSearch ? JsonPath.tryParse(_listPath.text.trim()) : null,
        fieldsRootPath: _isSearch
            ? null
            : JsonPath.tryParse(_fieldsRoot.text.trim()),
        totalPath: JsonPath.tryParse(_totalPath.text.trim()),
        nextCursorPath: JsonPath.tryParse(_nextCursor.text.trim()),
        fields: fields,
        pagination: _binding.response.pagination,
      ),
    );
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
      _error = null;
      _notice = null;
    });
    try {
      final report = await widget.onProbe();
      if (!mounted) return;
      setState(() {
        _busy = false;
        _lastTestSummary = null;
        _lastPreview = null;
        _notice = report.hasDraft
            ? '探测命中「${report.draftTemplateId}」，已生成初稿'
            : '没有候选可用：${report.outcomes.map((o) => '${o.candidateId}: ${o.failureReason ?? '得分 0'}').join('；')}';
        if (report.hasDraft) {
          _loadFromBinding(report.draft!);
          _json.text = _jsonPreview();
        }
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = '探测失败';
        });
      }
    }
  }

  Future<void> _runTest() async {
    final binding = _collect();
    if (_collectErrors.isNotEmpty) {
      setState(() => _error = _collectErrors.join('；'));
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _notice = null;
    });
    try {
      final result = await widget.onTest(
        binding,
        _testTrackId.text.trim().isEmpty ? null : _testTrackId.text.trim(),
      );
      if (!mounted) return;
      setState(() {
        _busy = false;
        _lastTestSummary = result.ok
            ? '试跑成功（HTTP ${result.statusCode}）：${result.mappedSummary ?? '已解析'}'
            : '试跑失败（HTTP ${result.statusCode ?? '-'}）：${result.failureReason ?? '未知原因'}';
        _lastPreview = result.responsePreview;
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = '试跑失败';
        });
      }
    }
  }

  void _applyJson() {
    try {
      final parsed = OnlineMusicCapabilityBinding.fromJson(
        jsonDecode(_json.text),
      );
      if (parsed is! OnlineMusicDeclarativeCapabilityBinding) {
        setState(() => _error = 'JSON 必须是声明式（http）绑定');
        return;
      }
      final issues = parsed.validationIssues(widget.capability);
      setState(() {
        _binding = parsed;
        _loadFromBinding(parsed);
        _json.text = _jsonPreview();
        _error = issues.isEmpty ? null : issues.join('；');
        _notice = issues.isEmpty ? '已应用 JSON' : null;
      });
    } catch (error) {
      setState(() => _error = 'JSON 解析失败：$error');
    }
  }

  void _submit() {
    final binding = _collect();
    final issues = [..._collectErrors, ...binding.validationIssues(widget.capability)];
    if (issues.isNotEmpty) {
      setState(() => _error = issues.join('；'));
      return;
    }
    Navigator.of(context).pop(binding);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      title: Text('${capabilityLabel(widget.capability)} · ${widget.definition.id}'),
      content: SizedBox(
        width: 720,
        height: 560,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_error != null)
              _Banner(text: _error!, color: scheme.error),
            if (_notice != null) _Banner(text: _notice!, color: scheme.primary),
            if (_lastTestSummary != null)
              _Banner(text: _lastTestSummary!, color: scheme.onSurfaceVariant),
            if (_lastPreview != null)
              Padding(
                padding: const EdgeInsets.only(top: 4, bottom: 8),
                child: Text(
                  _lastPreview!,
                  maxLines: 4,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: scheme.onSurfaceVariant,
                    fontSize: AppType.caption,
                  ),
                ),
              ),
            Expanded(
              child: _showJson
                  ? TextField(
                      controller: _json,
                      maxLines: null,
                      expands: true,
                      style: const TextStyle(fontFamily: 'monospace'),
                      decoration: const InputDecoration(
                        border: OutlineInputBorder(),
                        hintText: '能力绑定的 JSON',
                      ),
                    )
                  : _buildForm(),
            ),
          ],
        ),
      ),
      actions: [
        TextButton.icon(
          onPressed: () => setState(() => _showJson = !_showJson),
          icon: Icon(_showJson ? Symbols.list : Symbols.data_object),
          label: Text(_showJson ? '表单' : 'JSON'),
        ),
        if (_showJson)
          TextButton(onPressed: _applyJson, child: const Text('应用 JSON')),
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
        FilledButton(
          onPressed: _busy ? null : _submit,
          child: const Text('保存'),
        ),
      ],
    );
  }

  Widget _buildForm() {
    return ListView(
      children: [
        const _SectionTitle('请求'),
        SettingsTile(
          description: '请求方法',
          action: SegmentedButton<OnlineMusicHttpVerb>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: OnlineMusicHttpVerb.get, label: Text('GET')),
              ButtonSegment(value: OnlineMusicHttpVerb.post, label: Text('POST')),
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
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: () => setState(() => _queryRows.add(_ParamRow.empty())),
            icon: const Icon(Symbols.add),
            label: const Text('加查询参数'),
          ),
        ),
        const SizedBox(height: 8),
        SettingsTile(
          description: '认证方式',
          subtitle: '凭据值由该条目的凭据槽位提供，不写进配置',
          action: SegmentedButton<OnlineMusicAuthKind>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: OnlineMusicAuthKind.none, label: Text('无')),
              ButtonSegment(value: OnlineMusicAuthKind.query, label: Text('查询串')),
              ButtonSegment(value: OnlineMusicAuthKind.header, label: Text('请求头')),
              ButtonSegment(value: OnlineMusicAuthKind.body, label: Text('请求体')),
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
        const SizedBox(height: 12),
        for (var index = 0; index < _headerRows.length; index++)
          _headerRow(index),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: () => setState(() => _headerRows.add(_HeaderRow.empty())),
            icon: const Icon(Symbols.add),
            label: const Text('加请求头'),
          ),
        ),
        const SizedBox(height: 16),
        const _SectionTitle('响应'),
        _textRow('成功状态码（逗号分隔，留空 = 2xx）', _statusCodes),
        for (var index = 0; index < _predicateRows.length; index++)
          _predicateRow(index),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: () =>
                setState(() => _predicateRows.add(_PredicateRow.empty())),
            icon: const Icon(Symbols.add),
            label: const Text('加成功判定'),
          ),
        ),
        const SizedBox(height: 12),
        if (_isSearch)
          _textRow('列表路径（如 data.songs）', _listPath)
        else
          _textRow('字段根路径（如 data）', _fieldsRoot),
        _textRow('总数路径（可选）', _totalPath),
        _textRow('游标路径（可选）', _nextCursor),
        const SizedBox(height: 16),
        const _SectionTitle('字段映射'),
        for (final field in domainFieldsFor(widget.capability))
          _fieldRow(field, _fieldRows[field]!),
        const SizedBox(height: 16),
        const _SectionTitle('试跑'),
        if (!_isSearch) _textRow('试跑用的曲目 ID', _testTrackId),
      ],
    );
  }

  Widget _textRow(String label, TextEditingController controller) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: TextField(
      controller: controller,
      decoration: InputDecoration(labelText: label, isDense: true),
    ),
  );

  Widget _queryRow(int index) {
    final row = _queryRows[index];
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(
            flex: 3,
            child: TextField(
              controller: row.name,
              decoration: const InputDecoration(
                labelText: '参数名',
                isDense: true,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            flex: 3,
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: SegmentedButton<OnlineMusicInputSource>(
                showSelectedIcon: false,
                segments: [
                  for (final source in OnlineMusicInputSource.values)
                    ButtonSegment(value: source, label: Text(source.name)),
                ],
                selected: {row.source},
                onSelectionChanged: (selection) =>
                    setState(() => row.source = selection.first),
              ),
            ),
          ),
          IconButton(
            tooltip: '删除',
            onPressed: () => setState(() {
              _queryRows.removeAt(index).dispose();
            }),
            icon: const Icon(Symbols.remove_circle),
          ),
        ],
      ),
    );
  }

  Widget _headerRow(int index) {
    final row = _headerRows[index];
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: row.name,
              decoration: const InputDecoration(
                labelText: '请求头名',
                isDense: true,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: row.value,
              decoration: const InputDecoration(labelText: '值', isDense: true),
            ),
          ),
          IconButton(
            tooltip: '删除',
            onPressed: () => setState(() {
              _headerRows.removeAt(index).dispose();
            }),
            icon: const Icon(Symbols.remove_circle),
          ),
        ],
      ),
    );
  }

  Widget _predicateRow(int index) {
    final row = _predicateRows[index];
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(
            flex: 3,
            child: TextField(
              controller: row.path,
              decoration: const InputDecoration(
                labelText: '路径（如 code）',
                isDense: true,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            flex: 3,
            child: SegmentedButton<OnlineMusicPredicateOp>(
              showSelectedIcon: false,
              segments: [
                for (final op in OnlineMusicPredicateOp.values)
                  ButtonSegment(value: op, label: Text(op.name)),
              ],
              selected: {row.op},
              onSelectionChanged: (selection) =>
                  setState(() => row.op = selection.first),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            flex: 2,
            child: TextField(
              controller: row.value,
              decoration: const InputDecoration(labelText: '值', isDense: true),
            ),
          ),
          IconButton(
            tooltip: '删除',
            onPressed: () => setState(() {
              _predicateRows.removeAt(index).dispose();
            }),
            icon: const Icon(Symbols.remove_circle),
          ),
        ],
      ),
    );
  }

  Widget _fieldRow(OnlineMusicDomainField field, _FieldRow row) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Checkbox(
            value: row.enabled,
            onChanged: (value) => setState(() => row.enabled = value ?? false),
          ),
          SizedBox(
            width: 120,
            child: Text(field.name, style: const TextStyle(fontSize: AppType.body)),
          ),
          Expanded(
            flex: 4,
            child: TextField(
              controller: row.paths,
              decoration: const InputDecoration(
                labelText: '候选路径（逗号分隔，按序取第一个存在的）',
                isDense: true,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            flex: 4,
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: SegmentedButton<OnlineMusicFieldTransform>(
                showSelectedIcon: false,
                segments: [
                  for (final transform in _transformChoicesFor(field))
                    ButtonSegment(
                      value: transform,
                      label: Text(transform.name),
                    ),
                ],
                selected: {row.transform},
                onSelectionChanged: (selection) =>
                    setState(() => row.transform = selection.first),
              ),
            ),
          ),
        ],
      ),
    );
  }

  List<OnlineMusicFieldTransform> _transformChoicesFor(
    OnlineMusicDomainField field,
  ) => expectedFieldKinds[field]?.toList() ?? OnlineMusicFieldTransform.values;
}

enum OnlineMusicAuthKind { none, query, header, body }

OnlineMusicAuthKind _authKindOf(OnlineMusicAuthPlacement placement) =>
    switch (placement) {
      OnlineMusicNoAuthPlacement() => OnlineMusicAuthKind.none,
      OnlineMusicQueryAuthPlacement() => OnlineMusicAuthKind.query,
      OnlineMusicHeaderAuthPlacement() => OnlineMusicAuthKind.header,
      OnlineMusicBodyAuthPlacement() => OnlineMusicAuthKind.body,
    };

String capabilityLabel(OnlineMusicCapability capability) =>
    switch (capability) {
      OnlineMusicCapability.search => '搜索',
      OnlineMusicCapability.playlist => '歌曲列表',
      OnlineMusicCapability.lyric => '歌词',
      OnlineMusicCapability.stream => '播放解析',
    };

bool isPhaseTwo(OnlineMusicCapability capability) =>
    capability == OnlineMusicCapability.playlist ||
    capability == OnlineMusicCapability.lyric;

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 8, top: 4),
      child: Text(
        label,
        style: TextStyle(
          color: scheme.onSurfaceVariant,
          fontSize: AppType.caption,
          fontWeight: AppType.weightSemibold,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({required this.text, required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Text(
      text,
      style: TextStyle(color: color, fontSize: AppType.body),
    ),
  );
}

class _ParamRow {
  _ParamRow(this.name, this.source, this.required, this.defaultValue);

  factory _ParamRow.from(OnlineMusicParamBinding binding) => _ParamRow(
    TextEditingController(text: binding.name),
    binding.source,
    binding.required,
    TextEditingController(text: binding.defaultValue?.toString() ?? ''),
  );

  factory _ParamRow.empty() => _ParamRow(
    TextEditingController(),
    OnlineMusicInputSource.keyword,
    false,
    TextEditingController(),
  );

  final TextEditingController name;
  OnlineMusicInputSource source;
  final bool required;
  final TextEditingController defaultValue;

  void dispose() {
    name.dispose();
    defaultValue.dispose();
  }
}

class _HeaderRow {
  _HeaderRow(this.name, this.value);

  factory _HeaderRow.from(OnlineMusicHeaderSpec header) =>
      _HeaderRow(TextEditingController(text: header.name), TextEditingController(text: header.value));

  factory _HeaderRow.empty() =>
      _HeaderRow(TextEditingController(), TextEditingController());

  final TextEditingController name;
  final TextEditingController value;

  void dispose() {
    name.dispose();
    value.dispose();
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

OnlineMusicFieldTransform _defaultTransformFor(OnlineMusicDomainField field) =>
    expectedFieldKinds[field]?.first ?? OnlineMusicFieldTransform.asString;
