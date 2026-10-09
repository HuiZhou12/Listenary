import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:pure_music/component/settings_tile.dart';
import 'package:pure_music/core/design_tokens.dart';
import 'package:pure_music/core/hotkeys.dart';
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

  /// 歌单列表是"一次请求拿一个数组"，不需要曲目/歌单 ID。
  bool get _isPlaylistCollection =>
      widget.capability == OnlineMusicCapability.playlistCollection;

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
    _resultController.dispose();
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
          _collectErrors.add('字段 ${entry.key.name} 的路径「$candidate」写法无效');
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
      // 进行中先清空上一次结果，避免旧标题/旧详情被误读成本次结果。
      _resultHeadline = null;
      _resultOk = null;
      _resultController.clear();
    });
    try {
      final report = await widget.onProbe();
      if (!mounted) return;
      final detail = StringBuffer();
      for (final outcome in report.outcomes) {
        detail.writeln(
          '· ${outcome.label}（${outcome.candidateId}）：得分 ${outcome.score}'
          '${outcome.statusCode == null ? '' : ' · HTTP ${outcome.statusCode}'}'
          '${outcome.mappedTrackCount > 0 ? ' · 解析出 ${outcome.mappedTrackCount} 首' : ''}'
          '${outcome.needsAuthentication ? ' · 需要认证' : ''}',
        );
        if (outcome.failureReason != null) {
          detail.writeln('    ${outcome.failureReason}');
        }
      }
      setState(() {
        _busy = false;
        _resultOk = report.hasDraft;
        _resultHeadline = report.hasDraft
            ? '探测命中「${report.draftTemplateId}」，已生成可编辑初稿'
            : '没有候选可用（${report.outcomes.length} 个候选均未通过）';
        _resultController.text = detail.toString().trimRight();
        if (report.hasDraft) {
          _loadFromBinding(report.draft!);
          _json.text = _jsonPreview();
        }
      });
    } catch (_) {
      _setResult(headline: '探测失败（网络或服务不可达）', ok: false);
    }
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
      final result = await widget.onTest(
        binding,
        _testTrackId.text.trim().isEmpty ? null : _testTrackId.text.trim(),
      );
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
      final kindSuffix = result.ok || result.failureKind == null
          ? ''
          : ' · ${declarativeTestFailureLabel(result.failureKind!)}';
      _setResult(
        headline: '${result.ok ? '试跑成功' : '试跑失败'}$suffix$kindSuffix',
        ok: result.ok,
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
                title:
                    '${capabilityLabel(widget.capability)} · ${widget.definition.id}',
                subtitle: _showJson
                    ? 'JSON 高级视图（与表单共享同一份校验）'
                    : (_isSearch
                          ? '声明式搜索：请求与响应映射都可以在这里改'
                          : '声明式播放解析：请求与响应映射都可以在这里改'),
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
          () => setState(() => _queryRows.add(_ParamRow.empty())),
        ),
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
        if (_isSearch)
          _textRow('列表路径（如 data.songs）', _listPath)
        else
          _textRow('字段根路径（如 data）', _fieldsRoot),
        _textRow('总数路径（可选）', _totalPath),
        _textRow('游标路径（可选）', _nextCursor),
        const SizedBox(height: 16),
        const _SectionTitle('字段映射'),
        const Padding(
          padding: EdgeInsets.only(bottom: 8.0),
          child: _Hint('勾选后该字段才会写进配置；候选路径按顺序取第一个存在的。'),
        ),
        for (final field in domainFieldsFor(widget.capability))
          _fieldRow(field, _fieldRows[field]!),
        if (!_isSearch) ...[
          const SizedBox(height: 12.0),
          const _SectionTitle('试跑'),
          if (_isPlaylistCollection)
            const Padding(
              padding: EdgeInsets.only(bottom: 8.0),
              child: _Hint('歌单列表不需要额外 ID：试跑会直接请求一次列表。'),
            )
          else
            _textRow('试跑用的 ID（曲目 / 歌单）', _testTrackId),
        ],
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

  Widget _queryRow(int index) {
    final row = _queryRows[index];
    return Padding(
      padding: const EdgeInsets.only(bottom: 8.0),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final compact = constraints.maxWidth < 560.0;
          final nameField = _field(row.name, '参数名');
          final sourceField = _EnumMenuField<OnlineMusicInputSource>(
            label: '取值来源',
            value: row.source,
            options: OnlineMusicInputSource.values,
            labelOf: inputSourceLabel,
            sublabelOf: (source) => source.name,
            onChanged: (value) => setState(() => row.source = value),
          );
          final removeButton = IconButton(
            tooltip: '删除这一行',
            onPressed: () =>
                setState(() => _queryRows.removeAt(index).dispose()),
            icon: const Icon(Symbols.remove_circle),
          );
          if (compact) {
            return Column(
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
            );
          }
          return Row(
            children: [
              Expanded(flex: 3, child: nameField),
              const SizedBox(width: 12.0),
              Expanded(flex: 3, child: sourceField),
              removeButton,
            ],
          );
        },
      ),
    );
  }

  Widget _headerRow(int index) {
    final row = _headerRows[index];
    return Padding(
      padding: const EdgeInsets.only(bottom: 8.0),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final compact = constraints.maxWidth < 560.0;
          final nameField = _field(row.name, '请求头名');
          final valueField = _field(row.value, '值');
          final removeButton = IconButton(
            tooltip: '删除这一行',
            onPressed: () =>
                setState(() => _headerRows.removeAt(index).dispose()),
            icon: const Icon(Symbols.remove_circle),
          );
          if (compact) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                nameField,
                const SizedBox(height: 8.0),
                valueField,
                Align(alignment: Alignment.centerRight, child: removeButton),
              ],
            );
          }
          return Row(
            children: [
              Expanded(child: nameField),
              const SizedBox(width: 12.0),
              Expanded(child: valueField),
              removeButton,
            ],
          );
        },
      ),
    );
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
            sublabelOf: (transform) => transform.name,
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
String domainFieldLabel(OnlineMusicDomainField field, {bool required = false}) {
  final base = _domainFieldLabels[field] ?? field.name;
  return required ? '$base（必填）' : base;
}

/// 查询参数取值来源的界面标签。
const _inputSourceLabels = <OnlineMusicInputSource, String>{
  OnlineMusicInputSource.keyword: '搜索关键词',
  OnlineMusicInputSource.limit: '每页数量',
  OnlineMusicInputSource.offset: '偏移量',
  OnlineMusicInputSource.page: '页码',
  OnlineMusicInputSource.cursor: '游标',
  OnlineMusicInputSource.trackId: '曲目 ID',
  OnlineMusicInputSource.playlistId: '歌单 ID',
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

  factory _HeaderRow.from(OnlineMusicHeaderSpec header) => _HeaderRow(
    TextEditingController(text: header.name),
    TextEditingController(text: header.value),
  );

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
