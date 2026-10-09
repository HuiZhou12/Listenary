import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/services/music_platform/chksz/index.dart';
import 'package:pure_music/services/music_platform/declarative/declarative_http_transport.dart';
import 'package:pure_music/services/music_platform/declarative/declarative_request_builder.dart';
import 'package:pure_music/services/music_platform/online_music_composition.dart';

/// F0 切片 3：**Base URL 校验**（Spec §7 / 缺陷 P-18）。
///
/// 旧行为：非法 baseUrl 被**静默替换**成 `https://api.chksz.com` ⇒ 用户带着自己的
/// 凭据打到了一台他从未指定的主机上。
///
/// 这一片要同时证明两件相反的事：
/// 1. **显式提供的非法值** ⇒ 明确报错、**一个请求都不发**、目标**不被替换**；
/// 2. **缺失**（旧配置没写这一项）⇒ 仍然走默认地址，**行为与旧版一致**。
///
/// 全部证据来自假传输层 + 假凭据 —— 绝不用真 Key 打真地址。
void main() {
  const fakeKey = 'FAKE_API_KEY_FOR_BASE_URL_TEST_ONLY';
  // 旧实现会把这个值替换成下面这个主机，正是要证明"不再发生"。
  const replacedHost = 'api.chksz.com';

  group('显式提供的非法 baseUrl ⇒ 明确报错、不发请求、不替换目标', () {
    test('★ 声明式条目：传输层调用次数 = 0，且**根本没建立连接**', () async {
      final harness = _CompositionHarness();
      final composition = await harness.compose(
        _settings(baseUrl: 'ftp://invalid.example'),
        credentials: fakeKey,
      );
      addTearDown(composition.service.dispose);

      // 条目的能力声明**不变**：用户看到的应该是"这台服务地址错了"，
      // 而不是"这个平台没有可用来源"。
      expect(composition.service.capabilities.searchablePlatforms, {
        MusicPlatform.netease,
      });

      await expectLater(
        composition.service.search(
          platform: MusicPlatform.netease,
          keyword: 'x',
          cancelToken: OnlineMusicCancelToken(),
        ),
        throwsA(
          isA<OnlineMusicException>()
              .having(
                (error) => error.kind,
                'kind',
                OnlineMusicErrorKind.badRequest,
              )
              .having(
                (error) => error.safeMessage,
                'safeMessage',
                allOf(contains('服务地址无效'), contains('不会回落到默认服务地址')),
              ),
        ),
      );

      expect(harness.requests, isEmpty, reason: '一个请求都不能发');
      expect(harness.dioFactoryCalls, 0, reason: '连连接都不该建立');
      expect(harness.targets, isEmpty);
      // 假凭据不外发（没有请求，因此也不在任何地方出现过）。
      expect(harness.seenAnywhere(fakeKey), isFalse);
    });

    test('★ 内置 ChkSz 条目：同样是**配置**错误，不是一个"网络"错误', () async {
      final harness = _CompositionHarness();
      final composition = await harness.compose(
        OnlineMusicSettings.fromJson({
          'providers': [
            {'id': 'chksz', 'protocol': 'chksz', 'baseUrl': 'ftp://invalid.example'},
          ],
        }),
        credentials: fakeKey,
      );
      addTearDown(composition.service.dispose);

      await expectLater(
        composition.service.search(
          platform: MusicPlatform.netease,
          keyword: 'x',
          cancelToken: OnlineMusicCancelToken(),
        ),
        throwsA(
          isA<OnlineMusicException>().having(
            (error) => error.kind,
            'kind',
            // 分类必须同结论：配置问题不能报成网络问题。
            isNot(OnlineMusicErrorKind.network),
          ),
        ),
      );

      expect(harness.requests, isEmpty);
      expect(harness.dioFactoryCalls, 0);
    });

    test('报错文案里不出现任何一个"其实没被用上"的主机', () async {
      final harness = _CompositionHarness();
      final composition = await harness.compose(
        _settings(baseUrl: 'https://'),
      );
      addTearDown(composition.service.dispose);

      Object? captured;
      try {
        await composition.service.search(
          platform: MusicPlatform.netease,
          keyword: 'x',
          cancelToken: OnlineMusicCancelToken(),
        );
      } catch (error) {
        captured = error;
      }

      expect(captured, isA<OnlineMusicException>());
      final message = (captured! as OnlineMusicException).safeMessage;
      expect(message, contains('服务地址缺少主机名'));
      expect(
        message,
        isNot(contains(replacedHost)),
        reason: '旧实现会替换成 $replacedHost —— 报错里不该暗示这种回落',
      );
      expect(harness.seenAnywhere(replacedHost), isFalse);
    });
  });

  group('保存时拒绝（与界面校验同一个判据）', () {
    test('★ validationIssues 拦住非法地址并说明不会回落', () {
      final definition = OnlineMusicProviderDefinition.custom(
        id: 'selfData',
        baseUrl: 'ftp://invalid.example',
        requiresCredential: false,
      );

      final issues = definition.validationIssues();

      expect(issues, hasLength(1));
      expect(issues.single, contains('服务地址必须以 http:// 或 https:// 开头'));
      expect(issues.single, contains('不会回落到默认服务地址'));
      // 原值被**原样保留**（没有在解析/构造阶段被替换掉）。
      expect(definition.baseUrl, 'ftp://invalid.example');
      expect(definition.baseUrlIssue, isNotNull);
    });

    test('合法地址与"缺失"都不报错', () {
      expect(
        OnlineMusicProviderDefinition.custom(
          id: 'a',
          baseUrl: 'https://ok.example',
          requiresCredential: false,
        ).validationIssues(),
        isEmpty,
      );
      final missing = OnlineMusicSettings.fromJson({
        'providers': [
          {
            'id': 'a',
            'protocol': 'chksz',
            'capabilities': <String, Object?>{},
          },
        ],
      }).providers.single;

      expect(missing.baseUrl, '');
      expect(missing.baseUrlIssue, isNull);
      expect(missing.validationIssues(), isEmpty);
    });

    test('界面的逐字符校验与模型校验同结论（同一份判据）', () {
      // 界面 `_ProviderDialog._validateBaseUrl` 直接调用同一个函数，
      // 这里锁定的是"两层不会各说一套"。
      for (final value in ['ftp://x', '/relative', 'https://', 'https://ok.example']) {
        expect(
          onlineMusicBaseUrlIssue(value) == null,
          value == 'https://ok.example',
          reason: value,
        );
      }
    });
  });

  group('合法的旧配置仍然兼容（缺省行为不变）', () {
    test('★ 缺 baseUrl ⇒ 生效默认地址，请求真的打到默认 host', () async {
      final harness = _CompositionHarness();
      // 只写 id/protocol：这是最古老的条目形态，从来没有 baseUrl 这一项。
      final settings = OnlineMusicSettings.fromJson({
        'providers': [
          {
            'id': 'selfData',
            'protocol': 'chksz',
            'capabilities': {'search': _searchBindingJson()},
          },
        ],
        'defaultProvider': 'selfData',
      });
      expect(settings.providers.single.baseUrl, '');
      expect(
        settings.providers.single.effectiveBaseUrl,
        defaultOnlineMusicBaseUrl,
      );

      final composition = await harness.compose(settings);
      addTearDown(composition.service.dispose);
      await composition.service.search(
        platform: MusicPlatform.netease,
        keyword: 'x',
        cancelToken: OnlineMusicCancelToken(),
      );

      expect(harness.requests, hasLength(1));
      expect(harness.targets.single, defaultOnlineMusicBaseUrl);
    });

    test('★ 显式合法 baseUrl ⇒ 生效该地址（不被改成默认地址）', () async {
      final harness = _CompositionHarness();
      final composition = await harness.compose(
        _settings(baseUrl: 'http://127.0.0.1:8080'),
      );
      addTearDown(composition.service.dispose);
      await composition.service.search(
        platform: MusicPlatform.netease,
        keyword: 'x',
        cancelToken: OnlineMusicCancelToken(),
      );

      expect(harness.requests, hasLength(1));
      expect(harness.targets.single, 'http://127.0.0.1:8080');
      expect(harness.seenAnywhere(replacedHost), isFalse);
    });
  });

  group('试跑与探测在发请求之前就被拦下', () {
    test('★ 试跑报"配置"失败且 0 请求（连传输层都没建）', () async {
      final harness = _CompositionHarness();
      final settings = _settings(baseUrl: 'ftp://invalid.example');
      final transport = harness.probeTransport();

      final controller = OnlineMusicProviderSettingsController(
        activeSettings: settings,
        store: _MemoryStore(settings),
        fallbackCredentials: _FakeAccess(),
        probeTransportFactory: (_) => transport,
      );
      addTearDown(controller.dispose);

      final result = await controller.testCapability(
        settings.providers.single,
        OnlineMusicCapability.search,
      );

      expect(result.ok, isFalse);
      expect(result.failureKind, DeclarativeTestFailureKind.config);
      expect(result.failureReason, contains('服务地址无效'));
      expect(transport.requests, isEmpty);
    });

    test('★ 探测整体被拦下，且**不谎称**"候选都没通过"', () async {
      final harness = _CompositionHarness();
      final settings = _settings(baseUrl: 'ftp://invalid.example');
      final transport = harness.probeTransport();

      final controller = OnlineMusicProviderSettingsController(
        activeSettings: settings,
        store: _MemoryStore(settings),
        fallbackCredentials: _FakeAccess(),
        probeTransportFactory: (_) => transport,
      );
      addTearDown(controller.dispose);

      final report = await controller.probeSearch(settings.providers.single);

      expect(report.isBlocked, isTrue);
      expect(report.blockedReason, contains('服务地址无效'));
      expect(report.outcomes, isEmpty, reason: '没有试过，就不能造出"试过"的记录');
      expect(report.hasDraft, isFalse);
      expect(transport.requests, isEmpty);
    });
  });
}

// ---------------------------------------------------------------------- 夹具

JsonPath _p(String source) => JsonPath.tryParse(source)!;

Map<String, Object?> _searchBindingJson() =>
    OnlineMusicDeclarativeCapabilityBinding(
      request: const OnlineMusicRequestSpec(
        path: '/search',
        query: [
          OnlineMusicParamBinding(
            name: 'keywords',
            source: OnlineMusicInputSource.keyword,
            required: true,
          ),
        ],
      ),
      response: OnlineMusicResponseSpec(
        listPath: _p('result.songs'),
        fields: {
          OnlineMusicDomainField.trackId: OnlineMusicFieldSpec(
            candidates: [_p('id')],
            transform: OnlineMusicFieldTransform.asInt,
            required: true,
          ),
          OnlineMusicDomainField.title: OnlineMusicFieldSpec(
            candidates: [_p('name')],
            transform: OnlineMusicFieldTransform.asString,
            required: true,
          ),
        },
      ),
    ).toJson();

OnlineMusicSettings _settings({String? baseUrl}) =>
    OnlineMusicSettings.fromJson({
      'providers': [
        {
          'id': 'selfData',
          'baseUrl': ?baseUrl,
          'auth': {'kind': 'apiKey', 'reference': 'PureMusic/Self/APIKey'},
          'capabilities': {
            'search': _searchBindingJson(),
            // 同时给 search 与 stream：`searchablePlatforms` 有"搜得到也要播得了"
            // 的硬门槛（D3），只配 search 的平台本来就不该出现在里面 ——
            // 那样断言"条目还在"会变成断言一个与被测行为无关的门槛。
            'stream': _streamBindingJson(),
          },
        },
      ],
      'defaultProvider': 'selfData',
    });

Map<String, Object?> _streamBindingJson() =>
    OnlineMusicDeclarativeCapabilityBinding(
      request: const OnlineMusicRequestSpec(
        path: '/song/url',
        query: [
          OnlineMusicParamBinding(
            name: 'id',
            source: OnlineMusicInputSource.trackId,
            required: true,
          ),
        ],
      ),
      response: OnlineMusicResponseSpec(
        fieldsRootPath: _p('data'),
        fields: {
          OnlineMusicDomainField.streamUrl: OnlineMusicFieldSpec(
            candidates: [_p('url')],
            transform: OnlineMusicFieldTransform.asUri,
            required: true,
          ),
          OnlineMusicDomainField.streamBitrate: OnlineMusicFieldSpec(
            candidates: [_p('br')],
            transform: OnlineMusicFieldTransform.asInt,
          ),
        },
      ),
    ).toJson();

/// 记录「建立了哪些连接 / 发了哪些请求 / 目标是谁」，并保证假凭据可被检索。
final class _CompositionHarness {
  final List<RequestOptions> requests = [];
  final List<String> targets = [];
  int dioFactoryCalls = 0;

  /// 生产代码建 Dio 用的就是 `definition.effectiveBaseUrl`（见 `createOnlineMusicComposition`），
  /// 这里的替身照抄同一条表达式，因此 [targets] 记录的就是"真实目标"。
  ChkszCredentialAccess get _access =>
      ChkszCredentialAccess(portableBuild: true);

  Future<OnlineMusicComposition> compose(
    OnlineMusicSettings settings, {
    String? credentials,
  }) async {
    final access = _access;
    if (credentials != null) {
      await access.save('PureMusic/Self/APIKey', credentials);
    }
    final adapter = _RecordingAdapter(requests);
    return createOnlineMusicComposition(
      settings: settings,
      portableBuild: true,
      credentialAccess: access,
      dioFactory: (definition) {
        dioFactoryCalls++;
        targets.add(definition.effectiveBaseUrl);
        return Dio(BaseOptions(baseUrl: definition.effectiveBaseUrl))
          ..httpClientAdapter = adapter;
      },
    );
  }

  _RecordingTransport probeTransport() => _RecordingTransport(requests);

  bool seenAnywhere(String needle) {
    for (final request in requests) {
      final rendered = {
        'uri': request.uri.toString(),
        'base': request.baseUrl,
        'headers': '${request.headers}',
        'query': '${request.queryParameters}',
      }.toString();
      if (rendered.contains(needle)) return true;
    }
    return targets.any((target) => target.contains(needle));
  }
}

final class _RecordingAdapter implements HttpClientAdapter {
  _RecordingAdapter(this.requests);

  final List<RequestOptions> requests;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return ResponseBody.fromString(
      jsonEncode(const {
        'result': {
          'songs': [
            {'id': 1, 'name': 'x'},
          ],
        },
      }),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// 只统计"有没有发出请求"的传输层替身（试跑 / 探测路径用）。
final class _RecordingTransport implements DeclarativeHttpTransport {
  _RecordingTransport(this.requests);

  final List<RequestOptions> requests;

  @override
  Future<DeclarativeHttpResponse> send(
    BuiltDeclarativeRequest request, {
    required OnlineMusicCancelToken cancelToken,
  }) async {
    requests.add(RequestOptions(path: request.path));
    return const DeclarativeHttpResponse(statusCode: 200, data: {'code': 0});
  }
}

final class _MemoryStore implements OnlineMusicSettingsStore {
  _MemoryStore(this.value);

  OnlineMusicSettings value;

  @override
  OnlineMusicSettings read() => value;

  @override
  Future<bool> write(OnlineMusicSettings settings) async {
    value = settings;
    return true;
  }
}

final class _FakeAccess implements OnlineMusicCredentialAccess {
  @override
  String get credentialDisplayName => 'API Key';

  @override
  String get inputHint => 'API Key';

  @override
  bool isValidFormat(String value) => value.trim().isNotEmpty;

  @override
  Future<bool> isConfigured(String reference) async => false;

  @override
  Future<void> save(String reference, String value) async {}

  @override
  Future<void> clear(String reference) async {}
}
