import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';
import 'package:pure_music/component/danger_confirm_dialog.dart';
import 'package:pure_music/component/settings_tile.dart';
import 'package:pure_music/core/design_tokens.dart';
import 'package:pure_music/core/preference.dart';
import 'package:pure_music/core/settings.dart';
import 'package:pure_music/core/utils.dart';
import 'package:pure_music/services/music_platform/index.dart';
import 'package:pure_music/services/music_platform/provider/online_music_capability.dart';
import 'package:pure_music/services/music_platform/provider/online_music_provider_settings.dart';
import 'package:pure_music/services/music_platform/provider/online_music_provider_settings_controller.dart';

/// 设置页「在线音乐」页签：Provider 条目、逐条目 API Key、能力分配与默认音质。
class OnlineMusicSettingsPanel extends StatefulWidget {
  const OnlineMusicSettingsPanel({super.key, required this.active});

  final bool active;

  @override
  State<OnlineMusicSettingsPanel> createState() =>
      _OnlineMusicSettingsPanelState();
}

class _OnlineMusicSettingsPanelState extends State<OnlineMusicSettingsPanel> {
  late final OnlineMusicProviderSettingsController _controller;
  final Map<String, bool> _configured = {};
  bool _hasLoaded = false;
  bool _loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _controller = context.read<OnlineMusicProviderSettingsController>();
    _controller.addListener(_onSettingsChanged);
    if (widget.active) _load();
  }

  @override
  void didUpdateWidget(covariant OnlineMusicSettingsPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!oldWidget.active && widget.active && !_hasLoaded) _load();
  }

  @override
  void dispose() {
    _controller.removeListener(_onSettingsChanged);
    super.dispose();
  }

  void _onSettingsChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _load() async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final states = <String, bool>{};
      for (final provider in _controller.settings.providers) {
        states[provider.id] = await _controller.isCredentialConfigured(
          provider,
        );
      }
      if (!mounted) return;
      setState(() {
        _configured
          ..clear()
          ..addAll(states);
        _hasLoaded = true;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = '无法读取在线音乐配置';
        _loading = false;
      });
    }
  }

  Future<bool> _apply(Future<bool> operation) async {
    final saved = await operation;
    if (!saved && mounted) {
      showTextOnSnackBar('保存在线音乐设置失败', variant: ToastVariant.error);
    }
    return saved;
  }

  Future<void> _addProvider() async {
    final result = await showDialog<_ProviderDraft>(
      context: context,
      builder: (context) => _ProviderDialog(
        existingIds: _controller.providerIds,
      ),
    );
    if (result == null || !mounted) return;
    final definition = OnlineMusicProviderDefinition.custom(
      id: result.id,
      baseUrl: result.baseUrl,
      requiresCredential: result.requiresCredential,
    );
    await _apply(_controller.addProvider(definition));
    if (mounted) setState(() => _configured[definition.id] = false);
  }

  Future<void> _editProvider(OnlineMusicProviderDefinition provider) async {
    final result = await showDialog<_ProviderDraft>(
      context: context,
      builder: (context) => _ProviderDialog(
        existingIds: _controller.providerIds,
        editing: provider,
      ),
    );
    if (result == null || !mounted) return;
    final updated = provider.editedBy(
      baseUrl: result.baseUrl,
      requiresCredential: result.requiresCredential,
    );
    final saved = await _apply(_controller.updateProvider(updated));
    if (saved && mounted) {
      setState(() => _configured.remove(updated.id));
      await _refreshConfigured(updated);
    }
  }

  Future<void> _refreshConfigured(
    OnlineMusicProviderDefinition provider,
  ) async {
    try {
      final configured = await _controller.isCredentialConfigured(provider);
      if (mounted) setState(() => _configured[provider.id] = configured);
    } catch (_) {
      // 读取失败时保持原状态，具体错误由凭据对话框或状态行呈现。
    }
  }

  Future<void> _removeProvider(OnlineMusicProviderDefinition provider) async {
    if (_controller.settings.providers.length <= 1) return;
    final confirmed = await showDangerConfirmDialog(
      context: context,
      title: '删除提供商 ${provider.id}？',
      message: '指向它的能力分配与默认提供商都会回落到列表中的第一个条目。'
          '已保存的 API Key 不会被删除。',
      confirmLabel: '删除',
    );
    if (!confirmed || !mounted) return;
    await _apply(_controller.removeProvider(provider.id));
    if (mounted) setState(() => _configured.remove(provider.id));
  }

  Future<void> _openCredentialDialog(
    OnlineMusicProviderDefinition provider,
  ) async {
    await showDialog<void>(
      context: context,
      builder: (context) => _ProviderApiKeyDialog(
        providerId: provider.id,
        controller: _controller,
        onSaved: () async {
          if (!mounted) return;
          setState(() => _configured[provider.id] = true);
        },
      ),
    );
  }

  Future<void> _clearCredential(
    OnlineMusicProviderDefinition provider,
  ) async {
    final confirmed = await showDangerConfirmDialog(
      context: context,
      title: '清除 ${provider.id} 的 ${_controller.credentialDisplayName}？',
      message: portableBuild
          ? '这会清除本次运行中的 API Key，关闭应用后也不会保留。'
          : '这会删除当前 Windows 用户凭据中的该槽位。',
      confirmLabel: '清除',
    );
    if (!confirmed || !mounted) return;
    try {
      await _controller.clearCredential(provider);
      if (mounted) setState(() => _configured[provider.id] = false);
    } on OnlineMusicCredentialException catch (error) {
      if (mounted) {
        showTextOnSnackBar(error.safeMessage, variant: ToastVariant.error);
      }
    } catch (_) {
      if (mounted) {
        showTextOnSnackBar('无法清除 API Key', variant: ToastVariant.error);
      }
    }
  }

  String _authDescription(OnlineMusicProviderDefinition provider) {
    if (!provider.requiresCredential) return '不需要 API Key';
    final configured = _configured[provider.id];
    if (configured == null) return '需要 API Key';
    return configured ? '需要 API Key · 已配置' : '需要 API Key · 未配置';
  }

  String _hostOf(String baseUrl) {
    final uri = Uri.tryParse(baseUrl);
    if (uri == null || uri.host.isEmpty) return baseUrl;
    final port = uri.hasPort ? ':${uri.port}' : '';
    return '${uri.scheme}://${uri.host}$port';
  }

  Widget _buildProviderAction(OnlineMusicProviderDefinition provider) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (provider.requiresCredential) ...[
          FilledButton.icon(
            onPressed: () => _openCredentialDialog(provider),
            icon: Icon(
              _configured[provider.id] == true ? Symbols.edit : Symbols.key,
            ),
            label: Text(_configured[provider.id] == true ? '更新' : '配置'),
          ),
          const SizedBox(width: 8),
        ],
        IconButton(
          tooltip: '编辑',
          onPressed: () => _editProvider(provider),
          icon: const Icon(Symbols.edit_note),
        ),
        if (provider.requiresCredential && _configured[provider.id] == true)
          IconButton(
            tooltip: '清除 API Key',
            onPressed: () => _clearCredential(provider),
            icon: const Icon(Symbols.delete),
          ),
        if (_controller.settings.providers.length > 1)
          IconButton(
            tooltip: '删除',
            onPressed: () => _removeProvider(provider),
            icon: const Icon(Symbols.remove_circle),
          ),
      ],
    );
  }

  Widget _buildCredentialStatus() {
    if (!widget.active) return const SizedBox.shrink();
    if (_loading) {
      return const SizedBox(
        width: 24,
        height: 24,
        child: CircularProgressIndicator(
          strokeWidth: 2,
          semanticsLabel: '读取中',
        ),
      );
    }
    if (_error != null) {
      return IconButton(
        tooltip: '重试',
        onPressed: () {
          setState(() {
            _hasLoaded = false;
            _error = null;
          });
          _load();
        },
        icon: const Icon(Symbols.refresh),
      );
    }
    return const SizedBox.shrink();
  }

  @override
  Widget build(BuildContext context) {
    final settings = _controller.settings;
    final providerIds = settings.providers.map((p) => p.id).toList();
    return ListView(
      padding: const EdgeInsets.only(bottom: 96.0, right: 20),
      children: [
        const _SettingsSectionTitle('服务提供商'),
        if (_controller.hasPendingRestart) ...[
          const _SettingsHint('修改将在下次启动时生效'),
          const SizedBox(height: 8),
        ],
        if (_error != null || _loading) ...[
          Row(children: [_buildCredentialStatus()]),
          const SizedBox(height: 8),
        ],
        for (final provider in settings.providers) ...[
          SettingsTile(
            description: provider.id == settings.defaultProviderId
                ? '${provider.id} · 默认'
                : provider.id,
            subtitle:
                '${_hostOf(provider.baseUrl)} · ${_authDescription(provider)}',
            action: _buildProviderAction(provider),
          ),
          const SizedBox(height: 12),
        ],
        SettingsTile(
          description: '添加提供商',
          subtitle: '接自建或第三方在线音乐服务；标识不可与现有条目重复',
          action: FilledButton.icon(
            onPressed: _addProvider,
            icon: const Icon(Symbols.add),
            label: const Text('添加'),
          ),
        ),
        const SizedBox(height: 24),
        const _SettingsSectionTitle('能力分配'),
        for (final capability in OnlineMusicCapability.values) ...[
          SettingsTile(
            description: _capabilityLabel(capability),
            subtitle: '当前使用 ${settings.resolvedProviderIdFor(capability)}',
            action: SegmentedButton<String>(
              showSelectedIcon: false,
              segments: [
                for (final id in providerIds)
                  ButtonSegment(value: id, label: Text(id)),
              ],
              selected: {settings.resolvedProviderIdFor(capability)},
              onSelectionChanged: (selection) => _apply(
                _controller.assignCapability(capability, selection.first),
              ),
            ),
          ),
          const SizedBox(height: 12),
        ],
        const SizedBox(height: 12),
        const _SettingsSectionTitle('默认提供商'),
        SettingsTile(
          description: '默认提供商',
          subtitle: '能力没有单独指定时使用；也是能力分配回落的目标',
          action: SegmentedButton<String>(
            showSelectedIcon: false,
            segments: [
              for (final id in providerIds)
                ButtonSegment(value: id, label: Text(id)),
            ],
            selected: {settings.defaultProviderId},
            onSelectionChanged: (selection) =>
                _apply(_controller.setDefaultProvider(selection.first)),
          ),
        ),
        const SizedBox(height: 24),
        const _SettingsSectionTitle('播放音质'),
        const _DefaultQualityTile(),
      ],
    );
  }
}

String _capabilityLabel(OnlineMusicCapability capability) => switch (capability) {
  OnlineMusicCapability.search => '搜索',
  OnlineMusicCapability.playlist => '歌曲列表',
  OnlineMusicCapability.lyric => '歌词',
  OnlineMusicCapability.stream => '播放解析',
};

/// 设置分块标题：本页有多个设置项，用标题把它们分开。
class _SettingsSectionTitle extends StatelessWidget {
  const _SettingsSectionTitle(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 8),
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

/// 需要重启才生效时的提示行，样式与其他设置项的副标题一致。
class _SettingsHint extends StatelessWidget {
  const _SettingsHint(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 4),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Symbols.info, size: 16, color: scheme.primary),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(color: scheme.primary, fontSize: AppType.body),
          ),
        ],
      ),
    );
  }
}

/// 在线播放的默认音质：新建远程会话时使用（会话内手动切换的档位优先）。
class _DefaultQualityTile extends StatefulWidget {
  const _DefaultQualityTile();

  @override
  State<_DefaultQualityTile> createState() => _DefaultQualityTileState();
}

class _DefaultQualityTileState extends State<_DefaultQualityTile> {
  MusicQuality get _current {
    final level = AppPreference.instance.defaultQuality;
    for (final quality in MusicQuality.values) {
      if (quality.level == level) return quality;
    }
    return MusicQuality.lossless;
  }

  Future<void> _select(MusicQuality quality) async {
    if (quality.level == AppPreference.instance.defaultQuality) return;
    setState(() => AppPreference.instance.defaultQuality = quality.level);
    final saved = await AppPreference.instance.save();
    if (!saved && mounted) {
      showTextOnSnackBar('保存默认音质失败', variant: ToastVariant.error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final current = _current;
    return SettingsTile(
      description: '默认音质',
      subtitle: '在线播放未手动切换时使用；播放中手动选择的档位优先',
      // 与其他多选设置项保持一致（同「顶部歌词切换动画」的 SegmentedButton 写法）。
      action: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: SegmentedButton<MusicQuality>(
              showSelectedIcon: false,
              segments: [
                for (final quality in MusicQuality.values)
                  ButtonSegment(value: quality, label: Text(quality.label)),
              ],
              selected: {current},
              onSelectionChanged: (selection) => _select(selection.first),
            ),
          ),
        ],
      ),
    );
  }
}

/// 新增/编辑提供商对话框的返回值。
final class _ProviderDraft {
  const _ProviderDraft({
    required this.id,
    required this.baseUrl,
    required this.requiresCredential,
  });

  final String id;
  final String baseUrl;
  final bool requiresCredential;
}

class _ProviderDialog extends StatefulWidget {
  const _ProviderDialog({required this.existingIds, this.editing});

  final Set<String> existingIds;
  final OnlineMusicProviderDefinition? editing;

  @override
  State<_ProviderDialog> createState() => _ProviderDialogState();
}

class _ProviderDialogState extends State<_ProviderDialog> {
  late final TextEditingController _idController;
  late final TextEditingController _baseUrlController;
  late bool _requiresCredential;
  String? _idError;
  String? _baseUrlError;

  bool get _isEditing => widget.editing != null;

  @override
  void initState() {
    super.initState();
    final editing = widget.editing;
    _idController = TextEditingController(text: editing?.id ?? '');
    _baseUrlController = TextEditingController(
      text: editing?.baseUrl ?? defaultOnlineMusicBaseUrl,
    );
    _requiresCredential = editing?.requiresCredential ?? true;
  }

  @override
  void dispose() {
    _idController.dispose();
    _baseUrlController.dispose();
    super.dispose();
  }

  void _submit() {
    final id = _isEditing
        ? widget.editing!.id
        : _idController.text.trim();
    final idError = _isEditing
        ? null
        : validateOnlineMusicProviderId(
            id,
            existingIds: widget.existingIds,
          );
    final baseUrl = _baseUrlController.text.trim();
    final baseUrlError = _validateBaseUrl(baseUrl);
    setState(() {
      _idError = idError;
      _baseUrlError = baseUrlError;
    });
    if (idError != null || baseUrlError != null) return;
    Navigator.of(context).pop(
      _ProviderDraft(
        id: id,
        baseUrl: baseUrl,
        requiresCredential: _requiresCredential,
      ),
    );
  }

  String? _validateBaseUrl(String value) {
    if (value.isEmpty) return '请填写服务地址';
    final uri = Uri.tryParse(value);
    if (uri == null) return '服务地址无效';
    if (uri.scheme != 'http' && uri.scheme != 'https') {
      return '服务地址必须以 http:// 或 https:// 开头';
    }
    if (uri.host.isEmpty) return '服务地址缺少主机名';
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(_isEditing ? '编辑提供商 ${widget.editing!.id}' : '添加提供商'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _idController,
              autofocus: !_isEditing,
              enabled: !_isEditing,
              onChanged: (_) => setState(() => _idError = null),
              decoration: InputDecoration(
                labelText: '标识',
                hintText: 'selfdata',
                errorText: _idError,
                helperText: _isEditing ? '标识用于区分条目，创建后不可修改' : null,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _baseUrlController,
              onChanged: (_) => setState(() => _baseUrlError = null),
              decoration: InputDecoration(
                labelText: '服务地址',
                hintText: defaultOnlineMusicBaseUrl,
                errorText: _baseUrlError,
              ),
            ),
            const SizedBox(height: 16),
            SettingsTile(
              description: '认证方式',
              action: SegmentedButton<bool>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment<bool>(value: false, label: Text('不需要 Key')),
                  ButtonSegment<bool>(value: true, label: Text('需要 Key')),
                ],
                selected: {_requiresCredential},
                onSelectionChanged: (selection) =>
                    setState(() => _requiresCredential = selection.first),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(onPressed: _submit, child: const Text('保存')),
      ],
    );
  }
}

class _ProviderApiKeyDialog extends StatefulWidget {
  const _ProviderApiKeyDialog({
    required this.providerId,
    required this.controller,
    required this.onSaved,
  });

  final String providerId;
  final OnlineMusicProviderSettingsController controller;
  final Future<void> Function() onSaved;

  @override
  State<_ProviderApiKeyDialog> createState() => _ProviderApiKeyDialogState();
}

class _ProviderApiKeyDialogState extends State<_ProviderApiKeyDialog> {
  final _controller = TextEditingController();
  bool _obscureText = true;
  bool _saving = false;
  String? _saveError;

  OnlineMusicProviderDefinition get _provider =>
      widget.controller.settings.providerById(widget.providerId)!;

  bool get _isValid =>
      widget.controller.isCredentialFormatValid(_controller.text);

  String? get _formatError {
    if (_controller.text.isEmpty || _isValid) return null;
    return 'API Key 格式无效';
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_isValid || _saving) return;
    setState(() {
      _saving = true;
      _saveError = null;
    });
    try {
      await widget.controller.saveCredential(_provider, _controller.text);
      await widget.onSaved();
      if (mounted) Navigator.of(context).pop();
    } on OnlineMusicCredentialException catch (error) {
      if (mounted) setState(() => _saveError = error.safeMessage);
    } on FormatException {
      if (mounted) setState(() => _saveError = 'API Key 格式无效');
    } catch (_) {
      if (mounted) {
        setState(
          () => _saveError =
              '无法保存 ${widget.providerId} 的 '
              '${widget.controller.credentialDisplayName}',
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final errorText = _saveError ?? _formatError;
    return AlertDialog(
      title: Text(
        '配置 ${widget.providerId} 的 '
        '${widget.controller.credentialDisplayName}',
      ),
      content: SizedBox(
        width: 420,
        child: TextField(
          controller: _controller,
          autofocus: true,
          enabled: !_saving,
          obscureText: _obscureText,
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => _submit(),
          onChanged: (_) {
            setState(() => _saveError = null);
          },
          decoration: InputDecoration(
            labelText: widget.controller.credentialDisplayName,
            hintText: widget.controller.credentialHint,
            errorText: errorText,
            suffixIcon: IconButton(
              tooltip: _obscureText ? '显示 API Key' : '隐藏 API Key',
              onPressed: _saving
                  ? null
                  : () => setState(() => _obscureText = !_obscureText),
              icon: Icon(
                _obscureText ? Symbols.visibility : Symbols.visibility_off,
              ),
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _isValid && !_saving ? _submit : null,
          child: Text(_saving ? '保存中' : '保存'),
        ),
      ],
    );
  }
}
