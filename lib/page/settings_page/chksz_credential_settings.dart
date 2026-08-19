import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';
import 'package:pure_music/component/danger_confirm_dialog.dart';
import 'package:pure_music/component/settings_tile.dart';
import 'package:pure_music/core/settings.dart';
import 'package:pure_music/services/music_platform/index.dart';

class ChkszCredentialSettings extends StatefulWidget {
  const ChkszCredentialSettings({super.key, required this.active});

  final bool active;

  @override
  State<ChkszCredentialSettings> createState() =>
      _ChkszCredentialSettingsState();
}

class _ChkszCredentialSettingsState extends State<ChkszCredentialSettings> {
  late final OnlineMusicCredentialController _credentials;
  bool _hasLoaded = false;
  bool _loading = false;
  bool _configured = false;
  String? _error;
  String? _busyLabel;

  bool get _isBusy => _loading || _busyLabel != null;

  @override
  void initState() {
    super.initState();
    _credentials = context.read<OnlineMusicCredentialController>();
    if (widget.active) _load();
  }

  @override
  void didUpdateWidget(covariant ChkszCredentialSettings oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!oldWidget.active && widget.active && !_hasLoaded) _load();
  }

  Future<void> _load() async {
    if (_loading || _hasLoaded) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final configured = await _credentials.isConfigured();
      if (!mounted) return;
      setState(() {
        _configured = configured;
        _hasLoaded = true;
        _loading = false;
      });
    } on OnlineMusicCredentialException catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error.safeMessage;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = '无法读取 $_providerName $_credentialName';
        _loading = false;
      });
    }
  }

  Future<void> _openEditor() async {
    if (_isBusy) return;
    await showDialog<void>(
      context: context,
      builder: (context) => _ChkszApiKeyDialog(
        credentials: _credentials,
        onSave: _saveApiKey,
      ),
    );
  }

  String get _providerName => _credentials.providerDisplayName;
  String get _credentialName => _credentials.credentialDisplayName;

  Future<void> _saveApiKey(String apiKey) async {
    await _credentials.saveCredential(apiKey);
    if (!mounted) return;
    setState(() {
      _configured = true;
      _hasLoaded = true;
      _error = null;
    });
  }

  Future<void> _clearApiKey() async {
    if (_isBusy) return;
    final confirmed = await showDangerConfirmDialog(
      context: context,
      title: '清除 $_providerName $_credentialName？',
      message: portableBuild
          ? '这会清除本次运行中的 API Key，关闭应用后也不会保留。'
          : '这会删除当前 Windows 用户凭据中的 API Key。',
      confirmLabel: '清除',
    );
    if (!confirmed || !mounted) return;

    setState(() {
      _busyLabel = '清除中';
      _error = null;
    });
    try {
      await _credentials.clearCredential();
      if (!mounted) return;
      setState(() {
        _configured = false;
        _hasLoaded = true;
      });
    } on OnlineMusicCredentialException catch (error) {
      if (mounted) setState(() => _error = error.safeMessage);
    } catch (_) {
      if (mounted) {
        setState(() => _error = '无法清除 $_providerName $_credentialName');
      }
    } finally {
      if (mounted) setState(() => _busyLabel = null);
    }
  }

  String get _modeDescription =>
      portableBuild ? '仅本次运行有效，关闭应用后清除' : '保存在当前 Windows 用户凭据中';

  String get _statusDescription {
    if (!_hasLoaded && !_loading && !widget.active) return '打开页签后读取';
    if (_loading) return '读取中';
    if (_error != null) return _error!;
    return _configured ? '已配置' : '未配置';
  }

  Widget _buildAction() {
    if (!widget.active) return const SizedBox.shrink();
    if (_loading || _busyLabel != null) {
      return SizedBox(
        width: 24,
        height: 24,
        child: CircularProgressIndicator(
          strokeWidth: 2,
          semanticsLabel: _busyLabel ?? '读取中',
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
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        FilledButton.icon(
          onPressed: _openEditor,
          icon: Icon(_configured ? Symbols.edit : Symbols.key),
          label: Text(_configured ? '更新' : '配置'),
        ),
        if (_configured) ...[
          const SizedBox(width: 8),
          IconButton(
            tooltip: '清除 API Key',
            onPressed: _clearApiKey,
            icon: const Icon(Symbols.delete),
          ),
        ],
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsTile(
          description: '$_providerName $_credentialName',
          subtitle: '$_statusDescription · $_modeDescription · 仅在发起在线请求时发送',
          action: _buildAction(),
        ),
      ],
    );
  }
}

class _ChkszApiKeyDialog extends StatefulWidget {
  const _ChkszApiKeyDialog({required this.credentials, required this.onSave});

  final OnlineMusicCredentialController credentials;
  final Future<void> Function(String apiKey) onSave;

  @override
  State<_ChkszApiKeyDialog> createState() => _ChkszApiKeyDialogState();
}

class _ChkszApiKeyDialogState extends State<_ChkszApiKeyDialog> {
  final _controller = TextEditingController();
  bool _obscureText = true;
  bool _saving = false;
  String? _saveError;

  bool get _isValid => widget.credentials.isCredentialFormatValid(_controller.text);

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
      await widget.onSave(_controller.text);
      if (mounted) Navigator.of(context).pop();
    } on OnlineMusicCredentialException catch (error) {
      if (mounted) setState(() => _saveError = error.safeMessage);
    } on FormatException {
      if (mounted) setState(() => _saveError = 'API Key 格式无效');
    } catch (_) {
      if (mounted) {
        setState(
          () => _saveError =
              '无法保存 ${widget.credentials.providerDisplayName} '
              '${widget.credentials.credentialDisplayName}',
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
        '配置 ${widget.credentials.providerDisplayName} '
        '${widget.credentials.credentialDisplayName}',
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
            labelText: 'API Key',
            hintText: widget.credentials.inputHint,
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
