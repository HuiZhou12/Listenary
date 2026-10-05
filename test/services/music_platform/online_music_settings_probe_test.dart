import 'package:flutter_test/flutter_test.dart';
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

  test('probeSearch uses the entry baseUrl transport and yields a draft', () async {
    transport.responder = (request) async => _msapiBody;

    final report = await controller().probeSearch(store.value.providers.single);

    expect(report.draftTemplateId, 'netease-proxy');
    expect(
      transport.requests.map((request) => request.path),
      contains('/search'),
    );
  });

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

  test('probeSearch never attaches a credential the entry does not have', () async {
    transport.responder = (request) async => _msapiBody;

    final report = await controller().probeSearch(store.value.providers.single);

    // 两个候选都会真的被探测一次，且都不带凭据。
    expect(
      transport.requests.map((request) => request.path).toSet(),
      {'/api/163_search', '/search'},
    );
    for (final request in transport.requests) {
      expect(request.query.containsKey('apikey'), isFalse);
    }
    expect(report.draftTemplateId, 'netease-proxy');
  });

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

  test('testCapability reports a mapping failure instead of guessing', () async {
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
  });

  test('testCapability(stream) needs a track id and hides signed URLs', () async {
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
  });

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

    final unsupported = await controller().testCapability(
      store.value.providers.single,
      OnlineMusicCapability.lyric,
    );
    expect(unsupported.ok, isFalse);
    expect(unsupported.failureReason, contains('第二阶段'));
    expect(transport.requests, isEmpty);
  });

  test('the response preview is redacted and truncated', () async {
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
    expect(result.responsePreview!.length, lessThan(420));
  });

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
}

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
  Future<Map<String, Object?>> Function(BuiltDeclarativeRequest request)
  responder = (request) async => <String, Object?>{};

  @override
  Future<DeclarativeHttpResponse> send(
    BuiltDeclarativeRequest request, {
    required OnlineMusicCancelToken cancelToken,
  }) async {
    requests.add(request);
    return DeclarativeHttpResponse(
      statusCode: 200,
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
