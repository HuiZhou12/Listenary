import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/services/music_platform/chksz/index.dart';
import 'package:pure_music/services/music_platform/declarative/declarative_http_transport.dart';
import 'package:pure_music/services/music_platform/declarative/declarative_request_builder.dart';
import 'package:pure_music/services/music_platform/declarative/provider_templates.dart';

/// F5（P-28）：探测/试跑里 HTTP 传输资源的**所有权与释放**。
///
/// 旧缺陷：默认路径每次都 `new Dio(...)` 且**从不关闭**。
/// 现在的不变量：
/// - 控制器**自己创建**的 Dio ⇒ 探测/试跑结束后必须 `close`（**成功与异常都要**）；
/// - **外部注入**的传输（`probeTransportFactory`）⇒ 控制器**不关闭任何东西**（可能是共享实例）。
void main() {
  test('★ F5-P-28 默认路径：成功退出时创建的 Dio 被释放（创建 1 / 释放 1）', () async {
    final adapters = <_StubAdapter>[];
    final controller = _controller(dioFactory: (definition) {
      // `Dio.close()` 必然调用其适配器的 `close` ⇒ 在适配器上计数即可观测释放。
      final adapter = _StubAdapter(
        () => ResponseBody.fromString(
          '{"result":{"songs":[]}}',
          200,
          headers: {
            Headers.contentTypeHeader: ['application/json'],
          },
        ),
      );
      adapters.add(adapter);
      return Dio(BaseOptions(baseUrl: 'http://127.0.0.1:1'))
        ..httpClientAdapter = adapter;
    });

    final result = await controller.testCapability(
      _definition(),
      OnlineMusicCapability.search,
    );

    expect(adapters, hasLength(1), reason: '默认路径创建了 1 个 Dio');
    expect(
      adapters.single.closeCalls,
      1,
      reason: '用完必须释放（旧实现从不关闭 ⇒ 这里会是 0）',
    );
    expect(result.requestSummary, isNotNull, reason: '既有业务语义不变');
  });

  test('★ F5-P-28 默认路径：**异常退出**同样释放 Dio', () async {
    final adapters = <_StubAdapter>[];
    final controller = _controller(dioFactory: (definition) {
      final adapter = _StubAdapter(() => throw StateError('adapter boom'));
      adapters.add(adapter);
      return Dio(BaseOptions(baseUrl: 'http://127.0.0.1:1'))
        ..httpClientAdapter = adapter;
    });

    // 传输异常由执行引擎归类为失败结果（不抛出到调用者）—— 但资源仍必须释放。
    final result = await controller.testCapability(
      _definition(),
      OnlineMusicCapability.search,
    );

    expect(adapters, hasLength(1));
    expect(
      adapters.single.closeCalls,
      1,
      reason: '异常路径也必须在 finally 里释放',
    );
    expect(result.ok, isFalse);
  });

  test('★ F5-P-28 注入传输：控制器不创建也不关闭任何 Dio（外部所有权）', () async {
    var dioFactoryCalls = 0;
    final injected = _StubTransport();
    final controller = _controller(
      transportFactory: (definition) => injected,
      dioFactory: (definition) {
        dioFactoryCalls++;
        return Dio(BaseOptions(baseUrl: 'http://127.0.0.1:1'));
      },
    );

    await controller.testCapability(_definition(), OnlineMusicCapability.search);

    expect(
      dioFactoryCalls,
      0,
      reason: '有注入传输时不得再创建 Dio（否则就是无主资源）',
    );
  });
}

OnlineMusicProviderSettingsController _controller({
  DeclarativeProbeTransportFactory? transportFactory,
  DeclarativeProbeDioFactory? dioFactory,
}) => OnlineMusicProviderSettingsController(
  activeSettings: OnlineMusicSettings.defaults,
  store: const _MemoryStore(),
  fallbackCredentials: ChkszCredentialAccess(portableBuild: true),
  probeTransportFactory: transportFactory,
  probeDioFactory: dioFactory,
);

/// 声明式 search 定义：直接用**内置模板**（与其它测试同源，保证配置合法可试跑）。
OnlineMusicProviderDefinition _definition() =>
    OnlineMusicSettings.fromJson({
      'providers': [
        {
          'id': 'lifecycleProbe',
          'displayName': '生命周期探测',
          'contentPlatform': 'netease',
          'baseUrl': 'http://127.0.0.1:1',
          'capabilities': {'search': msapiSearchTemplate.toJson()},
        },
      ],
    }).providers.single;

class _MemoryStore implements OnlineMusicSettingsStore {
  const _MemoryStore();
  @override
  OnlineMusicSettings read() => OnlineMusicSettings.defaults;
  @override
  Future<bool> write(OnlineMusicSettings settings) async => true;
}

/// 计数用的适配器：`Dio.close()` 会调用它 ⇒ 用它观测"控制器有没有释放自己创建的 Dio"。
class _StubAdapter implements HttpClientAdapter {
  _StubAdapter(this._build);
  final ResponseBody Function() _build;

  int closeCalls = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async => _build();

  @override
  void close({bool force = false}) => closeCalls++;
}

/// 外部拥有的传输替身（记录自己是否被关闭 —— 应当**没有**）。
class _StubTransport implements DeclarativeHttpTransport {
  bool closed = false;

  @override
  Future<DeclarativeHttpResponse> send(
    BuiltDeclarativeRequest request, {
    required OnlineMusicCancelToken cancelToken,
  }) async => const DeclarativeHttpResponse(
    statusCode: 200,
    data: <String, Object?>{'result': <String, Object?>{'songs': <Object?>[]}},
  );
}
