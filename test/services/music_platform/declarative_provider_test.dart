import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/services/music_platform/chksz/index.dart';
import 'package:pure_music/services/music_platform/online_music_composition.dart';

JsonPath _p(String source) => JsonPath.tryParse(source)!;

Map<String, Object?> _searchBindingJson({
  String path = '/search',
  String keywordParam = 'keywords',
  String listPath = 'result.songs',
  String titlePath = 'name',
}) => OnlineMusicDeclarativeCapabilityBinding(
  request: OnlineMusicRequestSpec(
    path: path,
    query: [
      OnlineMusicParamBinding(
        name: keywordParam,
        source: OnlineMusicInputSource.keyword,
        required: true,
      ),
      const OnlineMusicParamBinding(
        name: 'limit',
        source: OnlineMusicInputSource.limit,
        defaultValue: 30,
      ),
    ],
  ),
  response: OnlineMusicResponseSpec(
    listPath: _p(listPath),
    fields: {
      OnlineMusicDomainField.trackId: OnlineMusicFieldSpec(
        candidates: [_p('id')],
        transform: OnlineMusicFieldTransform.asInt,
        required: true,
      ),
      OnlineMusicDomainField.title: OnlineMusicFieldSpec(
        candidates: [_p(titlePath)],
        transform: OnlineMusicFieldTransform.asString,
        required: true,
      ),
      OnlineMusicDomainField.artists: OnlineMusicFieldSpec(
        candidates: [_p('artists[*].name')],
        transform: OnlineMusicFieldTransform.asStringList,
      ),
    },
  ),
).toJson();

Map<String, Object?> _streamBindingJson() => {
  'kind': 'http',
  'request': const OnlineMusicRequestSpec(
    path: '/song/url',
    query: [
      OnlineMusicParamBinding(
        name: 'id',
        source: OnlineMusicInputSource.trackId,
        required: true,
      ),
    ],
    auth: OnlineMusicQueryAuthPlacement(parameterName: 'key'),
  ).toJson(),
  'response': OnlineMusicResponseSpec(
    success: OnlineMusicSuccessSpec(
      allOf: [
        OnlineMusicSuccessPredicate(
          path: _p('code'),
          op: OnlineMusicPredicateOp.eq,
          value: 0,
        ),
      ],
    ),
    fieldsRootPath: _p('data'),
    fields: {
      OnlineMusicDomainField.streamUrl: OnlineMusicFieldSpec(
        candidates: [_p('url')],
        transform: OnlineMusicFieldTransform.asUri,
        required: true,
      ),
      // P-42：播放解析**必须能证明身份**（没有它就无法判断返回的是不是请求的那首歌）。
      // 夹具随之补上：以前这里只有 url/br，属于"无法证明身份"的配置。
      OnlineMusicDomainField.trackId: OnlineMusicFieldSpec(
        candidates: [_p('id')],
        transform: OnlineMusicFieldTransform.asString,
      ),
      OnlineMusicDomainField.streamBitrate: OnlineMusicFieldSpec(
        candidates: [_p('br')],
        transform: OnlineMusicFieldTransform.asInt,
      ),
    },
  ).toJson(),
};

/// 一份「自建服务」配置：数据来自声明式 Search，播放走声明式 Stream，
/// Playlist / Lyric 明确不支持。
OnlineMusicSettings _selfHostedSettings() => OnlineMusicSettings.fromJson({
  'providers': [
    {
      'id': 'selfData',
      'baseUrl': 'https://self.invalid',
      'auth': {'kind': 'apiKey', 'reference': 'PureMusic/Self/APIKey'},
      'capabilities': {
        'search': _searchBindingJson(),
        'stream': _streamBindingJson(),
      },
    },
  ],
  'defaultProvider': 'selfData',
});

void main() {
  late _RecordingAdapter adapter;
  late ChkszCredentialAccess access;

  setUp(() {
    adapter = _RecordingAdapter();
    access = ChkszCredentialAccess(portableBuild: true);
  });

  Future<OnlineMusicComposition> compose(
    OnlineMusicSettings settings, {
    _Responder? responder,
  }) async {
    adapter.responder = responder ?? _defaultResponder;
    return createOnlineMusicComposition(
      settings: settings,
      portableBuild: true,
      credentialAccess: access,
      dioFactory: (_) =>
          Dio(BaseOptions(baseUrl: 'https://self.invalid'))
            ..httpClientAdapter = adapter,
    );
  }

  test(
    '★ P-54 条目设为「不需要 Key」但能力声明了认证 ⇒ 归**配置错误**（禁止回退），且一个请求都不发',
    () async {
      // P-36 的矛盾组合：能力级说"要注入认证"，条目级说"不需要 Key"。
      // ⚠️ 结论在 F2-S8 被**收紧**（本条断言随之上移，不是放宽）：
      // 以前它归 `notConfigured`（"凭据还没配"），而 `notConfigured` **在回退白名单里**
      // ⇒ 会被静默换个 Provider 掩盖；但"条目根本不需要 Key"这种矛盾换谁都没用。
      // 现在归 `badRequest`（配置错误，禁止回退），并由运行时与试跑**共用同一句文案**。
      // 对照：真正"需要 Key 但还没配"的情形仍然 `notConfigured`（见上一条用例）。
      final settings = OnlineMusicSettings.fromJson({
        'providers': [
          {
            'id': 'selfData',
            'baseUrl': 'https://self.invalid',
            'auth': {'kind': 'none'},
            'capabilities': {
              'search': _searchBindingJson(),
              'stream': _streamBindingJson(),
            },
          },
        ],
      });
      final composition = await compose(settings);
      addTearDown(composition.service.dispose);

      await expectLater(
        composition.service.resolve(
          const PlatformTrackRef(
            platform: MusicPlatform.netease,
            trackId: '347230',
          ),
          requestedQuality: 'lossless',
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
                contains('请先把条目的 Key 打开'),
              ),
        ),
      );
      expect(
        adapter.requests,
        isEmpty,
        reason: '配置矛盾 ⇒ fail-closed：一个请求都不该发出去',
      );
    },
  );

  test('a declarative search really issues the configured request', () async {
    final composition = await compose(_selfHostedSettings());
    addTearDown(composition.service.dispose);

    final page = await composition.service.search(
      platform: MusicPlatform.netease,
      keyword: '海阔天空',
      limit: 5,
      cancelToken: OnlineMusicCancelToken(),
    );

    final sent = adapter.requests.single;
    expect(sent.method, 'GET');
    expect(sent.path, '/search');
    expect(sent.queryParameters, {'keywords': '海阔天空', 'limit': '5'});

    expect(page.items, hasLength(1));
    final track = page.items.single;
    expect(track.ref.trackId, '347230');
    expect(track.title, '海阔天空');
    expect(track.artists, ['Beyond']);
  });

  test('a declarative stream injects the provider credential', () async {
    await access.save('PureMusic/Self/APIKey', 'self_KEY_TEST_ONLY');
    final composition = await compose(_selfHostedSettings());
    addTearDown(composition.service.dispose);

    const ref = PlatformTrackRef(
      platform: MusicPlatform.netease,
      trackId: '347230',
    );
    final stream = await composition.service.resolve(
      ref,
      requestedQuality: 'lossless',
      cancelToken: OnlineMusicCancelToken(),
    );

    final sent = adapter.requests.single;
    expect(sent.path, '/song/url');
    expect(sent.queryParameters['id'], '347230');
    expect(sent.queryParameters['key'], 'self_KEY_TEST_ONLY');
    expect(stream.uri, Uri.parse('https://media.invalid/song.flac'));
    expect(stream.bitrate, 320000);
  });

  test('a capability without a binding is unavailable, not faked', () async {
    final composition = await compose(_selfHostedSettings());
    addTearDown(composition.service.dispose);

    expect(composition.service.capabilities.playlistPlatforms, isEmpty);
    expect(composition.service.capabilities.lyricPlatforms, isEmpty);
    expect(composition.service.capabilities.searchablePlatforms, {
      MusicPlatform.netease,
    });

    await expectLater(
      composition.service.fetchPlaylist(
        platform: MusicPlatform.netease,
        playlistId: '1',
        cancelToken: OnlineMusicCancelToken(),
      ),
      throwsA(
        isA<OnlineMusicException>().having(
          (error) => error.kind,
          'kind',
          OnlineMusicErrorKind.unavailable,
        ),
      ),
    );
  });

  test(
    'a declarative capability that needs a key reports notConfigured',
    () async {
      final composition = await compose(_selfHostedSettings());
      addTearDown(composition.service.dispose);

      await expectLater(
        composition.service.resolve(
          const PlatformTrackRef(
            platform: MusicPlatform.netease,
            trackId: '347230',
          ),
          requestedQuality: 'lossless',
          cancelToken: OnlineMusicCancelToken(),
        ),
        throwsA(
          isA<OnlineMusicException>().having(
            (error) => error.kind,
            'kind',
            OnlineMusicErrorKind.notConfigured,
          ),
        ),
      );
      expect(adapter.requests, isEmpty, reason: '不应在缺凭据时发出请求');
    },
  );

  test('a business-level failure is reported, not mapped as success', () async {
    final settings = OnlineMusicSettings.fromJson({
      'providers': [
        {
          'id': 'selfData',
          'baseUrl': 'https://self.invalid',
          'capabilities': {'stream': _streamBindingJson()},
        },
      ],
    });
    final composition = await compose(
      settings,
      responder: (options) async => <String, Object?>{
        'code': 5,
        'data': <String, Object?>{},
      },
    );
    addTearDown(composition.service.dispose);

    await expectLater(
      composition.service.resolve(
        const PlatformTrackRef(platform: MusicPlatform.netease, trackId: '1'),
        requestedQuality: 'lossless',
        cancelToken: OnlineMusicCancelToken(),
      ),
      throwsA(isA<OnlineMusicException>()),
    );
  });

  test(
    'a declarative 404 is an interface mismatch, not a missing resource',
    () async {
      final composition = await compose(
        _selfHostedSettings(),
        responder: (options) async => <String, Object?>{'message': 'nope'},
      );
      adapter.failWithStatus = 404;
      addTearDown(composition.service.dispose);

      // D15：声明式 Provider 的 path 由用户配置，404 表示"接口定义对不上服务端"，
      // 与内置 Provider 的"资源不存在"（notFound）必须区分。
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
            OnlineMusicErrorKind.endpointMismatch,
          ),
        ),
      );
    },
  );

  test('legacy ChkSz entries keep working through the builtin path', () async {
    final composition = await compose(
      OnlineMusicSettings.fromJson({
        'providers': [
          {'id': 'chksz', 'protocol': 'chksz'},
        ],
      }),
    );
    addTearDown(composition.service.dispose);

    expect(composition.service.capabilities.searchablePlatforms, {
      MusicPlatform.netease,
    });
    expect(composition.credentialControllers.keys, [
      defaultOnlineMusicProviderId,
    ]);
  });

  test(
    'declarative entries still expose a credential entry for the UI',
    () async {
      final composition = await compose(_selfHostedSettings());
      addTearDown(composition.service.dispose);

      final controller = composition.credentialControllers['selfData']!;
      expect(await controller.isConfigured(), isFalse);
      await controller.saveCredential('self_SETTINGS_TEST_ONLY');
      expect(await controller.isConfigured(), isTrue);
      await controller.clearCredential();
      expect(await controller.isConfigured(), isFalse);
    },
  );
}

Future<Map<String, Object?>> _defaultResponder(RequestOptions options) async {
  if (options.path == '/search') {
    return const {
      'result': {
        'songs': [
          {
            'id': 347230,
            'name': '海阔天空',
            'artists': [
              {'id': 11127, 'name': 'Beyond'},
            ],
            'duration': 239560,
          },
        ],
      },
    };
  }
  return const {
    'code': 0,
    // P-42：播放解析响应必须带上**与请求同一首**的 id，否则映射层会明确失败
    // （"无法证明身份就不返回结果"）。
    'data': {
      'id': '347230',
      'url': 'https://media.invalid/song.flac',
      'br': 320000,
    },
  };
}

typedef _Responder =
    Future<Map<String, Object?>> Function(RequestOptions options);

final class _RecordingAdapter implements HttpClientAdapter {
  final List<RequestOptions> requests = [];
  _Responder responder = _defaultResponder;
  int? failWithStatus;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    final body = await responder(options);
    final status = failWithStatus ?? 200;
    return ResponseBody.fromString(
      jsonEncode(body),
      status,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
