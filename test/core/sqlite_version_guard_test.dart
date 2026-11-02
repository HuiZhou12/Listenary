import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/core/sqlite_version_guard.dart';

/// R8：`winsqlite3.dll` 版本下限守卫。
///
/// 按 Spec §6「测试口径」：这里只测**纯谓词**与三段式降级态的**不崩**性质；
/// 真实 DLL 版本探测属人工项 M3（本机实测 3.51.1，见日志锚点）。
void main() {
  setUp(() => SqliteVersionGuard.instance.resetForTest());
  tearDown(() => SqliteVersionGuard.instance.resetForTest());

  group('纯谓词边界', () {
    test('3034999 is rejected, 3035000 is accepted', () {
      expect(isSupportedSqliteVersion(3034999), isFalse);
      expect(isSupportedSqliteVersion(3035000), isTrue);
    });

    test('well below the floor is rejected', () {
      // 3.24 有 UPSERT 但没有 RETURNING / DROP COLUMN ⇒ 仍然不够。
      expect(isSupportedSqliteVersion(3024000), isFalse);
      expect(isSupportedSqliteVersion(0), isFalse);
    });

    test('newer versions are accepted', () {
      expect(isSupportedSqliteVersion(3035001), isTrue);
      expect(isSupportedSqliteVersion(3051001), isTrue);
    });

    test('the floor constant is the documented 3.35.0', () {
      expect(minimumSupportedSqliteVersion, 3035000);
    });
  });

  group('探测与降级态', () {
    test('probeOnce is idempotent and reports a usable state', () {
      final first = SqliteVersionGuard.instance.probeOnce();
      final second = SqliteVersionGuard.instance.probeOnce();
      expect(identical(first, second), isTrue, reason: '进程内只探测一次');
      // 本机 winsqlite3 3.51.1 ⇒ 支持；若某环境缺 DLL 则为 unavailable，
      // 这里不断言具体档位，只断言「有结论且不抛」。
      expect(
        first.state,
        isIn(const [
          SqliteSupportState.supported,
          SqliteSupportState.tooOld,
          SqliteSupportState.unavailable,
        ]),
      );
      expect(first.libVersion, isNotEmpty);
      expect(first.versionNumber, greaterThan(0));
    });

    test('canWrite defaults to true before any probe (no false degrade)', () {
      expect(SqliteVersionGuard.instance.probe, isNull);
      expect(SqliteVersionGuard.instance.canWrite, isTrue);
    });

    test('degraded notice is null when the version is supported', () {
      final probe = SqliteVersionGuard.instance.probeOnce();
      if (probe.isWritable) {
        expect(SqliteVersionGuard.instance.takeDegradedNotice(), isNull);
      }
    });

    test('probe exposes libVersion and sourceId for logs', () {
      final probe = SqliteVersionGuard.instance.probeOnce();
      expect(probe.libVersion, isNotEmpty);
      expect(probe.sourceId, isNotEmpty);
      expect(probe.error, isNull, reason: '本机应能成功探测');
    });
  });

  group('三段式降级的纯逻辑（不依赖真实低版本 DLL）', () {
    /// 用一个假的探测结果直接驱动降级态语义，避免为了测试去装旧 DLL。
    test('SqliteProbe.isWritable is false for tooOld/unavailable', () {
      const tooOld = SqliteProbe(
        state: SqliteSupportState.tooOld,
        versionNumber: 3034999,
        libVersion: '3.34.9',
        sourceId: 'fake',
      );
      const unavailable = SqliteProbe(
        state: SqliteSupportState.unavailable,
        versionNumber: 0,
        libVersion: '',
        sourceId: '',
      );
      const supported = SqliteProbe(
        state: SqliteSupportState.supported,
        versionNumber: 3035000,
        libVersion: '3.35.0',
        sourceId: 'fake',
      );
      expect(tooOld.isWritable, isFalse, reason: '① 禁写');
      expect(unavailable.isWritable, isFalse);
      expect(supported.isWritable, isTrue);
    });

    test(
      'the notice says "limited", never "failed to start", and fires once',
      () {
        // 注入一个「版本过旧」的探测结果，真实驱动降级态（不需要装旧 DLL）。
        SqliteVersionGuard.instance.debugSetProbeForTest(
          const SqliteProbe(
            state: SqliteSupportState.tooOld,
            versionNumber: 3034999,
            libVersion: '3.34.9',
            sourceId: 'fake',
          ),
        );
        expect(SqliteVersionGuard.instance.canWrite, isFalse, reason: '① 禁写');
        final notice = SqliteVersionGuard.instance.takeDegradedNotice();
        expect(notice, isNotNull, reason: '② 一次性提示');
        // 硬约束（Spec §6）：点明「功能受限」，不得说成「启动失败」。
        expect(notice, contains('受限'));
        expect(notice, isNot(contains('启动失败')));
        expect(notice, isNot(contains('无法启动')));
        expect(notice, contains('只读'));
        // 同一进程只提示一次。
        expect(
          SqliteVersionGuard.instance.takeDegradedNotice(),
          isNull,
          reason: '同一进程只提示一次',
        );
      },
    );

    test('unavailable state also degrades and notifies once', () {
      SqliteVersionGuard.instance.debugSetProbeForTest(
        const SqliteProbe(
          state: SqliteSupportState.unavailable,
          versionNumber: 0,
          libVersion: '',
          sourceId: '',
        ),
      );
      expect(SqliteVersionGuard.instance.canWrite, isFalse);
      expect(SqliteVersionGuard.instance.takeDegradedNotice(), isNotNull);
      expect(SqliteVersionGuard.instance.takeDegradedNotice(), isNull);
    });

    test('supported state never produces a notice', () {
      SqliteVersionGuard.instance.debugSetProbeForTest(
        const SqliteProbe(
          state: SqliteSupportState.supported,
          versionNumber: 3035000,
          libVersion: '3.35.0',
          sourceId: 'fake',
        ),
      );
      expect(SqliteVersionGuard.instance.canWrite, isTrue);
      expect(SqliteVersionGuard.instance.takeDegradedNotice(), isNull);
    });
  });
}
