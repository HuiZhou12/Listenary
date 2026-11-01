import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/services/music_platform/chksz/index.dart';
import 'package:pure_music/services/music_platform/declarative/declarative_probe_contract.dart';

/// **"不支持该能力"必须走统一错误契约**（open issue 3.4）。
///
/// 背景：`CompositeOnlineMusicService._dispatch` 只捕获 `OnlineMusicException` ——
/// 它据此写路由诊断，并按 `allowsProviderFallback` 决定是否换下一个候选。
/// 之前这些位置抛的是 Dart 核心的 `UnsupportedError`，于是：
/// 既没有可读文案，也**绕过回退白名单**，直接把原始异常穿透到调用方。
///
/// 本文件钉三件事：
/// 1. 行为：Provider 桩真的抛 `OnlineMusicException(unavailable)`，且**不发请求**；
/// 2. 边界：需要实体 ID 的能力在探测里由能力契约挡下（不会走到映射判定）；
/// 3. 源码守卫：`lib/services/music_platform/` 不得再出现 `UnsupportedError`。
void main() {
  group('Provider 桩：不支持的能力归一化为 OnlineMusicException', () {
    test('★ 四个账号相关能力都抛 unavailable，且一次请求都不发', () async {
      final transport = _CountingTransport();
      final provider = ChkszOnlineMusicProvider(
        runtime: ChkszRuntime(transport: transport),
      );
      addTearDown(provider.dispose);
      final token = OnlineMusicCancelToken();

      final calls = <String, Future<Object?> Function()>{
        'personalizedPlaylists': () => provider.fetchPersonalizedPlaylists(
          platform: MusicPlatform.netease,
          cancelToken: token,
        ),
        'followedArtists': () => provider.fetchFollowedArtists(
          platform: MusicPlatform.netease,
          cancelToken: token,
        ),
        'recommendedPlaylists': () => provider.fetchRecommendedPlaylists(
          platform: MusicPlatform.netease,
          cancelToken: token,
        ),
        'recommendedTracks': () => provider.fetchRecommendedTracks(
          platform: MusicPlatform.netease,
          cancelToken: token,
        ),
      };

      for (final entry in calls.entries) {
        await expectLater(
          entry.value(),
          throwsA(
            isA<OnlineMusicException>().having(
              (error) => error.kind,
              'kind',
              OnlineMusicErrorKind.unavailable,
            ),
          ),
          reason: '${entry.key} 必须走统一错误契约，否则会绕过 _dispatch 的回退白名单',
        );
      }
      expect(transport.calls, 0, reason: '声明为"不支持"的能力不得发出任何请求');
    });

    test('回退白名单认可 unavailable ⇒ 该错误允许切到下一个候选', () {
      // 这条是上一条的意义所在：换成 UnsupportedError 时这张表根本读不到它。
      expect(allowsProviderFallback(OnlineMusicErrorKind.unavailable), isTrue);
    });
  });

  group('探测：需要实体 ID 的能力由能力契约挡下', () {
    test('艺人 / 专辑 / 艺人专辑 / 艺人单曲 都不参与服务级探测', () {
      for (final capability in const [
        OnlineMusicCapability.artist,
        OnlineMusicCapability.album,
        OnlineMusicCapability.artistAlbums,
        OnlineMusicCapability.artistSongs,
      ]) {
        expect(
          probeNotProbeableReasonFor(capability),
          isNotNull,
          reason:
              '${capability.name} 需要实体 ID ⇒ 必须由契约给出"未尝试"原因，'
              '而不是一路走到映射判定再抛原始异常',
        );
        expect(probeCapableCapabilities, isNot(contains(capability)));
      }
    });
  });

  group('源码守卫', () {
    test('★ music_platform 下不得再抛 UnsupportedError（注释除外）', () {
      final offenders = <String>[];
      for (final entity in Directory(
        'lib/services/music_platform',
      ).listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        final lines = entity.readAsLinesSync();
        for (var index = 0; index < lines.length; index++) {
          final trimmed = lines[index].trimLeft();
          // 注释里提到历史补桩是允许的（那里正是在说明这条规则）。
          if (trimmed.startsWith('//') || trimmed.startsWith('*')) continue;
          if (lines[index].contains('UnsupportedError')) {
            offenders.add('${entity.path}:${index + 1}');
          }
        }
      }
      expect(
        offenders,
        isEmpty,
        reason: '这些位置会绕过 _dispatch 的异常处理与回退白名单：${offenders.join('、')}',
      );
    });
  });
}

/// 任何请求都算违约：本文件的被测方法**根本不该**走到传输层。
final class _CountingTransport implements ChkszTransport {
  int calls = 0;

  @override
  Future<ChkszTransportResponse> send(
    ChkszAuthorizedRequest request, {
    required ChkszCancelToken cancelToken,
  }) {
    calls++;
    throw StateError('不支持的能力不得发出请求');
  }
}
