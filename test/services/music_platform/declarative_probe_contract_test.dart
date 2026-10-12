import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/services/music_platform/declarative/declarative_probe_contract.dart';
import 'package:pure_music/services/music_platform/provider/online_music_capability.dart';

/// **F3-4a 验收**：探测的**能力契约**（Spec §9.1 / §13.3）。
///
/// 钉两件事：
/// 1. **只有一张表**：可探测性、不可探测的原因、结果单位都来自 `declarativeProbeCapabilityContracts`，
///    `probeCapableCapabilities` 与映射单位都从它派生（以前是两处各写一份，漏改就会出现
///    "能探但不会计数"或"探了却算作不可探"）；
/// 2. **新增能力不能悄悄漏掉契约**：`probeContractFor` 找不到就抛错（而不是放过）。
void main() {
  group('能力契约的完备性', () {
    test('★ **每一个**能力都有契约（漏补会抛错，而不是悄悄放过）', () {
      for (final capability in OnlineMusicCapability.values) {
        expect(
          () => probeContractFor(capability),
          returnsNormally,
          reason: '${capability.name} 缺少探测契约',
        );
      }
    });

    test('契约表本身不重复、不遗漏', () {
      final declared = declarativeProbeCapabilityContracts
          .map((contract) => contract.capability)
          .toList();

      expect(declared.toSet().length, declared.length, reason: '不得重复声明');
      expect(declared.toSet(), OnlineMusicCapability.values.toSet());
    });
  });

  group('可探测性（服务级探针）', () {
    test('可探测的七项与顺序（顺序即执行顺序，搜索优先）', () {
      expect(probeCapableCapabilities, const [
        OnlineMusicCapability.search,
        OnlineMusicCapability.newSongs,
        OnlineMusicCapability.playlistCollection,
        OnlineMusicCapability.playlistCategories,
        OnlineMusicCapability.chartList,
        // 2026-10-12 新增：新专辑同样"不需要实体 ID" ⇒ 也可探测 ✓。
        OnlineMusicCapability.newAlbums,
        // 搜索专辑：与搜索同判据（给默认关键词即可 ✓）。
        OnlineMusicCapability.searchAlbums,
      ]);
    });

    test('★ 每个可探测能力都有**非空结果单位**（防"能探但不会计数"）', () {
      for (final capability in probeCapableCapabilities) {
        expect(
          probeResultUnitFor(capability).trim(),
          isNotEmpty,
          reason: '${capability.name} 可探测却没有单位',
        );
      }
    });

    test('结果单位按能力区分（不把"歌单列表"说成"首"）', () {
      expect(probeResultUnitFor(OnlineMusicCapability.search), '首曲目');
      expect(probeResultUnitFor(OnlineMusicCapability.newSongs), '首曲目');
      expect(
        probeResultUnitFor(OnlineMusicCapability.playlistCollection),
        '个歌单',
      );
      expect(
        probeResultUnitFor(OnlineMusicCapability.playlistCategories),
        '个分类',
      );
      expect(probeResultUnitFor(OnlineMusicCapability.chartList), '个榜单');
    });

    test('可探测能力没有"不可探测原因"', () {
      for (final capability in probeCapableCapabilities) {
        expect(probeNotProbeableReasonFor(capability), isNull);
      }
    });
  });

  group('需要实体 ID 的能力：明确的边界，而不是伪造 ID', () {
    test('歌单详情 / 歌词 / 播放解析 都不可探测，且原因统一可读', () {
      for (final capability in const [
        OnlineMusicCapability.playlist,
        OnlineMusicCapability.lyric,
        OnlineMusicCapability.stream,
      ]) {
        expect(probeCapableCapabilities, isNot(contains(capability)));
        final reason = probeNotProbeableReasonFor(capability);
        expect(reason, isNotNull);
        expect(reason, contains('曲目 / 歌单 ID'));
        expect(reason, contains('不会伪造 ID'));
        expect(reason, contains('试跑'));
      }
    });

    test('不可探测能力不参与计数单位', () {
      expect(probeResultUnitFor(OnlineMusicCapability.lyric), isEmpty);
      expect(probeResultUnitFor(OnlineMusicCapability.stream), isEmpty);
    });
  });

  group('F3-4b 源码守卫', () {
    test('★ 探测入口不得再按能力隐藏（界面里不得出现 `if (_isSearch)`）', () {
      final source = File(
        'lib/page/settings_page/online_music_capability_editor.dart',
      ).readAsStringSync();

      expect(source, contains('探测该服务'), reason: '入口必须在（不隐藏）');
      expect(
        source,
        isNot(contains('if (_isSearch)')),
        reason:
            'F3-4：不得再按能力隐藏探测入口；'
            '需要实体 ID 的能力应由能力契约在点下后说明原因',
      );
    });
  });
}
