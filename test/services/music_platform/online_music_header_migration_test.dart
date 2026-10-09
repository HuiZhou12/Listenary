import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/services/music_platform/chksz/index.dart';
import 'package:pure_music/services/music_platform/provider/online_music_header_migration.dart';

/// F0 切片 5：**旧配置的安全迁移**（Spec §2 §3 §4 §11.3）。
///
/// 本机真实配置里敏感头为 0 ⇒ 真机迁移是空操作，**只能靠这里的合成夹具证明**。
/// 每个用例都在断言"要么完整成功、要么完全没动过"：绝不接受半迁移。
void main() {
  const cookiePlaintext = 'session=FAKE_COOKIE_VALUE_TEST_ONLY';
  const tokenPlaintext = 'FAKE_TOKEN_VALUE_TEST_ONLY_0123456789';
  const harmlessValue = 'listenary';

  late _FakeCredentialStore credentials;
  late _MemorySettingsStore store;

  setUp(() {
    credentials = _FakeCredentialStore();
    store = _MemorySettingsStore();
  });

  OnlineMusicHeaderMigration migrationFor(
    OnlineMusicSettings settings, {
    bool portable = false,
  }) {
    // 存储里放的就是"正在被迁移的那份配置"：失败路径要能断言"一个字节都没被改写"。
    store.value = settings;
    return OnlineMusicHeaderMigration(
      settings: settings,
      store: store,
      access: credentials,
      reader: credentials,
      portableBuild: portable,
    );
  }

  /// 一条自己提到槽位名的路径（与引擎派生的一致）。
  String cookieSlot(String providerId) => onlineMusicHeaderSlotName(
    providerId: providerId,
    capability: OnlineMusicCapability.search,
    headerName: 'Cookie',
  );

  String tokenSlot(String providerId) => onlineMusicHeaderSlotName(
    providerId: providerId,
    capability: OnlineMusicCapability.search,
    headerName: 'Authorization',
  );

  group('识别（只读，不写任何东西）', () {
    test('★ 三态闭合：名称命中 / 值可疑 / 普通，逐条都有结论', () {
      final settings = _settings(
        headers: const [
          {'name': 'X-Client', 'value': harmlessValue},
          {'name': 'Cookie', 'value': cookiePlaintext},
          {'name': 'X-Weird', 'value': 'Ab3Kd9Zx7Qm2Pl5R'},
          {'name': 'X-Page', 'value': '2'},
        ],
      );
      final migration = migrationFor(settings);

      final findings = migration.identify();

      expect(findings, hasLength(4));
      // 找不到就直接失败（避免"没命中却静默通过"）。
      OnlineMusicHeaderFinding lookup(String name) =>
          findings.firstWhere((finding) => finding.headerName == name);

      expect(
        lookup('Cookie').disposition,
        OnlineMusicHeaderDisposition.sensitive,
        reason: '名称命中规则 A（主判据）',
      );
      expect(
        lookup('X-Weird').disposition,
        OnlineMusicHeaderDisposition.needsUser,
        reason: '值形态只能生成"待确认"候选，绝不自动迁移',
      );
      expect(lookup('X-Client').disposition, OnlineMusicHeaderDisposition.plain);
      expect(lookup('X-Page').disposition, OnlineMusicHeaderDisposition.plain);

      // 只识别 ⇒ 一个字节都不写。
      expect(store.writes, 0);
      expect(credentials.slots, isEmpty);
      expect(credentials.writeCounts, isEmpty);
    });

    test('显式标记（规则 B）无条件按敏感处理', () {
      final settings = _settings(
        headers: const [
          {'name': 'X-Anything', 'value': '', 'sensitive': true},
        ],
      );

      final findings = migrationFor(settings).identify();

      expect(findings.single.disposition, OnlineMusicHeaderDisposition.sensitive);
      expect(findings.single.slot, isNotNull);
    });

    test('报告里没有任何值（只有名称/槽位/判定）', () {
      final settings = _settings(
        headers: const [
          {'name': 'Cookie', 'value': cookiePlaintext},
          {'name': 'X-Weird', 'value': tokenPlaintext},
        ],
      );

      final report = migrationFor(settings).identify().map((f) => f.summary).join('\n');

      expect(report, contains('Cookie'));
      expect(report, isNot(contains(cookiePlaintext)));
      expect(report, isNot(contains(tokenPlaintext)));
    });
  });

  group('迁移成功（§10.4-1）', () {
    test('★ 写槽位 → 回读一致 → 配置改写 → 重新解析 → 明文已移除', () async {
      final settings = _settings(
        headers: const [
          {'name': 'X-Client', 'value': harmlessValue},
          {'name': 'Cookie', 'value': cookiePlaintext},
        ],
      );

      final report = await migrationFor(settings).run();

      expect(report.stopped, isFalse);
      expect(report.migratedCount, 1);
      expect(
        report.entries.single.status,
        OnlineMusicMigrationEntryStatus.migrated,
      );

      // 凭据进了槽位……
      expect(credentials.slots[cookieSlot('p1')], cookiePlaintext);
      // ……配置里只剩引用，且明文已移除。
      final serialized = jsonEncode(store.value.toJson());
      expect(serialized, isNot(contains(cookiePlaintext)));
      expect(serialized, contains(cookieSlot('p1')));
      final header = _headersOf(store.value, 'p1').firstWhere(
        (h) => h.name == 'Cookie',
      );
      expect(header.sensitive, isTrue);
      expect(header.value, isEmpty);
      expect(header.credentialReference, cookieSlot('p1'));
      // 普通请求头一个字都没动。
      expect(
        _headersOf(store.value, 'p1').firstWhere((h) => h.name == 'X-Client').value,
        harmlessValue,
      );
      // 报告里也不含值。
      expect(
        report.entries.map((e) => e.reason ?? '').join(),
        isNot(contains(cookiePlaintext)),
      );
    });
  });

  group('失败 ⇒ 整条 entry 回滚，绝不半迁移（§10.4-2/3/4）', () {
    test('★ 凭据写入失败 ⇒ 配置不变，且先写进去的槽位被删掉', () async {
      final settings = _settings(
        headers: const [
          {'name': 'Cookie', 'value': cookiePlaintext},
          {'name': 'Authorization', 'value': tokenPlaintext},
        ],
      );
      // 第一个能写，第二个写失败 ⇒ 必须把第一个回滚掉。
      credentials.failWriteFor = {tokenSlot('p1')};

      final report = await migrationFor(settings).run();

      expect(
        report.entries.single.status,
        OnlineMusicMigrationEntryStatus.failedWrite,
      );
      expect(credentials.slots, isEmpty, reason: '不得留下半迁移');
      expect(jsonEncode(store.value.toJson()), contains(cookiePlaintext));
      expect(store.writes, 0, reason: '配置一个字节都不该被改写');
    });

    test('★ 回读不一致 ⇒ 回滚槽位、配置不变', () async {
      final settings = _settings(
        headers: const [
          {'name': 'Cookie', 'value': cookiePlaintext},
        ],
      );
      credentials.corruptReadBackFor = {cookieSlot('p1')};

      final report = await migrationFor(settings).run();

      expect(
        report.entries.single.status,
        OnlineMusicMigrationEntryStatus.failedReadBack,
      );
      expect(credentials.slots, isEmpty);
      expect(jsonEncode(store.value.toJson()), contains(cookiePlaintext));
      expect(store.writes, 0);
    });

    test('★ 配置保存失败 ⇒ 槽位已写也要回滚', () async {
      final settings = _settings(
        headers: const [
          {'name': 'Cookie', 'value': cookiePlaintext},
        ],
      );
      store.acceptWrites = false;

      final report = await migrationFor(settings).run();

      expect(
        report.entries.single.status,
        OnlineMusicMigrationEntryStatus.failedConfigSave,
      );
      expect(credentials.slots, isEmpty, reason: '配置没存下，凭据也不能留');
      expect(jsonEncode(store.value.toJson()), contains(cookiePlaintext));
    });

    test('★ 回滚失败 ⇒ 停止整个迁移，后面的 entry 一个都不碰', () async {
      final settings = _twoProviders(
        // 第一条要有两个敏感头：第一个写成功、第二个写失败 ⇒ 才会真的去删第一个，
        // 而删除也失败 ⇒ 触发"回滚失败"这条最严重的分支。
        first: const [
          {'name': 'Cookie', 'value': cookiePlaintext},
          {'name': 'Authorization', 'value': tokenPlaintext},
        ],
        second: const [
          {'name': 'Cookie', 'value': cookiePlaintext},
        ],
      );
      credentials.failWriteFor = {tokenSlot('p1')}; // 第二个写失败 ⇒ 触发回滚
      credentials.failRemoveFor = {'*'}; // ……而回滚也失败

      final report = await migrationFor(settings).run();

      expect(report.stopped, isTrue);
      expect(report.stopReason, isNotNull);
      expect(report.entries, hasLength(2));
      expect(
        report.entries.first.status,
        OnlineMusicMigrationEntryStatus.rollbackFailed,
      );
      expect(
        report.entries.last.status,
        OnlineMusicMigrationEntryStatus.skippedAfterStop,
        reason: '回滚失败后不得继续处理其它 entry 掩盖问题',
      );
      expect(
        store.writes,
        0,
        reason: '报告=$report；状态=${report.entries.map((e) => e.status.name).toList()}',
      );
      expect(credentials.slotsForSecondProviderTouched, isFalse);
    });
  });

  group('幂等重放与"不按值合并"（§10.4-6、§11.3）', () {
    test('★ 重复执行：不新建重复槽位、不改名、plain 项不动', () async {
      final settings = _settings(
        headers: const [
          {'name': 'X-Client', 'value': harmlessValue},
          {'name': 'Cookie', 'value': cookiePlaintext},
        ],
      );

      final first = await migrationFor(settings).run();
      expect(first.migratedCount, 1);
      final writtenAfterFirst = Map<String, int>.from(credentials.writeCounts);
      final configAfterFirst = jsonEncode(store.value.toJson());

      final second = await migrationFor(store.value).run();

      expect(second.migratedCount, 0);
      expect(
        second.entries.single.status,
        OnlineMusicMigrationEntryStatus.nothingToMigrate,
      );
      expect(credentials.writeCounts, writtenAfterFirst, reason: '不得重复写');
      // 槽位名稳定：没有改名、没有新建第二个。
      expect(credentials.slots.keys, [cookieSlot('p1')]);
      // plain 项不动，整份配置逐字节相同。
      expect(jsonEncode(store.value.toJson()), configAfterFirst);
      expect(second.settings, store.value);
    });

    test('★ 目标槽位已存在且内容相同 ⇒ 幂等通过、不重复写', () async {
      final settings = _settings(
        headers: const [
          {'name': 'Cookie', 'value': cookiePlaintext},
        ],
      );
      credentials.slots[cookieSlot('p1')] = cookiePlaintext;

      final report = await migrationFor(settings).run();

      expect(
        report.entries.single.status,
        OnlineMusicMigrationEntryStatus.migrated,
      );
      expect(credentials.writeCounts[cookieSlot('p1')] ?? 0, 0);
      expect(credentials.slots[cookieSlot('p1')], cookiePlaintext);
      expect(
        jsonEncode(store.value.toJson()),
        isNot(contains(cookiePlaintext)),
      );
    });

    test('★ 目标槽位已存在且内容不同 ⇒ 停止、不覆盖、报告', () async {
      final settings = _settings(
        headers: const [
          {'name': 'Cookie', 'value': cookiePlaintext},
        ],
      );
      credentials.slots[cookieSlot('p1')] = 'ANOTHER_EXISTING_SECRET';

      final report = await migrationFor(settings).run();

      expect(report.stopped, isTrue);
      expect(
        report.entries.single.status,
        OnlineMusicMigrationEntryStatus.conflict,
      );
      expect(
        credentials.slots[cookieSlot('p1')],
        'ANOTHER_EXISTING_SECRET',
        reason: '不得覆盖原凭据',
      );
      expect(store.writes, 0);
      expect(jsonEncode(store.value.toJson()), contains(cookiePlaintext));
    });

    test('★ 无法可靠确认槽位内容（读失败）⇒ 同样停止且不覆盖', () async {
      final settings = _settings(
        headers: const [
          {'name': 'Cookie', 'value': cookiePlaintext},
        ],
      );
      credentials.failReadFor = {cookieSlot('p1')};

      final report = await migrationFor(settings).run();

      expect(report.stopped, isTrue);
      expect(
        report.entries.single.status,
        OnlineMusicMigrationEntryStatus.conflict,
      );
      expect(store.writes, 0);
    });

    test('★ Header 名归一化碰撞 ⇒ 失败并报告（不合并、不覆盖）', () async {
      final settings = _settings(
        headers: const [
          {'name': 'X-Token', 'value': tokenPlaintext},
          {'name': 'x_token', 'value': tokenPlaintext},
        ],
      );

      final report = await migrationFor(settings).run();

      expect(
        report.entries.single.status,
        OnlineMusicMigrationEntryStatus.nameCollision,
      );
      expect(report.entries.single.reason, contains('X-Token'));
      expect(report.entries.single.reason, contains('x_token'));
      expect(credentials.slots, isEmpty);
      expect(store.writes, 0);
    });
  });

  group('portable（§11.2 / §11.5-6）', () {
    test('★ 跳过迁移：配置逐字节不变、未写内存槽位、不报成功', () async {
      final settings = _settings(
        headers: const [
          {'name': 'Cookie', 'value': cookiePlaintext},
        ],
      );
      final before = jsonEncode(settings.toJson());

      final report = await migrationFor(settings, portable: true).run();

      expect(report.portable, isTrue);
      expect(report.migratedCount, 0, reason: '跳过 ≠ 成功');
      expect(
        report.entries.single.status,
        OnlineMusicMigrationEntryStatus.skippedPortable,
      );
      expect(report.entries.single.reason, contains('安装版'));
      // 配置逐字节不变。
      expect(store.writes, 0);
      expect(jsonEncode(store.value.toJson()), before);
      // 没有写内存槽位（否则等于"重启即丢"）。
      expect(credentials.slots, isEmpty);
      expect(credentials.writeCounts, isEmpty);
      // 明文仍在（这是 portable 下唯一安全的选择，但绝不声称它已安全）。
      expect(report.settings, settings);
    });
  });

  group('迁移路径 vs 用户主动轮换（§11.3 边界）', () {
    test('★ 迁移不得覆盖；用户在凭据界面主动更新必须能覆盖', () async {
      // 真实实现（内存模式）验证"主动更新是合法轮换"。
      final real = ChkszCredentialAccess(portableBuild: true);
      const slot = 'rotation/test/slot';
      await real.save(slot, 'FIRST_KEY');
      expect(await real.readCredential(slot), 'FIRST_KEY');
      await real.save(slot, 'SECOND_KEY');
      expect(
        await real.readCredential(slot),
        'SECOND_KEY',
        reason: '否则用户永远换不了 Key',
      );

      // 迁移路径：同样"槽位已有不同内容"的场景必须停下。
      final settings = _settings(
        headers: const [
          {'name': 'Cookie', 'value': cookiePlaintext},
        ],
      );
      credentials.slots[cookieSlot('p1')] = 'EXISTING_DIFFERENT';
      final report = await migrationFor(settings).run();
      expect(
        report.entries.single.status,
        OnlineMusicMigrationEntryStatus.conflict,
      );
      expect(credentials.slots[cookieSlot('p1')], 'EXISTING_DIFFERENT');
    });
  });
}

// ---------------------------------------------------------------------- 夹具

List<OnlineMusicHeaderSpec> _headersOf(OnlineMusicSettings settings, String id) {
  final binding = settings.providerById(id)!.bindingFor(
    OnlineMusicCapability.search,
  );
  return (binding as OnlineMusicDeclarativeCapabilityBinding)
      .request
      .headers
      .toList();
}

Map<String, Object?> _bindingJson(List<Object?> headers) =>
    OnlineMusicDeclarativeCapabilityBinding(
      request: OnlineMusicRequestSpec(
        path: '/search',
        query: const [
          OnlineMusicParamBinding(
            name: 'keywords',
            source: OnlineMusicInputSource.keyword,
          ),
        ],
        headers: [
          for (final raw in headers)
            OnlineMusicHeaderSpec.fromJson(raw),
        ],
      ),
      response: OnlineMusicResponseSpec(
        listPath: JsonPath.tryParse('result.songs'),
        fields: {
          OnlineMusicDomainField.trackId: OnlineMusicFieldSpec(
            candidates: [JsonPath.tryParse('id')!],
            transform: OnlineMusicFieldTransform.asInt,
            required: true,
          ),
          OnlineMusicDomainField.title: OnlineMusicFieldSpec(
            candidates: [JsonPath.tryParse('name')!],
            transform: OnlineMusicFieldTransform.asString,
            required: true,
          ),
        },
      ),
    ).toJson();

OnlineMusicSettings _settings({required List<Object?> headers}) =>
    OnlineMusicSettings.fromJson({
      'providers': [
        {
          'id': 'p1',
          'baseUrl': 'https://self.invalid',
          'auth': {'kind': 'none'},
          'capabilities': {'search': _bindingJson(headers)},
        },
      ],
    });

OnlineMusicSettings _twoProviders({
  required List<Object?> first,
  required List<Object?> second,
}) => OnlineMusicSettings.fromJson({
  'providers': [
    {
      'id': 'p1',
      'baseUrl': 'https://self.invalid',
      'auth': {'kind': 'none'},
      'capabilities': {'search': _bindingJson(first)},
    },
    {
      'id': 'p2',
      'baseUrl': 'https://self.invalid',
      'auth': {'kind': 'none'},
      'capabilities': {'search': _bindingJson(second)},
    },
  ],
});

/// 一个既能读又能写的假凭据存储，带各种"坏掉"的开关。
final class _FakeCredentialStore
    implements OnlineMusicCredentialAccess, OnlineMusicCredentialReader {
  final Map<String, String> slots = {};

  /// 每个槽位被**写入**过几次（用来证明"幂等重放不重复写"）。
  final Map<String, int> writeCounts = {};

  /// 这些槽位的写入会失败；`*` 表示全部。
  Set<String> failWriteFor = const {};

  /// 这些槽位的删除会失败；`*` 表示全部。
  Set<String> failRemoveFor = const {};

  /// 这些槽位的读取会抛错（"无法可靠确认"）。
  Set<String> failReadFor = const {};

  /// 这些槽位写入后回读会返回不一致的值。
  Set<String> corruptReadBackFor = const {};

  bool slotsForSecondProviderTouched = false;

  bool _matches(Set<String> set, String slot) =>
      set.contains('*') || set.contains(slot);

  @override
  String get credentialDisplayName => 'API Key';

  @override
  String get inputHint => 'API Key';

  @override
  bool isValidFormat(String value) => value.trim().isNotEmpty;

  @override
  Future<bool> isConfigured(String reference) async =>
      slots.containsKey(reference);

  @override
  Future<void> save(String reference, String value) async {
    writeCounts[reference] = (writeCounts[reference] ?? 0) + 1;
    if (_matches(failWriteFor, reference)) throw StateError('write failed');
    slots[reference] = value;
    if (reference.contains('p2/')) slotsForSecondProviderTouched = true;
  }

  @override
  Future<void> clear(String reference) async {
    if (_matches(failRemoveFor, reference)) throw StateError('clear failed');
    slots.remove(reference);
  }

  @override
  Future<String?> readCredential(String reference) async {
    if (_matches(failReadFor, reference)) throw StateError('read failed');
    if (_matches(corruptReadBackFor, reference) && slots.containsKey(reference)) {
      return 'CORRUPTED_READ_BACK';
    }
    return slots[reference];
  }
}

final class _MemorySettingsStore implements OnlineMusicSettingsStore {
  OnlineMusicSettings value = OnlineMusicSettings.defaults;
  bool acceptWrites = true;
  int writes = 0;

  @override
  OnlineMusicSettings read() => value;

  @override
  Future<bool> write(OnlineMusicSettings settings) async {
    writes++;
    if (!acceptWrites) return false;
    value = settings;
    return true;
  }
}
