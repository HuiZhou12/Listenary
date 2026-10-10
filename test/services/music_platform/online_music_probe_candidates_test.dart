import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/services/music_platform/chksz/index.dart';
import 'package:pure_music/services/music_platform/declarative/provider_probe.dart';
import 'package:pure_music/services/music_platform/declarative/provider_templates.dart';
import 'package:pure_music/services/music_platform/provider/online_music_probe_candidates.dart';

/// F3-S3（P-05 / P-27 / D-F3-1 / D-F3-5）：探测候选**优先复用条目自身的配置**。
///
/// 这些用例是"探测到底该打谁"的判据：以前候选只有 2 个编译期模板（P-05：探测与用户
/// 配置完全脱钩；P-27：自建服务无法探测），现在必须是"条目自身优先、模板只作兼容兜底"。
void main() {
  OnlineMusicSettings settingsWith(Map<String, Object?> capabilities) =>
      OnlineMusicSettings.fromJson({
        'providers': [
          {
            'id': 'selfData',
            'baseUrl': 'https://self.invalid',
            'auth': {'kind': 'none'},
            'capabilities': capabilities,
          },
        ],
      });

  OnlineMusicDeclarativeCapabilityBinding binding(String path) =>
      OnlineMusicDeclarativeCapabilityBinding(
        request: OnlineMusicRequestSpec(path: path),
        response: OnlineMusicResponseSpec(),
      );

  test('★ 条目自己配了 search ⇒ 只探它，并标为"条目自身配置"', () {
    final definition = settingsWith({
      'search': binding('/search').toJson(),
      'stream': binding('/song/url').toJson(),
    }).providers.single;

    final candidates = probeCandidatesFor(definition);

    expect(candidates, hasLength(1));
    expect(candidates.single.id, 'user:search');
    expect(candidates.single.capability, OnlineMusicCapability.search);
    expect(
      candidates.single.source,
      ProviderProbeCandidateSource.userConfig,
      reason: '来源必须如实标注（D-F3-1 第 3 条）',
    );
    // D-F3-1 第 4 条：条目已有绑定 ⇒ **不得**把模板也塞进候选（否则模板的成功会掩盖问题）。
    expect(
      candidates.any(
        (candidate) =>
            candidate.source ==
            ProviderProbeCandidateSource.compatibilityTemplate,
      ),
      isFalse,
    );
  });

  test('★ 同时有 search 与 newSongs ⇒ search 优先（D-F3-5 第 1 条）', () {
    final definition = settingsWith({
      'newSongs': binding('/new').toJson(),
      'search': binding('/search').toJson(),
    }).providers.single;

    final candidates = probeCandidatesFor(definition);

    expect(candidates, hasLength(2));
    expect(candidates.first.capability, OnlineMusicCapability.search);
    expect(candidates.last.capability, OnlineMusicCapability.newSongs);
  });

  test('★ 没有 search、只有 newSongs ⇒ 用 newSongs（D-F3-5 第 2 条）', () {
    final definition = settingsWith({
      'newSongs': binding('/new').toJson(),
    }).providers.single;

    final candidates = probeCandidatesFor(definition);

    expect(candidates, hasLength(1));
    expect(candidates.single.capability, OnlineMusicCapability.newSongs);
    expect(candidates.single.id, 'user:newSongs');
  });

  test('★ 条目只配了 stream（不适合服务级探测）⇒ **没有候选**，且不退回模板', () {
    // stream/lyric/playlist 这些能力要么必须带 trackId/playlistId，要么返回的不是曲目列表，
    // 因此不是服务级探测的目标（Spec §19.5）。**关键**：此时也**不能**退回模板 ——
    // 那等于用模板的成功掩盖"用户配的是另一套服务"（D-F3-1 第 4 条）。
    final definition = settingsWith({
      'stream': binding('/song/url').toJson(),
    }).providers.single;

    final candidates = probeCandidatesFor(definition);

    expect(candidates, isEmpty);
    expect(hasAnyDeclarativeBinding(definition), isTrue);
    final reason = noProbeCandidateReason(definition);
    expect(reason, contains('不适合服务级探测'));
    expect(
      reason,
      isNot(contains('没有声明式绑定')),
      reason: '不能把"配的能力不适合探测"说成"没有绑定"（那就是在撒谎）',
    );
  });

  test('★ 条目**完全没有**绑定 ⇒ 才用兼容模板，并标为模板来源', () {
    // 旧条目（没有 capabilities 键）走内置实现 ⇒ 没有声明式绑定可探 ⇒ 兼容模板兜底。
    final definition = OnlineMusicSettings.fromJson({
      'providers': [
        {'id': 'chksz', 'protocol': 'chksz'},
      ],
    }).providers.single;

    final candidates = probeCandidatesFor(definition);

    expect(candidates, isNotEmpty);
    expect(
      candidates.every(
        (candidate) =>
            candidate.source ==
            ProviderProbeCandidateSource.compatibilityTemplate,
      ),
      isTrue,
    );
    expect(
      candidates.map((candidate) => candidate.id),
      contains(builtinOnlineMusicChkszId),
    );
    // 一个都没配、又没有可用模板时，理由必须说"没有绑定"（与上面那条形成对照）。
    expect(
      noProbeCandidateReason(definition),
      contains('没有声明式绑定'),
    );
    expect(probeCandidatesFor(definition, templates: const []), isEmpty);
  });

  test('★ 条目有绑定但**写坏了** ⇒ 仍然只探它（不退回模板）', () {
    final definition = settingsWith({
      // "写坏了"的**声明式**绑定：路径合法、能解析成声明式，但缺必填字段映射
      // ⇒ 校验会报问题（下面断言），而观测目标是"探测仍然只打它、不换模板"。
      'search': OnlineMusicDeclarativeCapabilityBinding(
        request: const OnlineMusicRequestSpec(path: '/search'),
        response: OnlineMusicResponseSpec(),
      ).toJson(),
    }).providers.single;

    final candidates = probeCandidatesFor(definition);

    expect(candidates, hasLength(1));
    expect(candidates.single.source, ProviderProbeCandidateSource.userConfig);
    expect(
      candidates.single.capability,
      OnlineMusicCapability.search,
      reason: '写坏了也要探它 —— 结论会如实报成配置问题，而不是悄悄换成模板',
    );
    expect(
      candidates.single.binding.validationIssues(OnlineMusicCapability.search),
      isNotEmpty,
      reason: '夹具确实是"写坏了"的绑定（校验报问题），否则这条用例没有覆盖到该场景',
    );
  });

  test('★ F3-S9 候选范围按裁定扩大：无需实体 ID 的能力都可作探针', () {
    // 用户裁定第 1/2 条：不要求"必须返回曲目列表" —— 只要**不需要用户提供具体实体 ID**、
    // 能独立执行并给出自己的服务级证据，就可作候选。
    expect(probeCapableCapabilities, const [
      OnlineMusicCapability.search,
      OnlineMusicCapability.newSongs,
      OnlineMusicCapability.playlistCollection,
      OnlineMusicCapability.playlistCategories,
      OnlineMusicCapability.chartList,
    ]);
    // 裁定第 3 条：需要具体曲目 / 歌单 ID 的能力**不作默认探针**（也绝不伪造 ID）。
    for (final capability in const [
      OnlineMusicCapability.playlist,
      OnlineMusicCapability.lyric,
      OnlineMusicCapability.stream,
    ]) {
      expect(
        probeCapableCapabilities,
        isNot(contains(capability)),
        reason: '${capability.name} 需要具体实体 ID ⇒ 只能试跑',
      );
    }
  });

  test('★ F3-S9 只配了歌单列表 / 分类 / 榜单 ⇒ 现在也能探测', () {
    for (final capability in const [
      OnlineMusicCapability.playlistCollection,
      OnlineMusicCapability.playlistCategories,
      OnlineMusicCapability.chartList,
    ]) {
      final definition = settingsWith({
        capability.name: binding('/x').toJson(),
      }).providers.single;

      final candidates = probeCandidatesFor(definition);

      expect(candidates, hasLength(1), reason: '${capability.name} 应当能作探针');
      expect(candidates.single.capability, capability);
      expect(
        candidates.single.source,
        ProviderProbeCandidateSource.userConfig,
      );
    }
  });

  test('★ F3-S9 search 优先；没有 search 时按可探测能力的顺序取', () {
    final definition = settingsWith({
      'chartList': binding('/toplist').toJson(),
      'search': binding('/search').toJson(),
    }).providers.single;

    final candidates = probeCandidatesFor(definition);

    expect(candidates.first.capability, OnlineMusicCapability.search);
    expect(
      candidates.map((candidate) => candidate.capability),
      contains(OnlineMusicCapability.chartList),
      reason: '其余可探测能力按 probeCapableCapabilities 的顺序跟在后面',
    );
  });
  test('界面标签写清"来源（能力）"，不得只报"探测成功"', () {
    final definition = settingsWith({
      'search': binding('/search').toJson(),
    }).providers.single;

    expect(
      probeCandidatesFor(definition).single.sourceLabel,
      '条目自身配置（搜索）',
    );
    expect(
      ProviderProbeCandidate.fromTemplate(
        onlineMusicProviderTemplates().first,
      ).sourceLabel,
      contains('兼容模板'),
    );
  });
}
