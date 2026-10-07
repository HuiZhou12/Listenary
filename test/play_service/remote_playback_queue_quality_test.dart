import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/play_service/remote_playback_queue.dart';
import 'package:pure_music/play_service/remote_playback_queue_controller.dart';
import 'package:pure_music/services/music_platform/models/music_models.dart';
import 'package:pure_music/services/music_platform/online_music_request.dart';
import 'package:pure_music/services/music_platform/provider/online_music_quality_tiers.dart';
import 'package:pure_music/services/music_platform/remote_stream_coordinator.dart';

/// §19.7 缺陷 B：**降级链必须按平台声明的档位走**，不能按内部枚举下标。
///
/// QQ 只有 128 / 320 / flac 三档；按内部枚举下标会一路降到网易云才有的
/// 更低档位（甚至发出 QQ 不认识的取值），按平台档位则只在这三档之间降。
void main() {
  late RemotePlaybackQueue queue;
  late _QualityGateway gateway;
  late RemotePlaybackQueueController controller;

  setUp(() {
    queue = RemotePlaybackQueue();
    queue.replace([_item('q1'), _item('q2')], currentIndex: 0);
    gateway = _QualityGateway(tiers: qqQualityTiers);
    controller = RemotePlaybackQueueController(queue: queue, gateway: gateway);
  });

  tearDown(() {
    controller.dispose();
    queue.dispose();
  });

  test('QQ：降级只走平台声明的档位（三档，而不是内部枚举七档）', () async {
    gateway.error = const RemoteStreamPlaybackException(
      kind: RemoteStreamPlaybackErrorKind.openFailed,
    );

    await expectLater(
      controller.play(0, requestedQuality: 'lossless'),
      throwsA(isA<RemoteStreamPlaybackException>()),
    );

    // 传下去的是**内部偏好档位**（服务层再转成平台取值），
    // 但候选集合由 QQ 的声明决定 ⇒ lossless → exhigh → standard，到此为止。
    expect(gateway.qualities, ['lossless', 'exhigh', 'standard']);
  });

  test('QQ：下限用平台取值表达时也认得（320 挡住继续下降）', () async {
    gateway.errors.addAll([
      const RemoteStreamPlaybackException(
        kind: RemoteStreamPlaybackErrorKind.openFailed,
      ),
      null,
    ]);

    final actual = await controller.play(
      0,
      requestedQuality: 'lossless',
      // 上一首 QQ 实际返回的是平台取值 320。
      fallbackQuality: '320',
    );

    // 只降到下限那一档（320 = exhigh）就停下，不会继续降到 standard。
    expect(gateway.qualities, ['lossless', 'exhigh']);
    expect(actual, 'flac');
  });

  test('平台没有档位声明时保持旧行为（内部枚举下标降级）', () async {
    final legacy = _QualityGateway(tiers: const []);
    final legacyController = RemotePlaybackQueueController(
      queue: queue,
      gateway: legacy,
    );
    addTearDown(legacyController.dispose);
    legacy.error = const RemoteStreamPlaybackException(
      kind: RemoteStreamPlaybackErrorKind.openFailed,
    );

    await expectLater(
      legacyController.play(
        0,
        requestedQuality: 'lossless',
        fallbackQuality: 'exhigh',
      ),
      throwsA(isA<RemoteStreamPlaybackException>()),
    );

    // lossless → exhigh（下限），与引入档位模型之前完全一致。
    expect(legacy.qualities, ['lossless', 'exhigh']);
  });

  test('网易云的档位声明与"无声明"产生完全相同的降级链（既有行为零变化）', () async {
    final declared = _QualityGateway(tiers: neteaseQualityTiers);
    final legacy = _QualityGateway(tiers: const []);
    final declaredController = RemotePlaybackQueueController(
      queue: queue,
      gateway: declared,
    );
    final legacyController = RemotePlaybackQueueController(
      queue: queue,
      gateway: legacy,
    );
    addTearDown(declaredController.dispose);
    addTearDown(legacyController.dispose);
    final failure = const RemoteStreamPlaybackException(
      kind: RemoteStreamPlaybackErrorKind.openFailed,
    );
    declared.error = failure;
    legacy.error = failure;

    for (final controller in [declaredController, legacyController]) {
      await expectLater(
        controller.play(
          0,
          requestedQuality: 'hires',
          fallbackQuality: 'exhigh',
        ),
        throwsA(isA<RemoteStreamPlaybackException>()),
      );
    }

    expect(declared.qualities, legacy.qualities);
    expect(declared.qualities, ['hires', 'lossless', 'exhigh']);
  });
}

RemotePlaybackQueueItem _item(String trackId) => RemotePlaybackQueueItem(
  ref: PlatformTrackRef(platform: MusicPlatform.qq, trackId: trackId),
  title: 'Track $trackId',
  artists: const ['Artist'],
);

final class _QualityGateway
    implements
        RemoteQueuePlaybackQualityGateway,
        RemoteQueuePlaybackMetadataGateway {
  _QualityGateway({required this.tiers});

  final List<PlatformQualityTier> tiers;
  final qualities = <String>[];
  final errors = <Object?>[];
  Object? error;

  @override
  List<PlatformQualityTier> qualityTiersFor(MusicPlatform platform) => tiers;

  @override
  Future<void> open(
    PlatformTrackRef ref, {
    required String requestedQuality,
    required OnlineMusicCancelToken cancelToken,
  }) async {
    await openWithMetadata(
      ref,
      requestedQuality: requestedQuality,
      cancelToken: cancelToken,
    );
  }

  @override
  Future<RemoteQueuePlaybackResult> openWithMetadata(
    PlatformTrackRef ref, {
    required String requestedQuality,
    required OnlineMusicCancelToken cancelToken,
  }) async {
    qualities.add(requestedQuality);
    final nextError = errors.isNotEmpty ? errors.removeAt(0) : error;
    if (nextError != null) throw nextError;
    return const RemoteQueuePlaybackResult(actualQuality: 'flac');
  }
}
