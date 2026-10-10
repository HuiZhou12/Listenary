import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/services/music_platform/chksz/index.dart';
import 'package:pure_music/services/music_platform/declarative/declarative_http_transport.dart';
import 'package:pure_music/services/music_platform/declarative/declarative_music_provider.dart';
import 'package:pure_music/services/music_platform/declarative/declarative_request_builder.dart';

/// F4-S4a（P-13 / D10b:a）：档位由**配置静态声明**（内部级别 → 平台取值 + 展示名）——
/// 声明式 Provider 从此不必写代码就能让装位菜单/回落提示显示平台自己的叫法；
/// 缺省空表 ⇒ 与修复前完全一致（不伪造平台档位名）。
final class _StubTransport implements DeclarativeHttpTransport {
  const _StubTransport();
  @override
  Future<DeclarativeHttpResponse> send(
    BuiltDeclarativeRequest request, {
    required OnlineMusicCancelToken cancelToken,
  }) async => const DeclarativeHttpResponse(statusCode: 200, data: {});
}

final class _NoCredentialReader implements OnlineMusicCredentialReader {
  const _NoCredentialReader();
  @override
  Future<String?> readCredential(String reference) async => null;
}

/// 一个带档位声明的条目（其余字段取最小可用值）。
OnlineMusicSettings _settingsWithTiers({
  List<Map<String, String>>? tiers,
  bool includeKey = true,
}) => OnlineMusicSettings.fromJson({
  'providers': [
    {
      'id': 'selfData',
      'baseUrl': 'https://self.invalid',
      'auth': {'kind': 'none'},
      'contentPlatform': 'netease',
      if (includeKey && tiers != null) 'qualityTiers': tiers,
      'capabilities': <String, Object?>{},
    },
  ],
});

const _tiers = [
  {'internal': 'standard', 'label': '标准', 'value': '128k'},
  {'internal': 'lossless', 'label': '无损', 'value': 'flac'},
];

void main() {
  group('★ F4-S4a 档位由配置静态声明（P-13）', () {
    test('声明写进配置并**往返不变**；缺省时不写该键（旧配置字节不变）', () {
      final withTiers = _settingsWithTiers(tiers: _tiers).providers.single;
      expect(withTiers.qualityTiers.map((tier) => tier.internalLevel), [
        'standard',
        'lossless',
      ]);
      expect(withTiers.qualityTiers.map((tier) => tier.displayLabel), [
        '标准',
        '无损',
      ]);
      expect(withTiers.qualityTiers.map((tier) => tier.requestValue), [
        '128k',
        'flac',
      ]);
      expect(
        withTiers.toJson()['qualityTiers'],
        _tiers,
        reason: '落盘形状必须与声明一一对应',
      );
      expect(
        OnlineMusicSettings.fromJson({
          'providers': [withTiers.toJson()],
        }).providers.single.qualityTiers.map((tier) => tier.requestValue),
        ['128k', 'flac'],
        reason: '往返不丢',
      );

      // 缺省：**不写** `qualityTiers` 键。
      final without = _settingsWithTiers(includeKey: false).providers.single;
      expect(without.qualityTiers, isEmpty);
      expect(without.toJson().containsKey('qualityTiers'), isFalse);
    });

    test('★ 三条"重建定义"的路径都必须**透传**档位（不得被静默丢掉）', () {
      final base = _settingsWithTiers(tiers: _tiers).providers.single;

      expect(
        base
            .editedBy(
              baseUrl: 'https://other.invalid',
              requiresCredential: false,
            )
            .qualityTiers
            .map((tier) => tier.requestValue),
        ['128k', 'flac'],
        reason: '编辑条目（界面保存走这条）不得丢档位',
      );
      expect(
        base
            .withCapabilityBinding(
              OnlineMusicCapability.search,
              const OnlineMusicUnsupportedCapabilityBinding(),
            )
            .qualityTiers
            .length,
        2,
        reason: '改某个能力的绑定不得动档位声明',
      );
      expect(
        base.withChkszCompatibleCapabilities().qualityTiers.length,
        2,
        reason: '一键填充改的是能力实现，不该动档位声明',
      );
    });

    test('坏档位条目 ⇒ **明确报错**（不静默丢一半）', () {
      expect(
        () => OnlineMusicSettings.fromJson({
          'providers': [
            {
              'id': 'x',
              'protocol': 'chksz',
              'baseUrl': 'https://x.invalid',
              'contentPlatform': 'netease',
              'qualityTiers': [
                {'internal': 'lossless', 'label': '无损'},
              ],
            },
          ],
        }),
        throwsA(isA<FormatException>()),
        reason: '缺 value ⇒ 明确报错（D4：不支持的必须报出、不得静默）',
      );
      expect(
        () => OnlineMusicSettings.fromJson({
          'providers': [
            {
              'id': 'x',
              'protocol': 'chksz',
              'baseUrl': 'https://x.invalid',
              'contentPlatform': 'netease',
              'qualityTiers': 'not-a-list',
            },
          ],
        }),
        throwsA(isA<FormatException>()),
      );
    });

    test('声明式 Provider 真的把声明的档位交给上层（以前恒空）', () {
      final declared = _settingsWithTiers(tiers: _tiers).providers.single;
      final provider = DeclarativeMusicProvider(
        providerId: declared.id,
        bindings: const {},
        transport: const _StubTransport(),
        credentials: const _NoCredentialReader(),
        contentPlatform: declared.contentPlatform,
        qualityTiers: declared.qualityTiers,
      );

      expect(provider.qualityTiersFor(MusicPlatform.netease).map((t) => t.displayLabel), [
        '标准',
        '无损',
      ]);

      // 不声明 ⇒ 空表（UI 只展示内部偏好，不伪造平台档位名）。
      final silent = DeclarativeMusicProvider(
        providerId: 'p',
        bindings: const {},
        transport: const _StubTransport(),
        credentials: const _NoCredentialReader(),
        contentPlatform: MusicPlatform.netease,
      );
      expect(silent.qualityTiersFor(MusicPlatform.netease), isEmpty);
    });
  });
}
