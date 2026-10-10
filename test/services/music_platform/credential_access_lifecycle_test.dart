import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/services/music_platform/chksz/index.dart';

/// F5（P-60）：`ChkszCredentialAccess`（**按引用的凭据出口缓存**）的可观测行为。
///
/// 背景（F5-S1 实读结论）：该缓存**不是缺陷**——它的键是"凭据引用"（不同条目天然不同键），
/// 而 `save`/`clear`/`readCredential`/`isConfigured` **全部走同一个 `_provider(reference)`**，
/// 因此"界面写入的 Key 与运行期读到的是同一份"（实现注释 :7-8/:17-18 的设计意图）。
/// 本轮**不重写缓存架构**，只补它对外可观测的行为：
/// - 保存后立即能通过相同引用读到**最新值**；
/// - 清除后立即表现为**未配置**且旧值不残留；
/// - 不同引用**相互隔离**；
/// - **显式共享**同一引用时，按契约复用同一出口。
///
/// ⚠️ portable 模式 = 内存凭据 ⇒ 不触碰 Windows 凭据管理器。
void main() {
  test('★ F5-P-60 同一引用：保存后立即可读；清除后立即未配置且旧值不残留', () async {
    final access = ChkszCredentialAccess(portableBuild: true);
    const reference = 'lifecycle/search/X-Api-Key';

    expect(
      await access.isConfigured(reference),
      isFalse,
      reason: '未保存过 ⇒ 未配置',
    );
    expect(await access.readCredential(reference), isNull);

    await access.save(reference, 'KEY_ONE');
    expect(await access.readCredential(reference), 'KEY_ONE');
    expect(await access.isConfigured(reference), isTrue);

    await access.save(reference, 'KEY_TWO');
    expect(
      await access.readCredential(reference),
      'KEY_TWO',
      reason: '覆盖写之后读到的必须是最新值（缓存实例与写入实例是同一个）',
    );

    await access.clear(reference);
    expect(await access.readCredential(reference), isNull, reason: '旧值不得残留');
    expect(await access.isConfigured(reference), isFalse, reason: '清除后立即表现为未配置');
  });

  test('★ F5-P-60 不同引用相互隔离（缓存按引用计数可观测）', () async {
    final access = ChkszCredentialAccess(portableBuild: true);
    await access.save('providerA/search/X-Key', 'A_KEY');
    await access.save('providerB/search/X-Key', 'B_KEY');

    expect(await access.readCredential('providerA/search/X-Key'), 'A_KEY');
    expect(await access.readCredential('providerB/search/X-Key'), 'B_KEY');

    await access.clear('providerA/search/X-Key');
    expect(
      await access.readCredential('providerB/search/X-Key'),
      'B_KEY',
      reason: '清除一个引用不得影响另一个',
    );
    expect(
      access.toString(),
      contains('slots=2'),
      reason: '两个引用 = 两个槽位（`toString` 暴露计数，便于观测）',
    );
  });

  test('★ F5-P-60 显式共享同一引用：按契约复用同一出口（同一实例）', () async {
    final access = ChkszCredentialAccess(portableBuild: true);
    const shared = 'shared/search/X-Key';

    final first = access.providerFor(shared);
    final second = access.providerFor(shared);

    expect(
      identical(first, second),
      isTrue,
      reason: '设计契约：同一引用在进程内复用同一个出口',
    );

    await access.save(shared, 'SHARED_KEY');
    expect(await access.readCredential(shared), 'SHARED_KEY');
    expect(
      await first.readApiKey(),
      'SHARED_KEY',
      reason: '共享引用 ⇒ 一处写入，另一处立即读到',
    );
  });
}
