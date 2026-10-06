/// 内置模板：**只收录两套能用真实服务客观验证的协议**（D3）。
///
/// 它们同时是主动探测的候选来源（闭集常量，按 P2/P7：不接受用户自定义候选、
/// 不做开放式扫描）。新增模板的前提是能拿到真实响应样本，否则宁可没有。
library;

import 'package:pure_music/services/music_platform/provider/online_music_binding.dart';
import 'package:pure_music/services/music_platform/provider/online_music_json_path.dart';
import 'package:pure_music/services/music_platform/provider/online_music_request_spec.dart';
import 'package:pure_music/services/music_platform/provider/online_music_response_spec.dart';

JsonPath _p(String source) => JsonPath.tryParse(source)!;

final class OnlineMusicProviderTemplate {
  const OnlineMusicProviderTemplate({
    required this.id,
    required this.label,
    required this.search,
  });

  final String id;
  final String label;
  final OnlineMusicDeclarativeCapabilityBinding search;
}

/// ChkSz：`GET /api/163_search?keyword&limit&offset&apikey`，信封 `data`，
/// `artists` 是字符串。
final OnlineMusicDeclarativeCapabilityBinding chkszSearchTemplate =
    OnlineMusicDeclarativeCapabilityBinding(
      request: const OnlineMusicRequestSpec(
        path: '/api/163_search',
        query: [
          OnlineMusicParamBinding(
            name: 'keyword',
            source: OnlineMusicInputSource.keyword,
            required: true,
          ),
          OnlineMusicParamBinding(
            name: 'limit',
            source: OnlineMusicInputSource.limit,
            defaultValue: 30,
          ),
          OnlineMusicParamBinding(
            name: 'offset',
            source: OnlineMusicInputSource.offset,
            defaultValue: 0,
          ),
        ],
        auth: OnlineMusicQueryAuthPlacement(parameterName: 'apikey'),
      ),
      response: OnlineMusicResponseSpec(
        success: OnlineMusicSuccessSpec(
          allOf: [
            OnlineMusicSuccessPredicate(
              path: _p('code'),
              op: OnlineMusicPredicateOp.eq,
              value: 200,
            ),
            OnlineMusicSuccessPredicate(
              path: _p('msg'),
              op: OnlineMusicPredicateOp.eq,
              value: 'success',
            ),
          ],
        ),
        listPath: _p('data.songs'),
        totalPath: _p('data.total'),
        fields: {
          OnlineMusicDomainField.trackId: OnlineMusicFieldSpec(
            candidates: [_p('id')],
            transform: OnlineMusicFieldTransform.asInt,
            required: true,
          ),
          OnlineMusicDomainField.title: OnlineMusicFieldSpec(
            candidates: [_p('name')],
            transform: OnlineMusicFieldTransform.asString,
            required: true,
          ),
          OnlineMusicDomainField.artists: OnlineMusicFieldSpec(
            candidates: [_p('artists')],
            transform: OnlineMusicFieldTransform.asSingleStringList,
          ),
          OnlineMusicDomainField.album: OnlineMusicFieldSpec(
            candidates: [_p('album')],
            transform: OnlineMusicFieldTransform.asString,
          ),
          OnlineMusicDomainField.coverUri: OnlineMusicFieldSpec(
            candidates: [_p('picUrl')],
            transform: OnlineMusicFieldTransform.asHttpsUri,
          ),
          OnlineMusicDomainField.duration: OnlineMusicFieldSpec(
            candidates: [_p('duration')],
            transform: OnlineMusicFieldTransform.asDurationMs,
          ),
        },
        pagination: const OnlineMusicPaginationSpec(
          kind: OnlineMusicPaginationKind.offsetLimit,
        ),
      ),
    );

/// MSAPI 型网易云代理：`GET /search?keywords`，信封 `result`，
/// `artists` 是对象数组、`album` 是对象、无认证。
final OnlineMusicDeclarativeCapabilityBinding msapiSearchTemplate =
    OnlineMusicDeclarativeCapabilityBinding(
      request: const OnlineMusicRequestSpec(
        path: '/search',
        query: [
          OnlineMusicParamBinding(
            name: 'keywords',
            source: OnlineMusicInputSource.keyword,
            required: true,
          ),
          OnlineMusicParamBinding(
            name: 'limit',
            source: OnlineMusicInputSource.limit,
          ),
          OnlineMusicParamBinding(
            name: 'offset',
            source: OnlineMusicInputSource.offset,
          ),
        ],
      ),
      response: OnlineMusicResponseSpec(
        listPath: _p('result.songs'),
        fields: {
          OnlineMusicDomainField.trackId: OnlineMusicFieldSpec(
            candidates: [_p('id')],
            transform: OnlineMusicFieldTransform.asInt,
            required: true,
          ),
          OnlineMusicDomainField.title: OnlineMusicFieldSpec(
            candidates: [_p('name')],
            transform: OnlineMusicFieldTransform.asString,
            required: true,
          ),
          OnlineMusicDomainField.artists: OnlineMusicFieldSpec(
            candidates: [_p('artists[*].name')],
            transform: OnlineMusicFieldTransform.asStringList,
          ),
          OnlineMusicDomainField.album: OnlineMusicFieldSpec(
            candidates: [_p('album.name')],
            transform: OnlineMusicFieldTransform.asString,
          ),
          OnlineMusicDomainField.duration: OnlineMusicFieldSpec(
            candidates: [_p('duration')],
            transform: OnlineMusicFieldTransform.asDurationMs,
          ),
        },
        pagination: const OnlineMusicPaginationSpec(
          kind: OnlineMusicPaginationKind.offsetLimit,
        ),
      ),
    );

/// 探测候选（编译期闭集，≤ maxRequests 由探测器再兜一层）。
List<OnlineMusicProviderTemplate> onlineMusicProviderTemplates() => [
  OnlineMusicProviderTemplate(
    id: builtinOnlineMusicChkszId,
    label: 'ChkSz 兼容',
    search: chkszSearchTemplate,
  ),
  OnlineMusicProviderTemplate(
    id: 'netease-proxy',
    label: '网易云代理型（MSAPI 兼容）',
    search: msapiSearchTemplate,
  ),
];
