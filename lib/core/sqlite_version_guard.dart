import 'package:pure_music/core/utils.dart';
import 'package:sqlite3/sqlite3.dart';

/// `winsqlite3.dll` 的版本下限：`3.35.0`。
///
/// 依据（仓库已在用的语法）：`RETURNING`（`playlist.dart`、`online_library_repository.dart`）
/// 与 `ALTER TABLE … DROP COLUMN`（`database.dart`）都需要 3.35；UPSERT 只要 3.24，
/// 因此下限由前两者唯一确定。
const int minimumSupportedSqliteVersion = 3035000;

/// 纯谓词：给定 `sqlite3_libversion_number()` 式的整数版本，是否达到下限。
///
/// 单独抽出来是为了让边界值（3034999 拒 / 3035000 收）可以在不加载任何
/// 原生库的情况下被测试固定。
bool isSupportedSqliteVersion(int versionNumber) =>
    versionNumber >= minimumSupportedSqliteVersion;

/// 进程内一次性探测结果。
///
/// 三种状态：
/// - [SqliteSupportState.supported]：版本达标，按原有行为读写；
/// - [SqliteSupportState.tooOld]：版本低于下限 ⇒ **禁写**（不迁移、不改 schema、
///   播放历史停写），曲库走 `index.json` 回退，封面走解码回退；
/// - [SqliteSupportState.unavailable]：探测本身失败（例如系统缺 `winsqlite3.dll`）
///   ⇒ 与 [SqliteSupportState.tooOld] 同样禁写，只是提示里的原因不同。
enum SqliteSupportState { supported, tooOld, unavailable }

/// 一次探测的产物：状态 + 供日志记录的版本信息。
class SqliteProbe {
  const SqliteProbe({
    required this.state,
    required this.versionNumber,
    required this.libVersion,
    required this.sourceId,
    this.error,
  });

  final SqliteSupportState state;
  final int versionNumber;
  final String libVersion;
  final String sourceId;
  final Object? error;

  bool get isWritable => state == SqliteSupportState.supported;
}

/// 版本守护：**首次**打开任何 SQLite 连接之前探测一次，结果在进程内复用。
///
/// 不做自愈、不尝试重载 DLL——探测只能判定，不能修复（这是本 Spec 已接受的
/// 残余风险）。真正的好处是把「未知」变成「可判定」：不足时明确进入
/// 禁写 + 一次性提示 + JSON 回退，而不是在某个 `RETURNING` 语句上崩掉。
class SqliteVersionGuard {
  SqliteVersionGuard._();

  static final SqliteVersionGuard instance = SqliteVersionGuard._();

  SqliteProbe? _probe;
  bool _noticeShown = false;

  /// 已探测结果；未探测时为 `null`。
  SqliteProbe? get probe => _probe;

  /// 是否允许写库。**未探测时按允许处理**，避免把「还没走到探测点」
  /// 误判成降级态。
  bool get canWrite => _probe?.isWritable ?? true;

  /// 探测一次并缓存结果（幂等）。
  SqliteProbe probeOnce() {
    final cached = _probe;
    if (cached != null) return cached;
    late final SqliteProbe result;
    try {
      final version = sqlite3.version;
      result = SqliteProbe(
        state: isSupportedSqliteVersion(version.versionNumber)
            ? SqliteSupportState.supported
            : SqliteSupportState.tooOld,
        versionNumber: version.versionNumber,
        libVersion: version.libVersion,
        sourceId: version.sourceId,
      );
    } catch (err, trace) {
      result = SqliteProbe(
        state: SqliteSupportState.unavailable,
        versionNumber: 0,
        libVersion: '',
        sourceId: '',
        error: err,
      );
      logger.e('SQLite 版本探测失败', error: err, stackTrace: trace);
    }
    _probe = result;
    // libVersion / sourceId 必须进日志：没有这两项，现场无法判断用户到底
    // 装的是哪个 SQLite（诊断凭据）。
    logger.i(
      '[sqlite] libVersion=${result.libVersion} '
      'number=${result.versionNumber} '
      'sourceId=${result.sourceId} '
      'minimum=$minimumSupportedSqliteVersion '
      'state=${result.state.name}',
    );
    return result;
  }

  /// 需要提示时的文案；同一进程只返回一次（`null` 表示不再提示）。
  ///
  /// 硬约束（Spec §6）：必须点明「功能受限」而不是「启动失败」，并且
  /// **不得吞掉日志**——文案只用来说明,具体版本信息已经在 [probeOnce] 里记过。
  String? takeDegradedNotice() {
    if (_noticeShown) return null;
    final probe = _probe;
    if (probe == null || probe.isWritable) return null;
    _noticeShown = true;
    return '数据库组件版本过旧，部分功能受限：曲库与播放统计本次以只读方式运行，'
        '播放次数暂不记录。详情见日志。';
  }

  /// 仅供测试复位（生产路径不调用）。
  void resetForTest() {
    _probe = null;
    _noticeShown = false;
  }

  /// 仅供测试注入探测结果：让降级态的三段式语义可以在**不装旧 DLL** 的
  /// 前提下被真实驱动（否则文案与一次性提示都只能靠静态断言）。
  void debugSetProbeForTest(SqliteProbe probe) {
    _probe = probe;
    _noticeShown = false;
  }
}
