import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/services/music_platform/chksz/index.dart';
import 'package:pure_music/services/music_platform/declarative/declarative_http_transport.dart';
import 'package:pure_music/services/music_platform/declarative/declarative_request_builder.dart';
import 'package:pure_music/services/music_platform/online_music_composition.dart';

/// F0 切片 2：**敏感请求头的运行期拒绝**（Spec §11.4 运行时行为 + §11.2.3）。
///
/// 这一片只证明一件事，但要求很硬：
/// **绝不能以明文发送敏感请求头，也绝不能静默降级** ——
/// 传输层的调用次数必须为 0，且错误与"没配凭据"可区分。
///
/// 证据里的"请求次数 / 目标 host / 假凭据命中"都来自 [_RecordingAdapter]。
void main() {
  const fakeSecret = 'FAKE_SECRET_HEADER_VALUE_TEST_ONLY';
  const plaintextSecret = 'PLAINTEXT_SECRET_IN_CONFIG_TEST_ONLY';

  late _RecordingAdapter adapter;
  late ChkszCredentialAccess access;

  setUp(() {
    adapter = _RecordingAdapter();
    access = ChkszCredentialAccess(portableBuild: true);
  });

  Future<OnlineMusicComposition> compose(OnlineMusicSettings settings) async {
    return createOnlineMusicComposition(
      settings: settings,
      portableBuild: true,
      credentialAccess: access,
      dioFactory: (_) =>
          Dio(BaseOptions(baseUrl: 'https://self.invalid'))
            ..httpClientAdapter = adapter,
    );
  }

  Future<MusicSearchPage> search(OnlineMusicComposition composition) =>
      composition.service.search(
        platform: MusicPlatform.netease,
        keyword: 'x',
        cancelToken: OnlineMusicCancelToken(),
      );

  group('敏感头 + 明文（未迁移）⇒ 明确错误且一个请求都不发', () {
    test('★ 传输层调用次数 = 0，错误与 missingCredential 可区分', () async {
      final composition = await compose(
        _settingsWithHeader(
          value: plaintextSecret,
          sensitive: true,
        ),
      );
      addTearDown(composition.service.dispose);

      await expectLater(
        search(composition),
        throwsA(
          isA<OnlineMusicException>()
              .having(
                (error) => error.kind,
                'kind',
                // notConfigured 会被路由当成"换个 Provider 试试"，把配置错误盖掉。
                isNot(OnlineMusicErrorKind.notConfigured),
              )
              .having(
                (error) => error.safeMessage,
                'safeMessage',
                contains('已标记为敏感'),
              ),
        ),
      );

      expect(adapter.requests, isEmpty, reason: '绝不能发出任何请求');
      // 明文值不得出现在任何请求里（没有请求，也就没有任何地方出现过它）。
      expect(adapter.seenPlaintext(plaintextSecret), isFalse);
    });

    test('敏感头 + 空值（"待填凭据"）同样不发请求，且报缺凭据', () async {
      final composition = await compose(
        _settingsWithHeader(value: '', sensitive: true),
      );
      addTearDown(composition.service.dispose);

      await expectLater(
        search(composition),
        throwsA(
          isA<OnlineMusicException>().having(
            (error) => error.safeMessage,
            'safeMessage',
            contains('没有可用的安全凭据引用'),
          ),
        ),
      );
      expect(adapter.requests, isEmpty);
    });

    test('"没配凭据"的错误文案与敏感头的错误文案确实不同', () async {
      // 认证放置要求凭据但槽位为空 ⇒ missingCredential 路径。
      final composition = await compose(_settingsWithAuthButNoCredential());
      addTearDown(composition.service.dispose);

      Object? captured;
      try {
        await search(composition);
      } catch (error) {
        captured = error;
      }
      expect(captured, isA<OnlineMusicException>());
      final missingCredentialMessage =
          (captured! as OnlineMusicException).safeMessage;
      expect(missingCredentialMessage, isNot(contains('已标记为敏感')));

      // 敏感头明文 ⇒ 另一条错误。
      final second = await compose(
        _settingsWithHeader(value: plaintextSecret, sensitive: true),
      );
      addTearDown(second.service.dispose);
      Object? secondError;
      try {
        await search(second);
      } catch (error) {
        secondError = error;
      }
      expect(secondError, isA<OnlineMusicException>());
      expect(
        (secondError! as OnlineMusicException).safeMessage,
        isNot(missingCredentialMessage),
      );
    });
  });

  group('敏感头 + 有效引用 ⇒ 正常注入，明文不出现', () {
    test('★ 值来自安全槽位，配置里的明文一个字都不发出', () async {
      const reference = 'selfData/search/x-secret';
      await access.save(reference, fakeSecret);

      final composition = await compose(
        _settingsWithHeader(value: '', sensitive: true, reference: reference),
      );
      addTearDown(composition.service.dispose);

      final page = await search(composition);

      expect(page.items, hasLength(1));
      expect(adapter.requests, hasLength(1));
      final request = adapter.requests.single;
      expect(request.uri.host, 'self.invalid', reason: '目标 host 不得被替换');
      expect(request.headers['X-Secret'], fakeSecret);
      // 明文（这里用配置里残留的另一个值模拟迁移前遗留）绝不出现在请求里。
      expect(adapter.seenPlaintext(plaintextSecret), isFalse);
    });

    test('引用的槽位为空 ⇒ 明确错误、不发请求（不发送空头，也不降级）', () async {
      final composition = await compose(
        _settingsWithHeader(
          value: '',
          sensitive: true,
          reference: 'selfData/search/x-secret',
        ),
      );
      addTearDown(composition.service.dispose);

      await expectLater(
        search(composition),
        throwsA(
          isA<OnlineMusicException>().having(
            (error) => error.safeMessage,
            'safeMessage',
            contains('使用安全凭据引用'),
          ),
        ),
      );
      expect(adapter.requests, isEmpty);
    });
  });

  group('未标记敏感 ⇒ 与今天完全一致', () {
    test('普通明文请求头照常发送', () async {
      final composition = await compose(
        _settingsWithHeader(value: 'plain-header-value'),
      );
      addTearDown(composition.service.dispose);

      await search(composition);

      expect(adapter.requests.single.headers['X-Secret'], 'plain-header-value');
    });
  });

  group('请求摘要按**值来源**遮蔽（P-35），不看名字', () {
    test('认证放置注入的值即使名字不在白名单里也被遮蔽', () {
      final request = buildDeclarativeRequest(
        spec: const OnlineMusicRequestSpec(
          path: '/search',
          query: [OnlineMusicParamBinding(name: 'kw', source: OnlineMusicInputSource.keyword)],
          // 名字刻意起成白名单之外的 `k`：只有"值来源"能拦住它。
          auth: OnlineMusicQueryAuthPlacement(parameterName: 'k'),
        ),
        inputs: const DeclarativeInputs(keyword: 'x'),
        credential: fakeSecret,
      );

      final summary = describeDeclarativeRequest(request);
      expect(summary, isNot(contains(fakeSecret)));
      expect(summary, contains('k=[redacted]'));
    });

    test('凭据引用的请求头即使名字不在白名单里也被遮蔽', () {
      final request = buildDeclarativeRequest(
        spec: const OnlineMusicRequestSpec(
          path: '/search',
          headers: [
            OnlineMusicHeaderSpec(name: 'X-Whatever', value: 'visible'),
            OnlineMusicHeaderSpec(
              name: 'X-Mystery',
              value: '',
              sensitive: true,
              credentialReference: 'a/b/c',
            ),
          ],
        ),
        inputs: const DeclarativeInputs(),
        headerCredentials: const {'a/b/c': fakeSecret},
      );

      final summary = describeDeclarativeRequest(request);
      expect(summary, contains('X-Whatever: visible'));
      expect(summary, isNot(contains(fakeSecret)));
      expect(summary, contains('X-Mystery: [redacted]'));
    });

    test('★ 值可疑但名字没命中的请求头（needs-user 类）在摘要里也被遮蔽', () {
      // 这一条是 F0 §7.3 边界 2 的裁定结果：名字白名单对"还不知道是不是秘密"
      // 的请求头必然漏，而漏掉的后果是摘要里直接显示那个值。
      final request = buildDeclarativeRequest(
        spec: const OnlineMusicRequestSpec(
          path: '/search',
          headers: [
            OnlineMusicHeaderSpec(name: 'X-Weird', value: 'Ab3Kd9Zx7Qm2Pl5R'),
            OnlineMusicHeaderSpec(name: 'X-Page', value: '2'),
          ],
        ),
        inputs: const DeclarativeInputs(),
      );

      final summary = describeDeclarativeRequest(request);
      expect(summary, contains('X-Weird'), reason: '名字仍要可见，否则没法排查');
      expect(summary, isNot(contains('Ab3Kd9Zx7Qm2Pl5R')));
      expect(summary, contains('X-Weird: [redacted]'));
      // 形态不可疑的照常显示（不能把诊断价值一起毁掉）。
      expect(summary, contains('X-Page: 2'));
    });

    test('普通请求（无凭据来源、名字也不敏感）不会被过度遮蔽', () {
      final request = buildDeclarativeRequest(
        spec: const OnlineMusicRequestSpec(
          path: '/search',
          query: [
            OnlineMusicParamBinding(
              name: 'kw',
              source: OnlineMusicInputSource.keyword,
            ),
          ],
        ),
        inputs: const DeclarativeInputs(keyword: 'x'),
      );

      expect(describeDeclarativeRequest(request), 'GET /search · kw=x');
    });
  });

  // ⚠️ 这一组是本片自查后补的：原先这里只有一条**名字与内容不符**的用例
  //（标题声称覆盖"非字符串/嵌套 JSON"，实际只断言了 describeDeclarativeRequest），
  // 导致 P-35 的结构化遮蔽**零覆盖**。现在真的把响应走一遍控制器路径。
  group('响应预览的结构化遮蔽（P-35：非字符串 / 嵌套 / 数组）', () {
    OnlineMusicProviderSettingsController controllerWith(Object? response) {
      final settings = _settingsWithHeader(value: 'plain-header-value');
      return OnlineMusicProviderSettingsController(
        activeSettings: settings,
        store: _MemoryStore(settings),
        fallbackCredentials: ChkszCredentialAccess(portableBuild: true),
        credentialReader: ChkszCredentialAccess(portableBuild: true),
        probeTransportFactory: (_) => _StubTransport(response),
      );
    }

    test('★ 非字符串值（数字 / 布尔 / null）同样被遮蔽', () async {
      final controller = controllerWith(const {
        'token': 12345678901234,
        'jwt': true,
        'session': null,
        'sessionid': 987654321,
        'visible': 7,
      });
      addTearDown(controller.dispose);

      final result = await controller.testCapability(
        controller.settings.providers.single,
        OnlineMusicCapability.search,
      );

      final preview = result.responsePreview!;
      for (final secret in ['12345678901234', '987654321']) {
        expect(preview, isNot(contains(secret)), reason: '非字符串的秘密也要挡');
      }
      expect(preview, contains('"token"'));
      expect(preview, contains('"visible": 7'), reason: '无关字段照常显示');
    });

    test('★ 嵌套 JSON 与数组里的秘密也被遮蔽', () async {
      final controller = controllerWith(const {
        'data': {
          'nested': {'apikey': 'NESTED_SECRET_TEST_ONLY'},
          'items': [
            {'jwt': 'ARRAY_SECRET_TEST_ONLY', 'name': 'keep-me'},
          ],
        },
      });
      addTearDown(controller.dispose);

      final result = await controller.testCapability(
        controller.settings.providers.single,
        OnlineMusicCapability.search,
      );

      final preview = result.responsePreview!;
      expect(preview, isNot(contains('NESTED_SECRET_TEST_ONLY')));
      expect(preview, isNot(contains('ARRAY_SECRET_TEST_ONLY')));
      expect(preview, contains('keep-me'), reason: '无关字段不该被牺牲');
    });
  });
  group('引用字段的模型与保存时校验', () {
    test('旧配置（只有 name/value）往返后语义与字节都不变', () {
      const legacy = {'name': 'Referer', 'value': 'https://example.com/'};

      final parsed = OnlineMusicHeaderSpec.fromJson(legacy);

      expect(parsed.sensitive, isFalse);
      expect(parsed.credentialReference, isNull);
      expect(parsed.toJson(), legacy);
    });

    test('引用会往返，且缺省不写盘', () {
      const header = OnlineMusicHeaderSpec(
        name: 'Cookie',
        value: '',
        sensitive: true,
        credentialReference: 'p/search/cookie',
      );

      final json = header.toJson();

      expect(json['reference'], 'p/search/cookie');
      expect(json['value'], '');
      expect(OnlineMusicHeaderSpec.fromJson(json), header);
      // 未标记敏感、无引用 ⇒ 不写这两个键。
      const plain = OnlineMusicHeaderSpec(name: 'X', value: 'y');
      expect(plain.toJson().containsKey('sensitive'), isFalse);
      expect(plain.toJson().containsKey('reference'), isFalse);
    });

    test('★ 有引用还留着明文 ⇒ 校验失败（迁移没做完）', () {
      final issues = const OnlineMusicRequestSpec(
        path: '/x',
        headers: [
          OnlineMusicHeaderSpec(
            name: 'Cookie',
            value: plaintextSecret,
            sensitive: true,
            credentialReference: 'p/search/cookie',
          ),
        ],
      ).validationIssues();

      expect(issues, hasLength(1));
      expect(issues.single, contains('明文值必须清空'));
    });

    test('有引用但没标记敏感 ⇒ 校验失败（配置自相矛盾）', () {
      final issues = const OnlineMusicRequestSpec(
        path: '/x',
        headers: [
          OnlineMusicHeaderSpec(
            name: 'Cookie',
            value: '',
            credentialReference: 'p/search/cookie',
          ),
        ],
      ).validationIssues();

      expect(issues, hasLength(1));
      expect(issues.single, contains('没有标记为敏感'));
    });

    test('★ Header 名归一化碰撞 ⇒ 校验失败并点名双方', () {
      final issues = const OnlineMusicRequestSpec(
        path: '/x',
        headers: [
          OnlineMusicHeaderSpec(name: 'X-Token', value: ''),
          OnlineMusicHeaderSpec(name: 'x_token', value: ''),
        ],
      ).validationIssues();

      expect(issues, hasLength(1));
      expect(issues.single, contains('X-Token'));
      expect(issues.single, contains('x_token'));
      expect(issues.single, contains('归一化后同名'));
    });

    test('归一化本身：大小写/连字符/下划线/空白收敛到同一段', () {
      String segment(String name) => normalizeOnlineMusicHeaderSlotSegment(name);

      expect(segment(' X-Token '), 'x-token');
      expect(segment('x_token'), 'x-token');
      expect(segment('X  Token'), 'x-token');
      expect(segment('Cookie'), 'cookie');
      // 槽位名稳定：同样的输入永远得到同一个槽位。
      expect(
        onlineMusicHeaderSlotName(
          providerId: 'selfData',
          capability: OnlineMusicCapability.search,
          headerName: 'X-Token',
        ),
        onlineMusicHeaderSlotName(
          providerId: 'selfData',
          capability: OnlineMusicCapability.search,
          headerName: 'x_token',
        ),
      );
      // providerId **保持原样**（Spec §3）：只差大小写的两个条目不得被合并到同一槽位。
      expect(
        onlineMusicHeaderSlotName(
          providerId: 'SelfData',
          capability: OnlineMusicCapability.search,
          headerName: 'Cookie',
        ),
        isNot(
          onlineMusicHeaderSlotName(
            providerId: 'selfData',
            capability: OnlineMusicCapability.search,
            headerName: 'Cookie',
          ),
        ),
      );
      // 能力段统一小写（枚举名实际是 camelCase）。
      expect(
        onlineMusicHeaderSlotName(
          providerId: 'p',
          capability: OnlineMusicCapability.playlistCollection,
          headerName: 'Cookie',
        ),
        'p/playlistcollection/cookie',
      );
    });
  });
}

// ---------------------------------------------------------------------- 夹具

JsonPath _p(String source) => JsonPath.tryParse(source)!;

Map<String, Object?> _searchBindingJson({
  required String value,
  bool sensitive = false,
  String? reference,
  bool withAuth = false,
}) => OnlineMusicDeclarativeCapabilityBinding(
  request: OnlineMusicRequestSpec(
    path: '/search',
    query: [
      const OnlineMusicParamBinding(
        name: 'keywords',
        source: OnlineMusicInputSource.keyword,
        required: true,
      ),
    ],
    headers: [
      const OnlineMusicHeaderSpec(name: 'X-Client', value: 'listenary'),
      OnlineMusicHeaderSpec(
        name: 'X-Secret',
        value: value,
        sensitive: sensitive,
        credentialReference: reference,
      ),
    ],
    auth: withAuth
        ? const OnlineMusicQueryAuthPlacement(parameterName: 'apikey')
        : const OnlineMusicNoAuthPlacement(),
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

OnlineMusicSettings _settingsWithHeader({
  required String value,
  bool sensitive = false,
  String? reference,
}) => OnlineMusicSettings.fromJson({
  'providers': [
    {
      'id': 'selfData',
      'baseUrl': 'https://self.invalid',
      'auth': {'kind': 'none'},
      'capabilities': {
        'search': _searchBindingJson(
          value: value,
          sensitive: sensitive,
          reference: reference,
        ),
      },
    },
  ],
  'defaultProvider': 'selfData',
});

OnlineMusicSettings _settingsWithAuthButNoCredential() =>
    OnlineMusicSettings.fromJson({
      'providers': [
        {
          'id': 'selfData',
          'baseUrl': 'https://self.invalid',
          'auth': {'kind': 'apiKey', 'reference': 'PureMusic/Self/APIKey'},
          'capabilities': {
            'search': _searchBindingJson(value: 'plain-header-value', withAuth: true),
          },
        },
      ],
      'defaultProvider': 'selfData',
    });

final class _RecordingAdapter implements HttpClientAdapter {
  final List<RequestOptions> requests = [];
  final List<String> bodies = [];

  bool seenPlaintext(String needle) {
    for (final request in requests) {
      final rendered = <String, Object?>{
        for (final entry in request.headers.entries) entry.key: entry.value,
        'uri': request.uri.toString(),
        'query': '${request.queryParameters}',
      }.toString();
      if (rendered.contains(needle)) return true;
    }
    return bodies.any((body) => body.contains(needle));
  }

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

/// 只回一个固定响应的传输层替身（试跑路径用）。
final class _StubTransport implements DeclarativeHttpTransport {
  _StubTransport(this.response);

  final Object? response;

  @override
  Future<DeclarativeHttpResponse> send(
    BuiltDeclarativeRequest request, {
    required OnlineMusicCancelToken cancelToken,
  }) async => DeclarativeHttpResponse(statusCode: 200, data: response);
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
