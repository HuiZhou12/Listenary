import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:pure_music/core/preference.dart';
import 'package:pure_music/core/settings.dart';
import 'package:pure_music/services/music_platform/declarative/declarative_errors.dart';
import 'package:pure_music/services/music_platform/declarative/declarative_http_transport.dart';
import 'package:pure_music/services/music_platform/declarative/declarative_request_builder.dart';
import 'package:pure_music/services/music_platform/declarative/declarative_response_mapper.dart';
import 'package:pure_music/services/music_platform/declarative/provider_probe.dart';
import 'package:pure_music/services/music_platform/models/music_models.dart';
import 'package:pure_music/services/music_platform/online_music_credentials.dart';
import 'package:pure_music/services/music_platform/online_music_request.dart';
import 'package:pure_music/services/music_platform/provider/online_music_binding.dart';
import 'package:pure_music/services/music_platform/provider/online_music_capability.dart';
import 'package:pure_music/services/music_platform/provider/online_music_header_migration.dart';
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
    this.statusCode,
    this.mappedSummary,
    this.failureReason,
    this.failureKind,
    this.responsePreview,
    this.requestSummary,
  });

  final bool ok;
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
      statusCode: statusCode,
      mappedSummary: mappedSummary,
      failureReason: failureReason,
      failureKind: failureKind,
      responsePreview: responsePreview,
      requestSummary: summary,
    );
  }
}

/// 成功判定不通过时的**大类**（W5）。
///
/// - 401 / 403 → 认证；
/// - 其它 4xx / 5xx → HTTP；
/// - 2xx 但判定不通过：响应是可读的结构（Map/List）⇒ 业务判定问题；
///   连结构都不是（HTML 错误页、纯文本）⇒ 响应格式与接口定义不匹配。
DeclarativeTestFailureKind classifyUnsuccessfulTestResponse(
  int statusCode,
  Object? body,
) {
  if (statusCode == 401 || statusCode == 403) {
    return DeclarativeTestFailureKind.authentication;
  }
  if (statusCode >= 400) return DeclarativeTestFailureKind.http;
  if (body is Map || body is List) return DeclarativeTestFailureKind.business;
  return DeclarativeTestFailureKind.responseFormat;
}

/// 敏感**参数名 / 请求头名 / JSON 键名**：这些名字的取值一律不进界面、不进日志。
///
/// ⚠️ 这只是一个**兜底白名单**（P-35 的教训）：白名单一定会漏（用户可以把认证参数
/// 起成任何名字），所以真正的判据是**值来源** —— 凭据来源的值由
/// [BuiltDeclarativeRequest.credentialHeaderNames] 与
/// [BuiltDeclarativeRequest.credentialQueryNames] 精确标出，
/// 不看名字就一律遮蔽。本名单只用于处理"来源未知"的响应体。
const sensitiveDiagnosticNamePattern =
    r'apikey|api[-_]?key|x-api-key|authorization|proxy-authorization|cookie|'
    r'set-cookie|token|access[-_]?token|refresh[-_]?token|id[-_]?token|x-token|'
    r'secret|appsecret|app[-_]?secret|appkey|app[-_]?key|password|passwd|pwd|'
    r'sign|signature|x-signature|x-sign|auth|key|csrf|xsrf|sid|session|sessionid|'
    r'jwt|qskey|pskey|qm_keyst|credential|h';

bool isSensitiveDiagnosticName(String name) => RegExp(
  '^($sensitiveDiagnosticNamePattern)\$',
  caseSensitive: false,
).hasMatch(name.trim());

/// 试跑结果里展示的**请求摘要**：方法 + 路径 + 参数名与值（敏感值脱敏）。
///
/// 未知服务无法自动探测时，"到底发了什么请求"是唯一的排查依据（W5），
/// 因此这里要把参数名与值都写出来。遮蔽判据有两条，**按来源优先**：
/// 1. 值来自凭据（认证放置 / 敏感请求头的凭据引用）⇒ 一律 `[redacted]`；
/// 2. 名字落在兜底名单里 ⇒ 也 `[redacted]`（覆盖"明文写死在配置里"的旧配置）。
String describeDeclarativeRequest(BuiltDeclarativeRequest request) {
  bool headerIsCredential(String name) =>
      request.credentialHeaderNames.contains(name) ||
      isSensitiveDiagnosticName(name);
  bool queryIsCredential(String name) =>
      request.credentialQueryNames.contains(name) ||
      isSensitiveDiagnosticName(name);

  final parts = <String>[
    for (final entry in request.query.entries)
      queryIsCredential(entry.key)
          ? '${entry.key}=[redacted]'
          : '${entry.key}=${entry.value}',
    for (final entry in request.headers.entries)
      headerIsCredential(entry.key)
          ? '${entry.key}: [redacted]'
          : '${entry.key}: ${entry.value}',
  ];
  final buffer = StringBuffer('${request.method} ${request.path}');
  if (parts.isNotEmpty) buffer.write(' · ${parts.join('&')}');
  if (request.body != null) {
    buffer.write(' · 请求体：已省略（可能含凭据）');
  }
  return buffer.toString();
}

/// 探测/试跑用的传输层工厂；默认按条目 baseUrl 建一个**不跟随重定向**的 Dio。
typedef DeclarativeProbeTransportFactory =
    DeclarativeHttpTransport Function(OnlineMusicProviderDefinition definition);

/// 单项试跑播放解析时的默认音质（与内置实现的默认档位一致）。
const defaultDeclarativeTestQuality = 'lossless';

/// 结果区展示响应片段时的字符上限。
///
/// 结果区现在是限高可滚动的，所以这个上限只管"别把超大响应整个塞进内存/界面"，
/// 不影响正常阅读；超出时会明确写出完整长度。
const responsePreviewMaxChars = 20000;

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
    OnlineMusicCredentialReader? credentialReader,
    this.isPortableBuild = portableBuild,
  }) : _activeSettings = activeSettings,
       _store = store,
       _fallbackCredentials = fallbackCredentials,
       _runningCredentials = Map.unmodifiable(runningCredentials),
       _probeTransportFactory = probeTransportFactory,
       _credentialReader = credentialReader,
       _settings = store.read();

  final OnlineMusicSettings _activeSettings;
  final OnlineMusicSettingsStore _store;
  final OnlineMusicCredentialAccess _fallbackCredentials;
  final Map<String, OnlineMusicCredentialController> _runningCredentials;
  final DeclarativeProbeTransportFactory? _probeTransportFactory;

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
    return probeDeclarativeSearch(
      transport: _transportFor(definition),
      platform: definition.contentPlatform,
      credential: await _readCredential(definition),
      cancelToken: cancelToken,
    );
  }

  /// 单项试跑：只跑这一个能力，把 HTTP 结果与映射结果一起回报。
  Future<DeclarativeCapabilityTestResult> testCapability(
    OnlineMusicProviderDefinition definition,
    OnlineMusicCapability capability, {
    String keyword = providerProbeKeyword,
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

    final token = cancelToken ?? OnlineMusicCancelToken();
    // F0：敏感请求头的值同样来自安全槽位；试跑必须与运行期走同一条路，
    // 否则"试跑成功、运行期报错"就成了两份说法（反模式 4/8）。
    //
    // 存储读取失败**不当成**"试试网络"（那会把配置/存储问题误报成网络问题）：
    // 这里单独收敛成配置大类，并且**不发任何请求**。
    final Map<String, String> headerCredentials;
    try {
      headerCredentials = await readHeaderCredentialValues(
        spec: binding.request,
        reader: _headerCredentialReader,
      );
    } catch (_) {
      return const DeclarativeCapabilityTestResult(
        ok: false,
        failureReason: '无法读取该请求头引用的安全凭据（凭据存储读取失败）',
        failureKind: DeclarativeTestFailureKind.config,
      );
    }
    String? preview;
    String? requestSummary;
    try {
      final request = buildDeclarativeRequest(
        spec: binding.request,
        inputs: DeclarativeInputs(
          keyword: keyword,
          limit: 1,
          offset: 0,
          page: 1,
          trackId: trackId,
          playlistId: effectivePlaylistId,
          quality: quality,
        ),
        credential: await _readCredential(definition),
        headerCredentials: headerCredentials,
      );
      // 请求摘要在**发出去之前**就记下来：失败时它是唯一的排查依据。
      requestSummary = describeDeclarativeRequest(request);
      final response = await _transportFor(
        definition,
      ).send(request, cancelToken: token);
      preview = _redactPreview(response.data);

      return _evaluateCapabilityResponse(
        definition: definition,
        capability: capability,
        binding: binding,
        response: response,
        preview: preview,
        trackId: trackId,
        requestedPlaylistId: effectivePlaylistId,
        quality: quality,
      ).withRequestSummary(requestSummary);
    } on DeclarativeRequestException catch (error) {
      // 请求都没构造出来：这是**配置**问题，不是服务问题。
      return DeclarativeCapabilityTestResult(
        ok: false,
        failureReason: error.safeMessage,
        failureKind: DeclarativeTestFailureKind.config,
        requestSummary: requestSummary,
      );
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
        failureReason: '请求失败（网络或服务不可达）',
        failureKind: DeclarativeTestFailureKind.network,
        requestSummary: requestSummary,
      );
    }
  }

  /// 对一次成功的 HTTP 往返做"成功判定 + 字段映射"，并在失败时给出大类。
  DeclarativeCapabilityTestResult _evaluateCapabilityResponse({
    required OnlineMusicProviderDefinition definition,
    required OnlineMusicCapability capability,
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

    if (capability == OnlineMusicCapability.search) {
      final page = mapDeclarativeSearchResponse(
        spec: binding.response,
        body: response.data,
        platform: definition.contentPlatform,
        limit: 1,
        offset: 0,
      );
      final first = page.items.isEmpty ? null : page.items.first.title;
      return DeclarativeCapabilityTestResult(
        ok: page.items.isNotEmpty,
        statusCode: response.statusCode,
        responsePreview: preview,
        mappedSummary: page.items.isEmpty
            ? '解析成功，但没有曲目'
            : '${page.items.length} 首曲目 · 第 1 首：$first',
        failureReason: page.items.isEmpty ? '没有解析出曲目' : null,
        failureKind: page.items.isEmpty
            ? DeclarativeTestFailureKind.mapping
            : null,
      );
    }

    if (capability == OnlineMusicCapability.playlist) {
      final playlist = mapDeclarativePlaylistResponse(
        spec: binding.response,
        body: response.data,
        platform: definition.contentPlatform,
        requestedPlaylistId: requestedPlaylistId!,
      );
      return DeclarativeCapabilityTestResult(
        ok: true,
        statusCode: response.statusCode,
        responsePreview: preview,
        mappedSummary: '歌单「${playlist.name}」· ${playlist.tracks.length} 首曲目',
      );
    }

    if (capability == OnlineMusicCapability.playlistCollection) {
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
            ? '解析成功，但没有歌单'
            : '${playlists.length} 个歌单 · 第一个：$first',
        failureReason: playlists.isEmpty ? '没有解析出歌单' : null,
        failureKind: playlists.isEmpty
            ? DeclarativeTestFailureKind.mapping
            : null,
      );
    }

    if (capability == OnlineMusicCapability.chartList) {
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
            ? '解析成功，但没有榜单'
            : '${charts.length} 个榜单 · 第一个：$first',
        failureReason: charts.isEmpty ? '没有解析出榜单' : null,
        failureKind: charts.isEmpty
            ? DeclarativeTestFailureKind.mapping
            : null,
      );
    }

    if (capability == OnlineMusicCapability.playlistCategories) {
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
            ? '解析成功，但没有分类'
            : '${categories.length} 个分类 · 第一个：$first',
        failureReason: categories.isEmpty ? '没有解析出分类' : null,
        failureKind: categories.isEmpty
            ? DeclarativeTestFailureKind.mapping
            : null,
      );
    }

    if (capability == OnlineMusicCapability.newSongs) {
      // 新歌与搜索同构（都是曲目数组），试跑复用同一个映射。
      final tracks = mapDeclarativeSearchResponse(
        spec: binding.response,
        body: response.data,
        platform: definition.contentPlatform,
        limit: 30,
        offset: 0,
      ).items;
      final first = tracks.isEmpty ? null : tracks.first.title;
      return DeclarativeCapabilityTestResult(
        ok: tracks.isNotEmpty,
        statusCode: response.statusCode,
        responsePreview: preview,
        mappedSummary: tracks.isEmpty
            ? '解析成功，但没有新歌'
            : '${tracks.length} 首曲目 · 第一首：$first',
        failureReason: tracks.isEmpty ? '没有解析出曲目' : null,
        failureKind: tracks.isEmpty
            ? DeclarativeTestFailureKind.mapping
            : null,
      );
    }

    if (capability == OnlineMusicCapability.lyric) {
      final lyrics = mapDeclarativeLyricsResponse(
        spec: binding.response,
        body: response.data,
        ref: PlatformTrackRef(
          platform: definition.contentPlatform,
          trackId: trackId!,
        ),
      );
      // 空歌词**不是失败**：纯音乐/间奏本来就没有歌词，配置可能是对的。
      return DeclarativeCapabilityTestResult(
        ok: true,
        statusCode: response.statusCode,
        responsePreview: preview,
        mappedSummary: lyrics.isEmpty
            ? '解析成功，但这份响应里没有歌词（纯音乐？）'
            : '歌词：原文${lyrics.original != null ? '有' : '无'}'
                  '${lyrics.translation != null ? ' · 翻译有' : ''}',
      );
    }

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

  DeclarativeHttpTransport _transportFor(
    OnlineMusicProviderDefinition definition,
  ) {
    final factory = _probeTransportFactory;
    if (factory != null) return factory(definition);
    return DioDeclarativeHttpTransport(
      dio: Dio(
        BaseOptions(
          // 缺失 ⇒ 默认地址；显式提供的非法值根本走不到这里（见上面的两处拦截）。
          baseUrl: definition.effectiveBaseUrl,
          connectTimeout: definition.connectTimeout,
          sendTimeout: definition.sendTimeout,
          receiveTimeout: definition.receiveTimeout,
        ),
      ),
      // P3：探测/试跑不跟随重定向，避免打到用户没有提供的主机。
      followRedirects: false,
    );
  }

  Future<String?> _readCredential(
    OnlineMusicProviderDefinition definition,
  ) async {
    final reader = _credentialReader;
    final reference = definition.credentialReference;
    if (reader == null || reference == null) return null;
    try {
      return await reader.readCredential(reference);
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

  /// 结果区展示的响应片段：**先按结构脱敏，再格式化，再补文本脱敏，最后才考虑截断**。
  ///
  /// - 结构脱敏（P-35）：解码后的 JSON 逐层走一遍，把敏感键的**值**换成 `[redacted]`。
  ///   这覆盖了正则做不到的部分：**非字符串值**（`"token": 12345`）、
  ///   **嵌套 JSON**、**数组元素**。上一步之后文本正则只是补刀。
  /// - 格式化：JSON 用 2 空格缩进，界面里才看得出层次（此前是压成一行的 `jsonEncode`）。
  /// - 文本脱敏：同时覆盖查询串（`apikey=…`、`?h=…&sid=…`）、JSON 键值对（`"token":"…"`）
  ///   与**敏感请求头**（`Authorization: …`、`Cookie: …`，W5 补充）。
  ///   宁可多脱敏，也不要把签名串渲染到界面上。
  /// - 截断：上限 [responsePreviewMaxChars]；超出时**明确写出完整长度**，
  ///   而不是让用户以为响应本来就只有这么长。
  String? _redactPreview(Object? data) {
    if (data == null) return null;
    var text = _prettyJson(_redactStructured(data, 0));
    text = text.replaceAllMapped(
      RegExp(
        '\\b($sensitiveDiagnosticNamePattern)=[^&"\\s,}]+',
        caseSensitive: false,
      ),
      (match) => '${match.group(1)}=[redacted]',
    );
    // JSON 键值对：**字符串与非字符串值都要挡**（`"token": 123` / `"jwt": null`）。
    text = text.replaceAllMapped(
      RegExp(
        '"($sensitiveDiagnosticNamePattern)"\\s*:\\s*'
        '(?:"[^"]*"|[^,}\\]\\s][^,}\\]]*)',
        caseSensitive: false,
      ),
      (match) => '"${match.group(1)}":"[redacted]"',
    );
    // 请求/响应头形态：`Authorization: Bearer …` / `Cookie: a=b`。
    text = text.replaceAllMapped(
      RegExp(
        '^\\s*($sensitiveDiagnosticNamePattern)\\s*:\\s*.*\$',
        caseSensitive: false,
        multiLine: true,
      ),
      (match) => '${match.group(1)}: [redacted]',
    );
    if (text.length <= responsePreviewMaxChars) return text;
    return '${text.substring(0, responsePreviewMaxChars)}\n'
        '…（已截断展示：完整响应共 ${text.length} 字符）';
  }

  /// 逐层把敏感键的**值**换成 `[redacted]`。
  ///
  /// [depth] 只是防御性上限：解码后的 JSON 不会有环，但预览不该被刻意做深的响应拖垮。
  static Object? _redactStructured(Object? data, int depth) {
    if (depth > 32) return '[redacted：层级过深]';
    if (data is Map) {
      return <String, Object?>{
        for (final entry in data.entries)
          '${entry.key}': isSensitiveDiagnosticName('${entry.key}')
              ? '[redacted]'
              : _redactStructured(entry.value, depth + 1),
      };
    }
    if (data is List) {
      return [
        for (final item in data) _redactStructured(item, depth + 1),
      ];
    }
    return data;
  }

  String _prettyJson(Object? data) {
    if (data is String) return data;
    try {
      return const JsonEncoder.withIndent('  ').convert(data);
    } catch (_) {
      return '$data';
    }
  }

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
final class _UnavailableCredentialReader implements OnlineMusicCredentialReader {
  const _UnavailableCredentialReader();

  @override
  Future<String?> readCredential(String reference) async => null;
}
