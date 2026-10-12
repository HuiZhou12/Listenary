import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/core/preference.dart';
import 'package:pure_music/services/music_platform/chksz/index.dart';
import 'package:pure_music/services/music_platform/declarative/declarative_diagnostics.dart';
import 'package:pure_music/services/music_platform/declarative/declarative_http_transport.dart';
import 'package:pure_music/services/music_platform/declarative/declarative_verification.dart';
import 'package:pure_music/services/music_platform/declarative/provider_probe.dart';
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
    '★ F3-S3 探测打的是**条目自己**的绑定（P-05）并标注来源与能力',
    () async {
      transport.responder = (request) async => _msapiBody;

      final report = await controller().probeSearch(
        store.value.providers.single,
      );

      // 以前这里探测的是**编译期模板**（`draftTemplateId == 'netease-proxy'`），
      // 而那正是 P-05「探测与用户配置完全脱钩」：探测"成功"的是模板指纹。
      // 现在候选来自条目自身配置，来源与能力都跟着结论走（D-F3-1 第 3 条 / D-F3-5 第 6 条）。
      expect(report.draftTemplateId, 'user:search');
      expect(report.draftSource, ProviderProbeCandidateSource.userConfig);
      expect(report.draftCapability, OnlineMusicCapability.search);
      expect(
        report.outcomes.single.source,
        ProviderProbeCandidateSource.userConfig,
      );
      expect(report.outcomes.single.sourceLabel, contains('条目自身配置'));
      expect(report.outcomes.single.sourceLabel, contains('搜索'));
      expect(
        transport.requests.map((request) => request.path),
        contains('/search'),
      );
      // D-F3-5 第 4 条：每个候选**最多一个**探针请求（服务级探测不逐能力重复打）。
      expect(transport.requests, hasLength(1));
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

      // ⚠️ 断言随 F3-S3（D-F3-1）更新，**不是放宽**：该条目**自己**配了声明式搜索绑定 ⇒
      // 候选只有"条目自身配置"这一条，**不再**顺带探测两个兼容模板
      //（以前那样会把模板的成功混进结论里，正是 P-05 的形态）。
      expect(transport.requests.map((request) => request.path).toSet(), {
        '/search',
      });
      for (final request in transport.requests) {
        expect(request.query.containsKey('apikey'), isFalse);
      }
      expect(report.draftTemplateId, 'user:search');
      expect(report.draftSource, ProviderProbeCandidateSource.userConfig);
    },
  );

  test(
    '★ P-54 条目「不需要 Key」时，probe 即使**读得到**凭据也不使用（与运行期同一口径）',
    () async {
      // ⚠️ 夹具刻意让读取口**有值**、且槽位名**显式保留**
      //（`kind: none` 也会保留 reference —— 既有设计：关掉认证不孤立已存的 Key）。
      // 因此只有"按 `requiresCredential` 判断是否可用"这一条口径能拦住它；
      // 若像以前那样只看 reference 是否存在，凭据就会被带进探测请求。
      reader.value = 'chksz_KEY_TEST_ONLY';
      transport.responder = (request) async => _msapiBody;
      final settings = OnlineMusicSettings.fromJson({
        'providers': [
          {
            'id': 'selfData',
            'baseUrl': 'https://self.invalid',
            'auth': {'kind': 'none', 'reference': 'a/b/c'},
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
                  ],
                ),
                response: OnlineMusicResponseSpec(
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
      final store = _MemorySettingsStore(settings);
      final controller = OnlineMusicProviderSettingsController(
        activeSettings: settings,
        store: store,
        fallbackCredentials: _FakeAccess(),
        probeTransportFactory: (_) => transport,
        credentialReader: reader,
      );

      await controller.probeSearch(settings.providers.single);

      expect(transport.requests, isNotEmpty, reason: '探测本身照常进行');
      for (final request in transport.requests) {
        expect(
          request.query.values,
          isNot(contains('chksz_KEY_TEST_ONLY')),
          reason: '条目不需要 Key ⇒ 探测不得使用凭据',
        );
        expect(request.headers.values, isNot(contains('chksz_KEY_TEST_ONLY')));
      }
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

    test('试跑先按配置校验拦下"放行但映射必然 null"的转换（P-30，且不发请求）', () async {
      transport.responder = (request) async => _allCapabilitiesBody;
      // 这份配置在**保存**时早就被拒（categoryCount 读取器只认 int），
      // 但试跑以前不校验配置 ⇒ 会发请求并报"成功"，而 count 其实是 null。
      final settings = OnlineMusicSettings.fromJson({
        'providers': [
          {
            'id': 'selfData',
            'baseUrl': 'https://self.invalid',
            'auth': {'kind': 'none'},
            'capabilities': {
              'playlistCategories': OnlineMusicDeclarativeCapabilityBinding(
                request: const OnlineMusicRequestSpec(
                  path: '/playlist/catlist',
                ),
                response: OnlineMusicResponseSpec(
                  success: _codeSuccess,
                  listPath: JsonPathForTest.data,
                  fields: {
                    OnlineMusicDomainField.categoryId: _stringField(
                      JsonPathForTest.id,
                      required: true,
                    ),
                    OnlineMusicDomainField.categoryName: _stringField(
                      JsonPathForTest.name,
                      required: true,
                    ),
                    OnlineMusicDomainField.categoryCount: _stringField(
                      JsonPathForTest.count,
                    ),
                  },
                ),
              ).toJson(),
            },
          },
        ],
      });

      final result = await controllerFor(settings).testCapability(
        settings.providers.single,
        OnlineMusicCapability.playlistCategories,
      );

      expect(result.ok, isFalse);
      expect(result.failureKind, DeclarativeTestFailureKind.config);
      expect(result.failureReason, contains('categoryCount'));
      expect(
        transport.requests,
        isEmpty,
        reason: '配置不合法 ⇒ 一个请求都不该发出去',
      );
    });

    test('★ P-54 试跑与运行期**同结论**：认证矛盾归配置错误，且不发请求', () async {
      transport.responder = (request) async => _allCapabilitiesBody;
      // 条目设为「不需要 Key」，但能力声明了认证 —— 以前试跑会**读到凭据并报成功**，
      // 而运行期因为没有凭据槽位报 missingCredential（两份说法）。
      // 现在两边共用同一个判据与**同一句文案**，并且都不发请求。
      final settings = OnlineMusicSettings.fromJson({
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
                      required: true,
                    ),
                  ],
                  auth: OnlineMusicQueryAuthPlacement(parameterName: 'key'),
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

      final result = await controllerFor(
        settings,
        credential: 'SECRET_PROBE_TEST_ONLY',
      ).testCapability(settings.providers.single, OnlineMusicCapability.search);

      expect(result.ok, isFalse);
      expect(result.failureKind, DeclarativeTestFailureKind.config);
      expect(result.failureReason, contains('请先把条目的 Key 打开'));
      expect(
        result.failureReason,
        isNot(contains('SECRET_PROBE_TEST_ONLY')),
        reason: '文案不得回显凭据值',
      );
      expect(
        transport.requests,
        isEmpty,
        reason: '配置矛盾 ⇒ 不发请求（与运行期同一判据）',
      );
    });

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

      // ⚠️ 断言随 F3-S2（D-F3-4）更新，**不是放宽**：`StateError` 是**编程错误**，
      // 不是传输异常 —— D-F3-4 明令"不得将编程错误或非传输异常一律吞成'网络不可达'"。
      // 因此这里改用**真正的传输异常**（`SocketException`）验证网络大类，
      // 并把"非传输异常"单独钉住（它必须与网络**不同**结论）。
      expect(
        (await run(error: const SocketException('connection refused'))).failureKind,
        DeclarativeTestFailureKind.network,
      );
      expect(
        (await run(error: StateError('offline'))).failureKind,
        isNot(DeclarativeTestFailureKind.network),
        reason: 'D-F3-4：编程错误不得再被吞成"网络不可达"',
      );
      expect(
        (await run(error: const SocketException('connection refused'))).failureReason,
        contains('无法连接'),
        reason: 'F3-S2：传输失败要说出**底层类型**，而不是一句"网络不可达"',
      );
      expect(
        (await run(error: StateError('offline'))).failureReason,
        contains('非传输异常'),
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

    test('每个能力都能用当前编辑中的配置试跑一次真请求', () async {
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

    // ---------------------------------------------------------------- F3-S6（D-F3-3）

    test('★ F3-S6 合法空结果 ⇒ **未能确认**（既不是成功，也不是映射失败）', () async {
      // 七个"列表 / 文本"型能力各给一份**结构合法但没有数据**的响应。
      transport
        ..statusCode = 200
        ..error = null
        ..responder = (request) async => _emptyCapabilitiesBody;
      final settings = _allCapabilitiesSettings();
      final controller = controllerFor(settings, credential: 'SECRET_API_KEY');
      final definition = settings.providers.single;

      const listCapabilities = [
        OnlineMusicCapability.search,
        OnlineMusicCapability.newSongs,
        OnlineMusicCapability.playlist,
        OnlineMusicCapability.playlistCollection,
        OnlineMusicCapability.chartList,
        OnlineMusicCapability.playlistCategories,
        OnlineMusicCapability.lyric,
      ];
      for (final capability in listCapabilities) {
        final result = await controller.testCapability(
          definition,
          capability,
          trackId: 'track-1',
          playlistId: 'playlist-1',
        );
        expect(
          result.confidence,
          DeclarativeVerificationConfidence.unconfirmed,
          reason: '${capability.name}：空结果不能算"可用"，也不能一律当"映射失败"',
        );
        expect(result.ok, isFalse, reason: '空列表什么也没证明');
        expect(
          result.failureKind,
          isNull,
          reason: '${capability.name}：这是"未能确认"，不该捏造一个失败大类',
        );
        expect(result.failureReason, contains('合法空结果'));
        expect(result.failureReason, contains('配置'));
      }

      // 对照组：同一份配置**有数据**时是"已验证可用" ⇒ 判据确实在区分两种情形。
      transport.responder = (request) async => _allCapabilitiesBody;
      final verified = await controller.testCapability(
        definition,
        OnlineMusicCapability.search,
      );
      expect(verified.confidence, DeclarativeVerificationConfidence.verified);
      expect(verified.ok, isTrue);
    });

    test('★ F3-S6 字段缺失 / 映射错误 ⇒ **验证失败**（与合法空结果不同判据）', () async {
      transport
        ..statusCode = 200
        ..error = null
        ..responder = (request) async => _allCapabilitiesBody;
      final settings = _allCapabilitiesSettings();
      final controller = controllerFor(settings, credential: 'SECRET_API_KEY');

      // ① 配置缺项（歌单详情没配列表路径）⇒ 明确的**配置**失败，不是"空歌单"。
      final withoutListPath = settings.providers.single.withCapabilityBinding(
        OnlineMusicCapability.playlist,
        const OnlineMusicDeclarativeCapabilityBinding(
          request: OnlineMusicRequestSpec(path: '/playlist/detail'),
          response: OnlineMusicResponseSpec(),
        ),
      );
      final missingListPath = await controller.testCapability(
        withoutListPath,
        OnlineMusicCapability.playlist,
        playlistId: 'playlist-1',
      );
      expect(
        missingListPath.confidence,
        DeclarativeVerificationConfidence.failed,
      );
      expect(missingListPath.failureKind, DeclarativeTestFailureKind.config);

      // ② 字段映射错误（必填的 id 取不到）⇒ 映射失败。
      transport.responder = (request) async => const {
        'code': 200,
        'data': [
          {'name': 'A'},
        ],
      };
      final mapping = await controller.testCapability(
        settings.providers.single,
        OnlineMusicCapability.search,
      );
      expect(mapping.confidence, DeclarativeVerificationConfidence.failed);
      expect(mapping.failureKind, DeclarativeTestFailureKind.mapping);
    });

    test('★ F3-S6 三态词表**只有一处**（探测与试跑同一套）', () {
      expect(
        declarativeVerificationConfidenceLabel(
          DeclarativeVerificationConfidence.verified,
        ),
        '已验证可用',
      );
      expect(
        declarativeVerificationConfidenceLabel(
          DeclarativeVerificationConfidence.unconfirmed,
        ),
        '未能确认',
      );
      expect(
        declarativeVerificationConfidenceLabel(
          DeclarativeVerificationConfidence.failed,
        ),
        '验证失败',
      );
      expect(DeclarativeVerificationConfidence.values, hasLength(3));
    });

    test('★ F4-S8 试跑遇到 HTML 响应 ⇒ 归"响应格式"并说明不是 JSON（不是映射失败）', () async {
      transport
        ..statusCode = 200
        ..error = null
        ..responder = (request) async => '<!DOCTYPE html><html></html>';
      final settings = _searchOnlySettingsWithSecrets();
      final controller = controllerFor(settings, credential: 'SECRET_API_KEY');

      final result = await controller.testCapability(
        settings.providers.single,
        OnlineMusicCapability.search,
      );

      expect(result.confidence, DeclarativeVerificationConfidence.failed);
      expect(
        result.failureKind,
        DeclarativeTestFailureKind.responseFormat,
        reason: '不是 mapping（那会把人引去补字段配置）',
      );
      expect(result.failureReason, allOf(contains('不是 JSON'), contains('不匹配')));
    });

    test('★ F3-S7 试跑用**用户给的**关键词与数量，不再写死（默认值仍然保留）', () async {
      transport
        ..statusCode = 200
        ..error = null
        ..responder = (request) async => _allCapabilitiesBody;
      // ⚠️ 用**本用例自带**的绑定：它显式声明了 `keywords` 与 `limit` 两个查询参数 ——
      // 只有绑定声明了某个参数，用户的输入才可能出现在请求里（这正是要验的那条链路）。
      final settings = OnlineMusicSettings.fromJson({
        'providers': [
          {
            'id': 'selfData',
            'baseUrl': 'https://self.invalid',
            'auth': {'kind': 'apiKey', 'reference': 'self/APIKey'},
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
                ),
                response: OnlineMusicResponseSpec(
                  success: _codeSuccess,
                  listPath: JsonPathForTest.data,
                  fields: {
                    OnlineMusicDomainField.trackId: _intField(
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
              'newSongs': OnlineMusicDeclarativeCapabilityBinding(
                request: const OnlineMusicRequestSpec(
                  path: '/new',
                  query: [
                    OnlineMusicParamBinding(
                      name: 'limit',
                      source: OnlineMusicInputSource.limit,
                    ),
                  ],
                ),
                response: OnlineMusicResponseSpec(
                  success: _codeSuccess,
                  listPath: JsonPathForTest.data,
                  fields: {
                    OnlineMusicDomainField.trackId: _intField(
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
      final controller = controllerFor(settings, credential: 'SECRET_API_KEY');
      final definition = settings.providers.single;

      // ① 自定义关键词与数量**真的**进了请求。
      await controller.testCapability(
        definition,
        OnlineMusicCapability.search,
        keyword: '自定义关键词',
        limit: 7,
      );
      final sent = transport.requests.last.query;
      expect(sent['keywords'], '自定义关键词', reason: 'P-49：以前恒为探测用的常量');
      expect(sent['limit'], '7', reason: 'P-49：搜索以前恒为 1');

      // ② 不传时行为不变（仍然是既有默认值）。
      await controller.testCapability(definition, OnlineMusicCapability.search);
      final defaults = transport.requests.last.query;
      expect(defaults['keywords'], providerProbeKeyword);
      expect(defaults['limit'], '$providerProbeLimit');

      // ③ 新歌同理（以前把 30 写死，用户给的数量被忽略）。
      //
      // ⚠️ 只断言**请求**里的 limit：映射器拿到 limit 后只用于分页元数据
      //（`hasMore` 之类），**不截断**解析出的条目 ⇒ 结果摘要在 limit=3 与 limit=30 下
      // 完全一样、没有可观察差异。因此"映射侧也用用户的 limit"这条**今日无独立覆盖**，
      // 如实记录（不为它编造断言）。
      await controller.testCapability(
        definition,
        OnlineMusicCapability.newSongs,
        limit: 3,
      );
      expect(transport.requests.last.query['limit'], '3');
    });
    test('★ F3-S6 界面词表与判定**同源**（源码守卫）', () {
      // 试跑标题与探测逐行都必须按**三态**分支；以前是 `result.ok ? 成功 : 失败`，
      // 于是"未能确认"会被渲染成"失败"（或反过来被渲染成成功）—— D-F3-3 明令禁止。
      final source = File(
        'lib/page/settings_page/online_music_capability_editor.dart',
      ).readAsStringSync();

      expect(
        source,
        contains('DeclarativeVerificationConfidence.unconfirmed'),
        reason: '标题必须按三态分支，而不是布尔',
      );
      expect(source, contains('未能确认'));
      expect(
        source,
        isNot(contains("result.ok ? '试跑成功' : '试跑失败'")),
        reason: 'D-F3-3：不能把"未能确认"渲染成失败（也不能渲染成成功）',
      );
      expect(
        source,
        contains('declarativeVerificationConfidenceLabel(outcome.confidence)'),
        reason: '探测逐行与试跑必须用**同一套**词表',
      );
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
    {'id': 1, 'name': 'A', 'count': 7},
  ],
  'detail': {
    'id': 9,
    'name': 'P',
    'tracks': [
      {'id': 1, 'name': 'T'},
    ],
  },
  'lrc': {'lyric': '[00:01.00]line'},
  'stream': {'id': 'track-1', 'url': 'https://media.invalid/a.flac'},
};

/// 七能力共用的**合法空结果**：结构与成功判定都对，只是没有任何可验证的数据。
///
/// 空歌单 / 空榜单 / 纯音乐没有歌词都是**合法**的 ⇒ 结论必须是"未能确认"，
/// 既不能算"可用"，也不能一律当"映射失败"（D-F3-3）。
const _emptyCapabilitiesBody = <String, Object?>{
  'code': 200,
  'data': <Object?>[],
  'detail': {
    'id': 9,
    'name': 'P',
    'tracks': <Object?>[],
  },
  'lrc': <String, Object?>{},
  'stream': {'id': 'track-1', 'url': 'https://media.invalid/a.flac'},
};

OnlineMusicFieldSpec _stringField(JsonPath path, {bool required = false}) =>
    OnlineMusicFieldSpec(
      candidates: [path],
      transform: OnlineMusicFieldTransform.asString,
      required: required,
    );

/// 数量类字段必须用**整数**转换：读取器（`_readIntField`）只认 `int`，
/// 配成 `asString` 会被校验拦下（P-30），放行时也会静默变 null。
OnlineMusicFieldSpec _intField(JsonPath path, {bool required = false}) =>
    OnlineMusicFieldSpec(
      candidates: [path],
      transform: OnlineMusicFieldTransform.asInt,
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

/// **每个**能力各有一条声明式绑定：用来证明"每个能力都能试跑"。
/// （新增能力时必须同步补一条，否则 `OnlineMusicCapability.values` 的遍历会暴露缺口。）
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
        'artist': OnlineMusicDeclarativeCapabilityBinding(
          request: const OnlineMusicRequestSpec(
            path: '/artists',
            query: [
              OnlineMusicParamBinding(
                name: 'id',
                source: OnlineMusicInputSource.artistId,
              ),
            ],
          ),
          response: OnlineMusicResponseSpec(
            success: _codeSuccess,
            listPath: JsonPathForTest.data,
            fields: {
              // 标量（艺人名）+ 曲目字段（热门曲目）—— 与真实配置同形 ✓。
              OnlineMusicDomainField.artistName: _stringField(
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
        'chartList': OnlineMusicDeclarativeCapabilityBinding(
          request: const OnlineMusicRequestSpec(path: '/toplist'),
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
              OnlineMusicDomainField.playlistUpdateFrequency: _stringField(
                JsonPathForTest.name,
              ),
            },
          ),
        ).toJson(),
        'playlistCategories': OnlineMusicDeclarativeCapabilityBinding(
          request: const OnlineMusicRequestSpec(path: '/playlist/catlist'),
          response: OnlineMusicResponseSpec(
            success: _codeSuccess,
            listPath: JsonPathForTest.data,
            fields: {
              OnlineMusicDomainField.categoryId: _stringField(
                JsonPathForTest.id,
                required: true,
              ),
              OnlineMusicDomainField.categoryName: _stringField(
                JsonPathForTest.name,
                required: true,
              ),
              OnlineMusicDomainField.categoryCount: _intField(
                JsonPathForTest.count,
              ),
            },
          ),
        ).toJson(),
        'newSongs': OnlineMusicDeclarativeCapabilityBinding(
          request: const OnlineMusicRequestSpec(path: '/personalized/newsong'),
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
              // P-30 连带修正：歌单详情的**必填**字段是 playlistId + playlistName，
              // 这个夹具以前只有 name ⇒ 保存路径会拒绝它，而试跑（当时不校验配置）
              // 照样报成功。补齐后夹具才是"每个能力都能试跑"的有效配置。
              OnlineMusicDomainField.playlistId: _stringField(
                JsonPathForTest.id,
                required: true,
              ),
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
              // P-42：播放解析必须能证明身份（响应体里的 `stream.id` 与试跑用的 trackId 一致）。
              OnlineMusicDomainField.trackId: _stringField(
                JsonPathForTest.id,
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
  static final count = JsonPath.tryParse('count')!;
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
