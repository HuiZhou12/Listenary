import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/services/music_platform/chksz/index.dart';

JsonPath _path(String source) => JsonPath.tryParse(source)!;

OnlineMusicDeclarativeCapabilityBinding _searchBinding({
  String path = '/search',
  String keywordParam = 'keywords',
  String listPath = 'result.songs',
  String titlePath = 'name',
}) {
  return OnlineMusicDeclarativeCapabilityBinding(
    request: OnlineMusicRequestSpec(
      path: path,
      query: [
        OnlineMusicParamBinding(
          name: keywordParam,
          source: OnlineMusicInputSource.keyword,
          required: true,
        ),
      ],
    ),
    response: OnlineMusicResponseSpec(
      listPath: _path(listPath),
      fields: {
        OnlineMusicDomainField.trackId: OnlineMusicFieldSpec(
          candidates: [_path('id')],
          transform: OnlineMusicFieldTransform.asInt,
          required: true,
        ),
        OnlineMusicDomainField.title: OnlineMusicFieldSpec(
          candidates: [_path(titlePath)],
          transform: OnlineMusicFieldTransform.asString,
          required: true,
        ),
      },
      pagination: const OnlineMusicPaginationSpec(
        kind: OnlineMusicPaginationKind.offsetLimit,
      ),
    ),
  );
}

void main() {
  group('capabilities / protocol priority (spec §5.3)', () {
    test(
      'legacy entry without capabilities keeps the builtin interpretation',
      () {
        final settings = OnlineMusicSettings.fromJson({
          'providers': [
            {'id': 'chksz', 'protocol': 'chksz'},
          ],
        });

        final definition = settings.providers.single;
        expect(definition.capabilities, isNull);
        for (final capability in OnlineMusicCapability.values) {
          expect(
            definition.bindingFor(capability),
            isA<OnlineMusicBuiltinCapabilityBinding>(),
          );
        }
      },
    );

    test('legacy entry with an unknown protocol is still dropped', () {
      final settings = OnlineMusicSettings.fromJson({
        'providers': [
          {'id': 'mystery', 'protocol': 'mystery'},
        ],
      });

      expect(
        settings.providers.single.id,
        defaultOnlineMusicProviderId,
        reason: '无法识别的旧条目会被忽略并回落默认 Provider',
      );
    });

    test('an empty capabilities object means "nothing supported"', () {
      final settings = OnlineMusicSettings.fromJson({
        'providers': [
          {
            'id': 'selfData',
            'protocol': 'chksz',
            'capabilities': <String, Object?>{},
          },
        ],
      });

      final definition = settings.providers.single;
      expect(definition.capabilities, isNotNull);
      for (final capability in OnlineMusicCapability.values) {
        expect(
          definition.bindingFor(capability),
          isA<OnlineMusicUnsupportedCapabilityBinding>(),
          reason: '新模型下缺失的能力必须是不支持，而不是回落 ChkSz',
        );
      }
    });

    test('capabilities wins over protocol when both are present', () {
      final settings = OnlineMusicSettings.fromJson({
        'providers': [
          {
            'id': 'selfData',
            'protocol': 'chksz',
            'capabilities': {'search': _searchBinding().toJson()},
          },
        ],
      });

      final definition = settings.providers.single;
      expect(
        definition.bindingFor(OnlineMusicCapability.search),
        isA<OnlineMusicDeclarativeCapabilityBinding>(),
      );
      expect(
        definition.bindingFor(OnlineMusicCapability.stream),
        isA<OnlineMusicUnsupportedCapabilityBinding>(),
      );
    });

    test(
      'writing a legacy entry back does not promote it to the new model',
      () {
        final settings = OnlineMusicSettings.fromJson({
          'providers': [
            {'id': 'chksz', 'protocol': 'chksz'},
          ],
        });

        final json = settings.toJson();
        final providers = json['providers']! as List;
        expect((providers.single as Map).containsKey('capabilities'), isFalse);
        expect(
          OnlineMusicSettings.fromJson(json),
          settings,
          reason: '旧条目往返后语义不变',
        );
      },
    );

    test('a new entry starts as unsupported and can be filled one-click', () {
      final definition = OnlineMusicProviderDefinition.custom(
        id: 'selfData',
        baseUrl: 'https://self.invalid',
        requiresCredential: false,
      );

      expect(definition.capabilities, isEmpty);
      expect(
        definition.bindingFor(OnlineMusicCapability.search),
        isA<OnlineMusicUnsupportedCapabilityBinding>(),
      );

      final filled = definition.withChkszCompatibleCapabilities();
      // ChkSz 兼容模板只覆盖它**真的有实现**的四条链路。这里用**显式白名单**而不是
      // "遍历所有能力再跳过几个"：后者每新增一个能力就会错误地要求它也被填成 builtin，
      // 而假装支持比留空更糟（Spec §19.2 / §19.5：不得把没有依据的能力标成可用）。
      const chkszCapabilities = {
        OnlineMusicCapability.search,
        OnlineMusicCapability.playlist,
        OnlineMusicCapability.lyric,
        OnlineMusicCapability.stream,
      };
      for (final capability in chkszCapabilities) {
        expect(
          filled.bindingFor(capability),
          isA<OnlineMusicBuiltinCapabilityBinding>(),
          reason: '$capability 应当被一键填充为内置实现',
        );
      }
      for (final capability in OnlineMusicCapability.values) {
        if (chkszCapabilities.contains(capability)) continue;
        expect(
          filled.bindingFor(capability),
          isA<OnlineMusicUnsupportedCapabilityBinding>(),
          reason: '$capability 没有 ChkSz 接口，一键填充不得假装它支持',
        );
      }
    });
  });

  group('binding serialization', () {
    test('declarative binding round-trips', () {
      final binding = _searchBinding();
      final restored = OnlineMusicCapabilityBinding.fromJson(binding.toJson());

      expect(restored, binding);
      expect(
        (restored as OnlineMusicDeclarativeCapabilityBinding).request.path,
        '/search',
      );
      expect(restored.response.listPath, _path('result.songs'));
    });

    test('display name and content platform round-trip', () {
      final settings = OnlineMusicSettings.fromJson({
        'providers': [
          {
            'id': 'selfData',
            'displayName': '我的自建服务',
            'contentPlatform': 'qq',
            'capabilities': {'search': _searchBinding().toJson()},
          },
        ],
      });

      final definition = settings.providers.single;
      expect(definition.displayName, '我的自建服务');
      expect(definition.label, '我的自建服务');
      expect(definition.contentPlatform, MusicPlatform.qq);

      final restored = OnlineMusicSettings.fromJson(settings.toJson());
      expect(restored, settings);
      expect(restored.providers.single.displayName, '我的自建服务');

      // 未写显示名时回落到标识，且不会写进配置。
      final unnamed = OnlineMusicSettings.fromJson({
        'providers': [
          {'id': 'selfData'},
        ],
      });
      expect(unnamed.providers.single.label, 'selfData');
      expect(
        (unnamed.providers.single.toJson()).containsKey('displayName'),
        isFalse,
      );
    });

    test('builtin and unsupported round-trip', () {
      expect(
        OnlineMusicCapabilityBinding.fromJson(
          const OnlineMusicBuiltinCapabilityBinding().toJson(),
        ),
        const OnlineMusicBuiltinCapabilityBinding(),
      );
      expect(
        OnlineMusicCapabilityBinding.fromJson(
          const OnlineMusicUnsupportedCapabilityBinding().toJson(),
        ),
        const OnlineMusicUnsupportedCapabilityBinding(),
      );
    });

    test('unknown kinds are rejected instead of silently degraded', () {
      expect(
        () => OnlineMusicCapabilityBinding.fromJson({'kind': 'script'}),
        throwsFormatException,
      );
      expect(
        () => OnlineMusicCapabilityBinding.fromJson({
          'kind': 'builtin',
          'builtin': 'unknown-protocol',
        }),
        throwsFormatException,
      );
      expect(
        () => OnlineMusicCapabilityBinding.fromJson({
          'kind': 'http',
          'request': {'verb': 'PATCH', 'path': '/x'},
          'response': <String, Object?>{},
        }),
        throwsFormatException,
      );
    });

    test('a single broken capability does not break the whole entry', () {
      final settings = OnlineMusicSettings.fromJson({
        'providers': [
          {
            'id': 'selfData',
            'capabilities': {
              'search': {'kind': 'script'},
              'stream': const OnlineMusicBuiltinCapabilityBinding().toJson(),
            },
          },
        ],
      });

      final definition = settings.providers.single;
      expect(
        definition.bindingFor(OnlineMusicCapability.search),
        isA<OnlineMusicUnsupportedCapabilityBinding>(),
      );
      expect(
        definition.bindingFor(OnlineMusicCapability.stream),
        isA<OnlineMusicBuiltinCapabilityBinding>(),
      );
    });
  });

  group('validation rejects out-of-model configs', () {
    test('request path rules', () {
      final issues = const OnlineMusicRequestSpec(
        path: 'https://other.invalid/api/search?q={timestamp}',
      ).validationIssues();

      expect(issues, contains('请求路径必须是相对 baseUrl 的相对路径'));
      expect(issues, contains('请求路径不能带查询串或锚点，请把它们写成 query 参数'));
      expect(issues, contains('路径占位 {timestamp} 不是受支持的输入来源'));
    });

    test('response field rules', () {
      final binding = OnlineMusicDeclarativeCapabilityBinding(
        request: const OnlineMusicRequestSpec(path: '/search'),
        response: OnlineMusicResponseSpec(
          listPath: _path('result.songs'),
          fields: {
            // 缺少必填的 trackId / title
            OnlineMusicDomainField.album: OnlineMusicFieldSpec(
              candidates: [_path('al.name')],
              transform: OnlineMusicFieldTransform.asUri,
            ),
          },
          pagination: const OnlineMusicPaginationSpec(
            kind: OnlineMusicPaginationKind.cursor,
          ),
        ),
      );

      final issues = binding.validationIssues(OnlineMusicCapability.search);
      expect(issues, contains('缺少必填字段映射 trackId'));
      expect(issues, contains('缺少必填字段映射 title'));
      expect(issues, contains('album 的类型转换 asUri 不合适'));
      expect(issues, contains('游标分页必须配置游标路径'));
    });

    test('playlist / lyric report real validation, not a phase-two guard', () {
      final binding = _searchBinding();

      // S7b-1：不再有"第二阶段"这类阶段守卫，改为真实校验规则。
      expect(
        binding.validationIssues(OnlineMusicCapability.playlist),
        isNot(contains('第二阶段')),
      );
      expect(
        binding.validationIssues(OnlineMusicCapability.lyric),
        isNot(contains('第二阶段')),
      );
      // 歌词：一个歌词字段都没配 → 明确告诉用户这是配置问题
      // （否则用户会以为是"这首没有歌词"）。
      expect(
        binding.validationIssues(OnlineMusicCapability.lyric),
        contains('歌词能力至少需要配置一个歌词字段'),
      );
    });

    test('a complete search binding passes validation', () {
      expect(
        _searchBinding().validationIssues(OnlineMusicCapability.search),
        isEmpty,
      );
    });

    test('GET with a body and auth-in-body are rejected', () {
      final issues = const OnlineMusicRequestSpec(
        path: '/search',
        body: OnlineMusicRequestBodySpec(
          fields: [
            OnlineMusicParamBinding(
              name: 'keyword',
              source: OnlineMusicInputSource.keyword,
            ),
          ],
        ),
        auth: OnlineMusicBodyAuthPlacement(fieldName: 'apikey'),
      ).validationIssues();

      expect(issues, contains('只有 POST 才能带请求体'));
      expect(issues, contains('认证放在请求体时必须是 POST'));
    });
  });

  group('JsonPath', () {
    test('parses only the controlled grammar', () {
      expect(JsonPath.tryParse('data.songs'), isNotNull);
      expect(JsonPath.tryParse('a.b[0].c'), isNotNull);
      expect(JsonPath.tryParse('a.b[*].name'), isNotNull);
      expect(JsonPath.tryParse(''), isNull);
      expect(JsonPath.tryParse('a..b'), isNull);
      expect(JsonPath.tryParse('a.b[x]'), isNull);
      expect(JsonPath.tryParse('a[b]'), isNull);
      expect(JsonPath.tryParse(r'a.b\c'), isNull);
    });

    test('reads keys, indexes and projections', () {
      const sample = {
        'result': {
          'songs': [
            {
              'id': 1,
              'name': 'first',
              'ar': [
                {'name': 'A'},
                {'name': 'B'},
              ],
            },
            {
              'id': 2,
              'name': 'second',
              'ar': [
                {'name': 'C'},
              ],
            },
          ],
          'total': 2,
        },
      };

      expect(_path('result.total').read(sample), 2);
      expect(_path('result.songs[0].name').read(sample), 'first');
      expect(_path('result.songs[*].name').read(sample), ['first', 'second']);
      expect(_path('result.songs[0].ar[*].name').read(sample), ['A', 'B']);
      // 投影路径总是列表：哪怕只剩一个元素，也不会退化成标量。
      expect(_path('result.songs[1].ar[*].name').read(sample), ['C']);
      expect(_path('result.missing').read(sample), isNull);
      expect(_path('result.songs[5].name').read(sample), isNull);
      expect(_path('result.songs').read(sample), isA<List<Object?>>());
    });
  });
}
