import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:pure_music/core/preference.dart';
import 'package:pure_music/core/settings.dart';
import 'package:pure_music/services/music_platform/declarative/declarative_errors.dart';
import 'package:pure_music/services/music_platform/declarative/declarative_execution.dart';
import 'package:pure_music/services/music_platform/declarative/declarative_http_transport.dart';
import 'package:pure_music/services/music_platform/declarative/declarative_request_builder.dart';
import 'package:pure_music/services/music_platform/declarative/declarative_response_mapper.dart';
import 'package:pure_music/services/music_platform/declarative/declarative_verification.dart';
import 'package:pure_music/services/music_platform/declarative/declarative_probe_inputs.dart';
import 'package:pure_music/services/music_platform/declarative/provider_probe.dart';
import 'package:pure_music/services/music_platform/models/music_models.dart';
import 'package:pure_music/services/music_platform/online_music_credentials.dart';
import 'package:pure_music/services/music_platform/online_music_error.dart';
import 'package:pure_music/services/music_platform/online_music_request.dart';
import 'package:pure_music/services/music_platform/provider/online_music_binding.dart';
import 'package:pure_music/services/music_platform/provider/online_music_capability.dart';
import 'package:pure_music/services/music_platform/provider/online_music_header_migration.dart';
import 'package:pure_music/services/music_platform/provider/online_music_probe_candidates.dart';
import 'package:pure_music/services/music_platform/provider/online_music_provider_credentials.dart';
import 'package:pure_music/services/music_platform/provider/online_music_provider_settings.dart';

/// 试跑失败的**大类**（W5 / Spec §19.5）。
///
/// 用户口径：错误必须能区分"网络 / HTTP / 认证 / 业务 / 响应格式 / 映射失败"——
/// 否则看到一句"试跑失败"根本不知道该去改哪里。
enum DeclarativeTestFailureKind {
  /// 请求没发出去或连不上：网络、超时、DNS、TLS。
  network,

  /// 拿到了 HTTP 响应但状态码不是成功（不含 401/403）。
  http,

  /// 401 / 403：认证或权限问题（凭据不对 / 没有权限）。
  authentication,

  /// HTTP 成功但业务判定不通过（业务 code / msg 表示失败）。
  business,

  /// 响应不是可读 JSON / 无法判定业务语义：接口定义与响应不匹配。
  responseFormat,

  /// 成功判定通过、但字段映射失败（缺必填字段、路径取不到值）。
  mapping,

  /// 配置不完整，请求根本没构造出来（缺路径、缺必填参数）。
  config,
}

/// 空结果的**统一措辞**（F3-S6 / D-F3-3）。
///
/// 既说明"响应有效但没有可验证的数据"，也**保留**"可能是合法空结果"这一合法性说明
/// （空歌单、空榜单、纯音乐没有歌词都是正常的），并给出"也可能是列表路径 / 字段映射
/// 配置有误"的方向 —— 但**不武断**地断言"配置错误"：
/// 这次试跑拿到的证据不足以区分这两者，所以结论只能是"未能确认"。
String declarativeEmptyResultNote(String what) =>
    '响应有效，但$what —— 没有可验证的数据：可能是合法空结果，'
    '也可能是列表路径 / 字段映射配置有误；这次无法确认该能力可用';

/// 试跑失败大类的界面文案。
String declarativeTestFailureLabel(DeclarativeTestFailureKind kind) =>
    switch (kind) {
      DeclarativeTestFailureKind.network => '网络',
      DeclarativeTestFailureKind.http => 'HTTP',
      DeclarativeTestFailureKind.authentication => '认证',
      DeclarativeTestFailureKind.business => '业务',
      DeclarativeTestFailureKind.responseFormat => '响应格式',
      DeclarativeTestFailureKind.mapping => '映射失败',
      DeclarativeTestFailureKind.config => '配置',
    };

/// 单项试跑的结果：给界面同时看"HTTP 层发生了什么"和"映射成了什么"。
final class DeclarativeCapabilityTestResult {
  const DeclarativeCapabilityTestResult({
    required this.ok,
    this.explicitConfidence,
    this.statusCode,
    this.mappedSummary,
    this.failureReason,
    this.failureKind,
    this.responsePreview,
    this.requestSummary,
  });

  final bool ok;

  /// 显式的可信度结论（F3-S6 / D-F3-3）；为 null 时按 [ok] 推得。
  ///
  /// "**未能确认**"（请求完成但结果为空/证据不足）必须**显式**给出 ——
  /// 它既不是成功（空结果什么也没证明）也不是失败（可能只是合法空结果），
  /// 靠 `ok` 猜不出来。
  final DeclarativeVerificationConfidence? explicitConfidence;

  /// 这次试跑的**结论可信度**（D-F3-3 的三态）。
  DeclarativeVerificationConfidence get confidence =>
      explicitConfidence ??
      (ok
          ? DeclarativeVerificationConfidence.verified
          : DeclarativeVerificationConfidence.failed);

  final int? statusCode;

  /// 映射结果的**非敏感**摘要（例如「1 首曲目 / 第 1 首：海阔天空」）。
  final String? mappedSummary;

  final String? failureReason;

  /// 失败的大类；成功时为 null（W5）。
  final DeclarativeTestFailureKind? failureKind;

  /// 截断并脱敏后的响应片段，供用户判断字段名是否对得上。
  final String? responsePreview;

  /// 实际发出的请求摘要（方法 + 路径 + 参数名与值，敏感值脱敏）。
  ///
  /// 未知服务无法自动探测时，"到底发了什么请求"是用户唯一的排查依据，
  /// 因此失败时也要带上它。凭据类参数与请求头一律 `[redacted]`。
  final String? requestSummary;

  /// 补上请求摘要（结果是在不知道摘要的地方构造的）。
  DeclarativeCapabilityTestResult withRequestSummary(String? summary) {
    if (summary == null || requestSummary != null) return this;
    return DeclarativeCapabilityTestResult(
      ok: ok,
      explicitConfidence: explicitConfidence,
      statusCode: statusCode,
      mappedSummary: mappedSummary,
      failureReason: failureReason,
      failureKind: failureKind,
      responsePreview: responsePreview,
      requestSummary: summary,
    );
  }
}

/// 统一分类 → **试跑界面的展示大类**（P-16；这是唯一的投影表）。
///
/// 试跑的词表比运行期更粗（Spec §19.5 的用户口径：网络 / HTTP / 认证 / 业务 /
/// 响应格式 / 映射失败），但它必须是 [OnlineMusicErrorKind] 的**纯函数** ——
/// 否则同一个失败会出现"运行期说 X、试跑说 Y"（P-16 的原始症状）。
DeclarativeTestFailureKind declarativeTestFailureKindFor(
  OnlineMusicErrorKind kind,
) => switch (kind) {
  OnlineMusicErrorKind.network ||
  OnlineMusicErrorKind.cancelled => DeclarativeTestFailureKind.network,
  OnlineMusicErrorKind.notConfigured ||
  OnlineMusicErrorKind.forbidden => DeclarativeTestFailureKind.authentication,
  OnlineMusicErrorKind.businessFailure => DeclarativeTestFailureKind.business,
  OnlineMusicErrorKind.endpointMismatch ||
  OnlineMusicErrorKind.invalidResponse =>
    DeclarativeTestFailureKind.responseFormat,
  OnlineMusicErrorKind.badRequest ||
  OnlineMusicErrorKind.notFound ||
  OnlineMusicErrorKind.quotaExhausted ||
  OnlineMusicErrorKind.rateLimited ||
  OnlineMusicErrorKind.unavailable ||
  OnlineMusicErrorKind.unknown => DeclarativeTestFailureKind.http,
};

/// 成功判定不通过时的**大类**（W5）。
///
/// 分类本身住在**共享引擎**里（`declarative_execution.dart` 的
/// [classifyDeclarativeUnsuccessfulResponse]），这里只是把它投影成**界面词表** ——
/// 词表更粗（Spec §19.5 的用户口径），但必须是同一个结论的纯函数，
/// 否则同一个失败会出现"运行期说 X、试跑说 Y"（P-16 的原始症状）。
DeclarativeTestFailureKind classifyUnsuccessfulTestResponse(
  int statusCode,
  Object? body,
) => declarativeTestFailureKindFor(
  classifyDeclarativeUnsuccessfulResponse(statusCode, body),
);

/// 敏感**参数名 / 请求头名 / JSON 键名**与请求摘要、响应片段的脱敏实现已移到
/// **声明式层**（`declarative/declarative_diagnostics.dart`）—— 探测与试跑共用同一套，
/// 避免出现第二份脱敏实现（漏一处就等于泄漏）。这里的旧定义已删除。
///
/// 探测/试跑用的传输层工厂；默认按条目 baseUrl 建一个**不跟随重定向**的 Dio。
typedef DeclarativeProbeTransportFactory =
    DeclarativeHttpTransport Function(OnlineMusicProviderDefinition definition);

/// F5（P-28）：探测/试跑**默认路径**里 Dio 的创建口。
///
/// 存在的唯一理由是**可观测**：注入一个计数用的 Dio，就能断言
/// "默认路径创建的 Dio 在成功与异常退出时都被释放"（旧实现每次新建且从不关闭）。
typedef DeclarativeProbeDioFactory =
    Dio Function(OnlineMusicProviderDefinition definition);

/// 单项试跑播放解析时的默认音质（与内置实现的默认档位一致）。
const defaultDeclarativeTestQuality = 'lossless';

/// 已保存配置的读写出口。
abstract interface class OnlineMusicSettingsStore {
  OnlineMusicSettings read();

  /// 返回是否成功落盘。
  Future<bool> write(OnlineMusicSettings settings);
}

/// 落地到 `app_preference.json` 的 `onlineMusic` 键。
final class AppPreferenceOnlineMusicSettingsStore
    implements OnlineMusicSettingsStore {
  const AppPreferenceOnlineMusicSettingsStore();

  @override
  OnlineMusicSettings read() => AppPreference.instance.onlineMusicSettings;

  @override
  Future<bool> write(OnlineMusicSettings settings) async {
    final preference = AppPreference.instance;
    final previous = preference.onlineMusicSettings;
    final wasDirty = preference.onlineMusicSettingsDirty;
    preference.setOnlineMusicSettings(settings);
    final saved = await preference.save();
    if (!saved) {
      preference.restoreOnlineMusicSettings(previous, dirty: wasDirty);
    }
    return saved;
  }
}

/// 设置页「在线音乐」的数据入口。
///
/// - [settings] 是当前**已保存**的配置，界面在它上面编辑；
/// - [activeSettings] 是当前进程内**正在生效**的配置（启动时组装 Provider 用的那份），
///   两者不同即表示需要重启才会生效；
/// - 凭据按引用读写，所以新增条目无需重启就能先配好 Key。
final class OnlineMusicProviderSettingsController extends ChangeNotifier {
  OnlineMusicProviderSettingsController({
    required OnlineMusicSettings activeSettings,
    required OnlineMusicSettingsStore store,
    required OnlineMusicCredentialAccess fallbackCredentials,
    Map<String, OnlineMusicCredentialController> runningCredentials = const {},
    DeclarativeProbeTransportFactory? probeTransportFactory,
    DeclarativeProbeDioFactory? probeDioFactory,
    OnlineMusicCredentialReader? credentialReader,
    this.isPortableBuild = portableBuild,
  }) : _activeSettings = activeSettings,
       _store = store,
       _fallbackCredentials = fallbackCredentials,
       _runningCredentials = Map.unmodifiable(runningCredentials),
       _probeTransportFactory = probeTransportFactory,
       _probeDioFactory = probeDioFactory,
       _credentialReader = credentialReader,
       _settings = store.read();

  final OnlineMusicSettings _activeSettings;
  final OnlineMusicSettingsStore _store;
  final OnlineMusicCredentialAccess _fallbackCredentials;
  final Map<String, OnlineMusicCredentialController> _runningCredentials;
  final DeclarativeProbeTransportFactory? _probeTransportFactory;
  final DeclarativeProbeDioFactory? _probeDioFactory;

  /// 探测/试跑时需要凭据值（界面层拿不到），因此单独注入一个读取口。
  final OnlineMusicCredentialReader? _credentialReader;

  /// 是否便携版构建（决定"能否安全持久保存秘密"，F0-5 / §11.2）。
  final bool isPortableBuild;

  OnlineMusicSettings _settings;
  bool _disposed = false;

  OnlineMusicSettings get settings => _settings;

  OnlineMusicSettings get activeSettings => _activeSettings;

  /// 是否有尚未生效（需要重启）的改动。
  bool get hasPendingRestart => _settings != _activeSettings;

  /// 该条目是否有尚未生效的改动（P-04：把"待重启"从**整页布尔**下沉为**逐项**）。
  ///
  /// 判据是"已保存配置"与"运行中配置"在该条目上的差异：新增 / 删除 / 任何字段变化
  /// 都算；用户把它改回去（与运行中一致）就自动恢复为"已生效"。
  bool providerNeedsRestart(String providerId) =>
      _settings.providerById(providerId) !=
      _activeSettings.providerById(providerId);

  /// 该 (平台, 能力) 的候选来源是否有尚未生效的改动。
  ///
  /// 要比**两件事**，缺一不可：
  /// - **可选项清单**（`capableProviderIdsFor`）：新增/删除条目会改变它，
  ///   而"自动"就是按这个顺序走的；
  /// - **显式选择**（`explicitCandidateIdsFor`）：用户指定/清除来源时变的是它。
  ///
  /// （只比"可选项"会漏掉用户的指定；只比"显式选择"会漏掉"新增条目导致自动目标变化"。）
  bool capabilityNeedsRestart(
    MusicPlatform platform,
    OnlineMusicCapability capability,
  ) {
    if (!_sameIds(
      _settings.capableProviderIdsFor(platform, capability),
      _activeSettings.capableProviderIdsFor(platform, capability),
    )) {
      return true;
    }
    return !_sameIds(
      _settings.explicitCandidateIdsFor(platform, capability),
      _activeSettings.explicitCandidateIdsFor(platform, capability),
    );
  }

  /// 两个有序 id 列表是否相同（P-04：逐项差异的判据）。
  static bool _sameIds(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var index = 0; index < a.length; index++) {
      if (a[index] != b[index]) return false;
    }
    return true;
  }

  /// 该平台是否有尚未生效的改动（启用状态，或任一能力的候选）。
  bool platformNeedsRestart(MusicPlatform platform) {
    if (_settings.isPlatformEnabled(platform) !=
        _activeSettings.isPlatformEnabled(platform)) {
      return true;
    }
    for (final capability in OnlineMusicCapability.values) {
      if (capabilityNeedsRestart(platform, capability)) return true;
    }
    return false;
  }

  String get credentialDisplayName =>
      _fallbackCredentials.credentialDisplayName;

  String get credentialHint => _fallbackCredentials.inputHint;

  bool isCredentialFormatValid(String value) =>
      _fallbackCredentials.isValidFormat(value);

  Set<String> get providerIds => _settings.providerIds;

  /// 已进入运行时的条目用运行中的凭据入口（保留其取消/配额语义），
  /// 新增条目回落到按引用访问。
  ///
  /// 只有「启动时就需要凭据、且槽位未被改动」的条目才能复用运行中的入口：
  /// 否则运行中的 Provider 根本没有凭据源，复用它会让保存报出
  /// 「当前在线音乐服务不需要 API Key」这种自相矛盾的错误。
  OnlineMusicCredentialController? _runningFor(
    OnlineMusicProviderDefinition definition,
  ) {
    final running = _runningCredentials[definition.id];
    if (running == null) return null;
    final active = _activeSettings.providerById(definition.id);
    if (active == null || !active.requiresCredential) return null;
    if (active.credentialReference != definition.credentialReference) {
      return null;
    }
    return running;
  }

  /// 写入一次配置改动；落盘失败时把界面状态回滚为改动前的值。
  Future<bool> apply(OnlineMusicSettings next) async {
    if (next == _settings) return true;
    final previous = _settings;
    _settings = next;
    _notify();
    final saved = await _store.write(next);
    if (!saved && !_disposed) {
      _settings = previous;
      _notify();
    }
    return saved;
  }

  Future<bool> addProvider(OnlineMusicProviderDefinition provider) =>
      apply(_settings.withAddedProvider(provider));

  Future<bool> updateProvider(OnlineMusicProviderDefinition provider) =>
      apply(_settings.withUpdatedProvider(provider));

  Future<bool> removeProvider(String providerId) =>
      apply(_settings.withoutProvider(providerId));

  Future<bool> assignCapability(
    OnlineMusicCapability capability,
    String providerId,
  ) => apply(_settings.withCapabilityProvider(capability, providerId));

  Future<bool> setDefaultProvider(String providerId) =>
      apply(_settings.withDefaultProvider(providerId));

  /// 平台卡上的启用开关（D8:A）。
  Future<bool> setPlatformEnabled(
    MusicPlatform platform, {
    required bool enabled,
  }) => apply(_settings.withPlatformEnabled(platform, enabled: enabled));

  /// 平台卡上为某个能力指定的条目；[providerId] 为 null 表示回到"自动"
  /// （清除该 `(platform, capability)` 的显式候选）。
  Future<bool> assignPlatformCapability(
    MusicPlatform platform,
    OnlineMusicCapability capability,
    String? providerId,
  ) => apply(
    _settings.withRoutingCandidates(
      platform,
      capability,
      providerId == null ? const [] : [providerId],
    ),
  );

  Future<bool> isCredentialConfigured(
    OnlineMusicProviderDefinition definition,
  ) async {
    // 槽位可能被保留着以备再次打开认证，但「当前不需要凭据」的条目不算已配置。
    if (!definition.requiresCredential) return false;
    final running = _runningFor(definition);
    if (running != null) return running.isConfigured();
    final reference = definition.credentialReference;
    if (reference == null) return false;
    return _fallbackCredentials.isConfigured(reference);
  }

  Future<void> saveCredential(
    OnlineMusicProviderDefinition definition,
    String value,
  ) async {
    if (!definition.requiresCredential) {
      throw const FormatException('该 Provider 不需要 API Key');
    }
    final running = _runningFor(definition);
    if (running != null) return running.saveCredential(value);
    final reference = definition.credentialReference;
    if (reference == null) {
      throw const FormatException('该 Provider 没有凭据槽位');
    }
    return _fallbackCredentials.save(reference, value);
  }

  Future<void> clearCredential(OnlineMusicProviderDefinition definition) {
    if (!definition.requiresCredential) return Future<void>.value();
    final running = _runningFor(definition);
    if (running != null) return running.clearCredential();
    final reference = definition.credentialReference;
    if (reference == null) return Future<void>.value();
    return _fallbackCredentials.clear(reference);
  }

  /// **逐请求头引用**的凭据是否已配置（F0-4）。
  ///
  /// 与条目级 API Key 共用同一个凭据出口：main 里注入的就是运行时装配用的那一个，
  /// 因此在设置页写入后，运行中的 Provider 立刻读得到（不需要重启）。
  Future<bool> isReferencedCredentialConfigured(String reference) =>
      _fallbackCredentials.isConfigured(reference);

  /// 把凭据值写进指定槽位（F0-4）。
  ///
  /// 这里是**用户主动更新**，属于合法轮换 ⇒ 允许覆盖既有值
  /// （Spec §11.3 的"不得覆盖"只约束**迁移路径**）。
  Future<void> saveReferencedCredential(String reference, String value) =>
      _fallbackCredentials.save(reference, value);

  /// F0-5：**只识别**当前已保存配置里的敏感请求头（三态清单，不写任何东西）。
  List<OnlineMusicHeaderFinding> identifySensitiveHeaders() =>
      _credentialProviderMigration()?.identify() ?? const [];

  /// F0-5：执行迁移。
  ///
  /// 返回 `null` 表示**前置条件不成立**（没有凭据读取口 ⇒ 无法做"写后立即回读校验"）：
  /// 宁可不迁移，也不要写进去没法验证。
  Future<OnlineMusicHeaderMigrationReport?> migrateSensitiveHeaders() async {
    final migration = _credentialProviderMigration();
    if (migration == null) return null;
    final report = await migration.run();
    // 迁移成功后 _settings 必须跟着走（迁移自己已经落盘）。
    if (report.settings != _settings && !_disposed) {
      _settings = report.settings;
      _notify();
    }
    return report;
  }

  /// 迁移用的协作对象；缺少读取口时返回 null（fail-closed）。
  OnlineMusicHeaderMigration? _credentialProviderMigration() {
    final reader = _credentialReader;
    if (reader == null) return null;
    return OnlineMusicHeaderMigration(
      settings: _settings,
      store: _store,
      access: _fallbackCredentials,
      reader: reader,
      portableBuild: isPortableBuild,
    );
  }

  /// 探测该条目的 search 能力（Spec §4 的 P1–P10）。
  ///
  /// 已经配置好的凭据会被使用；没有凭据也照样探测（记「需要认证」）。
  Future<ProviderProbeReport> probeSearch(
    OnlineMusicProviderDefinition definition, {
    OnlineMusicCancelToken? cancelToken,

    /// F3-2：**按能力定义的探测输入**（默认值时保持"一键探测"不变）。
    DeclarativeProbeInputs inputs = const DeclarativeProbeInputs(),
  }) async {
    final baseUrlIssue = definition.baseUrlIssue;
    if (baseUrlIssue != null) {
      // F0-3：服务地址是显式提供的非法值 ⇒ **一个请求都不发**。
      // 探测会试多个候选路径，必须在这里整体拦下；且不能报成"候选都没通过"。
      return ProviderProbeReport(
        outcomes: const [],
        blockedReason: '服务地址无效：$baseUrlIssue（不会回落到默认地址，也不会发出请求）',
      );
    }
    // F3-S3（P-05 / P-27 / D-F3-1 / D-F3-5）：候选**优先取条目自身的声明式绑定**
    // （服务级：先 search，再其它可探测能力）；只有条目完全没有绑定时才用兼容模板，
    // 并在结果里标注来源。条目有绑定却配坏了时**绝不**退回模板（那会掩盖配置问题）。
    final candidates = probeCandidatesFor(definition);
    if (candidates.isEmpty) {
      // D-F3-5 第 6 条：没有候选就**如实报告"未尝试"**，不构造虚假的成功结果，
      // 也不谎称"候选都没通过"（那意味着我们试过了）。
      return ProviderProbeReport(
        outcomes: const [],
        blockedReason: noProbeCandidateReason(definition),
      );
    }
    // F5（P-28）：默认路径创建的 Dio 用完即释放（成功与异常都释放）。
    return _withTransport(
      definition,
      (transport) async => probeDeclarativeSearch(
        transport: transport,
        // F3-S1：探测与试跑**共用**同一条执行路径（含敏感请求头凭据读取）。
        headerCredentialReader: _headerCredentialReader,
        platform: definition.contentPlatform,
        candidates: candidates,
        credential: await _readCredential(definition),
        cancelToken: cancelToken,
        inputs: inputs,
      ),
    );
  }

  /// 单项试跑：只跑这一个能力，把 HTTP 结果与映射结果一起回报。
  Future<DeclarativeCapabilityTestResult> testCapability(
    OnlineMusicProviderDefinition definition,
    OnlineMusicCapability capability, {
    String? keyword,

    /// P-49：试跑的"每页数量"由调用方给（默认值与探测一致，默认行为不变）。
    int? limit,
    String? trackId,
    String? playlistId,
    String quality = defaultDeclarativeTestQuality,
    OnlineMusicCancelToken? cancelToken,
  }) async {
    final binding = definition.bindingFor(capability);
    if (binding is! OnlineMusicDeclarativeCapabilityBinding) {
      return const DeclarativeCapabilityTestResult(
        ok: false,
        failureReason: '该能力不是声明式配置（内置实现，或尚未配置）',
        failureKind: DeclarativeTestFailureKind.config,
      );
    }
    final baseUrlIssue = definition.baseUrlIssue;
    if (baseUrlIssue != null) {
      // F0-3：发请求前的**防御性再校验**。保存时已经拦过一次，但配置文件是
      // 可以被手工编辑的，这里再拦一次才能保证"非法地址一个请求都不发"。
      return DeclarativeCapabilityTestResult(
        ok: false,
        failureReason: '服务地址无效：$baseUrlIssue（不会回落到默认地址，也不会发出请求）',
        failureKind: DeclarativeTestFailureKind.config,
      );
    }
    if (capability == OnlineMusicCapability.stream &&
        (trackId == null || trackId.trim().isEmpty)) {
      return const DeclarativeCapabilityTestResult(
        ok: false,
        failureReason: '试跑播放解析需要先填一个曲目 ID',
        failureKind: DeclarativeTestFailureKind.config,
      );
    }
    if (capability == OnlineMusicCapability.lyric &&
        (trackId == null || trackId.trim().isEmpty)) {
      return const DeclarativeCapabilityTestResult(
        ok: false,
        failureReason: '试跑歌词需要先填一个曲目 ID',
        failureKind: DeclarativeTestFailureKind.config,
      );
    }
    // 试跑面板只有一个 ID 输入框（一次只编辑一个能力）：playlist 用它当歌单 ID，
    // stream / lyric 用它当曲目 ID；程序化调用仍可显式传 playlistId。
    final effectivePlaylistId = playlistId ?? trackId;
    if (capability == OnlineMusicCapability.playlist &&
        (effectivePlaylistId == null || effectivePlaylistId.trim().isEmpty)) {
      return const DeclarativeCapabilityTestResult(
        ok: false,
        failureReason: '试跑歌单详情需要先填一个歌单 ID',
        failureKind: DeclarativeTestFailureKind.config,
      );
    }

    // P-30（Spec D4:A）：**不支持的字段转换必须在保存或试跑时明确报错**，
    // 不得放行之后在映射层静默返回 null。保存路径早就有这道闸门，试跑以前**没有** ——
    // 于是"校验放行、映射恒 null"的配置在这里照样报**成功**（字段其实一个都没读出来）。
    final configIssues = binding.validationIssues(capability);
    if (configIssues.isNotEmpty) {
      return DeclarativeCapabilityTestResult(
        ok: false,
        failureReason: configIssues.join('\n'),
        failureKind: DeclarativeTestFailureKind.config,
      );
    }

    // P-54：条目级/能力级认证的矛盾 —— 与**运行期同一文案、同一结论**，
    // 而且**不发请求**。此前试跑会读到凭据并报成功，运行期却 missingCredential。
    final authIssue = declarativeAuthConfigIssue(
      auth: binding.request.auth,
      hasCredentialReference: declarativeCredentialAvailable(
        requiresCredential: definition.requiresCredential,
        credentialReference: definition.credentialReference,
      ),
    );
    if (authIssue != null) {
      return DeclarativeCapabilityTestResult(
        ok: false,
        failureReason: authIssue,
        failureKind: DeclarativeTestFailureKind.config,
      );
    }

    // P-49：没给就用既有默认值（默认行为不变）。
    final effectiveKeyword = keyword ?? providerProbeKeyword;
    final effectiveLimit = limit ?? providerProbeLimit;
    final token = cancelToken ?? OnlineMusicCancelToken();
    // F3-S1（P-07）：探测与试跑**共用同一个执行引擎** ——
    // 构造请求（含敏感请求头凭据）→ 发送 → 成功判定 → **唯一分类表** → 脱敏诊断。
    // 试跑只保留"自己的那一半"：按能力做字段映射。
    // 这样同一个响应在探测与试跑里不可能再得到两个结论（审计的"第四处分类"已删除）。
    final execution = await _withTransport(
      definition,
      (transport) async => executeDeclarativeRequest(
        spec: binding.request,
        success: binding.response.success,
        inputs: DeclarativeInputs(
          keyword: effectiveKeyword,
          limit: effectiveLimit,
          offset: 0,
          page: 1,
          trackId: trackId,
          playlistId: effectivePlaylistId,
          quality: quality,
        ),
        transport: transport,
        headerCredentialReader: _headerCredentialReader,
        credential: await _readCredential(definition),
        cancelToken: token,
      ),
    );
    final requestSummary = execution.requestSummary;
    if (execution.stage == DeclarativeExecutionStage.notSent) {
      // 凭据读取失败 / 请求构造失败：都是**配置**问题，而且**一个请求都没发**。
      return DeclarativeCapabilityTestResult(
        ok: false,
        failureReason: execution.failureReason,
        failureKind: DeclarativeTestFailureKind.config,
        requestSummary: requestSummary,
      );
    }
    if (!execution.isSuccess) {
      return DeclarativeCapabilityTestResult(
        ok: false,
        statusCode: execution.statusCode,
        responsePreview: execution.responsePreview,
        failureReason: execution.failureReason,
        failureKind: declarativeTestFailureKindFor(execution.failureKind!),
        requestSummary: requestSummary,
      );
    }
    final preview = execution.responsePreview;
    try {
      return _evaluateCapabilityResponse(
        definition: definition,
        capability: capability,
        limit: effectiveLimit,
        binding: binding,
        response: DeclarativeHttpResponse(
          statusCode: execution.statusCode!,
          data: execution.body,
        ),
        preview: preview,
        trackId: trackId,
        requestedPlaylistId: effectivePlaylistId,
        quality: quality,
      ).withRequestSummary(requestSummary);
    } on DeclarativeMappingException catch (error) {
      return DeclarativeCapabilityTestResult(
        ok: false,
        responsePreview: preview,
        failureReason: '映射失败：${error.reason}',
        failureKind: DeclarativeTestFailureKind.mapping,
        requestSummary: requestSummary,
      );
    } catch (_) {
      return DeclarativeCapabilityTestResult(
        ok: false,
        responsePreview: preview,
        // F3-S2（D-F3-4）：这条兜底只覆盖**映射/处理响应**阶段的非预期异常，
        // 它们**不是**网络问题 —— 以前一律写成"网络或服务不可达"是把编程错误
        // 误诊成传输故障。传输异常已经由共享引擎分类（超时/连接/DNS/TLS/取消）。
        failureReason: '处理响应时出现非预期异常（不是网络问题）',
        failureKind: DeclarativeTestFailureKind.http,
        requestSummary: requestSummary,
      );
    }
  }

  /// 对一次成功的 HTTP 往返做"成功判定 + 字段映射"，并在失败时给出大类。
  DeclarativeCapabilityTestResult _evaluateCapabilityResponse({
    required OnlineMusicProviderDefinition definition,
    required OnlineMusicCapability capability,

    /// P-49：映射时用的"每页数量"（与请求里发出去的**同一个**值）。
    required int limit,
    required OnlineMusicDeclarativeCapabilityBinding binding,
    required DeclarativeHttpResponse response,
    required String? preview,
    required String? trackId,
    required String? requestedPlaylistId,
    required String quality,
  }) {
    if (!declarativeResponseIsSuccess(
      spec: binding.response.success,
      statusCode: response.statusCode,
      body: response.data,
    )) {
      return DeclarativeCapabilityTestResult(
        ok: false,
        statusCode: response.statusCode,
        responsePreview: preview,
        failureReason: '成功判定未通过（HTTP ${response.statusCode}）',
        failureKind: classifyUnsuccessfulTestResponse(
          response.statusCode,
          response.data,
        ),
      );
    }

    // F4-S8：响应根本不是 JSON（HTML / 纯文本）时**明确**说清 —— 以前会被笼统报成
    // "字段映射不完整"，把人引去补字段配置，而真正的问题是接口定义与返回不匹配。
    final nonStructured = nonStructuredResponseReason(response.data);
    if (nonStructured != null) {
      return DeclarativeCapabilityTestResult(
        ok: false,
        explicitConfidence: DeclarativeVerificationConfidence.failed,
        statusCode: response.statusCode,
        failureKind: DeclarativeTestFailureKind.responseFormat,
        failureReason: nonStructured,
        responsePreview: preview,
      );
    }

    switch (capability) {
      case OnlineMusicCapability.search:
        {
          final page = mapDeclarativeSearchResponse(
            spec: binding.response,
            body: response.data,
            platform: definition.contentPlatform,
            limit: limit,
            offset: 0,
          );
          final first = page.items.isEmpty ? null : page.items.first.title;
          return DeclarativeCapabilityTestResult(
            ok: page.items.isNotEmpty,
            statusCode: response.statusCode,
            responsePreview: preview,
            mappedSummary: page.items.isEmpty
                ? '没有可验证的数据（空结果）'
                : '${page.items.length} 首曲目 · 第 1 首：$first',
            explicitConfidence: page.items.isEmpty
                ? DeclarativeVerificationConfidence.unconfirmed
                : null,
            failureReason: page.items.isEmpty
                ? declarativeEmptyResultNote('没有解析出曲目')
                : null,
          );
        }

      case OnlineMusicCapability.playlist:
        {
          // P-01：曲目数组路径**没配**时曲目必然为空 —— 那是"配置缺项"，不是"这个歌单
          // 没有曲目"（**配置错误**与**空结果**必须用不同判据，D-F3-3）。
          // ⚠️ F3-S6 修正：配了列表路径但数组为空，**不再**算"成功"——
          // 合法性说明保留，但结论只能是"未能确认"（见下）。
          if (binding.response.listPath == null) {
            return DeclarativeCapabilityTestResult(
              ok: false,
              statusCode: response.statusCode,
              responsePreview: preview,
              failureReason: '歌单详情没有配置「列表路径」（曲目数组所在位置），因此取不到任何曲目',
              failureKind: DeclarativeTestFailureKind.config,
            );
          }
          final playlist = mapDeclarativePlaylistResponse(
            spec: binding.response,
            body: response.data,
            platform: definition.contentPlatform,
            requestedPlaylistId: requestedPlaylistId!,
          );
          final isEmpty = playlist.tracks.isEmpty;
          return DeclarativeCapabilityTestResult(
            ok: !isEmpty,
            // D-F3-3：空歌单是**合法**的，但它同样**没有证明**这份配置可用
            // ⇒ 结论是"未能确认"，且不给失败大类。
            explicitConfidence: isEmpty
                ? DeclarativeVerificationConfidence.unconfirmed
                : null,
            statusCode: response.statusCode,
            responsePreview: preview,
            mappedSummary: isEmpty
                ? '没有可验证的数据（空结果）'
                : '歌单「${playlist.name}」· ${playlist.tracks.length} 首曲目',
            failureReason: isEmpty
                ? declarativeEmptyResultNote('没有解析出任何曲目')
                : null,
          );
        }

      case OnlineMusicCapability.playlistCollection:
        {
          final playlists = mapDeclarativePlaylistCollectionResponse(
            spec: binding.response,
            body: response.data,
            platform: definition.contentPlatform,
          );
          final first = playlists.isEmpty ? null : playlists.first.name;
          return DeclarativeCapabilityTestResult(
            ok: playlists.isNotEmpty,
            statusCode: response.statusCode,
            responsePreview: preview,
            mappedSummary: playlists.isEmpty
                ? '没有可验证的数据（空结果）'
                : '${playlists.length} 个歌单 · 第一个：$first',
            explicitConfidence: playlists.isEmpty
                ? DeclarativeVerificationConfidence.unconfirmed
                : null,
            failureReason: playlists.isEmpty
                ? declarativeEmptyResultNote('没有解析出歌单')
                : null,
          );
        }

      case OnlineMusicCapability.chartList:
        {
          // 榜单索引与歌单集合同构，试跑用同一个映射（见映射函数的说明）。
          final charts = mapDeclarativePlaylistCollectionResponse(
            spec: binding.response,
            body: response.data,
            platform: definition.contentPlatform,
          );
          final first = charts.isEmpty ? null : charts.first.name;
          return DeclarativeCapabilityTestResult(
            ok: charts.isNotEmpty,
            statusCode: response.statusCode,
            responsePreview: preview,
            mappedSummary: charts.isEmpty
                ? '没有可验证的数据（空结果）'
                : '${charts.length} 个榜单 · 第一个：$first',
            explicitConfidence: charts.isEmpty
                ? DeclarativeVerificationConfidence.unconfirmed
                : null,
            failureReason: charts.isEmpty
                ? declarativeEmptyResultNote('没有解析出榜单')
                : null,
          );
        }

      case OnlineMusicCapability.playlistCategories:
        {
          final categories = mapDeclarativePlaylistCategoriesResponse(
            spec: binding.response,
            body: response.data,
            platform: definition.contentPlatform,
          );
          final first = categories.isEmpty ? null : categories.first.name;
          return DeclarativeCapabilityTestResult(
            ok: categories.isNotEmpty,
            statusCode: response.statusCode,
            responsePreview: preview,
            mappedSummary: categories.isEmpty
                ? '没有可验证的数据（空结果）'
                : '${categories.length} 个分类 · 第一个：$first',
            explicitConfidence: categories.isEmpty
                ? DeclarativeVerificationConfidence.unconfirmed
                : null,
            failureReason: categories.isEmpty
                ? declarativeEmptyResultNote('没有解析出分类')
                : null,
          );
        }

      case OnlineMusicCapability.newSongs:
        {
          // 新歌与搜索同构（都是曲目数组），试跑复用同一个映射。
          final tracks = mapDeclarativeSearchResponse(
            spec: binding.response,
            body: response.data,
            platform: definition.contentPlatform,
            // P-49：以前写死 30，用户给的数量被忽略。
            limit: limit,
            offset: 0,
          ).items;
          final first = tracks.isEmpty ? null : tracks.first.title;
          return DeclarativeCapabilityTestResult(
            ok: tracks.isNotEmpty,
            statusCode: response.statusCode,
            responsePreview: preview,
            mappedSummary: tracks.isEmpty
                ? '没有可验证的数据（空结果）'
                : '${tracks.length} 首曲目 · 第一首：$first',
            explicitConfidence: tracks.isEmpty
                ? DeclarativeVerificationConfidence.unconfirmed
                : null,
            failureReason: tracks.isEmpty
                ? declarativeEmptyResultNote('没有解析出曲目')
                : null,
          );
        }

      case OnlineMusicCapability.lyric:
        {
          final lyrics = mapDeclarativeLyricsResponse(
            spec: binding.response,
            body: response.data,
            ref: PlatformTrackRef(
              platform: definition.contentPlatform,
              trackId: trackId!,
            ),
          );
          // 空歌词**不是失败**：纯音乐/间奏本来就没有歌词，配置可能是对的。
          // ⚠️ F3-S6（D-F3-3）：但"没有歌词"也**不能**证明歌词接口配置正确
          // —— 它同样可能是字段路径配错。因此结论是"未能确认"（既非可用、也非失败），
          // 并在说明里同时保留合法性与"可能是配置问题"两个方向。
          final isEmpty = lyrics.isEmpty;
          return DeclarativeCapabilityTestResult(
            ok: !isEmpty,
            explicitConfidence: isEmpty
                ? DeclarativeVerificationConfidence.unconfirmed
                : null,
            statusCode: response.statusCode,
            responsePreview: preview,
            mappedSummary: isEmpty
                ? '没有可验证的数据（空结果）'
                : '歌词：原文${lyrics.original != null ? '有' : '无'}'
                      '${lyrics.translation != null ? ' · 翻译有' : ''}',
            failureReason: isEmpty
                ? declarativeEmptyResultNote('没有解析出歌词（纯音乐 / 间奏本来就没有歌词）')
                : null,
          );
        }

      case OnlineMusicCapability.stream:
        {
          final stream = mapDeclarativeResolveResponse(
            spec: binding.response,
            body: response.data,
            expectedRef: PlatformTrackRef(
              platform: definition.contentPlatform,
              trackId: trackId!,
            ),
            requestedQuality: quality,
            resolvedAt: DateTime.now(),
          );
          return DeclarativeCapabilityTestResult(
            ok: true,
            statusCode: response.statusCode,
            responsePreview: preview,
            // 只显示主机与路径：签名串留在 query 里，不进界面。
            mappedSummary: '播放地址：${stream.uri.host}${stream.uri.path}',
          );
        }
    }
  }

  /// F5（P-28）**所有权约定**（谁创建、谁拥有、谁释放）：
  ///
  /// - 注入了 `probeTransportFactory` ⇒ 传输由**外部**拥有（可能是共享实例）⇒
  ///   控制器**不关闭任何东西**，绝不无条件关闭别人的资源；
  /// - 否则由本方法**创建** `Dio` ⇒ 由 `_withTransport` 在用完后 `close(force: true)`，
  ///   成功与异常路径都释放。
  ({DeclarativeHttpTransport transport, Dio? ownedDio}) _transportFor(
    OnlineMusicProviderDefinition definition,
  ) {
    final factory = _probeTransportFactory;
    if (factory != null) {
      return (transport: factory(definition), ownedDio: null);
    }
    final dio = (_probeDioFactory ?? _defaultProbeDio)(definition);
    return (
      transport: DioDeclarativeHttpTransport(
        dio: dio,
        // P3：探测/试跑不跟随重定向，避免打到用户没有提供的主机。
        followRedirects: false,
      ),
      // 这个 Dio 是**我们创建的** ⇒ 由本控制器负责释放。
      ownedDio: dio,
    );
  }

  Dio _defaultProbeDio(OnlineMusicProviderDefinition definition) => Dio(
    BaseOptions(
      // 缺失 ⇒ 默认地址；显式提供的非法值根本走不到这里（见上面的两处拦截）。
      baseUrl: definition.effectiveBaseUrl,
      connectTimeout: definition.connectTimeout,
      sendTimeout: definition.sendTimeout,
      receiveTimeout: definition.receiveTimeout,
    ),
  );

  /// 在「用完即释放」的边界内执行探测/试跑（F5-P-28：成功与异常退出都不泄漏）。
  Future<T> _withTransport<T>(
    OnlineMusicProviderDefinition definition,
    Future<T> Function(DeclarativeHttpTransport transport) body,
  ) async {
    final resolved = _transportFor(definition);
    try {
      return await body(resolved.transport);
    } finally {
      // 只释放**自己创建的** Dio；外部注入的传输不归我们管。
      resolved.ownedDio?.close(force: true);
    }
  }

  Future<String?> _readCredential(
    OnlineMusicProviderDefinition definition,
  ) async {
    final reader = _credentialReader;
    final reference = definition.credentialReference;
    // P-54：与**运行期同一口径** —— 装配层只在"需要 Key 且槽位存在"时
    // 才把槽位交给声明式 Provider；试跑不能比运行期多读一次凭据，
    // 否则就会出现"试跑成功、运行期 missingCredential"那种两份说法。
    if (reader == null ||
        !declarativeCredentialAvailable(
          requiresCredential: definition.requiresCredential,
          credentialReference: reference,
        )) {
      return null;
    }
    try {
      return await reader.readCredential(reference!);
    } catch (_) {
      return null;
    }
  }

  /// 逐请求头引入的凭据值要用的读取口。
  ///
  /// 没有注入读取口时回落到"一律读不到"：敏感头会因此报"没有可用凭据"，
  /// 而不是**假装成功**（这类假阳性正是反模式 3）。
  OnlineMusicCredentialReader get _headerCredentialReader =>
      _credentialReader ?? const _UnavailableCredentialReader();

  void _notify() {
    if (_disposed) return;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  @override
  String toString() =>
      'OnlineMusicProviderSettingsController(providers=${providerIds.length}, '
      'pendingRestart=$hasPendingRestart)';
}

/// 没有注入凭据读取口时的占位实现：一律"读不到"。
///
/// 合法的失败，而不是静默通过 —— 敏感请求头缺凭据时**必须**明确报错。
final class _UnavailableCredentialReader
    implements OnlineMusicCredentialReader {
  const _UnavailableCredentialReader();

  @override
  Future<String?> readCredential(String reference) async => null;
}
