import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';
import 'package:pure_music/component/danger_confirm_dialog.dart';
import 'package:pure_music/component/settings_tile.dart';
import 'package:pure_music/core/design_tokens.dart';
import 'package:pure_music/core/hotkeys.dart';
import 'package:pure_music/core/preference.dart';
import 'package:pure_music/core/utils.dart';
import 'package:pure_music/page/settings_page/online_music_capability_editor.dart';
import 'package:pure_music/services/music_platform/index.dart';
import 'package:pure_music/services/music_platform/provider/online_music_binding.dart';
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

  /// 迁移正在进行（防止按钮重入）。
  String? _error;

  /// 当前**运行中**的能力集合（D3b:a）：平台卡据此解释"为什么这个平台不能搜"。
  ///
  /// 它来自启动时装配的 service，反映的是 `activeSettings`；用户刚改的配置要重启后
  /// 才会体现在这里，因此卡片上的开关另有"下次启动生效"的提示。
  OnlineMusicCapabilities? _capabilities;

  @override
  void initState() {
    super.initState();
    _controller = context.read<OnlineMusicProviderSettingsController>();
    _controller.addListener(_onSettingsChanged);
    if (widget.active) _load();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _capabilities = context.read<OnlineMusicService>().capabilities;
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
      builder: (context) =>
          _ProviderDialog(existingIds: _controller.providerIds),
    );
    if (result == null || !mounted) return;
    final definition = OnlineMusicProviderDefinition.custom(
      id: result.id,
      baseUrl: result.baseUrl,
      requiresCredential: result.requiresCredential,
      displayName: result.displayName,
      contentPlatform: result.contentPlatform,
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
      contentPlatform: result.contentPlatform,
      displayName: result.displayName,
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
      title: '删除提供商 ${provider.label}？',
      message:
          '指向它的能力分配与默认提供商都会回落到列表中的第一个条目。'
          '已保存的 API Key 不会被删除。',
      confirmLabel: '删除',
    );
    if (!confirmed || !mounted) return;
    await _apply(_controller.removeProvider(provider.id));
    if (mounted) setState(() => _configured.remove(provider.id));
  }

  /// 能力列表：四个能力各自的状态，以及一键按 ChkSz 兼容方式填充。
  Future<void> _openCapabilities(OnlineMusicProviderDefinition provider) async {
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => OnlineMusicCapabilitiesDialog(
        definition: provider,
        onEditCapability: (capability) {
          Navigator.of(dialogContext).pop();
          _openCapabilityEditor(provider, capability);
        },
        onFillChkszCompatible: () {
          Navigator.of(dialogContext).pop();
          _fillChkszCompatible(provider);
        },
      ),
    );
  }

  /// 「一键按 ChkSz 兼容方式填充」（P-20）。
  ///
  /// 两件事必须同时做到：
  /// 1. **动手前确认**，并在确认框里逐项说清"哪几个会被覆盖、哪几个保持不变"
  ///    （旧实现直接改配置：无确认、无撤销）；
  /// 2. 填充是**合并**（见 `withChkszCompatibleCapabilities`），
  ///    不再把用户已经配好的其它能力整表丢掉。
  Future<void> _fillChkszCompatible(
    OnlineMusicProviderDefinition provider,
  ) async {
    final overwrites = provider.chkszFillOverwrites();
    final keeps = provider.chkszFillKeeps();
    final confirmed = await showDangerConfirmDialog(
      context: context,
      title: '按 ChkSz 兼容方式填充？',
      message:
          '会把「${_capabilityNames(overwrites)}」改成内置 ChkSz 实现'
          '（这四项当前的配置会被覆盖）。'
          '${keeps.isEmpty ? '' : '其它已配置的能力（${_capabilityNames(keeps)}）保持不变。'}'
          '改动在重启后生效。',
      confirmLabel: '填充',
    );
    if (!confirmed || !mounted) return;
    final saved = await _apply(
      _controller.updateProvider(provider.withChkszCompatibleCapabilities()),
    );
    if (saved && mounted) showTextOnSnackBar('已按 ChkSz 兼容方式填充；重启后生效');
  }

  String _capabilityNames(List<OnlineMusicCapability> capabilities) =>
      capabilities.map(onlineMusicCapabilityLabel).join('、');

  Future<void> _openCapabilityEditor(
    OnlineMusicProviderDefinition provider,
    OnlineMusicCapability capability,
  ) async {
    final result = await showDialog<OnlineMusicCapabilityBinding>(
      context: context,
      builder: (dialogContext) => OnlineMusicCapabilityEditorDialog(
        definition: provider,
        capability: capability,
        initialBinding: provider.bindingFor(capability),
        // F3-2b：探测**先出计划**（候选 / 输入 / 凭据需求），用户确认并改完输入后才真正发请求。
        onProbePlan: () => _controller.probePlanFor(provider),
        onProbe: (inputs) => _controller.probeSearch(provider, inputs: inputs),
        onTest: (binding, inputs) => _controller.testCapability(
          provider.withCapabilityBinding(capability, binding),
          capability,
          // P-49：把用户填的真实输入原样送进去；没填的用控制器的既有默认值。
          keyword: inputs.keyword,
          limit: inputs.limit,
          trackId: inputs.trackId,
          playlistId: inputs.playlistId,
          artistId: inputs.artistId,
          albumId: inputs.albumId,
        ),
        // F0-4：敏感请求头的凭据按**槽位名**读写，与条目级 API Key 同一个出口。
        onIsCredentialConfigured: _controller.isReferencedCredentialConfigured,
        onSaveCredential: _controller.saveReferencedCredential,
      ),
    );
    if (result == null || !mounted) return;
    final saved = await _apply(
      _controller.updateProvider(
        provider.withCapabilityBinding(capability, result),
      ),
    );
    if (saved && mounted) showTextOnSnackBar('能力配置已保存；重启后生效');
  }

  /// F0-5：明文敏感请求头的迁移入口。
  ///
  /// **先只报告识别结果**，用户明确放行后才执行 —— 也就是说，
  /// "改动用户配置"这件事永远发生在一次明确的点击之后（Spec §4.1/§4.2）。

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

  Future<void> _clearCredential(OnlineMusicProviderDefinition provider) async {
    final confirmed = await showDangerConfirmDialog(
      context: context,
      title: '清除 ${provider.label} 的 ${_controller.credentialDisplayName}？',
      message: _controller.isPortableBuild
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
    // 状态未知时给一个长度接近的稳定占位，避免加载完成前后文字剧烈变化。
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
    // SettingsTile 在非紧凑宽度下不会替 action 做滚动，条目操作按钮较多时
    // 需要自己提供横向滚动，避免溢出。
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      reverse: true,
      child: Row(
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
            tooltip: '能力配置',
            onPressed: () => _openCapabilities(provider),
            icon: const Icon(Symbols.tune),
          ),
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
      ),
    );
  }

  /// 凭据读取**静默进行**，不为"读取中"做任何占位。
  ///
  /// 上一轮验收反馈：固定高度的空占位只留下一条没有意义的空白间距，而
  /// 「正在读取凭据状态…」又只是闪一下，反而更吵。所以这里只在**真的失败**时
  /// 才出现提示与重试；成功路径下这一块完全不占高度。
  Widget _buildLoadErrorRow() {
    final error = _error;
    if (error == null) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8.0),
      child: Row(
        children: [
          Icon(Symbols.error, size: 16.0, color: scheme.error),
          const SizedBox(width: 8.0),
          Expanded(
            child: Text(
              error,
              style: TextStyle(color: scheme.error, fontSize: AppType.body),
            ),
          ),
          IconButton(
            tooltip: '重试',
            onPressed: () {
              setState(() {
                _hasLoaded = false;
                _error = null;
              });
              _load();
            },
            icon: const Icon(Symbols.refresh),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final settings = _controller.settings;
    return ListView(
      padding: const EdgeInsets.only(bottom: Spacing.bottomNav, right: 20),
      children: [
        const _SettingsSectionTitle('服务提供商'),
        if (_controller.hasPendingRestart) ...[
          const _SettingsHint('修改将在下次启动时生效'),
          const SizedBox(height: 8),
        ],
        if (_controller.isPortableBuild) ...[
          const _SettingsHint('便携版：API Key 只在本次运行内有效，重启后需要重新配置'),
          const SizedBox(height: 8),
        ],
        _buildLoadErrorRow(),
        for (final provider in settings.providers) ...[
          SettingsTile(
            // W8：不再标「· 默认」—— D14 之后 defaultProvider 不参与任何路由，
            // 留着这个标记只会让用户以为它还在决定什么（字段本身仍兼容可读）。
            description: provider.label,
            subtitle:
                '${_hostOf(provider.effectiveBaseUrl)} · '
                // P-64：内容来源也用中文平台名（以前这里露英文枚举名）。
                '${musicPlatformLabel(provider.contentPlatform)} · '
                '${_authDescription(provider)}',
            action: _buildProviderAction(provider),
          ),
          // P-32：这个条目有**配置问题**（能力 JSON 损坏 / 服务地址非法 / 标识非法）时
          // 如实列出来。以前"能力配置写坏了"会被静默当成"这个能力就是不支持"，
          // 用户完全看不出是自己的配置坏了 —— 与"从未配置"长得一模一样。
          if (provider.validationIssues().isNotEmpty) ...[
            const SizedBox(height: 4),
            _SettingsHint('配置问题：${provider.validationIssues().join('；')}'),
          ],
          // P-04：**逐条目**的"未生效"标记（以前只有页面顶部一句全局提示，
          // 用户看不出到底是哪一项改了还没生效）。
          if (_controller.providerNeedsRestart(provider.id)) ...[
            const SizedBox(height: 4),
            const _SettingsHint('未生效：这个条目的改动要重启后才进入运行时'),
          ],
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
        // P-14：**设置级**的旧旋钮提示（旧的能力分配 / 默认提供商仍在这份配置里）。
        // 它们不在单个条目上，因此单独列在这里 —— 以前它们在界面上完全看不到。
        for (final issue in settings.legacyKnobIssues()) _SettingsHint(issue),
        if (settings.legacyKnobIssues().isNotEmpty) const SizedBox(height: 12),
        const SizedBox(height: 24),
        const _SettingsSectionTitle('提供商配置'),
        if (_controller.hasPendingRestart)
          const _SettingsHint('平台与能力的改动将在下次启动时生效'),
        for (final platform in builtinMusicPlatforms) ...[
          _PlatformCard(
            platform: platform,
            settings: settings,
            enabled: settings.isPlatformEnabled(platform),
            // 空集 = 全部启用；不允许把最后一个启用的平台关掉（否则"全部停用"会退化成
            // "全部启用"，见 `OnlineMusicSettings.enabledPlatforms` 的约定）。
            canToggle:
                !settings.isPlatformEnabled(platform) ||
                _enabledPlatformCount(settings) > 1,
            unavailableReason: _capabilities?.unavailableSearchReasonFor(
              platform,
            ),
            // P-37：两个事实源各自标注来源。运行中的 service 是否**仍在服务**这个平台
            // （从它的能力集合推导），用来回答"配置里停用了、但运行中其实还能用"。
            runtimeServesPlatform: _runtimeServesPlatform(
              _capabilities,
              platform,
            ),
            needsRestart: _controller.platformNeedsRestart(platform),
            capabilityNeedsRestart: (capability) =>
                _controller.capabilityNeedsRestart(platform, capability),
            onEnabledChanged: (value) => _apply(
              _controller.setPlatformEnabled(platform, enabled: value),
            ),
            onCapabilityChanged: (capability, providerId) => _apply(
              _controller.assignPlatformCapability(
                platform,
                capability,
                providerId,
              ),
            ),
          ),
          const SizedBox(height: 12),
        ],
        const SizedBox(height: 24),
        const _SettingsSectionTitle('播放音质'),
        const _DefaultQualityTile(),
      ],
    );
  }
}


int _enabledPlatformCount(OnlineMusicSettings settings) =>
    builtinMusicPlatforms.where(settings.isPlatformEnabled).length;

/// 能力文案与能力编辑器共用 [onlineMusicCapabilityLabel]，避免两处走偏。
String _capabilityLabel(OnlineMusicCapability capability) =>
    onlineMusicCapabilityLabel(capability);

/// 选择"自动"时使用的哨兵值。
///
/// 真实 Provider 标识不可能为空（创建时校验非空），因此不会与条目冲突；
/// 选它等价于清除该 `(platform, capability)` 的显式候选（D17:b 之后，
/// "显式指定过"意味着隐式条目不再救场，所以必须给用户一条回到"自动"的路）。
const _autoProviderValue = '';

/// 一个平台一张卡（D8:A）：卡头 = 平台名 + 启用开关 + 不可用原因；
/// 卡内每个能力一行，选择该平台下支持该能力的 Provider。
class _PlatformCard extends StatelessWidget {
  const _PlatformCard({
    required this.platform,
    required this.settings,
    required this.enabled,
    required this.canToggle,
    required this.unavailableReason,
    required this.runtimeServesPlatform,
    required this.needsRestart,
    required this.capabilityNeedsRestart,
    required this.onEnabledChanged,
    required this.onCapabilityChanged,
  });

  final MusicPlatform platform;
  final OnlineMusicSettings settings;
  final bool enabled;

  /// 是否允许切换启用状态（最后一个启用的平台不允许关掉）。
  final bool canToggle;

  /// 运行中的 service 给出的"为什么不能搜"；停用或未涉及时为 null。
  final String? unavailableReason;

  /// 运行中的 service 是否**仍在**这个平台提供服务（P-37）。
  ///
  /// 用来识别"配置里已停用、但运行中其实还能用"这种状态：
  /// 两边都要说出来，而不是让展示优先级吃掉其中一个。
  final bool runtimeServesPlatform;

  /// 该平台是否有尚未生效的改动（P-04）。
  final bool needsRestart;

  /// 该能力的候选来源是否有尚未生效的改动（P-04）。
  final bool Function(OnlineMusicCapability capability) capabilityNeedsRestart;

  final ValueChanged<bool> onEnabledChanged;
  final void Function(OnlineMusicCapability capability, String? providerId)
  onCapabilityChanged;

  /// P-37：卡上的状态行，**每条都标注事实来源**。
  ///
  /// 以前这里只显示一句、且用优先级把另一个事实吃掉（运行中原因优先，其次才是
  /// "已停用"）—— 用户看到"已停用"就以为运行中也停了，反之亦然。
  /// 现在：运行中的事实带「运行中：」前缀；配置态用「已停用」（配合卡片级的
  /// "未生效"提示说明它要下次启动才生效）。
  List<String> get _statusLines {
    final lines = <String>[];
    final reason = unavailableReason;
    if (reason != null && reason.isNotEmpty) {
      lines.add('运行中：$reason');
    } else if (!enabled && runtimeServesPlatform) {
      // 配置说停用、运行中却仍能服务 ⇒ 明说这是"下次启动才生效"，不冒充。
      lines.add('运行中：仍可用（停用要下次启动才生效）');
    }
    if (!enabled) lines.add('已停用');
    return lines;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final statusLines = _statusLines;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 8, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        musicPlatformLabel(platform),
                        style: const TextStyle(
                          fontSize: AppType.body,
                          fontWeight: AppType.weightSemibold,
                        ),
                      ),
                      for (final line in statusLines)
                        Text(
                          line,
                          style: TextStyle(
                            fontSize: AppType.caption,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                    ],
                  ),
                ),
                Tooltip(
                  message: canToggle ? '启用 / 停用该平台' : '至少保留一个启用的平台',
                  child: Switch(
                    value: enabled,
                    onChanged: canToggle
                        ? (value) => onEnabledChanged(value)
                        : null,
                  ),
                ),
              ],
            ),
            // P-04：平台级"未生效"标记（启用状态或任一能力来源有改动）。
            if (needsRestart)
              const Padding(
                padding: EdgeInsets.only(top: 4.0),
                child: _SettingsHint('该平台的改动尚未生效（下次启动）'),
              ),
            for (final capability in OnlineMusicCapability.values)
              _buildCapabilityRow(context, capability),
          ],
        ),
      ),
    );
  }

  Widget _buildCapabilityRow(
    BuildContext context,
    OnlineMusicCapability capability,
  ) {
    final candidates = settings.capableProviderIdsFor(platform, capability);
    // P-04：**逐能力**的"未生效"标记。
    final pending = capabilityNeedsRestart(capability);
    if (candidates.isEmpty) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SettingsTile(
            description: _capabilityLabel(capability),
            subtitle: '未配置：该平台下没有支持此能力的条目',
            action: const Text('未配置'),
          ),
          if (pending) const _SettingsHint('这里的改动尚未生效（下次启动）'),
        ],
      );
    }
    final selected = settings.selectedProviderIdFor(platform, capability);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsTile(
          description: _capabilityLabel(capability),
          subtitle: selected == null
              ? '自动：按条目顺序使用 ${candidates.first}'
              : '已指定 $selected',
          action: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: SegmentedButton<String>(
              showSelectedIcon: false,
              segments: [
                const ButtonSegment(
                  value: _autoProviderValue,
                  label: Text('自动'),
                ),
                for (final id in candidates)
                  ButtonSegment(value: id, label: Text(id)),
              ],
              selected: {selected ?? _autoProviderValue},
              onSelectionChanged: (selection) {
                final value = selection.first;
                onCapabilityChanged(
                  capability,
                  value == _autoProviderValue ? null : value,
                );
              },
            ),
          ),
        ),
        if (pending) const _SettingsHint('这里的改动尚未生效（下次启动）'),
      ],
    );
  }
}

/// 运行中的能力集合是否**仍在这个平台提供服务**（P-37 的"配置停用但运行中可用"）。
bool _runtimeServesPlatform(
  OnlineMusicCapabilities? capabilities,
  MusicPlatform platform,
) {
  if (capabilities == null) return false;
  return capabilities.searchablePlatforms.contains(platform) ||
      capabilities.resolvablePlatforms.contains(platform) ||
      capabilities.playlistPlatforms.contains(platform) ||
      capabilities.playlistCollectionPlatforms.contains(platform) ||
      capabilities.playlistCategoryPlatforms.contains(platform) ||
      capabilities.chartPlatforms.contains(platform) ||
      capabilities.newSongPlatforms.contains(platform) ||
      capabilities.lyricPlatforms.contains(platform);
}

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
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Symbols.info, size: 16, color: scheme.primary),
          const SizedBox(width: 6),
          // 文本必须能换行：提示文案长短不一（P-04 的逐项"未生效"标记、
          // P-32 的配置问题列表都可能很长），而 Row 里的裸 Text 不会自动换行 ——
          // 这曾让长提示直接把整行撑出屏幕。
          Expanded(
            child: Text(
              label,
              style: TextStyle(color: scheme.primary, fontSize: AppType.body),
            ),
          ),
        ],
      ),
    );
  }
}

/// 在线播放的默认音质**偏好级别**（新建远程会话时使用；会话内手动切换优先）。
///
/// Spec §7.3（W7）：这里选的是**内部偏好级别**（跨平台语义），不是某个平台的档位名；
/// 各平台实际会用哪一档由各平台的档位声明换算，因此下面同时给出**只读**的映射说明。
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

  /// "各平台对应档位"的只读映射：只列**有档位声明**的平台，用平台自己的文案。
  ///
  /// 没有档位声明的平台（自建声明式 Provider）不列：它的 `quality` 取值由用户自己
  /// 的接口决定，我们无从推断，硬编一个映射只会误导（补充口径④）。
  List<String> _platformMappings(BuildContext context) {
    final service = context.watch<OnlineMusicService?>();
    if (service == null) return const [];
    final mappings = <String>[];
    for (final platform in builtinMusicPlatforms) {
      final tiers = service.qualityTiersFor(platform);
      if (tiers.isEmpty) continue;
      final labels = tiers.map((tier) => tier.displayLabel).join(' / ');
      mappings.add('${musicPlatformLabel(platform)}：$labels');
    }
    return mappings;
  }

  @override
  Widget build(BuildContext context) {
    final current = _current;
    final mappings = _platformMappings(context);
    final subtitle = StringBuffer('在线播放未手动切换时使用；播放中手动选择的档位优先。');
    if (mappings.isNotEmpty) {
      subtitle.write('\n各平台对应档位（只读）：${mappings.join('；')}');
    }
    return SettingsTile(
      description: '偏好级别',
      subtitle: subtitle.toString(),
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
    this.displayName = '',
    this.contentPlatform = MusicPlatform.netease,
  });

  final String id;
  final String baseUrl;
  final bool requiresCredential;
  final String displayName;
  final MusicPlatform contentPlatform;
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
  late final TextEditingController _displayNameController;
  late bool _requiresCredential;
  late MusicPlatform _contentPlatform;
  String? _idError;
  String? _baseUrlError;

  bool get _isEditing => widget.editing != null;

  @override
  void initState() {
    super.initState();
    final editing = widget.editing;
    _idController = TextEditingController(text: editing?.id ?? '');
    _baseUrlController = TextEditingController(
      // 配置里没有这一项时显示**实际生效**的默认地址（它是可编辑的原值，
      // 用户看到的就是运行时真正会用的地址）。
      text: editing?.effectiveBaseUrl ?? defaultOnlineMusicBaseUrl,
    );
    _displayNameController = TextEditingController(
      text: editing?.displayName ?? '',
    );
    _requiresCredential = editing?.requiresCredential ?? true;
    _contentPlatform = editing?.contentPlatform ?? MusicPlatform.netease;
  }

  @override
  void dispose() {
    _idController.dispose();
    _baseUrlController.dispose();
    _displayNameController.dispose();
    super.dispose();
  }

  void _submit() {
    final id = _isEditing ? widget.editing!.id : _idController.text.trim();
    final idError = _isEditing
        ? null
        : validateOnlineMusicProviderId(id, existingIds: widget.existingIds);
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
        displayName: _displayNameController.text.trim(),
        contentPlatform: _contentPlatform,
      ),
    );
  }

  String? _validateBaseUrl(String value) {
    if (value.trim().isEmpty) return '请填写服务地址';
    // 非空值的判据只有一份（`onlineMusicBaseUrlIssue`），避免界面与模型各说一套。
    return onlineMusicBaseUrlIssue(value);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      // P-64：用户可见文案统一用**展示名**（label 优先 displayName），与列表里的称呼一致。
      title: Text(_isEditing ? '编辑提供商 ${widget.editing!.label}' : '添加提供商'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Focus(
              onFocusChange: HotkeysHelper.onFocusChanges,
              child: TextField(
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
            ),
            const SizedBox(height: 12),
            Focus(
              onFocusChange: HotkeysHelper.onFocusChanges,
              child: TextField(
                controller: _baseUrlController,
                onChanged: (_) => setState(() => _baseUrlError = null),
                decoration: InputDecoration(
                  labelText: '服务地址',
                  hintText: defaultOnlineMusicBaseUrl,
                  errorText: _baseUrlError,
                ),
              ),
            ),
            const SizedBox(height: 12),
            Focus(
              onFocusChange: HotkeysHelper.onFocusChanges,
              child: TextField(
                controller: _displayNameController,
                decoration: const InputDecoration(
                  labelText: '显示名（可选）',
                  hintText: '留空则显示标识',
                ),
              ),
            ),
            const SizedBox(height: 16),
            SettingsTile(
              description: '内容来源',
              // D8b:b：平台已参与来源语义，改平台会让已有内容与 Provider 语义不一致，
              // 所以创建后只读；需要别的平台请新建条目。
              subtitle: _isEditing
                  ? '创建后不可修改；需要其它平台请新建条目'
                  : '该服务代理哪一家的内容；非网易云来源属于当前模型边界',
              action: SegmentedButton<MusicPlatform>(
                showSelectedIcon: false,
                segments: [
                  for (final platform in builtinMusicPlatforms)
                    ButtonSegment(
                      value: platform,
                      // P-64：这里以前直接显示英文枚举名（netease/qq/kugou），
                      // 而平台卡用的是 `musicPlatformLabel`。同一个平台两种称呼 ⇒ 统一成中文。
                      label: Text(musicPlatformLabel(platform)),
                    ),
                ],
                selected: {_contentPlatform},
                onSelectionChanged: _isEditing
                    ? null
                    : (selection) =>
                          setState(() => _contentPlatform = selection.first),
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
        child: Focus(
          onFocusChange: HotkeysHelper.onFocusChanges,
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
