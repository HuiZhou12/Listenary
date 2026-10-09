/// 旧配置的**明文敏感请求头**安全迁移（F0 / Spec §2 §3 §4 §11.3）。
///
/// 这段代码只做四件事，且顺序被刻意固定：
/// 1. **只识别**：把每个请求头判成 `sensitive` / `needs-user` / `plain` 三态之一，
///    产出只含**名称、槽位与判定**的报告（绝不含值）；
/// 2. **写凭据**：逐项写进系统凭据管理器；
/// 3. **立即回读逐字节校验**；
/// 4. 全部成功**才**改写配置，改写后重新解析校验，并确认明文已移除。
///
/// 硬约束（逐条对应 Spec / 用户裁定）：
/// - 顺序**永不**颠倒（绝不"先删明文再写凭据"）；
/// - 任一步失败 ⇒ **整条 entry 回滚**（删掉本次新建的槽位、配置不变）⇒ 不留半迁移；
/// - **回滚失败 ⇒ 停止整个迁移并报告**，不得继续处理其它 entry 掩盖问题；
/// - 写槽位前**必须检查冲突**：不存在⇒新建；内容完全相同⇒幂等重放；内容不同或
///   **无法可靠确认**⇒停止且**不得覆盖**（`CredWrite` 是"存在即覆盖"语义）；
/// - 不同槽位之间**不得**因明文值相同而自动合并（共享只能靠显式引用）；
/// - `needs-user` 项**永不自动迁移**；
/// - portable 模式**跳过**迁移：原配置逐字节不变、不写内存槽位、**不报成功**。
library;

import 'dart:convert';

import 'package:pure_music/services/music_platform/provider/online_music_binding.dart';
import 'package:pure_music/services/music_platform/provider/online_music_capability.dart';
import 'package:pure_music/services/music_platform/provider/online_music_header_slot.dart';
import 'package:pure_music/services/music_platform/provider/online_music_provider_credentials.dart';
import 'package:pure_music/services/music_platform/provider/online_music_provider_settings.dart';
import 'package:pure_music/services/music_platform/provider/online_music_provider_settings_controller.dart';
import 'package:pure_music/services/music_platform/provider/online_music_request_spec.dart';

/// 一个请求头的判定（Spec §2 的三态闭合；每条都必须落到其中一态）。
enum OnlineMusicHeaderDisposition {
  /// 名称命中规则 A，或被显式标记（规则 B）⇒ 进入迁移流程。
  sensitive,

  /// 名称未命中、但**值形态可疑** ⇒ 只生成"待确认"候选，**不迁移**。
  needsUser,

  /// 名称未命中且不可疑 ⇒ 保留明文（无害），不被迁移改写。
  plain,
}

/// 规则 A 的名单（Spec §2），按归一化后比较（大小写/连字符/下划线不敏感）。
///
/// 刻意**不含**裸 `key` / `auth`：这两个词太常见（`X-Key: 1` 之类），
/// 自动迁移宁可少认几个，也不要误搬无害请求头 ——
/// 漏掉的由规则 C（用户在编辑器里手动勾"敏感"）兜底。
const sensitiveHeaderSlotSegments = {
  'cookie',
  'set-cookie',
  'authorization',
  'proxy-authorization',
  'x-api-key',
  'api-key',
  'apikey',
  'appkey',
  'app-key',
  'appsecret',
  'app-secret',
  'x-token',
  'token',
  'access-token',
  'refresh-token',
  'id-token',
  'session',
  'sessionid',
  'jwt',
  'sign',
  'signature',
  'x-signature',
  'x-sign',
  'qskey',
  'pskey',
  'qm-keyst',
  'credential',
  'password',
  'passwd',
};

/// 名称是否命中规则 A。
bool isSensitiveHeaderName(String headerName) =>
    sensitiveHeaderSlotSegments.contains(
      normalizeOnlineMusicHeaderSlotSegment(headerName),
    );

/// 值形态是否**可疑**（Spec §2 C）。
///
/// ⚠️ 这**只能**用来生成"待用户确认"的候选清单，**绝不能**当作自动迁移依据
/// （Spec §2「禁止」条）。判据刻意保守：
/// - 长度 ≥ 16：任何形态都算可疑（Key / UUID / Cookie 常见长度）；
/// - 长度 ≥ 8 且**无空白**、字符集受限、且**同时含字母与数字**：
///   像 Key / 摘要，但排除了 `listenary` 这类普通词。
bool looksLikeSensitiveHeaderValue(String value) {
  final trimmed = value.trim();
  if (trimmed.length >= 16) return true;
  if (trimmed.length < 8) return false;
  if (RegExp(r'\s').hasMatch(trimmed)) return false;
  if (!RegExp(r'^[A-Za-z0-9+/=_.~-]+$').hasMatch(trimmed)) return false;
  final hasLetter = RegExp('[A-Za-z]').hasMatch(trimmed);
  final hasDigit = RegExp('[0-9]').hasMatch(trimmed);
  return hasLetter && hasDigit;
}

/// 一条识别结果。**只含名称/槽位/判定，不含任何值。**
final class OnlineMusicHeaderFinding {
  const OnlineMusicHeaderFinding({
    required this.providerId,
    required this.capability,
    required this.headerName,
    required this.disposition,
    this.slot,
    this.actionable = false,
  });

  final String providerId;
  final OnlineMusicCapability capability;
  final String headerName;
  final OnlineMusicHeaderDisposition disposition;

  /// 仅当 [disposition] 为 `sensitive` 时有值。
  final String? slot;

  /// 这一项**这次真的会被迁移**（已标记敏感、还没有引用、且值非空）。
  ///
  /// 不是所有 `sensitive` 项都会被搬：**已带引用**的（迁移过，或用户手工配好）与
  /// **空值**的（"待填凭据"中间态）都会被跳过。
  /// 界面与迁移计划**共用这一个判据**，否则会出现"先说将迁移 N 项、结果报无需迁移"。
  final bool actionable;

  /// 供报告与界面展示的一行（**绝不含值**）。
  String get summary => switch (disposition) {
    OnlineMusicHeaderDisposition.sensitive =>
      '$providerId · ${capability.name} · $headerName → $slot',
    OnlineMusicHeaderDisposition.needsUser =>
      '$providerId · ${capability.name} · $headerName（待你裁定，未迁移）',
    OnlineMusicHeaderDisposition.plain =>
      '$providerId · ${capability.name} · $headerName',
  };

  @override
  String toString() => 'Finding(${disposition.name}, $summary)';
}

/// 单个条目的迁移结果。
enum OnlineMusicMigrationEntryStatus {
  /// 迁移成功（配置里已无明文、凭据可读）。
  migrated,

  /// 该条目本来就没有需要迁移的明文敏感头。
  nothingToMigrate,

  /// portable 模式：跳过迁移（配置并不变、不写内存槽位、**不报成功**）。
  skippedPortable,

  /// 凭据写入失败 ⇒ 已回滚，配置不变。
  failedWrite,

  /// 回读与原文不一致 ⇒ 已回滚，配置不变。
  failedReadBack,

  /// 配置落盘失败 ⇒ 已回滚凭据，配置不变。
  failedConfigSave,

  /// 槽位已存在且内容不同（或无法可靠确认）⇒ **停止且不覆盖**。
  conflict,

  /// 请求头名归一化后碰撞 ⇒ 失败并报告。
  nameCollision,

  /// 迁移后配置里**仍能找到**明文 ⇒ 视为失败并尝试还原。
  plaintextStillPresent,

  /// 更早的条目已导致整体停止，本条目未被处理。
  skippedAfterStop,

  /// 回滚本身失败 ⇒ **停止整个迁移**并报告。
  rollbackFailed,
}

/// 状态的界面文案与"是否算失败"。穷举 switch：新增状态漏改会编译失败。
String onlineMusicMigrationEntryLabel(OnlineMusicMigrationEntryStatus status) =>
    switch (status) {
      OnlineMusicMigrationEntryStatus.migrated => '已迁移',
      OnlineMusicMigrationEntryStatus.nothingToMigrate => '无需迁移',
      OnlineMusicMigrationEntryStatus.skippedPortable => '已跳过（便携模式）',
      OnlineMusicMigrationEntryStatus.failedWrite => '失败：凭据写入失败（已回滚）',
      OnlineMusicMigrationEntryStatus.failedReadBack => '失败：回读不一致（已回滚）',
      OnlineMusicMigrationEntryStatus.failedConfigSave =>
        '失败：配置保存失败（已回滚）',
      OnlineMusicMigrationEntryStatus.conflict => '停止：目标槽位已有不同内容（未覆盖）',
      OnlineMusicMigrationEntryStatus.nameCollision => '失败：请求头名归一化后碰撞',
      OnlineMusicMigrationEntryStatus.plaintextStillPresent =>
        '失败：配置里仍有明文（已尝试还原）',
      OnlineMusicMigrationEntryStatus.skippedAfterStop => '未处理：迁移已停止',
      OnlineMusicMigrationEntryStatus.rollbackFailed => '严重：回滚失败',
    };

bool onlineMusicMigrationEntryIsFailure(
  OnlineMusicMigrationEntryStatus status,
) => switch (status) {
  OnlineMusicMigrationEntryStatus.migrated ||
  OnlineMusicMigrationEntryStatus.nothingToMigrate ||
  OnlineMusicMigrationEntryStatus.skippedPortable ||
  OnlineMusicMigrationEntryStatus.skippedAfterStop => false,
  OnlineMusicMigrationEntryStatus.failedWrite ||
  OnlineMusicMigrationEntryStatus.failedReadBack ||
  OnlineMusicMigrationEntryStatus.failedConfigSave ||
  OnlineMusicMigrationEntryStatus.conflict ||
  OnlineMusicMigrationEntryStatus.nameCollision ||
  OnlineMusicMigrationEntryStatus.plaintextStillPresent ||
  OnlineMusicMigrationEntryStatus.rollbackFailed => true,
};

final class OnlineMusicMigrationEntryOutcome {
  const OnlineMusicMigrationEntryOutcome({
    required this.providerId,
    required this.status,
    this.reason,
    this.migratedHeaderNames = const [],
  });

  final String providerId;
  final OnlineMusicMigrationEntryStatus status;

  /// **非敏感**说明（绝不包含任何值）。
  final String? reason;

  /// 该条目里实际迁移的请求头**名称**。
  final List<String> migratedHeaderNames;

  @override
  String toString() =>
      'EntryOutcome($providerId, ${status.name}'
      '${reason == null ? '' : ', $reason'})';
}

/// 一次迁移的完整报告（可安全打印：只有名称、计数与判定）。
final class OnlineMusicHeaderMigrationReport {
  const OnlineMusicHeaderMigrationReport({
    required this.findings,
    required this.entries,
    required this.settings,
    required this.stopped,
    this.stopReason,
    this.portable = false,
  });

  /// 迁移**前**的识别结果（三态清单）。
  final List<OnlineMusicHeaderFinding> findings;

  final List<OnlineMusicMigrationEntryOutcome> entries;

  /// 迁移**后**的配置；任何失败/跳过都保持原值。
  final OnlineMusicSettings settings;

  /// 是否因失败而停止（含回滚失败）。
  final bool stopped;

  /// 停止原因（非敏感）。
  final String? stopReason;

  /// 是否处于便携模式（此时**什么都没做**）。
  final bool portable;

  Iterable<OnlineMusicHeaderFinding> get sensitiveFindings =>
      findings.where((f) => f.disposition == OnlineMusicHeaderDisposition.sensitive);

  Iterable<OnlineMusicHeaderFinding> get needsUserFindings =>
      findings.where((f) => f.disposition == OnlineMusicHeaderDisposition.needsUser);

  int get migratedCount => entries
      .where((e) => e.status == OnlineMusicMigrationEntryStatus.migrated)
      .length;

  bool get hasWork =>
      sensitiveFindings.any((f) => f.slot != null);

  bool get anyFailure => entries.any(
    (e) => onlineMusicMigrationEntryIsFailure(e.status),
  );

  @override
  String toString() =>
      'MigrationReport(findings=${findings.length}, '
      'sensitive=${sensitiveFindings.length}, needsUser=${needsUserFindings.length}, '
      'migrated=$migratedCount, stopped=$stopped, portable=$portable)';
}

/// 待迁移的一项（**只在内存中存在，绝不写盘**）。
final class _MigrationItem {
  _MigrationItem({
    required this.capability,
    required this.header,
    required this.slot,
  });

  final OnlineMusicCapability capability;
  final OnlineMusicHeaderSpec header;
  final String slot;

  /// 槽位已存在且内容相同 ⇒ 幂等重放，不重复写。
  bool alreadyIdentical = false;

  String get value => header.value;
}

/// 异步读一个槽位；区分"没有"与"读失败"。
sealed class _SlotProbe {
  const _SlotProbe();
}

final class _SlotAbsent extends _SlotProbe {
  const _SlotAbsent();
}

final class _SlotPresent extends _SlotProbe {
  const _SlotPresent(this.value);
  final String value;
}

final class _SlotUnreadable extends _SlotProbe {
  const _SlotUnreadable(this.reason);
  final String reason;
}

/// 明文敏感头的迁移执行者（Spec §4）。
///
/// 构造后**只读**：`identify()` 不写任何东西；`run()` 才按事务执行。
final class OnlineMusicHeaderMigration {
  OnlineMusicHeaderMigration({
    required OnlineMusicSettings settings,
    required OnlineMusicSettingsStore store,
    required OnlineMusicCredentialAccess access,
    required OnlineMusicCredentialReader reader,
    required bool portableBuild,
  }) : _settings = settings,
       _store = store,
       _access = access,
       _reader = reader,
       _portable = portableBuild;

  /// 迁移**开始时**的配置；迁移过程中的新值只走局部变量，不改这个字段
  /// （因此 `identify()` 与失败回滚都拿得到原始输入）。
  final OnlineMusicSettings _settings;
  final OnlineMusicSettingsStore _store;
  final OnlineMusicCredentialAccess _access;
  final OnlineMusicCredentialReader _reader;
  final bool _portable;

  /// **只识别**（Spec §4.1）：不写配置、不写凭据、不建连接。
  List<OnlineMusicHeaderFinding> identify() {
    final findings = <OnlineMusicHeaderFinding>[];
    for (final provider in _settings.providers) {
      final capabilities = provider.capabilities;
      if (capabilities == null) continue;
      for (final entry in capabilities.entries) {
        final binding = entry.value;
        if (binding is! OnlineMusicDeclarativeCapabilityBinding) continue;
        for (final header in binding.request.headers) {
          findings.add(_classify(provider.id, entry.key, header));
        }
      }
    }
    return List.unmodifiable(findings);
  }

  OnlineMusicHeaderFinding _classify(
    String providerId,
    OnlineMusicCapability capability,
    OnlineMusicHeaderSpec header,
  ) {
    final slot = onlineMusicHeaderSlotName(
      providerId: providerId,
      capability: capability,
      headerName: header.name,
    );
    // 规则 B（权威判据）：显式标记 / 已有引用 ⇒ 无条件按敏感处理。
    if (header.sensitive || header.credentialReference != null) {
      return OnlineMusicHeaderFinding(
        providerId: providerId,
        capability: capability,
        headerName: header.name,
        disposition: OnlineMusicHeaderDisposition.sensitive,
        slot: header.credentialReference ?? slot,
        actionable: _isActionable(header),
      );
    }
    // 规则 A（主判据）：名称命中名单。
    if (isSensitiveHeaderName(header.name)) {
      return OnlineMusicHeaderFinding(
        providerId: providerId,
        capability: capability,
        headerName: header.name,
        disposition: OnlineMusicHeaderDisposition.sensitive,
        slot: slot,
        actionable: _isActionable(header),
      );
    }
    // 规则 C（兜底）：值形态可疑 ⇒ **只**生成待确认候选。
    if (looksLikeSensitiveHeaderValue(header.value)) {
      return OnlineMusicHeaderFinding(
        providerId: providerId,
        capability: capability,
        headerName: header.name,
        disposition: OnlineMusicHeaderDisposition.needsUser,
      );
    }
    return OnlineMusicHeaderFinding(
      providerId: providerId,
      capability: capability,
      headerName: header.name,
      disposition: OnlineMusicHeaderDisposition.plain,
    );
  }

  /// 该项**这次真的会被搬**：还没有引用（没迁移过、也没手工配好），且确有明文可搬。
  ///
  /// 识别报告与迁移计划**共用它** —— 界面显示"将迁移 N 项"时，
  /// 那个 N 就是计划里真的会写槽位的项数，不会出现"先说 N 项、结果报无需迁移"。
  static bool _isActionable(OnlineMusicHeaderSpec header) =>
      header.credentialReference == null && header.value.trim().isNotEmpty;

  /// 事务化执行迁移（Spec §4.3/§4.4/§11.3）。
  ///
  /// 调用方**必须**已经拿到用户对识别结果的放行；本方法自己不再询问。
  Future<OnlineMusicHeaderMigrationReport> run() async {
    final findings = identify();

    // portable：无法持久化安全凭据 ⇒ **跳过**，原配置不变、不写内存槽位、不报成功。
    if (_portable) {
      return OnlineMusicHeaderMigrationReport(
        findings: findings,
        entries: [
          for (final provider in _settings.providers)
            OnlineMusicMigrationEntryOutcome(
              providerId: provider.id,
              status: OnlineMusicMigrationEntryStatus.skippedPortable,
              reason: '便携模式无法持久保存秘密：请改用安装版完成迁移（本次未改动任何配置）',
            ),
        ],
        settings: _settings,
        stopped: false,
        portable: true,
      );
    }

    var current = _settings;
    var stopped = false;
    String? stopReason;
    final entries = <OnlineMusicMigrationEntryOutcome>[];

    for (final provider in _settings.providers) {
      if (stopped) {
        entries.add(
          OnlineMusicMigrationEntryOutcome(
            providerId: provider.id,
            status: OnlineMusicMigrationEntryStatus.skippedAfterStop,
          ),
        );
        continue;
      }
      final outcome = await _migrateEntry(current, provider);
      entries.add(outcome.outcome);
      if (outcome.settings != null) current = outcome.settings!;
      if (outcome.stopReason != null) {
        stopped = true;
        stopReason = outcome.stopReason;
      }
    }

    return OnlineMusicHeaderMigrationReport(
      findings: findings,
      entries: List.unmodifiable(entries),
      settings: current,
      stopped: stopped,
      stopReason: stopReason,
    );
  }

  Future<_EntryOutcome> _migrateEntry(
    OnlineMusicSettings current,
    OnlineMusicProviderDefinition provider,
  ) async {
    final plan = _planFor(provider);

    final collision = plan.collision;
    if (collision != null) {
      return _EntryOutcome(
        OnlineMusicMigrationEntryOutcome(
          providerId: provider.id,
          status: OnlineMusicMigrationEntryStatus.nameCollision,
          reason: '请求头 ${collision.join(' 与 ')} 归一化后同名，会互相覆盖',
        ),
        stopReason: '${provider.id}：请求头归一化后碰撞',
      );
    }
    if (plan.items.isEmpty) {
      return _EntryOutcome(
        OnlineMusicMigrationEntryOutcome(
          providerId: provider.id,
          status: OnlineMusicMigrationEntryStatus.nothingToMigrate,
        ),
      );
    }

    // ---- 写之前：冲突检查（Spec §11.3）----
    for (final item in plan.items) {
      final probe = await _probeSlot(item.slot);
      switch (probe) {
        case _SlotAbsent():
          break;
        case _SlotPresent(:final value):
          if (value == item.value) {
            // 内容完全相同 ⇒ 幂等重放：不重复写。
            item.alreadyIdentical = true;
          } else {
            return _EntryOutcome(
              OnlineMusicMigrationEntryOutcome(
                providerId: provider.id,
                status: OnlineMusicMigrationEntryStatus.conflict,
                reason: '目标槽位已存在且内容不同：${item.slot}',
              ),
              stopReason: '${provider.id}：目标槽位已有不同内容，已停止且未覆盖',
            );
          }
        case _SlotUnreadable(:final reason):
          // "无法可靠确认" 与 "内容不同" 同等对待：不覆盖。
          return _EntryOutcome(
            OnlineMusicMigrationEntryOutcome(
              providerId: provider.id,
              status: OnlineMusicMigrationEntryStatus.conflict,
              reason: '无法确认目标槽位内容（$reason）：${item.slot}',
            ),
            stopReason: '${provider.id}：无法确认目标槽位内容，已停止且未覆盖',
          );
      }
    }

    // ---- 写凭据 ----
    final created = <String>[];
    for (final item in plan.items) {
      if (item.alreadyIdentical) continue;
      try {
        await _access.save(item.slot, item.value);
        created.add(item.slot);
      } catch (_) {
        return _rollbackEntry(
          providerId: provider.id,
          created: created,
          status: OnlineMusicMigrationEntryStatus.failedWrite,
          reason: '凭据写入失败（配置保持不变）',
        );
      }
    }

    // ---- 立即回读，逐字节校验 ----
    for (final item in plan.items) {
      final probe = await _probeSlot(item.slot);
      final matches = switch (probe) {
        _SlotPresent(:final value) => value == item.value,
        _SlotAbsent() => false,
        _SlotUnreadable() => false,
      };
      if (!matches) {
        return _rollbackEntry(
          providerId: provider.id,
          created: created,
          status: OnlineMusicMigrationEntryStatus.failedReadBack,
          reason: '回读校验不一致（配置保持不变）',
        );
      }
    }

    // ---- 改写配置并落盘 ----
    final next = _rewrite(current, provider, plan.items);
    var saved = false;
    try {
      saved = await _store.write(next);
    } catch (_) {
      saved = false;
    }
    if (!saved) {
      return _rollbackEntry(
        providerId: provider.id,
        created: created,
        status: OnlineMusicMigrationEntryStatus.failedConfigSave,
        reason: '配置保存失败（凭据已回滚）',
      );
    }

    // ---- 重新解析校验 + 确认明文已移除 ----
    //
    // 明文检查必须**只针对这条 entry**：另一条还没轮到迁移的 entry 完全可能持有
    // 同样的明文（同一个 Cookie 值出现在两个条目里是合法的），
    // 拿整份配置去搜会把"已经迁干净"误判成失败，进而去还原配置。
    final rewrittenJson = jsonEncode(next.providerById(provider.id)!.toJson());
    final reparsed = OnlineMusicSettings.fromJson(jsonDecode(jsonEncode(next.toJson())));
    final plaintextLeft = [
      for (final item in plan.items)
        if (rewrittenJson.contains(item.value)) item.header.name,
    ];
    if (reparsed != next || plaintextLeft.isNotEmpty) {
      // 走到这里说明改写/落盘有问题：把配置还原回去，绝不能留着"看起来迁移完了"。
      //
      // ⚠️ **防御性分支**：只要"配置能往返解析"且 `_rewrite` 真的清空了明文，这里就进不来。
      // 已实测的只有它的**通过侧** —— 每个迁移成功用例都必须先通过这次重新解析校验，
      // 因此一旦模型不再能往返，那些用例会立刻翻红。失败侧（下面两条 return）在
      // 当前不变式下**无法由外部注入构造**，故**无测试覆盖**，如实登记。
      final restored = await _restore(current);
      if (!restored) {
        // ⚠️ 磁盘上现在是**已经改写过的** next。这里**不删凭据**（配置引用了它们），
        // 并且把 report.settings 报成 next —— 让界面/内存与**磁盘真实状态**一致。
        // 若继续报 current，界面会显示明文、而磁盘已是引用（两份说法）。
        return _EntryOutcome(
          OnlineMusicMigrationEntryOutcome(
            providerId: provider.id,
            status: OnlineMusicMigrationEntryStatus.rollbackFailed,
            reason: '配置无法还原：磁盘上已是改写后的配置'
                '（${plaintextLeft.isEmpty ? '重新解析不一致' : '仍有明文'}），'
                '凭据已写入且未删除，请人工核对',
          ),
          settings: next,
          stopReason: '${provider.id}：回滚失败，已停止整个迁移',
        );
      }
      return _rollbackEntry(
        providerId: provider.id,
        created: created,
        status: OnlineMusicMigrationEntryStatus.plaintextStillPresent,
        reason: plaintextLeft.isEmpty
            ? '迁移后配置无法重新解析（已还原配置）'
            : '迁移后配置里仍有明文（已还原配置）',
      );
    }

    return _EntryOutcome(
      OnlineMusicMigrationEntryOutcome(
        providerId: provider.id,
        status: OnlineMusicMigrationEntryStatus.migrated,
        migratedHeaderNames: [
          for (final item in plan.items) item.header.name,
        ],
      ),
      settings: next,
    );
  }

  /// 该条目的迁移计划；名字归一化碰撞在这里就被拦下（Spec §11.3）。
  _MigrationPlan _planFor(OnlineMusicProviderDefinition provider) {
    final capabilities = provider.capabilities;
    if (capabilities == null) return const _MigrationPlan(items: [], collision: null);
    final items = <_MigrationItem>[];
    List<String>? collision;
    for (final entry in capabilities.entries) {
      final binding = entry.value;
      if (binding is! OnlineMusicDeclarativeCapabilityBinding) continue;
      final names = <String>[];
      for (final header in binding.request.headers) {
        // 已有引用 ⇒ 已经迁移过（或用户手工配好），跳过；但名称仍参与碰撞检测。
        names.add(header.name);
        // 与识别报告**共用同一个判据**（actionable）：界面说的"将迁移 N 项"
        // 就是这里真的会搬的那 N 项。值形态启发式（needs-user）**永不**迁移。
        final finding = _classify(provider.id, entry.key, header);
        if (!finding.actionable) continue;
        items.add(
          _MigrationItem(
            capability: entry.key,
            header: header,
            slot: finding.slot!,
          ),
        );
      }
      final collisions = onlineMusicHeaderNameCollisions(names);
      if (collisions.isNotEmpty) collision = collisions.first;
    }
    return _MigrationPlan(items: items, collision: collision);
  }

  /// 把计划里的请求头改写成**引用形式**（值清空、标记敏感、写入槽位名）。
  OnlineMusicSettings _rewrite(
    OnlineMusicSettings current,
    OnlineMusicProviderDefinition provider,
    List<_MigrationItem> items,
  ) {
    final byCapability = <OnlineMusicCapability, List<_MigrationItem>>{};
    for (final item in items) {
      (byCapability[item.capability] ??= <_MigrationItem>[]).add(item);
    }

    var definition = provider;
    for (final entry in byCapability.entries) {
      final binding = definition.bindingFor(entry.key);
      if (binding is! OnlineMusicDeclarativeCapabilityBinding) continue;
      final slotByHeaderName = {
        for (final item in entry.value) item.header.name: item.slot,
      };
      final headers = [
        for (final header in binding.request.headers)
          if (slotByHeaderName[header.name] case final slot?)
            header.asCredentialReference(slot)
          else
            header,
      ];
      definition = definition.withCapabilityBinding(
        entry.key,
        OnlineMusicDeclarativeCapabilityBinding(
          request: OnlineMusicRequestSpec(
            verb: binding.request.verb,
            path: binding.request.path,
            query: binding.request.query,
            headers: headers,
            body: binding.request.body,
            auth: binding.request.auth,
          ),
          response: binding.response,
        ),
      );
    }
    return current.withUpdatedProvider(definition);
  }

  /// 回滚本次**新建**的槽位（幂等重放的槽位不动 —— 它不是我们建的）。
  Future<bool> _deleteCreated(List<String> created) async {
    var ok = true;
    for (final slot in created) {
      try {
        await _access.clear(slot);
      } catch (_) {
        ok = false;
      }
    }
    return ok;
  }

  Future<_EntryOutcome> _rollbackEntry({
    required String providerId,
    required List<String> created,
    required OnlineMusicMigrationEntryStatus status,
    required String reason,
  }) async {
    final rolledBack = await _deleteCreated(created);
    if (!rolledBack) {
      // 回滚失败 ⇒ **停止整个迁移并报告**，不得继续处理其它 entry 掩盖问题。
      return _EntryOutcome(
        OnlineMusicMigrationEntryOutcome(
          providerId: providerId,
          status: OnlineMusicMigrationEntryStatus.rollbackFailed,
          reason: '$reason；且槽位回滚失败',
        ),
        stopReason: '$providerId：回滚失败，已停止整个迁移',
      );
    }
    return _EntryOutcome(
      OnlineMusicMigrationEntryOutcome(
        providerId: providerId,
        status: status,
        reason: reason,
      ),
    );
  }

  /// 把配置写回成迁移前的样子；返回是否成功。
  Future<bool> _restore(OnlineMusicSettings previous) async {
    try {
      return await _store.write(previous);
    } catch (_) {
      return false;
    }
  }

  Future<_SlotProbe> _probeSlot(String slot) async {
    try {
      final value = await _reader.readCredential(slot);
      return value == null ? const _SlotAbsent() : _SlotPresent(value);
    } catch (_) {
      return const _SlotUnreadable('读取失败');
    }
  }
}

final class _MigrationPlan {
  const _MigrationPlan({required this.items, required this.collision});

  final List<_MigrationItem> items;
  final List<String>? collision;
}

final class _EntryOutcome {
  const _EntryOutcome(this.outcome, {this.settings, this.stopReason});

  final OnlineMusicMigrationEntryOutcome outcome;

  /// 成功迁移后的新配置；其余情况为 null（保持原值）。
  final OnlineMusicSettings? settings;

  /// 非 null ⇒ 停止整个迁移。
  final String? stopReason;
}
