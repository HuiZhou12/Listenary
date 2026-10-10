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
      '★ legacy entry without capabilities declares ONLY what the builtin implements',
      () {
        // ⚠️ 语义变更（F1-c / P-19）：旧断言是"旧条目对**全部 8 个**能力都是内置实现"，
        // 而运行时只服务四项 ⇒ 平台卡声称 8 个、运行说不能（静默 `unavailable`）。
        // 现在旧条目的兼容解释**只覆盖内置实现真正有的能力**，其余如实为"不支持"。
        final settings = OnlineMusicSettings.fromJson({
          'providers': [
            {'id': 'chksz', 'protocol': 'chksz'},
          ],
        });

        final definition = settings.providers.single;
        expect(definition.capabilities, isNull, reason: '这仍是旧条目（无该键）');
        for (final capability in OnlineMusicCapability.values) {
          final supported = builtinOnlineMusicCapabilities.contains(capability);
          expect(
            definition.bindingFor(capability),
            supported
                ? isA<OnlineMusicBuiltinCapabilityBinding>()
                : isA<OnlineMusicUnsupportedCapabilityBinding>(),
            reason:
                '${capability.name}：内置实现'
                '${supported ? '有' : '没有'}实现 ⇒ 声明必须一致',
          );
        }
        // 自定义条目**不**受这条限制：它们仍按各自 `capabilities` 里的绑定判断。
        final custom = OnlineMusicProviderDefinition.custom(
          id: 'selfData',
          baseUrl: 'https://self.invalid',
          requiresCredential: false,
        ).withCapabilityBinding(
          OnlineMusicCapability.chartList,
          _searchBinding(),
        );
        expect(
          custom.bindingFor(OnlineMusicCapability.chartList),
          isA<OnlineMusicDeclarativeCapabilityBinding>(),
          reason: 'P-19 的收窄只针对旧条目的内置解释，不得扩散到自定义 Provider',
        );
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

    test('★ P-20 一键填充是**合并**：已配好的其它能力一个字节都不动', () {
      final declarative = _searchBinding();
      final definition = OnlineMusicProviderDefinition.custom(
        id: 'selfData',
        baseUrl: 'https://self.invalid',
        requiresCredential: false,
      ).withCapabilityBinding(
        OnlineMusicCapability.playlistCollection,
        declarative,
      ).withCapabilityBinding(OnlineMusicCapability.chartList, declarative);

      // 界面确认框要说的两句话先在这里钉住（由模型回答，不靠界面自己猜）。
      expect(
        definition.chkszFillOverwrites().toSet(),
        const {
          OnlineMusicCapability.search,
          OnlineMusicCapability.playlist,
          OnlineMusicCapability.lyric,
          OnlineMusicCapability.stream,
        },
      );
      expect(
        definition.chkszFillKeeps().toSet(),
        const {
          OnlineMusicCapability.playlistCollection,
          OnlineMusicCapability.chartList,
        },
      );

      final filled = definition.withChkszCompatibleCapabilities();

      // 四条 ChkSz 链路被填成内置实现……
      for (final capability in const {
        OnlineMusicCapability.search,
        OnlineMusicCapability.playlist,
        OnlineMusicCapability.lyric,
        OnlineMusicCapability.stream,
      }) {
        expect(
          filled.bindingFor(capability),
          isA<OnlineMusicBuiltinCapabilityBinding>(),
        );
      }
      // ……而**其它已配置的能力原样保留**。旧实现是整表替换 ⇒ 这两条会变成"不支持"，
      // 且没有任何确认与撤销（这就是 P-20 的静默数据丢失）。
      expect(
        filled.bindingFor(OnlineMusicCapability.playlistCollection),
        declarative,
        reason: '已配好的歌单列表不得被一键填充丢掉',
      );
      expect(
        filled.bindingFor(OnlineMusicCapability.chartList),
        declarative,
        reason: '已配好的榜单不得被一键填充丢掉',
      );
      // 已经填过 ⇒ 再点一次什么都不变（幂等），"会被覆盖"的集合也只剩真正不同的项。
      expect(filled.chkszFillKeeps().toSet(), {
        OnlineMusicCapability.playlistCollection,
        OnlineMusicCapability.chartList,
      });
      expect(filled.chkszFillOverwrites(), isEmpty);
      expect(filled.withChkszCompatibleCapabilities(), filled);
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

    test('★ P-32 单个能力写坏：仍然只影响该能力，但**必须能被报出来**', () {
      // ⚠️ 这条用例原来叫 `a single broken capability does not break the whole entry`，
      // 只断言"坏的变 unsupported、好的不受影响" —— 那部分是**正确语义**（fail-closed，保留）。
      // 但它**不完整**：写坏的项与"从未配置"在界面上完全同形，
      // 用户只看到"这个能力就是不支持"，无从知道是自己的配置坏了（P-32）。
      // 因此在不改动原断言的前提下**补上可见性断言**。
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
        reason: '仍然 fail-closed：坏配置不当作可用（运行期语义不放宽）',
      );
      expect(
        definition.bindingFor(OnlineMusicCapability.stream),
        isA<OnlineMusicBuiltinCapabilityBinding>(),
        reason: '同条目其它能力不受影响',
      );
      final issues = definition.validationIssues();
      expect(issues, hasLength(1), reason: '坏掉的那一项要被报出来');
      expect(issues.single, contains('search'));
      expect(issues.single, contains('损坏'));
      expect(
        issues.single,
        isNot(contains('script')),
        reason: '配置里的原始值不得回显进界面文案',
      );
    });

    test('★ P-32 整块 capabilities 不是对象：全部按不支持，并报出来', () {
      final settings = OnlineMusicSettings.fromJson({
        'providers': [
          {'id': 'selfData', 'capabilities': 'not-an-object'},
        ],
      });

      final definition = settings.providers.single;
      expect(
        definition.bindingFor(OnlineMusicCapability.search),
        isA<OnlineMusicUnsupportedCapabilityBinding>(),
      );
      expect(
        definition.validationIssues().join('\n'),
        contains('不是一个对象'),
      );
    });

    test('★ P-32 损坏项只是解析期事实：不落盘、不影响相等性、编辑后即清空', () {
      final settings = OnlineMusicSettings.fromJson({
        'providers': [
          {
            'id': 'selfData',
            'capabilities': {
              'search': {'kind': 'script'},
            },
          },
        ],
      });
      final definition = settings.providers.single;

      // 不落盘：损坏标记不得写进用户配置。
      expect(definition.toJson().toString(), isNot(contains('capabilityConfigIssues')));
      expect(definition.toJson().toString(), isNot(contains('损坏')));
      // 往返：损坏项**不会被写回去**（`toJson` 写的是降级后的 `unsupported`）⇒
      // 再次解析时它已是"显式 unsupported"，只剩「尚未配置」那一句。
      // 这是**规范化**（保存一次配置就干净了），不是信息丢失 —— 如实断言。
      final again = OnlineMusicSettings.fromJson({
        'providers': [definition.toJson()],
      });
      expect(
        again.providers.single.id,
        definition.id,
        reason: '往返后仍是同一个条目',
      );
      expect(
        again.providers.single.validationIssues().join('\n'),
        isNot(contains('损坏')),
        reason: '损坏项不会被写回去（保存即规范化为显式 unsupported）',
      );
      expect(
        again.providers.single.validationIssues().join('\n'),
        contains('尚未配置'),
        reason: '规范化之后它回到"显式不支持"这一事实',
      );
      // 相等性：只差"哪一项坏了"的两份配置在语义上是同一份（否则会破坏既有往返/去重逻辑）。
      final clean = OnlineMusicSettings.fromJson({
        'providers': [
          {
            'id': 'selfData',
            'capabilities': {
              'search': const OnlineMusicUnsupportedCapabilityBinding().toJson(),
            },
          },
        ],
      });
      expect(
        clean.providers.single,
        definition,
        reason: '损坏项与显式 unsupported 的绑定结果相同 ⇒ 语义相同',
      );
      // 程序化编辑（用户从编辑器重新保存）之后，这一项不再是"损坏的旧数据"。
      final edited = definition.withCapabilityBinding(
        OnlineMusicCapability.search,
        const OnlineMusicBuiltinCapabilityBinding(),
      );
      expect(edited.validationIssues(), isEmpty);
    });
  });

  group('★ P-42 播放解析必须声明身份映射', () {
    test('stream 绑定缺 trackId 映射 ⇒ 校验明确报出（保存/试跑即拦）', () {
      final withoutIdentity = OnlineMusicDeclarativeCapabilityBinding(
        request: const OnlineMusicRequestSpec(path: '/song/url'),
        response: OnlineMusicResponseSpec(
          fieldsRootPath: _path('data'),
          fields: {
            OnlineMusicDomainField.streamUrl: OnlineMusicFieldSpec(
              candidates: [_path('url')],
              transform: OnlineMusicFieldTransform.asUri,
              required: true,
            ),
          },
        ),
      );
      final issues = withoutIdentity
          .validationIssues(OnlineMusicCapability.stream)
          .join('\n');

      expect(issues, contains('trackId'));
      expect(issues, contains('必填'));

      // 配上身份映射之后不再有该问题。
      final withIdentity = OnlineMusicDeclarativeCapabilityBinding(
        request: const OnlineMusicRequestSpec(path: '/song/url'),
        response: OnlineMusicResponseSpec(
          fieldsRootPath: _path('data'),
          fields: {
            OnlineMusicDomainField.streamUrl: OnlineMusicFieldSpec(
              candidates: [_path('url')],
              transform: OnlineMusicFieldTransform.asUri,
              required: true,
            ),
            OnlineMusicDomainField.trackId: OnlineMusicFieldSpec(
              candidates: [_path('id')],
              transform: OnlineMusicFieldTransform.asString,
            ),
          },
        ),
      );
      expect(
        withIdentity
            .validationIssues(OnlineMusicCapability.stream)
            .join('\n'),
        isNot(contains('必填')),
      );
    });
  });

  group('★ P-36 条目级与能力级认证的一致性', () {
    OnlineMusicProviderDefinition entry({
      required bool requiresCredential,
      required Map<String, Object?> capabilities,
    }) => OnlineMusicSettings.fromJson({
      'providers': [
        {
          'id': 'selfData',
          'baseUrl': 'https://self.invalid',
          'auth': {'kind': requiresCredential ? 'apiKey' : 'none'},
          'capabilities': capabilities,
        },
      ],
    }).providers.single;

    Map<String, Object?> httpBinding({String? authParam}) =>
        OnlineMusicDeclarativeCapabilityBinding(
          request: OnlineMusicRequestSpec(
            path: '/search',
            query: const [
              OnlineMusicParamBinding(
                name: 'keywords',
                source: OnlineMusicInputSource.keyword,
                required: true,
              ),
            ],
            auth: authParam == null
                ? const OnlineMusicNoAuthPlacement()
                : OnlineMusicQueryAuthPlacement(parameterName: authParam),
          ),
          response: OnlineMusicResponseSpec(
            listPath: _path('data'),
            fields: {
              OnlineMusicDomainField.trackId: OnlineMusicFieldSpec(
                candidates: [_path('id')],
                transform: OnlineMusicFieldTransform.asInt,
                required: true,
              ),
              OnlineMusicDomainField.title: OnlineMusicFieldSpec(
                candidates: [_path('name')],
                transform: OnlineMusicFieldTransform.asString,
                required: true,
              ),
            },
          ),
        ).toJson();

    test('「不需要 Key」+ 能力声明了认证 ⇒ 提示运行期会缺凭据', () {
      final issues = entry(
        requiresCredential: false,
        capabilities: {'search': httpBinding(authParam: 'k')},
      ).validationIssues().join('\n');

      expect(issues, contains('search'));
      expect(issues, contains('不需要 Key'));
      expect(issues, contains('缺少凭据'));
    });

    test('「需要 Key」+ 已配能力都不用 ⇒ 提示槽位不会被读取', () {
      final issues = entry(
        requiresCredential: true,
        capabilities: {'search': httpBinding()},
      ).validationIssues().join('\n');

      expect(issues, contains('不会被读取'));
    });

    test('一致或无关的配置**不**产生认证提示', () {
      // a) 需要 Key + 声明认证 ⇒ 一致
      expect(
        entry(
          requiresCredential: true,
          capabilities: {'search': httpBinding(authParam: 'k')},
        ).validationIssues().join('\n'),
        isNot(contains('认证')),
      );
      // b) 不需要 Key + 无认证 ⇒ 一致
      expect(
        entry(
          requiresCredential: false,
          capabilities: {'search': httpBinding()},
        ).validationIssues().join('\n'),
        isNot(contains('凭据')),
      );
      // c) 需要 Key + **还没配任何能力** ⇒ 不打扰（那只是"还没配"）
      expect(
        entry(
          requiresCredential: true,
          capabilities: const {},
        ).validationIssues().join('\n'),
        isNot(contains('不会被读取')),
      );
      // d) 旧条目（无 capabilities 键）：认证由条目级 authFor 决定 ⇒ 结构上不可能矛盾
      final legacy = OnlineMusicSettings.fromJson({
        'providers': [
          {'id': 'chksz', 'protocol': 'chksz'},
        ],
      }).providers.single;
      expect(
        legacy.validationIssues().join('\n'),
        isNot(contains('不会被读取')),
      );
      // e) 需要 Key + 内置绑定：内置用条目级 authFor ⇒ 会用到这个 Key
      expect(
        entry(
          requiresCredential: true,
          capabilities: {
            'search': const OnlineMusicBuiltinCapabilityBinding().toJson(),
          },
        ).validationIssues().join('\n'),
        isNot(contains('不会被读取')),
      );
    });
    test('★ P-54 capabilityAuth 对声明式无效时如实说明（旧旋钮可见）', () {
      // 这个旋钮的唯一消费者是内置 ChkSz 链路；声明式绑定自己的认证在
      // `binding.request.auth` 里。非空且**没有内置能力**时如实说明，
      // 免得用户以为设了它就有认证。
      final declarativeOnly = OnlineMusicSettings.fromJson({
        'providers': [
          {
            'id': 'selfData',
            'baseUrl': 'https://self.invalid',
            'auth': {'kind': 'apiKey', 'reference': 'a/b/c'},
            'capabilityAuth': {'search': 'none'},
            'capabilities': {'search': httpBinding()},
          },
        ],
      }).providers.single;
      expect(
        declarativeOnly.validationIssues().join('\n'),
        contains('capabilityAuth'),
      );

      // 有内置能力时它**确实生效**（`authFor` 会用它）⇒ 不该报"无效"。
      final withBuiltin = OnlineMusicSettings.fromJson({
        'providers': [
          {
            'id': 'selfData',
            'baseUrl': 'https://self.invalid',
            'auth': {'kind': 'apiKey', 'reference': 'a/b/c'},
            'capabilityAuth': {'search': 'none'},
            'capabilities': {
              'search': const OnlineMusicBuiltinCapabilityBinding().toJson(),
            },
          },
        ],
      }).providers.single;
      expect(
        withBuiltin.validationIssues().join('\n'),
        isNot(contains('capabilityAuth')),
      );

      // 旧条目（无 `capabilities` 键）按内置实现解释 ⇒ 也生效。
      final legacy = OnlineMusicSettings.fromJson({
        'providers': [
          {
            'id': 'chksz',
            'protocol': 'chksz',
            'capabilityAuth': {'search': 'none'},
          },
        ],
      }).providers.single;
      expect(
        legacy.validationIssues().join('\n'),
        isNot(contains('capabilityAuth')),
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

    // ---------------------------------------------------------- F4-S7（P-41）

    test('★ F4-S7 引号键：含点键 / 中文键可以寻址（以前根本表达不出来）', () {
      const sample = {
        'result': {
          'a.b': 'dotted',
          '中文键': 'chinese',
          'a"b': 'quoted',
          'a\\b': 'backslash',
        },
      };

      expect(JsonPath.tryParse('result["a.b"]')!.read(sample), 'dotted');
      expect(JsonPath.tryParse('result["中文键"]')!.read(sample), 'chinese');
      expect(JsonPath.tryParse("result['a.b']")!.read(sample), 'dotted');
      expect(JsonPath.tryParse(r'result["a\"b"]')!.read(sample), 'quoted');
      expect(JsonPath.tryParse(r'result["a\\b"]')!.read(sample), 'backslash');
      // 段首就是引号键、以及与后缀混用都要能解析
      expect(JsonPath.tryParse('["a.b"]')!.read(const {'a.b': 1}), 1);
      expect(
        JsonPath.tryParse('result["a.b"][0]')!.read(const {
          'result': {
            'a.b': ['x'],
          },
        }),
        'x',
      );
    });

    test('★ F4-S7 引号键的非法写法仍然一律拒绝', () {
      expect(JsonPath.tryParse('result[]'), isNull);
      expect(JsonPath.tryParse('result[""]'), isNull, reason: '空键没有意义');
      expect(JsonPath.tryParse('result["abc'), isNull, reason: '引号未闭合');
      expect(JsonPath.tryParse('result["abc"'), isNull, reason: '少了 `]`');
      expect(JsonPath.tryParse('result["abc"x]'), isNull);
      expect(JsonPath.tryParse('result[a]'), isNull, reason: '方括号里只能是指号或引号键');
      expect(JsonPath.tryParse('[0].a'), isNull, reason: '段首只能是裸键或引号键（老语法不变）');
      expect(JsonPath.tryParse(r'result["a\nb"]'), isNull, reason: '只支持引号与反斜杠两种转义');
    });

    test('★ F4-S7 引号键的原始写法原样保留（往返不变）', () {
      // 注意：中文键**必须**写成引号键（裸键仍限 `[A-Za-z0-9_-]`，老语法不变）。
      const source = 'result["a.b"]["列表"]["x y"]';
      final path = JsonPath.tryParse(source)!;

      expect(path.source, source, reason: 'source 保留用户写法 ⇒ 落盘往返不变');
      expect(path.segments.whereType<JsonPathKey>().map((s) => s.key), [
        'result',
        'a.b',
        '列表',
        'x y',
      ]);
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
