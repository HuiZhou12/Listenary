import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/services/online_lyric/api/isolate_helpers.dart';
import 'package:pure_music/services/online_lyric/api/lyric_http_transport.dart';

// ═══════════════════════════════════════════════════════════════════════════
// fake transport 单测（Spec Q5：离线、零网络）
//
// 覆盖：
//   R1 六个公开入口都经替身发请求，且实例在**执行 isolate 内**构造；
//   R2 请求形状零漂移（method / 绝对 URL / query / headers / body）；
//   R3 响应处理零漂移（非 200 / 非法 UTF-8 / 异常 / 超时 ⇒ 既有哨兵）+ 全静默；
//   R4 跨 isolate 边界只传纯数据（结构扫描 + 工厂可见性运行断言）。
//
// ═══════════════════════════════════════════════════════════════════════════
// Q2 约束（Spec §6.3-1）：注册的工厂必须**可跨 isolate 发送**
//
// fake 由「纯数据脚本 + SendPort」构成：脚本与端口可发送，请求记录经端口回传主
// isolate；transport **实例**只在执行 isolate 内构造。绝不能把 fake 实例本身
// 放进 `Isolate.run` 闭包 —— 那样单测可能绿而真机炸。
// ═══════════════════════════════════════════════════════════════════════════

typedef _Step = Map<String, Object?>;

/// 脚本步骤：`{'status': int, 'body': String, 'bytes': List<int>}`。
///
/// 仅测试用的特殊状态码：
/// - `-1` —— 长时间不返回（保活计时器），驱动 `Future.timeout` 的 onTimeout 哨兵；
/// - `-2` —— 抛异常，驱动传输层 catch 降级。
///
/// 注意 `-1` 必须挂一个**真实计时器**：只留一个未完成的 `Completer` 时 isolate
/// 事件循环排空后会自行退出，`Isolate.run` 以错误结束而不是继续等待，超时分支
/// 就永远测不到。真实 4s 连接超时同样持有计时器，因此这更贴近现状。
const _hangStatus = -1;
const _throwStatus = -2;
const _hangKeepAlive = Duration(seconds: 30);

_Step _step(int status, {String body = '', List<int>? bytes}) =>
    <String, Object?>{'status': status, 'body': body, 'bytes': bytes};

LyricHttpTransportFactory _scriptedFactory(SendPort port, List<_Step> script) =>
    () => _ScriptedTransport(port, script);

final class _ScriptedTransport implements LyricHttpTransport {
  _ScriptedTransport(this._port, this._script);

  final SendPort _port;
  final List<_Step> _script;
  int _index = 0;

  @override
  Future<LyricHttpResponse?> send(LyricHttpRequest request) async {
    final step =
        _script[_index < _script.length ? _index++ : _script.length - 1];
    _port.send(<String, Object?>{
      'method': request.method.name,
      'url': request.url.toString(),
      'headers': request.headers,
      'body': request.body,
      'isolate': Isolate.current.hashCode,
    });
    final status = step['status']! as int;
    if (status == _hangStatus) {
      final keepAlive = Completer<LyricHttpResponse?>();
      Timer(_hangKeepAlive, () {
        if (!keepAlive.isCompleted) {
          keepAlive.complete(null);
        }
      });
      return keepAlive.future;
    }
    if (status == _throwStatus) {
      throw StateError('scripted transport failure');
    }
    final rawBytes = step['bytes'] as List<int>?;
    final body = step['body'] as String? ?? '';
    return LyricHttpResponse(
      statusCode: status,
      body: rawBytes != null ? decodeLyricBodyStrict(rawBytes) : body,
    );
  }
}

/// 请求记录器：纯数据经端口回传主 isolate。
class _Recorder {
  _Recorder() {
    _sub = _port.listen((message) {
      _seen.add((message as Map).cast<String, Object?>());
    });
  }

  final ReceivePort _port = ReceivePort();
  late final StreamSubscription<Object?> _sub;
  final List<Map<String, Object?>> _seen = <Map<String, Object?>>[];

  SendPort get sendPort => _port.sendPort;
  List<Map<String, Object?>> get requests => List.unmodifiable(_seen);

  /// 等端口消息排空（isolate 的 send 是异步的）。
  Future<void> settle([int ms = 150]) =>
      Future<void>.delayed(Duration(milliseconds: ms));

  Future<void> dispose() async {
    await _sub.cancel();
    _port.close();
  }
}

/// 把 `Uri` 的 query 拍平成可比较的 Map。
Map<String, String> _queryOf(String url) => Uri.parse(url).queryParameters;

/// 去掉 query 后的绝对 URL（用于断言路径本身）。
String _pathOf(String url) {
  final uri = Uri.parse(url);
  return '${uri.scheme}://${uri.authority}${uri.path}';
}

const _kgSearchExpectedUrl = 'http://mobilecdn.kugou.com/api/v3/search/song';
const _neSearchExpectedUrl = 'https://music.163.com/api/cloudsearch/pc';
const _qqSearchExpectedUrl = 'https://u.y.qq.com/cgi-bin/musicu.fcg';
const _qqLyricFallbackUrl =
    'https://c.y.qq.com/qqmusic/fcgi-bin/lyric_download.fcg';

void main() {
  late _Recorder recorder;

  setUp(() {
    recorder = _Recorder();
    setLyricHttpTransportFactoryForTest(null);
  });

  tearDown(() async {
    setLyricHttpTransportFactoryForTest(null);
    await recorder.dispose();
  });

  void inject(List<_Step> script) {
    setLyricHttpTransportFactoryForTest(
      _scriptedFactory(recorder.sendPort, script),
    );
  }

  // ─────────────────────────────────────────────────────────────────────────
  group('默认注册', () {
    test('未注入时工厂返回生产实现，注册点默认不产出任何实例', () {
      expect(lyricHttpTransportFactory(), isA<IoLyricHttpTransport>());
    });

    test('注入只保存工厂；取用之前不构造 transport', () {
      var built = 0;
      setLyricHttpTransportFactoryForTest(() {
        built++;
        return const IoLyricHttpTransport();
      });
      expect(built, 0);
      lyricHttpTransportFactory();
      expect(built, 1);
    });
  });

  // ─────────────────────────────────────────────────────────────────────────
  // R1 + R4：注入生效、实例只在执行 isolate 内构造
  group('注入穿透 isolate', () {
    test('六个公开入口的请求都到达替身', () async {
      final mainId = Isolate.current.hashCode;
      final hits = <String>[];

      Future<void> probe(
        String label,
        List<_Step> script,
        Future<Object?> Function() run,
      ) async {
        inject(script);
        final before = recorder.requests.length;
        await run();
        await recorder.settle();
        final got = recorder.requests.length - before;
        if (got > 0) hits.add(label);
      }

      await probe('kgSearch', [
        _step(
          200,
          body: jsonEncode({
            'data': {'info': []},
          }),
        ),
      ], () => kgSearchIsolate(text: 'k', offset: 1, limit: 8));
      await probe('kgLyric', [
        _step(200, body: jsonEncode({'candidates': []})),
      ], () => kgLyricIsolate(hash: 'h'));
      await probe('neSearch', [
        _step(
          200,
          body: jsonEncode({
            'result': {'songs': []},
          }),
        ),
      ], () => neSearchIsolate(text: 'n', offset: 0, limit: 8));
      await probe('neLyric', [
        _step(
          200,
          body: jsonEncode({
            'lrc': {'lyric': '[00:01.00]x'},
          }),
        ),
      ], () => neLyricIsolate(id: 1));
      await probe('qqSearch', [
        _step(
          200,
          body: jsonEncode({
            'req_0': {
              'data': {
                'body': {'item_song': []},
              },
            },
          }),
        ),
      ], () => qqSearchIsolate(text: 'q', offset: 1, limit: 8));
      await probe('qqLyric', [
        _step(
          200,
          body: jsonEncode({
            'req_0': {'data': null},
          }),
        ),
        _step(200, body: '<content><![CDATA[[00:01.00]a]]></content>'),
      ], () => qqLyricIsolate(id: 7, title: 't'));

      expect(hits, [
        'kgSearch',
        'kgLyric',
        'neSearch',
        'neLyric',
        'qqSearch',
        'qqLyric',
      ]);

      final isolates = recorder.requests.map((r) => r['isolate']).toSet();
      expect(isolates, hasLength(greaterThan(0)));
      expect(
        isolates.contains(mainId),
        isFalse,
        reason: 'R4：transport 实例必须在执行 isolate 内构造，不能在主 isolate 构造',
      );
    });

    test('主 isolate 注册的工厂在执行 isolate 内可见（R4 运行断言）', () async {
      inject([
        _step(
          200,
          body: jsonEncode({
            'data': {'info': []},
          }),
        ),
      ]);
      await kgSearchIsolate(text: 'k', offset: 1, limit: 8);
      await recorder.settle();
      expect(
        recorder.requests,
        isNotEmpty,
        reason: '若工厂不可见，执行 isolate 会走真实 HttpClient 而不留记录',
      );
    });

    test('结构断言：跨 Isolate.run 边界的载荷不含 transport / HttpClient 实例（R4）', () {
      final source = File(
        'lib/services/online_lyric/api/isolate_helpers.dart',
      ).readAsStringSync();

      // 每个 Isolate.run 闭包体都必须经 _withTransportFactory 注入工厂，
      // 闭包内不得出现 HttpClient / transport 实例。
      expect(
        RegExp(
          r'Isolate\.run\(\s*\(\)\s*=>\s*_withTransportFactory\(',
        ).allMatches(source).length,
        6,
        reason: '六个公开入口（qqFallbackLyricIsolate 复用 qqLyricIsolate）',
      );
      // 只扫代码行：注释里提到 HttpClient 是说明文字，不构成实例化。
      final code = source
          .split('\n')
          .where((line) => !line.trimLeft().startsWith('//'))
          .join('\n');
      expect(
        code.contains('HttpClient'),
        isFalse,
        reason: 'isolate_helpers 的自建 client 已收敛到 transport 实现内',
      );
      expect(
        RegExp(r'Isolate\.run\([^;]{0,200}?LyricHttp').hasMatch(source),
        isFalse,
        reason: '禁止把 transport 实例送过 isolate 边界',
      );
    });
  });

  // ─────────────────────────────────────────────────────────────────────────
  // R2：请求形状零漂移
  group('请求形状零漂移', () {
    test('KG 搜索：GET + 绝对明文 URL + query + UA/Accept', () async {
      inject([
        _step(
          200,
          body: jsonEncode({
            'data': {'info': []},
          }),
        ),
      ]);
      await kgSearchIsolate(text: '周杰伦', offset: 1, limit: 8, cacheBust: 99);
      await recorder.settle();

      final req = recorder.requests.first;
      expect(req['method'], 'get');
      expect(_pathOf(req['url']! as String), _kgSearchExpectedUrl);
      expect(_queryOf(req['url']! as String), {
        'format': 'json',
        'keyword': '周杰伦',
        'page': '1',
        'pagesize': '8',
        '_': '99',
      });
      expect(req['headers'], {
        'User-Agent':
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/138.0.0.0 Safari/537.36',
        'Accept': 'application/json,text/plain,*/*',
      });
      expect(req['body'], isNull);
    });

    test('KG 搜索：主域名空响应 ⇒ 降级到 fallback 域名（形状不同）', () async {
      inject([
        _step(200, body: ''),
        _step(
          200,
          body: jsonEncode({
            'data': {'lists': []},
          }),
        ),
      ]);
      await kgSearchIsolate(text: 'k', offset: 1, limit: 8);
      await recorder.settle();

      expect(recorder.requests, hasLength(2));
      expect(
        Uri.parse(recorder.requests[0]['url']! as String).host,
        'mobilecdn.kugou.com',
      );
      final fallback = Uri.parse(recorder.requests[1]['url']! as String);
      expect(
        fallback.toString(),
        startsWith('https://songsearch.kugou.com/song_search_v2'),
      );
      expect(_queryOf(fallback.toString()), {
        'keyword': 'k',
        'page': '1',
        'pagesize': '8',
      });
    });

    test('NE 搜索：GET + 绝对 URL + UA/Accept/Referer', () async {
      inject([
        _step(
          200,
          body: jsonEncode({
            'result': {'songs': []},
          }),
        ),
      ]);
      await neSearchIsolate(text: 'n', offset: 8, limit: 8);
      await recorder.settle();

      final req = recorder.requests.first;
      expect(req['method'], 'get');
      expect(_pathOf(req['url']! as String), _neSearchExpectedUrl);
      expect(_queryOf(req['url']! as String), {
        's': 'n',
        'type': '1',
        'offset': '8',
        'total': 'true',
        'limit': '8',
      });
      expect(req['headers'], {
        'User-Agent':
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/138.0.0.0 Safari/537.36',
        'Accept': 'application/json,text/plain,*/*',
        'Referer': 'https://music.163.com/',
      });
    });

    test('NE 歌词：query 含 lv/yv/tv/rv/os（保护区输入零变化 R6）', () async {
      inject([
        _step(
          200,
          body: jsonEncode({
            'lrc': {'lyric': '[00:01.00]x'},
          }),
        ),
      ]);
      await neLyricIsolate(id: 42);
      await recorder.settle();

      final req = recorder.requests.first;
      expect(req['headers'], containsPair('Referer', 'https://music.163.com/'));
      expect(_queryOf(req['url']! as String), {
        'id': '42',
        'lv': '-1',
        'yv': '-1',
        'tv': '-1',
        'rv': '-1',
        'os': 'pc',
      });
    });

    test('QQ 搜索：POST + Host/Content-Type + 无 query', () async {
      inject([
        _step(
          200,
          body: jsonEncode({
            'req_0': {'data': null},
          }),
        ),
      ]);
      await qqSearchIsolate(text: 'q', offset: 1, limit: 8);
      await recorder.settle();

      final req = recorder.requests.first;
      expect(req['method'], 'post');
      expect(Uri.parse(req['url']! as String).toString(), _qqSearchExpectedUrl);
      expect(req['headers'], {
        'User-Agent':
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/138.0.0.0 Safari/537.36',
        'Host': 'u.y.qq.com',
        'Content-Type': 'text/plain; charset=utf-8',
      });
      final decoded =
          jsonDecode(req['body']! as String) as Map<String, dynamic>;
      expect(decoded['req_0']['method'], 'DoSearchForQQMusicLite');
      expect(decoded['req_0']['param']['query'], 'q');
      expect(decoded['comm']['tmeAppID'], 'qqmusiclight');
    });

    test('QQ 歌词方案 A→B：GET 降级请求不带自定义 header', () async {
      inject([
        _step(
          200,
          body: jsonEncode({
            'req_0': {'data': null},
          }),
        ),
        _step(200, body: '<content><![CDATA[[00:01.00]a]]></content>'),
      ]);
      await qqLyricIsolate(
        id: 7,
        title: '标题',
        album: '专辑',
        artist: '歌手',
        durationSec: 200,
      );
      await recorder.settle();

      expect(recorder.requests, hasLength(2));
      final a =
          jsonDecode(recorder.requests[0]['body']! as String)
              as Map<String, dynamic>;
      expect(a['req_0']['method'], 'GetPlayLyricInfo');
      expect(a['req_0']['param']['qrc'], 1);
      expect(a['req_0']['param']['trans'], 1);
      expect(a['req_0']['param']['roma'], 1);
      expect(a['req_0']['param']['crypt'], 1);
      expect(a['req_0']['param']['songID'], 7);

      final b = recorder.requests[1];
      expect(b['method'], 'get');
      expect(_pathOf(b['url']! as String), _qqLyricFallbackUrl);
      expect(b['headers'], isNull, reason: '方案 B 改造前即传 null header');
      expect(_queryOf(b['url']! as String), {
        'version': '15',
        'miniversion': '82',
        'lrctype': '4',
        'musicid': '7',
      });
    });

    test('KG 歌词候选循环：最多 5 条，命中内容即停止', () async {
      inject([
        _step(
          200,
          body: jsonEncode({
            'candidates': [
              {'id': 'i1', 'accesskey': 'a1'},
              {'id': 'i2', 'accesskey': 'a2'},
              {'id': 'i3', 'accesskey': 'a3'},
              {'id': 'i4', 'accesskey': 'a4'},
              {'id': 'i5', 'accesskey': 'a5'},
              {'id': 'i6', 'accesskey': 'a6'},
            ],
          }),
        ),
        _step(200, body: jsonEncode({'content': ''})),
        _step(200, body: jsonEncode({'content': 'ENCRYPTED'})),
      ]);
      final result = await kgLyricIsolate(hash: 'H');
      await recorder.settle();

      expect(result, {'encrypted': 'ENCRYPTED'});
      expect(
        recorder.requests,
        hasLength(3),
        reason: '第 1 条空 content ⇒ 继续；第 2 条命中 ⇒ 停止，不试第 6 条',
      );
      expect(_queryOf(recorder.requests[0]['url']! as String), {
        'ver': '1',
        'man': 'yes',
        'client': 'pc',
        'hash': 'H',
      });
      expect(_queryOf(recorder.requests[2]['url']! as String), {
        'ver': '1',
        'client': 'pc',
        'id': 'i2',
        'accesskey': 'a2',
        'fmt': 'krc',
        'charset': 'utf8',
      });
    });

    test('请求不含任何凭据/代理参数（Q3）', () async {
      inject([
        _step(
          200,
          body: jsonEncode({
            'data': {'info': []},
          }),
        ),
      ]);
      await kgSearchIsolate(text: 'k', offset: 1, limit: 8);
      await recorder.settle();

      final url = (recorder.requests.first['url']! as String).toLowerCase();
      for (final banned in [
        'apikey',
        'api_key',
        'token',
        'authorization',
        'proxy',
        'credential',
      ]) {
        expect(url.contains(banned), isFalse, reason: 'URL 不得含 $banned');
      }
      final headers = (recorder.requests.first['headers']! as Map).keys.map(
        (k) => k.toString().toLowerCase(),
      );
      expect(headers.contains('authorization'), isFalse);
      expect(headers.contains('proxy-authorization'), isFalse);
      expect(headers.contains('cookie'), isFalse);
    });
  });

  // ─────────────────────────────────────────────────────────────────────────
  // R3：响应处理零漂移 + 全静默
  group('响应处理零漂移', () {
    test('非 200 ⇒ 各入口既有哨兵逐字相等', () async {
      inject([_step(503)]);

      expect(await kgSearchIsolate(text: 'k', offset: 1, limit: 8), isEmpty);
      expect(await kgLyricIsolate(hash: 'h'), {'encrypted': null});
      expect(await neSearchIsolate(text: 'n', offset: 0, limit: 8), isEmpty);
      expect(await neLyricIsolate(id: 1), {
        'main': null,
        'trans': null,
        'roma': null,
        'format': 'lrc',
      });
      expect(await qqSearchIsolate(text: 'q', offset: 1, limit: 8), isEmpty);
      expect(await qqLyricIsolate(id: 1), {
        'encryptedLyric': null,
        'encryptedTrans': null,
        'roma': null,
      });
      await recorder.settle();
    });

    test('传输层异常 ⇒ 同样降级到哨兵（无重试）', () async {
      // NE 搜索没有降级链，因此「一次异常 ⇒ 一条请求」可精确证明没有重试。
      inject([_step(_throwStatus)]);
      expect(await neSearchIsolate(text: 'n', offset: 0, limit: 8), isEmpty);
      await recorder.settle();
      expect(recorder.requests, hasLength(1), reason: '无重试：异常后不重发');

      // KG 搜索的第二次请求是改造前就有的**域名降级**，不是重试。
      inject([_step(_throwStatus), _step(_throwStatus)]);
      expect(await kgSearchIsolate(text: 'k', offset: 1, limit: 8), isEmpty);
      await recorder.settle();
      expect(recorder.requests, hasLength(3), reason: 'KG 降级链只走一次主域 + 一次备域');
    });

    test('非法 JSON ⇒ 哨兵，且不抛到调用方', () async {
      inject([_step(200, body: '{not json')]);
      expect(await kgSearchIsolate(text: 'k', offset: 1, limit: 8), isEmpty);
      inject([_step(200, body: '{not json')]);
      expect(await neLyricIsolate(id: 1), {
        'main': null,
        'trans': null,
        'roma': null,
        'format': 'lrc',
      });
      await recorder.settle();
    });

    test('非法 UTF-8 ⇒ null 哨兵（严格解码，不 allowMalformed）', () async {
      // 0xFF 在 UTF-8 中永远非法。
      inject([
        _step(200, bytes: [0xFF, 0xFE]),
      ]);
      expect(await kgLyricIsolate(hash: 'h'), {
        'encrypted': null,
      }, reason: '严格 UTF-8 失败必须退化为 null 哨兵，而不是被替换成 U+FFFD');
      await recorder.settle();
    });

    test('传输层返回原文 body：不预解析，由源层自行 jsonDecode', () async {
      // 若传输层预先解析，`content` 前后的空白与键顺序都会变；这里逐字比对。
      const raw = '{"candidates":[{"id":"1","accesskey":"k"}]}';
      inject([
        _step(200, body: raw),
        _step(200, body: jsonEncode({'content': 'X'})),
      ]);
      final result = await kgLyricIsolate(hash: 'h');
      expect(result, {'encrypted': 'X'});
      await recorder.settle();
    });

    test('失败路径不产生任何输出（Q4 全静默）', () async {
      final prints = <String>[];
      await runZoned(
        () async {
          inject([_step(503)]);
          await kgSearchIsolate(text: 'k', offset: 1, limit: 8);
          inject([_step(_throwStatus)]);
          await kgLyricIsolate(hash: 'h');
          inject([
            _step(200, bytes: [0xFF]),
          ]);
          await neSearchIsolate(text: 'n', offset: 0, limit: 8);
          await recorder.settle();
        },
        zoneSpecification: ZoneSpecification(
          print: (self, parent, zone, line) => prints.add(line),
        ),
      );
      expect(prints, isEmpty, reason: 'Q4：传输层失败不得新增日志或 debug 输出');
    });
  });

  // ─────────────────────────────────────────────────────────────────────────
  // 超时哨兵：isolate 包装层（8s / 12s）数值与哨兵值均不变
  //
  // 用真实时钟断言，不用虚拟时钟：`Future.timeout` 在 isolate 包装层创建，
  // 只有真实经过 8s / 12s 才能证明数值没有被缩短。六个入口并发启动，总耗时
  // 约 12.4s（不是 6 × 8s）。`fake_async` 不是 pubspec 直接依赖，不为此改依赖。
  group('超时哨兵', () {
    test('六个入口在 isolate 包装超时后给出既有哨兵，且 8s/12s 数值未漂移', () async {
      inject([_step(_hangStatus)]);
      final results = <String, Object?>{};

      for (final entry in <String, Future<Object?>>{
        'kgSearch': kgSearchIsolate(text: 'k', offset: 1, limit: 8),
        'kgLyric': kgLyricIsolate(hash: 'h'),
        'neSearch': neSearchIsolate(text: 'n', offset: 0, limit: 8),
        'neLyric': neLyricIsolate(id: 1),
        'qqSearch': qqSearchIsolate(text: 'q', offset: 1, limit: 8),
        'qqLyric': qqLyricIsolate(id: 1),
      }.entries) {
        entry.value.then((value) => results[entry.key] = value);
      }

      await Future<void>.delayed(const Duration(milliseconds: 7500));
      expect(results, isEmpty, reason: '7.5s 时六个入口都还没超时：8s / 12s 的包装超时没有被缩短');

      await Future<void>.delayed(const Duration(milliseconds: 900));
      expect(results.keys.toSet(), {
        'kgSearch',
        'kgLyric',
        'neSearch',
        'neLyric',
        'qqSearch',
      }, reason: '约 8.4s 时五个 8s 入口已超时，QQ 歌词仍在等 12s');

      await Future<void>.delayed(const Duration(milliseconds: 4000));
      expect(results.keys, contains('qqLyric'));

      expect(results['kgSearch'], isEmpty);
      expect(results['kgLyric'], {'encrypted': null});
      expect(results['neSearch'], isEmpty);
      expect(results['neLyric'], {
        'main': null,
        'trans': null,
        'roma': null,
        'format': 'lrc',
      });
      expect(results['qqSearch'], isEmpty);
      expect(results['qqLyric'], {
        'encryptedLyric': null,
        'encryptedTrans': null,
        'roma': null,
      });
      await recorder.settle();
    }, timeout: const Timeout(Duration(seconds: 60)));
  });
}
