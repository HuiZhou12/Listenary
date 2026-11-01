import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/services/music_platform/chksz/index.dart';
import 'package:pure_music/services/music_platform/declarative/declarative_http_transport.dart';
import 'package:pure_music/services/music_platform/declarative/declarative_music_provider.dart';
import 'package:pure_music/services/music_platform/declarative/declarative_request_builder.dart';
import 'package:pure_music/services/music_platform/online_music_composition.dart';

/// decoupling-2.2（R1 / R2 / R4 / R6 / R7）：自定义平台 UI 背后的配置与路由契约。
///
/// 覆盖三条最容易"看起来做完、实际是死 UI"的链路：
/// 1. 新建自定义平台能落盘、能读回、`platformId` 编辑前后不变（R1 / R2）；
/// 2. **停用任一内置平台后，自定义平台候选仍非空**（R4 / G7 回归 —— 这是 2.2 之前的
///    阻断缺陷：启用集合只录内置枚举，一旦非空就把所有自定义平台过滤成空）；
/// 3. 没有自定义平台的旧配置读写往返后**字节不变**（R6）。
void main() {
  const alphaId = '0f9a1c2e-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
  const betaId = '0f9a1c2e-bbbb-4bbb-8bbb-bbbbbbbbbbbb';

  Map<String, Object?> customProvider({
    required String id,
    required String platformId,
    String? platformName,
    String contentPlatform = 'custom',
  }) => {
    'id': id,
    'contentPlatform': contentPlatform,
    'platformId': platformId,
    'platformName': ?platformName,
    'baseUrl': 'http://127.0.0.1:3100',
    'auth': {'kind': 'none'},
    'capabilities': <String, Object?>{},
  };

  group('R1 / R2 新建自定义平台可落盘、身份稳定', () {
    test(
      '★ R1 新建：toJson 含 contentPlatform=custom + platformId + platformName，读回身份有效',
      () {
        final definition = OnlineMusicProviderDefinition.custom(
          id: 'customAlpha',
          baseUrl: 'http://127.0.0.1:3100',
          requiresCredential: false,
          contentPlatform: MusicPlatform.custom,
          platformId: alphaId,
          platformName: '我的自建平台',
        );

        final json = definition.toJson();
        expect(json['contentPlatform'], 'custom');
        expect(json['platformId'], alphaId);
        expect(json['platformName'], '我的自建平台');

        final restored = OnlineMusicSettings.fromJson({
          'providers': [json],
        }).providers.single;
        expect(restored.identity, const PlatformIdentity.custom(alphaId));
        expect(restored.identity.isValid, isTrue);
        expect(
          restored.platformConfigIssue,
          isNull,
          reason: 'R1：显式声明了 custom + platformId ⇒ 不再是「可见但不路由」',
        );
      },
    );

    test('★ R1 编辑保存（editedBy）不得重写 platformId，可改 platformName', () {
      final base = OnlineMusicSettings.fromJson({
        'providers': [
          customProvider(
            id: 'customAlpha',
            platformId: alphaId,
            platformName: '旧名',
          ),
        ],
      }).providers.single;

      final renamed = base.editedBy(
        baseUrl: 'https://other.invalid',
        requiresCredential: false,
        platformName: '新名',
      );

      expect(renamed.platformId, alphaId, reason: 'R2：创建后不可修改');
      expect(renamed.platformName, '新名');
      expect(renamed.identity, base.identity);
    });

    test('★ R2 生成器：标准 UUID v4，且三次快照（新建/编辑/读回）保持一致', () {
      final generated = generateCustomPlatformId();
      expect(
        RegExp(
          r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
        ).hasMatch(generated),
        isTrue,
        reason: '必须是标准 UUID v4（小写带连字符）',
      );

      final created = OnlineMusicProviderDefinition.custom(
        id: 'customAlpha',
        baseUrl: 'http://127.0.0.1:3100',
        requiresCredential: false,
        contentPlatform: MusicPlatform.custom,
        platformId: generated,
        platformName: '甲',
      );
      final snapshot1 = created.platformId;

      final edited = created.editedBy(
        baseUrl: 'http://127.0.0.1:3101',
        requiresCredential: false,
      );
      final snapshot2 = edited.platformId;

      final reread = OnlineMusicSettings.fromJson({
        'providers': [edited.toJson()],
      }).providers.single;
      final snapshot3 = reread.platformId;

      expect({snapshot1, snapshot2, snapshot3}, {generated});
    });

    test('★ R2 生成器只用于新建：读取既有配置不产生新的 platformId', () {
      final settings = OnlineMusicSettings.fromJson({
        'providers': [
          {'id': 'chksz', 'protocol': 'chksz'},
        ],
      });
      final restored = OnlineMusicSettings.fromJson(settings.toJson());
      expect(restored.providers.single.platformId, isNull);
      expect(restored.toJson().toString(), isNot(contains('platformId')));
    });
  });

  group('R4 / G7 自定义平台可路由、不串台', () {
    /// 一个声明式自定义平台提供者（search + stream 都有 ⇒ 过得了搜索门槛）。
    DeclarativeMusicProvider provider(String id) => DeclarativeMusicProvider(
      providerId: id,
      contentPlatform: MusicPlatform.custom,
      bindings: {
        OnlineMusicCapability.search: OnlineMusicDeclarativeCapabilityBinding(
          request: const OnlineMusicRequestSpec(path: '/search'),
          response: _searchResponse(),
        ),
        OnlineMusicCapability.stream: OnlineMusicDeclarativeCapabilityBinding(
          request: const OnlineMusicRequestSpec(path: '/song/url'),
          response: _searchResponse(),
        ),
      },
      transport: _NoopTransport(),
      credentials: const _NoCredentialReader(),
    );

    OnlineMusicSettings twoCustomPlatforms() => OnlineMusicSettings.fromJson({
      'providers': [
        {
          ...customProvider(
            id: 'alpha',
            platformId: alphaId,
            platformName: '甲',
          ),
          'baseUrl': 'https://alpha.invalid',
          'capabilities': {
            'search': _declarativeBinding().toJson(),
            'stream': _declarativeBinding().toJson(),
          },
        },
        {
          ...customProvider(id: 'beta', platformId: betaId, platformName: '乙'),
          'baseUrl': 'https://beta.invalid',
          'capabilities': {
            'search': _declarativeBinding().toJson(),
            'stream': _declarativeBinding().toJson(),
          },
        },
      ],
    });

    /// 只装配声明式条目本身：注册表直接拿到 provider 与身份（跳过真实网络）。
    OnlineMusicProviderRegistry registryFor(OnlineMusicSettings settings) =>
        OnlineMusicProviderRegistry(
          providers: [provider('alpha'), provider('beta')],
          providerIdentities: {
            for (final definition in settings.providers)
              definition.id: definition.identity,
          },
          enabledPlatforms: settings.enabledPlatforms,
          explicitCandidatesForIdentity:
              settings.explicitCandidateIdsForIdentity,
        );

    test('★ R4 两个自定义平台各自只命中自己的 provider（不串台）', () {
      final settings = twoCustomPlatforms();
      final registry = registryFor(settings);

      expect(
        registry
            .providersForIdentity(
              const PlatformIdentity.custom(alphaId),
              OnlineMusicCapability.search,
            )
            .map((provider) => provider.providerId),
        ['alpha'],
      );
      expect(
        registry
            .providersForIdentity(
              const PlatformIdentity.custom(betaId),
              OnlineMusicCapability.search,
            )
            .map((provider) => provider.providerId),
        ['beta'],
      );
    });

    test('★ R4 / G7 回归：停用任一内置平台后，自定义平台候选仍然非空', () {
      final settings = twoCustomPlatforms();
      // 停用酷狗 ⇒ 启用集合变成**非空**（2.2 之前正是这一步让所有自定义平台候选恒空）。
      final disabled = settings.withPlatformEnabled(
        MusicPlatform.kugou,
        enabled: false,
      );
      expect(disabled.enabledPlatforms, isNotEmpty);
      expect(
        disabled.isIdentityEnabled(const PlatformIdentity.custom(alphaId)),
        isTrue,
      );

      final registry = registryFor(disabled);
      expect(
        registry.providersForIdentity(
          const PlatformIdentity.custom(alphaId),
          OnlineMusicCapability.search,
        ),
        isNotEmpty,
        reason: 'G7：内置平台的停用不得牵连自定义平台的候选',
      );
      expect(
        registry.providersForIdentity(
          const PlatformIdentity.custom(betaId),
          OnlineMusicCapability.stream,
        ),
        isNotEmpty,
      );
    });

    test('★ R4 / G5 两个自定义平台可分别停用（身份化启用集合）', () {
      final settings = twoCustomPlatforms();
      final onlyAlpha = settings.withIdentityEnabled(
        const PlatformIdentity.custom(betaId),
        enabled: false,
      );

      expect(
        onlyAlpha.isIdentityEnabled(const PlatformIdentity.custom(alphaId)),
        isTrue,
      );
      expect(
        onlyAlpha.isIdentityEnabled(const PlatformIdentity.custom(betaId)),
        isFalse,
      );
      // 落盘写法：内置仍写枚举名、自定义写 `custom:<稳定 ID>`。
      expect(onlyAlpha.toJson()['enabledPlatforms'], [
        'netease',
        'qq',
        'kugou',
        'custom:$alphaId',
      ]);

      final registry = registryFor(onlyAlpha);
      expect(
        registry.providersForIdentity(
          const PlatformIdentity.custom(betaId),
          OnlineMusicCapability.search,
        ),
        isEmpty,
        reason: '被停用的自定义平台：候选按空处理（该平台即 unavailable）',
      );
      expect(
        registry.providersForIdentity(
          const PlatformIdentity.custom(alphaId),
          OnlineMusicCapability.search,
        ),
        isNotEmpty,
      );
    });

    test('★ R4 显式候选按身份写入与读出（两个自定义平台互不影响）', () {
      final settings = twoCustomPlatforms();
      final routed = settings.withRoutingCandidatesForIdentity(
        const PlatformIdentity.custom(alphaId),
        OnlineMusicCapability.search,
        ['alpha'],
      );

      expect(
        routed.explicitCandidateIdsForIdentity(
          const PlatformIdentity.custom(alphaId),
          OnlineMusicCapability.search,
        ),
        ['alpha'],
      );
      expect(
        routed.explicitCandidateIdsForIdentity(
          const PlatformIdentity.custom(betaId),
          OnlineMusicCapability.search,
        ),
        isEmpty,
      );
      // 落盘键 = `custom:<稳定 ID>`，读回后仍是同一个身份。
      final json = routed.toJson();
      expect((json['routing'] as Map)['custom:$alphaId'], isNotNull);
      expect(OnlineMusicSettings.fromJson(json), routed);
    });

    test('★ R4 / G5 旧配置里裸写 `custom` 的 routing 键：明确丢弃、不迁移', () {
      // 裸 `custom` 不含稳定 ID ⇒ 歧义键（两个自定义平台会串台）。
      // 决定（2026-11-01，minor-1 收口）：**解析时丢弃，不迁移、不猜、不回落内置平台**。
      // 用户改在设置页重新选来源时才会写成 `custom:<uuid>`。
      final settings = OnlineMusicSettings.fromJson({
        'providers': [
          {
            ...customProvider(
              id: 'alpha',
              platformId: alphaId,
              platformName: '甲',
            ),
            'baseUrl': 'https://alpha.invalid',
            'capabilities': {'search': _declarativeBinding().toJson()},
          },
        ],
        'routing': {
          'custom': {
            'search': ['alpha'],
          },
        },
      });

      // 丢弃：该格没有显式候选（回到"自动"），也没有被改写成任何别的平台。
      expect(
        settings.explicitCandidateIdsForIdentity(
          const PlatformIdentity.custom(alphaId),
          OnlineMusicCapability.search,
        ),
        isEmpty,
      );
      for (final platform in MusicPlatform.values) {
        expect(
          settings.explicitCandidateIdsFor(
            platform,
            OnlineMusicCapability.search,
          ),
          isEmpty,
          reason: '裸 custom 不得被猜成任何具体平台（含内置）',
        );
      }
      // 不迁移：落盘不出现 `custom:` 键（用户没重新选择过）。
      expect(settings.toJson().toString(), isNot(contains('custom:')));
      // 但条目本身照旧可路由：丢失的只是"显式候选"，不是平台身份。
      expect(
        settings.isIdentityEnabled(const PlatformIdentity.custom(alphaId)),
        isTrue,
      );
    });

    test('★ R4 组合服务：可搜索身份集合含两个自定义平台，且各自能解析', () {
      final settings = twoCustomPlatforms();
      final composition = createOnlineMusicComposition(
        settings: settings,
        portableBuild: true,
      );
      addTearDown(composition.service.dispose);

      expect(
        composition.service.capabilities.searchableIdentities,
        containsAll(const [
          PlatformIdentity.custom(alphaId),
          PlatformIdentity.custom(betaId),
        ]),
      );
    });
  });

  group('R6 / R7 兼容与内置零回归', () {
    test('★ R6 没有自定义平台的旧配置：往返后 Map 完全相等（不新增键）', () {
      final original = <String, Object?>{
        'defaultProvider': 'chksz',
        'providers': [
          {
            'id': 'chksz',
            'protocol': 'chksz',
            'baseUrl': 'https://api.example',
            'contentPlatform': 'netease',
            'connectTimeoutMs': 8000,
            'sendTimeoutMs': 8000,
            'receiveTimeoutMs': 10000,
            'auth': {
              'kind': 'apiKey',
              'reference': 'PureMusic/ChKSz/APIKey',
              'parameter': 'apikey',
            },
          },
        ],
        'capabilities': <String, Object?>{},
      };

      final roundTripped = OnlineMusicSettings.fromJson(original).toJson();

      expect(roundTripped, original, reason: 'R6：旧配置读写后字节不变');
      expect(roundTripped['providers'], original['providers']);
    });

    test('★ R6 旧 enabledPlatforms / routing 写法保持原样（不出现 custom: 前缀）', () {
      // 起点必须是 `toJson` 的**规范形态**（`contentPlatform` 一直会被写出，
      // 这是既有行为、不是 2.2 引入的）⇒ 用它做"逐键相等"的基线。
      final original = <String, Object?>{
        'defaultProvider': 'chksz',
        'providers': [
          {
            'id': 'chksz',
            'protocol': 'chksz',
            'contentPlatform': 'netease',
            'connectTimeoutMs': 8000,
            'sendTimeoutMs': 8000,
            'receiveTimeoutMs': 10000,
            'auth': {
              'kind': 'apiKey',
              'reference': 'PureMusic/ChKSz/APIKey',
              'parameter': 'apikey',
            },
          },
        ],
        'capabilities': <String, Object?>{},
        'enabledPlatforms': ['netease', 'qq'],
        'routing': {
          'netease': {
            'search': ['chksz'],
          },
        },
      };

      final roundTripped = OnlineMusicSettings.fromJson(original).toJson();
      expect(roundTripped, original);
      // 2.2 只在使用自定义平台时才产生新形态。
      expect(roundTripped.toString(), isNot(contains('custom:')));
      expect(
        (roundTripped['providers'] as List).single,
        isNot(anyElement(anyOf('platformId', 'platformName'))),
      );
    });

    test('★ R7 内置平台路由与候选语义不变（含旧单值回落）', () {
      final settings = OnlineMusicSettings.fromJson({
        'providers': [
          {'id': 'chksz', 'protocol': 'chksz'},
        ],
      });

      // 内置平台候选与显式候选仍是既有口径。
      for (final capability in OnlineMusicCapability.values) {
        expect(
          settings.explicitCandidateIdsFor(MusicPlatform.netease, capability),
          isEmpty,
        );
      }
      expect(
        settings.capableProviderIdsFor(
          MusicPlatform.netease,
          OnlineMusicCapability.search,
        ),
        ['chksz'],
      );
      expect(
        settings.selectedProviderIdFor(
          MusicPlatform.netease,
          OnlineMusicCapability.search,
        ),
        isNull,
      );
      // 内置平台的 routing 键与以前一致（枚举名，不带 `custom:` 前缀）。
      expect(
        settings.withRoutingCandidates(
          MusicPlatform.netease,
          OnlineMusicCapability.search,
          ['chksz'],
        ).toJson()['routing'],
        {
          'netease': {
            'search': ['chksz'],
          },
        },
      );
    });
  });
}

OnlineMusicResponseSpec _searchResponse() => OnlineMusicResponseSpec(
  listPath: JsonPath.tryParse('result.songs'),
  fields: {
    OnlineMusicDomainField.trackId: OnlineMusicFieldSpec(
      candidates: [JsonPath.tryParse('id')!],
      transform: OnlineMusicFieldTransform.asInt,
      required: true,
    ),
    OnlineMusicDomainField.title: OnlineMusicFieldSpec(
      candidates: [JsonPath.tryParse('name')!],
      transform: OnlineMusicFieldTransform.asString,
      required: true,
    ),
  },
);

OnlineMusicDeclarativeCapabilityBinding _declarativeBinding() =>
    OnlineMusicDeclarativeCapabilityBinding(
      request: const OnlineMusicRequestSpec(path: '/search'),
      response: _searchResponse(),
    );

final class _NoopTransport implements DeclarativeHttpTransport {
  @override
  Future<DeclarativeHttpResponse> send(
    BuiltDeclarativeRequest request, {
    required OnlineMusicCancelToken cancelToken,
  }) async => const DeclarativeHttpResponse(
    statusCode: 200,
    data: <String, Object?>{
      'result': <String, Object?>{
        'songs': <Object?>[
          <String, Object?>{'id': 1, 'name': 'x'},
        ],
      },
    },
  );
}

final class _NoCredentialReader implements OnlineMusicCredentialReader {
  const _NoCredentialReader();
  @override
  Future<String?> readCredential(String reference) async => null;
}
