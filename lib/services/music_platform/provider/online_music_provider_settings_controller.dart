import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:pure_music/core/preference.dart';
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
import 'package:pure_music/services/music_platform/provider/online_music_provider_credentials.dart';
import 'package:pure_music/services/music_platform/provider/online_music_provider_settings.dart';

/// 单项试跑的结果：给界面同时看"HTTP 层发生了什么"和"映射成了什么"。
final class DeclarativeCapabilityTestResult {
  const DeclarativeCapabilityTestResult({
    required this.ok,
    this.statusCode,
    this.mappedSummary,
    this.failureReason,
    this.responsePreview,
  });

  final bool ok;
  final int? statusCode;

  /// 映射结果的**非敏感**摘要（例如「1 首曲目 / 第 1 首：海阔天空」）。
  final String? mappedSummary;

  final String? failureReason;

  /// 截断并脱敏后的响应片段，供用户判断字段名是否对得上。
  final String? responsePreview;
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

  /// 探测该条目的 search 能力（Spec §4 的 P1–P10）。
  ///
  /// 已经配置好的凭据会被使用；没有凭据也照样探测（记「需要认证」）。
  Future<ProviderProbeReport> probeSearch(
    OnlineMusicProviderDefinition definition, {
    OnlineMusicCancelToken? cancelToken,
  }) async {
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
      );
    }
    if (capability == OnlineMusicCapability.stream &&
        (trackId == null || trackId.trim().isEmpty)) {
      return const DeclarativeCapabilityTestResult(
        ok: false,
        failureReason: '试跑播放解析需要先填一个曲目 ID',
      );
    }
    if (capability == OnlineMusicCapability.lyric &&
        (trackId == null || trackId.trim().isEmpty)) {
      return const DeclarativeCapabilityTestResult(
        ok: false,
        failureReason: '试跑歌词需要先填一个曲目 ID',
      );
    }
    // 试跑面板只有一个 ID 输入框（一次只编辑一个能力）：playlist 用它当歌单 ID，
    // stream / lyric 用它当曲目 ID；程序化调用仍可显式传 playlistId。
    final effectivePlaylistId = playlistId ?? trackId;
    if (capability == OnlineMusicCapability.playlist &&
        (effectivePlaylistId == null || effectivePlaylistId.trim().isEmpty)) {
      return const DeclarativeCapabilityTestResult(
        ok: false,
        failureReason: '试跑歌曲列表需要先填一个歌单 ID',
      );
    }

    final token = cancelToken ?? OnlineMusicCancelToken();
    String? preview;
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
      );
      final response = await _transportFor(
        definition,
      ).send(request, cancelToken: token);
      preview = _redactPreview(response.data);

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
        );
      }

      if (capability == OnlineMusicCapability.playlist) {
        final playlist = mapDeclarativePlaylistResponse(
          spec: binding.response,
          body: response.data,
          platform: definition.contentPlatform,
          requestedPlaylistId: effectivePlaylistId!,
        );
        return DeclarativeCapabilityTestResult(
          ok: true,
          statusCode: response.statusCode,
          responsePreview: preview,
          mappedSummary: '歌单「${playlist.name}」· ${playlist.tracks.length} 首曲目',
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
    } on DeclarativeRequestException catch (error) {
      return DeclarativeCapabilityTestResult(
        ok: false,
        failureReason: error.safeMessage,
      );
    } on DeclarativeMappingException catch (error) {
      return DeclarativeCapabilityTestResult(
        ok: false,
        responsePreview: preview,
        failureReason: '映射失败：${error.reason}',
      );
    } catch (_) {
      return DeclarativeCapabilityTestResult(
        ok: false,
        responsePreview: preview,
        failureReason: '请求失败（网络或服务不可达）',
      );
    }
  }

  DeclarativeHttpTransport _transportFor(
    OnlineMusicProviderDefinition definition,
  ) {
    final factory = _probeTransportFactory;
    if (factory != null) return factory(definition);
    return DioDeclarativeHttpTransport(
      dio: Dio(
        BaseOptions(
          baseUrl: definition.baseUrl,
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

  /// 结果区展示的响应片段：**先格式化，再脱敏，最后才考虑截断**。
  ///
  /// - 格式化：JSON 用 2 空格缩进，界面里才看得出层次（此前是压成一行的 `jsonEncode`）。
  /// - 脱敏：同时覆盖查询串（`apikey=…`、`?h=…&sid=…`）与 JSON 键值对（`"token":"…"`）。
  ///   宁可多脱敏，也不要把签名串渲染到界面上。
  /// - 截断：上限 [responsePreviewMaxChars]；超出时**明确写出完整长度**，
  ///   而不是让用户以为响应本来就只有这么长。
  String? _redactPreview(Object? data) {
    if (data == null) return null;
    var text = _prettyJson(data);
    text = text.replaceAllMapped(
      RegExp(
        r'\b(apikey|api_key|key|token|access_token|refresh_token|secret|'
        r'password|pwd|sign|signature|auth|sid|h)=[^&"\s,}]+',
        caseSensitive: false,
      ),
      (match) => '${match.group(1)}=[redacted]',
    );
    text = text.replaceAllMapped(
      RegExp(
        r'"(apikey|api_key|key|token|access_token|refresh_token|secret|'
        r'password|pwd|sign|signature|auth|sid)"\s*:\s*"[^"]*"',
        caseSensitive: false,
      ),
      (match) => '"${match.group(1)}":"[redacted]"',
    );
    if (text.length <= responsePreviewMaxChars) return text;
    return '${text.substring(0, responsePreviewMaxChars)}\n'
        '…（已截断展示：完整响应共 ${text.length} 字符）';
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
