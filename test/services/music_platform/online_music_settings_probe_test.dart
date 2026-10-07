import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/core/preference.dart';
import 'package:pure_music/services/music_platform/chksz/index.dart';
import 'package:pure_music/services/music_platform/declarative/declarative_http_transport.dart';
import 'package:pure_music/services/music_platform/declarative/declarative_request_builder.dart';
import 'package:pure_music/services/music_platform/declarative/provider_templates.dart';

void main() {
  late _FakeTransport transport;
  late _MemorySettingsStore store;
  late _FakeCredentialReader reader;

  setUp(() {
    transport = _FakeTransport();
    store = _MemorySettingsStore(_declarativeSettings());
    reader = _FakeCredentialReader();
  });

  OnlineMusicProviderSettingsController controller() =>
      OnlineMusicProviderSettingsController(
        activeSettings: store.value,
        store: store,
        fallbackCredentials: _FakeAccess(),
        probeTransportFactory: (_) => transport,
        credentialReader: reader,
      );

  test(
    'probeSearch uses the entry baseUrl transport and yields a draft',
    () async {
      transport.responder = (request) async => _msapiBody;

      final report = await controller().probeSearch(
        store.value.providers.single,
      );

      expect(report.draftTemplateId, 'netease-proxy');
      expect(
        transport.requests.map((request) => request.path),
        contains('/search'),
      );
    },
  );

  test('probeSearch passes an already-configured credential', () async {
    reader.value = 'chksz_KEY_TEST_ONLY';
    transport.responder = (request) async => _chkszBody;
    final credentialed = _MemorySettingsStore(_credentialedSettings());
    final controller = OnlineMusicProviderSettingsController(
      activeSettings: credentialed.value,
      store: credentialed,
      fallbackCredentials: _FakeAccess(),
      probeTransportFactory: (_) => transport,
      credentialReader: reader,
    );

    final report = await controller.probeSearch(
      credentialed.value.providers.single,
    );

    final chkszRequest = transport.requests.firstWhere(
      (request) => request.path == '/api/163_search',
    );
    expect(chkszRequest.query['apikey'], 'chksz_KEY_TEST_ONLY');
    expect(report.draftTemplateId, builtinOnlineMusicChkszId);
  });

  test(
    'probeSearch never attaches a credential the entry does not have',
    () async {
      transport.responder = (request) async => _msapiBody;

      final report = await controller().probeSearch(
        store.value.providers.single,
      );

      // 两个候选都会真的被探测一次，且都不带凭据。
      expect(transport.requests.map((request) => request.path).toSet(), {
        '/api/163_search',
        '/search',
      });
      for (final request in transport.requests) {
        expect(request.query.containsKey('apikey'), isFalse);
      }
      expect(report.draftTemplateId, 'netease-proxy');
    },
  );

  test('testCapability(search) reports both HTTP and mapped result', () async {
    transport.responder = (request) async => _msapiBody;

    final result = await controller().testCapability(
      store.value.providers.single,
      OnlineMusicCapability.search,
    );

    expect(result.ok, isTrue);
    expect(result.statusCode, 200);
    expect(result.mappedSummary, contains('海阔天空'));
    expect(result.responsePreview, contains('result'));
    expect(transport.requests.single.query['keywords'], 'listenary');
  });

  test(
    'testCapability reports a mapping failure instead of guessing',
    () async {
      transport.responder = (request) async => const {
        'result': {
          'songs': [
            {'id': 1},
          ],
        },
      };

      final result = await controller().testCapability(
        store.value.providers.single,
        OnlineMusicCapability.search,
      );

      expect(result.ok, isFalse);
      expect(result.failureReason, contains('映射失败'));
      expect(result.failureReason, contains('title'));
    },
  );

  test(
    'testCapability(stream) needs a track id and hides signed URLs',
    () async {
      transport.responder = (request) async => const {
        'code': 0,
        'data': {
          'id': 123456,
          'url': 'https://media.invalid/a.flac?sign=SECRET_TEST_ONLY',
          'br': 320000,
        },
      };

      final declaration = store.value.providers.single;
      final withoutTrack = await controller().testCapability(
        declaration,
        OnlineMusicCapability.stream,
      );
      expect(withoutTrack.ok, isFalse);
      expect(withoutTrack.failureReason, contains('曲目 ID'));
      expect(transport.requests, isEmpty);

      final result = await controller().testCapability(
        declaration,
        OnlineMusicCapability.stream,
        trackId: '123456',
      );
      expect(result.ok, isTrue);
      expect(result.mappedSummary, '播放地址：media.invalid/a.flac');
      expect(result.mappedSummary, isNot(contains('SECRET')));
    },
  );

  test('testCapability refuses builtin and phase-two capabilities', () async {
    final builtinStore = _MemorySettingsStore(
      OnlineMusicSettings.fromJson({
        'providers': [
          {'id': 'chksz', 'protocol': 'chksz'},
        ],
      }),
    );
    final builtin = OnlineMusicProviderSettingsController(
      activeSettings: builtinStore.value,
      store: builtinStore,
      fallbackCredentials: _FakeAccess(),
      probeTransportFactory: (_) => transport,
    );

    final builtinResult = await builtin.testCapability(
      builtinStore.value.providers.single,
      OnlineMusicCapability.search,
    );
    expect(builtinResult.ok, isFalse);
    expect(builtinResult.failureReason, contains('不是声明式'));

    // S7b-2：lyric / playlist 不再被"第二阶段"拦住。这个 fixture 的条目**没有**
    // 声明式 lyric / playlist 绑定，所以它们会走到"该能力不是声明式配置"这一层；
    // 关键是**不再有阶段守卫**，且同样在发请求之前返回。
    final lyricWithoutTrack = await controller().testCapability(
      store.value.providers.single,
      OnlineMusicCapability.lyric,
    );
    expect(lyricWithoutTrack.ok, isFalse);
    expect(lyricWithoutTrack.failureReason, isNot(contains('第二阶段')));

    final playlistWithoutId = await controller().testCapability(
      store.value.providers.single,
      OnlineMusicCapability.playlist,
    );
    expect(playlistWithoutId.ok, isFalse);
    expect(playlistWithoutId.failureReason, isNot(contains('第二阶段')));
    expect(transport.requests, isEmpty);
  });

  test(
    'the response preview is redacted but no longer hard-truncated at 400',
    () async {
      transport.responder = (request) async => {
        'msg': 'apikey=chksz_SECRET_TEST_ONLY',
        'padding': 'x' * 600,
      };

      final result = await controller().testCapability(
        store.value.providers.single,
        OnlineMusicCapability.search,
      );

      expect(result.responsePreview, isNot(contains('chksz_SECRET_TEST_ONLY')));
      expect(result.responsePreview, contains('[redacted]'));
      // 之前固定截到 400 字符，看起来就像"服务只返回了这么点数据"。
      expect(result.responsePreview!.length, greaterThan(600));
    },
  );

  test(
    'the preview is pretty-printed and states the full length when cut',
    () async {
      transport.responder = (request) async => {
        'result': {
          'songs': [
            {'id': 1, 'name': 'x' * (responsePreviewMaxChars + 5000)},
          ],
        },
      };

      final result = await controller().testCapability(
        store.value.providers.single,
        OnlineMusicCapability.search,
      );

      final preview = result.responsePreview!;
      // 缩进 → 界面里能看出层次。
      expect(preview, contains('\n  "result"'));
      // 超长时才截断，并明确写出完整长度，避免被读成"数据不完整"。
      expect(preview, contains('已截断展示：完整响应共'));
      expect(preview.length, lessThanOrEqualTo(responsePreviewMaxChars + 100));
    },
  );

  test('the preview also redacts JSON key/value secrets', () async {
    // JSON 键值形式（含签名 URL 的常见参数名）同样不能出现在界面上。
    transport.responder = (request) async => {
      'token': 'SECRET_TOKEN_TEST_ONLY',
      'url': 'https://media.invalid/a.flac?h=SECRET_H_TEST_ONLY&sid=SECRET_SID',
    };

    final result = await controller().testCapability(
      store.value.providers.single,
      OnlineMusicCapability.search,
    );

    expect(result.responsePreview, isNot(contains('SECRET_TOKEN_TEST_ONLY')));
    expect(result.responsePreview, isNot(contains('SECRET_H_TEST_ONLY')));
    expect(result.responsePreview, isNot(contains('SECRET_SID')));
    expect(result.responsePreview, contains('"token":"[redacted]"'));
  });

  // ------------------------------------------------------------------ W5
  group('W5 试跑：请求信息 / 错误分类 / 配置隔离', () {
    OnlineMusicProviderSettingsController controllerFor(
      OnlineMusicSettings settings, {
      String? credential,
    }) {
      reader.value = credential;
      return OnlineMusicProviderSettingsController(
        activeSettings: settings,
        store: _MemorySettingsStore(settings),
        fallbackCredentials: _FakeAccess(),
        probeTransportFactory: (_) => transport,
        credentialReader: reader,
      );
    }

    test('请求摘要写出实际发了什么：参数名与值可见，凭据与敏感头脱敏', () async {
      transport.responder = (request) async => _searchBody;
      final settings = _searchOnlySettingsWithSecrets();

      final result = await controllerFor(
        settings,
        credential: 'SECRET_API_KEY',
      ).testCapability(settings.providers.single, OnlineMusicCapability.search);

      expect(result.ok, isTrue);
      final summary = result.requestSummary!;
      expect(summary, startsWith('GET /search'));
      expect(summary, contains('keywords=listenary'));
      expect(summary, contains('limit=1'));
      expect(summary, contains('X-Client: listenary'));
      // 凭据类参数与请求头一律 [redacted]。
      expect(summary, contains('apikey=[redacted]'));
      expect(summary, contains('Cookie: [redacted]'));
      expect(summary, isNot(contains('SECRET_API_KEY')));
      expect(summary, isNot(contains('SECRET_COOKIE')));
    });

    test('失败时也带上请求摘要（失败时它才是唯一排查依据）', () async {
      transport.error = StateError('offline');
      final settings = _searchOnlySettingsWithSecrets();

      final result = await controllerFor(
        settings,
        credential: 'SECRET_API_KEY',
      ).testCapability(settings.providers.single, OnlineMusicCapability.search);

      expect(result.ok, isFalse);
      expect(result.requestSummary, contains('GET /search'));
      expect(result.requestSummary, isNot(contains('SECRET_API_KEY')));
    });

    test('失败大类可区分：网络 / HTTP / 认证 / 业务 / 响应格式 / 映射 / 配置', () async {
      Future<DeclarativeCapabilityTestResult> run({
        int statusCode = 200,
        Object? body,
        Object? error,
      }) async {
        transport
          ..statusCode = statusCode
          ..error = error
          ..responder = (request) async => body ?? _searchBody;
        final settings = _searchOnlySettingsWithSecrets();
        return controllerFor(
          settings,
          credential: 'SECRET_API_KEY',
        ).testCapability(
          settings.providers.single,
          OnlineMusicCapability.search,
        );
      }

      expect(
        (await run(error: StateError('offline'))).failureKind,
        DeclarativeTestFailureKind.network,
      );
      expect(
        (await run(statusCode: 500)).failureKind,
        DeclarativeTestFailureKind.http,
      );
      expect(
        (await run(statusCode: 401)).failureKind,
        DeclarativeTestFailureKind.authentication,
      );
      expect(
        (await run(statusCode: 403)).failureKind,
        DeclarativeTestFailureKind.authentication,
      );
      expect(
        (await run(body: const {'code': 500, 'data': <Object?>[]})).failureKind,
        DeclarativeTestFailureKind.business,
      );
      expect(
        (await run(body: '<html>bad gateway</html>')).failureKind,
        DeclarativeTestFailureKind.responseFormat,
      );
      expect(
        (await run(
          body: const {
            'code': 200,
            'data': [
              {'id': 1},
            ],
          },
        )).failureKind,
        DeclarativeTestFailureKind.mapping,
      );

      // 配置问题：能力根本没配绑定。
      final settings = _searchOnlySettingsWithSecrets();
      final controller = controllerFor(settings, credential: 'SECRET_API_KEY');
      expect(
        (await controller.testCapability(
          settings.providers.single,
          OnlineMusicCapability.lyric,
        )).failureKind,
        DeclarativeTestFailureKind.config,
      );

      // 同一条目上配好的能力不受影响：仍然真的发请求并给出摘要。
      transport
        ..statusCode = 200
        ..error = null
        ..responder = (request) async => _searchBody;
      final search = await controller.testCapability(
        settings.providers.single,
        OnlineMusicCapability.search,
      );
      expect(search.ok, isTrue);
      expect(search.requestSummary, isNotNull);
    });

    test('五个能力都能用当前编辑中的配置试跑一次真请求', () async {
      transport
        ..statusCode = 200
        ..error = null
        ..responder = (request) async => _allCapabilitiesBody;
      final settings = _allCapabilitiesSettings();
      final controller = controllerFor(settings, credential: 'SECRET_API_KEY');
      final definition = settings.providers.single;

      for (final capability in OnlineMusicCapability.values) {
        final result = await controller.testCapability(
          definition,
          capability,
          trackId: 'track-1',
          playlistId: 'playlist-1',
        );
        expect(
          result.ok,
          isTrue,
          reason: '${capability.name} 必须能试跑：${result.failureReason}',
        );
        expect(result.requestSummary, isNotNull);
      }
      // 五次请求都真的发出去了（不是"跳过"或"守卫挡住"）。
      expect(
        transport.requests,
        hasLength(OnlineMusicCapability.values.length),
      );
    });

    test('试跑只读当前编辑中的配置：不改写配置、全局偏好或播放状态', () async {
      transport
        ..statusCode = 200
        ..error = null
        ..responder = (request) async => _allCapabilitiesBody;
      final settings = _allCapabilitiesSettings();
      final store = _MemorySettingsStore(settings);
      reader.value = 'SECRET_API_KEY';
      final controller = OnlineMusicProviderSettingsController(
        activeSettings: settings,
        store: store,
        fallbackCredentials: _FakeAccess(),
        probeTransportFactory: (_) => transport,
        credentialReader: reader,
      );

      final qualityBefore = AppPreference.instance.defaultQuality;
      final preferenceBefore = AppPreference.instance.onlineMusicSettings;
      final definition = settings.providers.single;

      for (final capability in OnlineMusicCapability.values) {
        await controller.testCapability(
          definition,
          capability,
          trackId: 'track-1',
          playlistId: 'playlist-1',
        );
      }

      // 试跑是"只读演练"：配置、落盘内容与全局偏好都不该被它改动。
      expect(controller.settings, settings);
      expect(store.value, settings);
      expect(AppPreference.instance.defaultQuality, qualityBefore);
      expect(AppPreference.instance.onlineMusicSettings, preferenceBefore);
    });
  });
}

/// 一次搜索试跑用的响应：过成功判定 + 能映射出一条曲目。
const _searchBody = <String, Object?>{
  'code': 200,
  'data': [
    {'id': 1, 'name': 'A'},
  ],
};

/// 五能力共用的响应：每一段都刚好够该能力的映射器读出来。
const _allCapabilitiesBody = <String, Object?>{
  'code': 200,
  'data': [
    {'id': 1, 'name': 'A'},
  ],
  'detail': {
    'name': 'P',
    'tracks': [
      {'id': 1, 'name': 'T'},
    ],
  },
  'lrc': {'lyric': '[00:01.00]line'},
  'stream': {'url': 'https://media.invalid/a.flac'},
};

OnlineMusicFieldSpec _stringField(JsonPath path, {bool required = false}) =>
    OnlineMusicFieldSpec(
      candidates: [path],
      transform: OnlineMusicFieldTransform.asString,
      required: required,
    );

/// 成功判定：业务 code ∈ {0, 200}。后面几种失败大类都要靠它区分。
final _codeSuccess = OnlineMusicSuccessSpec(
  allOf: [
    OnlineMusicSuccessPredicate(
      path: JsonPathForTest.anyCode,
      op: OnlineMusicPredicateOp.inList,
      value: const [0, 200],
    ),
  ],
);

/// 带凭据、敏感请求头与普通参数的 search 绑定（W5 的脱敏与请求摘要用）。
OnlineMusicSettings _searchOnlySettingsWithSecrets() =>
    OnlineMusicSettings.fromJson({
      'providers': [
        {
          'id': 'selfData',
          'baseUrl': 'https://self.invalid',
          'auth': {'kind': 'apiKey', 'reference': 'PureMusic/Self/APIKey'},
          'capabilities': {
            'search': OnlineMusicDeclarativeCapabilityBinding(
              request: const OnlineMusicRequestSpec(
                path: '/search',
                query: [
                  OnlineMusicParamBinding(
                    name: 'keywords',
                    source: OnlineMusicInputSource.keyword,
                    required: true,
                  ),
                  OnlineMusicParamBinding(
                    name: 'limit',
                    source: OnlineMusicInputSource.limit,
                  ),
                ],
                headers: [
                  OnlineMusicHeaderSpec(name: 'X-Client', value: 'listenary'),
                  OnlineMusicHeaderSpec(
                    name: 'Cookie',
                    value: 'session=SECRET_COOKIE',
                  ),
                ],
                auth: OnlineMusicQueryAuthPlacement(parameterName: 'apikey'),
              ),
              response: OnlineMusicResponseSpec(
                success: _codeSuccess,
                listPath: JsonPathForTest.data,
                fields: {
                  OnlineMusicDomainField.trackId: _stringField(
                    JsonPathForTest.id,
                    required: true,
                  ),
                  OnlineMusicDomainField.title: _stringField(
                    JsonPathForTest.name,
                    required: true,
                  ),
                },
              ),
            ).toJson(),
          },
        },
      ],
    });

/// 五个能力各有一条声明式绑定：用来证明"每个能力都能试跑"。
OnlineMusicSettings _allCapabilitiesSettings() => OnlineMusicSettings.fromJson({
  'providers': [
    {
      'id': 'selfData',
      'baseUrl': 'https://self.invalid',
      'auth': {'kind': 'none'},
      'capabilities': {
        'search': OnlineMusicDeclarativeCapabilityBinding(
          request: const OnlineMusicRequestSpec(
            path: '/search',
            query: [
              OnlineMusicParamBinding(
                name: 'keywords',
                source: OnlineMusicInputSource.keyword,
              ),
            ],
          ),
          response: OnlineMusicResponseSpec(
            success: _codeSuccess,
            listPath: JsonPathForTest.data,
            fields: {
              OnlineMusicDomainField.trackId: _stringField(
                JsonPathForTest.id,
                required: true,
              ),
              OnlineMusicDomainField.title: _stringField(
                JsonPathForTest.name,
                required: true,
              ),
            },
          ),
        ).toJson(),
        'playlistCollection': OnlineMusicDeclarativeCapabilityBinding(
          request: const OnlineMusicRequestSpec(path: '/top/playlist'),
          response: OnlineMusicResponseSpec(
            success: _codeSuccess,
            listPath: JsonPathForTest.data,
            fields: {
              OnlineMusicDomainField.playlistId: _stringField(
                JsonPathForTest.id,
                required: true,
              ),
              OnlineMusicDomainField.playlistName: _stringField(
                JsonPathForTest.name,
                required: true,
              ),
            },
          ),
        ).toJson(),
        'playlist': OnlineMusicDeclarativeCapabilityBinding(
          request: const OnlineMusicRequestSpec(
            path: '/playlist/detail',
            query: [
              OnlineMusicParamBinding(
                name: 'id',
                source: OnlineMusicInputSource.playlistId,
                required: true,
              ),
            ],
          ),
          response: OnlineMusicResponseSpec(
            success: _codeSuccess,
            fieldsRootPath: JsonPathForTest.detail,
            listPath: JsonPathForTest.detailTracks,
            fields: {
              OnlineMusicDomainField.playlistName: _stringField(
                JsonPathForTest.name,
              ),
              OnlineMusicDomainField.trackId: _stringField(
                JsonPathForTest.id,
                required: true,
              ),
              OnlineMusicDomainField.title: _stringField(
                JsonPathForTest.name,
                required: true,
              ),
            },
          ),
        ).toJson(),
        'lyric': OnlineMusicDeclarativeCapabilityBinding(
          request: const OnlineMusicRequestSpec(
            path: '/lyric',
            query: [
              OnlineMusicParamBinding(
                name: 'id',
                source: OnlineMusicInputSource.trackId,
                required: true,
              ),
            ],
          ),
          response: OnlineMusicResponseSpec(
            success: _codeSuccess,
            fieldsRootPath: JsonPathForTest.lrc,
            fields: {
              OnlineMusicDomainField.lyricOriginal: _stringField(
                JsonPathForTest.lyric,
              ),
            },
          ),
        ).toJson(),
        'stream': OnlineMusicDeclarativeCapabilityBinding(
          request: const OnlineMusicRequestSpec(
            path: '/song/url',
            query: [
              OnlineMusicParamBinding(
                name: 'id',
                source: OnlineMusicInputSource.trackId,
                required: true,
              ),
              OnlineMusicParamBinding(
                name: 'quality',
                source: OnlineMusicInputSource.quality,
              ),
            ],
          ),
          response: OnlineMusicResponseSpec(
            success: _codeSuccess,
            fieldsRootPath: JsonPathForTest.stream,
            fields: {
              OnlineMusicDomainField.streamUrl: OnlineMusicFieldSpec(
                candidates: [JsonPathForTest.url],
                transform: OnlineMusicFieldTransform.asUri,
                required: true,
              ),
            },
          ),
        ).toJson(),
      },
    },
  ],
});

OnlineMusicSettings _declarativeSettings() => OnlineMusicSettings.fromJson({
  'providers': [
    {
      'id': 'selfData',
      'baseUrl': 'https://self.invalid',
      'auth': {'kind': 'none'},
      'capabilities': {
        'search': msapiSearchTemplate.toJson(),
        'stream': OnlineMusicDeclarativeCapabilityBinding(
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
            success: OnlineMusicSuccessSpec(
              allOf: [
                OnlineMusicSuccessPredicate(
                  path: JsonPathForTest.anyCode,
                  op: OnlineMusicPredicateOp.inList,
                  value: [0, 200],
                ),
              ],
            ),
            fieldsRootPath: JsonPathForTest.data,
            fields: {
              OnlineMusicDomainField.streamUrl: OnlineMusicFieldSpec(
                candidates: [JsonPathForTest.url],
                transform: OnlineMusicFieldTransform.asUri,
                required: true,
              ),
              OnlineMusicDomainField.trackId: OnlineMusicFieldSpec(
                candidates: [JsonPathForTest.id],
                transform: OnlineMusicFieldTransform.asInt,
              ),
            },
          ),
        ).toJson(),
      },
    },
  ],
});

/// 带凭据槽位的条目：用于验证「已配置的凭据会被探测使用」。
OnlineMusicSettings _credentialedSettings() => OnlineMusicSettings.fromJson({
  'providers': [
    {
      'id': 'selfData',
      'baseUrl': 'https://self.invalid',
      'auth': {'kind': 'apiKey', 'reference': 'PureMusic/Self/APIKey'},
    },
  ],
});

/// 测试里用到的固定路径（避免在常量表达式里调用 tryParse）。
abstract final class JsonPathForTest {
  static final anyCode = JsonPath.tryParse('code')!;
  static final data = JsonPath.tryParse('data')!;
  static final url = JsonPath.tryParse('url')!;
  static final id = JsonPath.tryParse('id')!;
  static final name = JsonPath.tryParse('name')!;
  static final detail = JsonPath.tryParse('detail')!;
  static final detailTracks = JsonPath.tryParse('detail.tracks')!;
  static final lrc = JsonPath.tryParse('lrc')!;
  static final lyric = JsonPath.tryParse('lyric')!;
  static final stream = JsonPath.tryParse('stream')!;
}

const _chkszBody = <String, Object?>{
  'code': 200,
  'msg': 'success',
  'data': {
    'songs': [
      {'id': 65800, 'name': '最佳损友', 'artists': '陈奕迅', 'duration': 233560},
    ],
    'total': 1,
  },
};

const _msapiBody = <String, Object?>{
  'result': {
    'songs': [
      {
        'id': 347230,
        'name': '海阔天空',
        'artists': [
          {'name': 'Beyond'},
        ],
        'duration': 239560,
      },
    ],
  },
};

final class _FakeTransport implements DeclarativeHttpTransport {
  final List<BuiltDeclarativeRequest> requests = [];
  Future<Object?> Function(BuiltDeclarativeRequest request) responder =
      (request) async => <String, Object?>{};

  /// 响应状态码；W5 的错误分类用例会改它。
  int statusCode = 200;

  /// 非空时直接抛出（模拟网络层失败）。
  Object? error;

  @override
  Future<DeclarativeHttpResponse> send(
    BuiltDeclarativeRequest request, {
    required OnlineMusicCancelToken cancelToken,
  }) async {
    requests.add(request);
    final failure = error;
    if (failure != null) throw failure;
    return DeclarativeHttpResponse(
      statusCode: statusCode,
      data: await responder(request),
    );
  }
}

final class _FakeCredentialReader implements OnlineMusicCredentialReader {
  String? value;

  @override
  Future<String?> readCredential(String reference) async => value;
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

final class _MemorySettingsStore implements OnlineMusicSettingsStore {
  _MemorySettingsStore(this.value);

  OnlineMusicSettings value;

  @override
  OnlineMusicSettings read() => value;

  @override
  Future<bool> write(OnlineMusicSettings settings) async {
    value = settings;
    return true;
  }
}
