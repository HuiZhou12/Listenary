/// **共享的声明式请求执行引擎**（P-07：探测与试跑必须走同一条执行与判定路径）。
///
/// 为什么需要它：探测此前**自带一套内联分类**（401/403 手写、成功判定手写、
/// 兜底 `catch (_)` 归"网络"），于是同一个响应在探测与试跑里可能得到不同结论
/// （审计的"第四处分类逻辑"）。这里把四件事收敛成**一份**：
/// 1. 请求构造（`buildDeclarativeRequest`，含敏感请求头凭据读取）；
/// 2. 发送（调用方注入传输层，探测用不跟随重定向的实例）；
/// 3. **成功判定 + 失败分类**（唯一表 `classifyHttpStatus`，声明式对照规则见
///    [classifyDeclarativeUnsuccessfulResponse]）；
/// 4. 诊断：**脱敏**的请求摘要（发出前就记下）与响应片段。
///
/// 调用方只负责**各自**的后续：试跑按能力做字段映射，探测按 search 打分。
library;

import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:pure_music/services/music_platform/declarative/declarative_diagnostics.dart';
import 'package:pure_music/services/music_platform/declarative/declarative_errors.dart';
import 'package:pure_music/services/music_platform/declarative/declarative_http_transport.dart';
import 'package:pure_music/services/music_platform/declarative/declarative_request_builder.dart';
import 'package:pure_music/services/music_platform/declarative/declarative_response_mapper.dart';
import 'package:pure_music/services/music_platform/provider/online_music_provider_credentials.dart';
import 'package:pure_music/services/music_platform/online_music_error.dart';
import 'package:pure_music/services/music_platform/online_music_request.dart';
import 'package:pure_music/services/music_platform/provider/online_music_request_spec.dart';
import 'package:pure_music/services/music_platform/provider/online_music_response_spec.dart';

/// 传输失败的**结构化详情**（D-F3-4）。
///
/// 刻意**不**新增顶层失败类别（不加 `DeclarativeTestFailureKind.timeout`）：
/// 超时/连接/DNS/TLS 仍然属于既有的**传输失败大类**（[OnlineMusicErrorKind.network]），
/// 判据不变；但底层类型必须**真的读出来**并写进诊断，否则"超时"与"域名打错"
/// 在界面上都只会显示"网络不可达"（P-50 的原始症状）。
enum DeclarativeTransportFailure {
  /// 连接/发送/接收**超时**。
  timeout,

  /// 连不上（拒绝、重置、无法建立）。
  connection,

  /// **域名解析**失败。
  dns,

  /// TLS/证书问题。
  tls,

  /// 主动取消。
  cancelled,

  /// **不是传输异常**：编程错误或其它非传输异常（D-F3-4 明令不得吞成"网络不可达"）。
  notTransport,
}

String declarativeTransportFailureLabel(DeclarativeTransportFailure failure) =>
    switch (failure) {
      DeclarativeTransportFailure.timeout => '超时',
      DeclarativeTransportFailure.connection => '无法连接',
      DeclarativeTransportFailure.dns => '域名解析失败',
      DeclarativeTransportFailure.tls => 'TLS/证书问题',
      DeclarativeTransportFailure.cancelled => '已取消',
      DeclarativeTransportFailure.notTransport => '非传输异常',
    };

/// 把底层异常**读出结构**（D-F3-4：不得只改静态文案而不读类型）。
///
/// 覆盖 `DioException.type` 各分支，并向下看一层嵌套错误来分辨 DNS 与 TLS ——
/// Dio 把这两者都归进 `connectionError`，只看 `type` 是分不出来的。
DeclarativeTransportFailure classifyTransportFailure(Object error) {
  if (error is DioException) {
    switch (error.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
        return DeclarativeTransportFailure.timeout;
      case DioExceptionType.cancel:
        return DeclarativeTransportFailure.cancelled;
      case DioExceptionType.badCertificate:
        return DeclarativeTransportFailure.tls;
      case DioExceptionType.connectionError:
      case DioExceptionType.badResponse:
      case DioExceptionType.unknown:
        return _classifyNestedTransportError(error.error);
    }
  }
  if (error is TimeoutException) return DeclarativeTransportFailure.timeout;
  return _classifyNestedTransportError(error);
}

DeclarativeTransportFailure _classifyNestedTransportError(Object? error) {
  if (error is TimeoutException) return DeclarativeTransportFailure.timeout;
  if (error is HandshakeException ||
      error is TlsException ||
      error is CertificateException) {
    return DeclarativeTransportFailure.tls;
  }
  if (error is SocketException) {
    return _looksLikeDnsFailure(error.message)
        ? DeclarativeTransportFailure.dns
        : DeclarativeTransportFailure.connection;
  }
  return DeclarativeTransportFailure.notTransport;
}

/// `SocketException` 的文案是唯一能分辨"域名打错"与"连不上"的线索（Dio 不细分这两者）。
bool _looksLikeDnsFailure(String message) {
  final lower = message.toLowerCase();
  return lower.contains('host lookup') ||
      lower.contains('nodename') ||
      lower.contains('name or service not known') ||
      lower.contains('getaddrinfo') ||
      lower.contains('no address associated');
}
/// 一次声明式请求走到了**哪一步**。
///
/// D-F3-4 的要求："未发起请求、主动取消、请求超时和请求失败必须有可区分的状态或详情"。
/// 本枚举负责第一刀：**请求到底发出去了没有**（超时/失败的区别在传输异常的详情里）。
enum DeclarativeExecutionStage {
  /// **没有发出请求**：配置/凭据问题（请求构造失败、敏感头凭据读取失败）。
  notSent,

  /// 请求已发出：成败都在这一支（`failureKind == null` 表示通过成功判定）。
  sent,
}

/// 一次声明式请求的执行结果（探测与试跑共用）。
final class DeclarativeExecutionResult {
  const DeclarativeExecutionResult._({
    required this.stage,
    this.statusCode,
    this.body,
    this.requestSummary,
    this.responsePreview,
    this.failureKind,
    this.failureReason,
    this.transportFailure,
  });

  final DeclarativeExecutionStage stage;

  /// 响应状态码；[DeclarativeExecutionStage.notSent] 或传输异常时为 null。
  final int? statusCode;

  /// 原始响应体（**未脱敏**，仅供调用方做映射；界面只能用 [responsePreview]）。
  final Object? body;

  /// **已脱敏**的请求摘要；请求构造成功后就一定有（失败时它是唯一的排查依据）。
  final String? requestSummary;

  /// **已脱敏**的响应片段。
  final String? responsePreview;

  /// 唯一判定表给出的失败分类；null 表示通过了成功判定。
  final OnlineMusicErrorKind? failureKind;

  final String? failureReason;

  /// 传输失败的**结构化详情**（F3-S2）；只有传输阶段失败时非 null。
  final DeclarativeTransportFailure? transportFailure;

  /// 是否通过成功判定。**注意**：这只说明"响应符合声明的成功条件"，
  /// 不代表"这个能力可用" —— 后者还要看字段映射结果（试跑）或候选证据（探测）。
  bool get isSuccess => failureKind == null;

  @override
  String toString() =>
      'DeclarativeExecutionResult(stage=${stage.name}, status=$statusCode, '
      'kind=${failureKind?.name})';
}

/// 成功判定不通过时的**唯一**分类。
///
/// - 状态码分类统一由 `classifyHttpStatus` 决定（声明式 origin ⇒ 404 与不可读响应归
///   「接口定义不匹配」）；
/// - 2xx（或其它非错误状态）却判定不过：响应结构可读（Map/List）⇒ 业务判定问题；
///   连结构都不是（HTML 错误页、纯文本）⇒ 接口定义/响应格式不匹配。
OnlineMusicErrorKind classifyDeclarativeUnsuccessfulResponse(
  int statusCode,
  Object? body,
) {
  final readableJson = body is Map || body is List;
  if (statusCode < 400) {
    return readableJson
        ? OnlineMusicErrorKind.businessFailure
        : OnlineMusicErrorKind.endpointMismatch;
  }
  return classifyHttpStatus(
    statusCode,
    origin: OnlineMusicErrorOrigin.declarative,
    readableJson: readableJson,
  );
}

/// 执行一次声明式请求：构造 → 发送 → 成功判定 → 分类 → 诊断。
///
/// [headerCredentialReader] 用来读**敏感请求头**引用的凭据；读取失败一律当作
/// **配置问题**（`notSent`）而**不是**"试试网络"——那会把存储问题误报成网络问题。
Future<DeclarativeExecutionResult> executeDeclarativeRequest({
  required OnlineMusicRequestSpec spec,
  required OnlineMusicSuccessSpec success,
  required DeclarativeInputs inputs,
  required DeclarativeHttpTransport transport,
  required OnlineMusicCredentialReader headerCredentialReader,
  String? credential,
  OnlineMusicCancelToken? cancelToken,
}) async {
  final token = cancelToken ?? OnlineMusicCancelToken();

  final Map<String, String> headerCredentials;
  try {
    headerCredentials = await readHeaderCredentialValues(
      spec: spec,
      reader: headerCredentialReader,
    );
  } catch (_) {
    return const DeclarativeExecutionResult._(
      stage: DeclarativeExecutionStage.notSent,
      failureReason: '无法读取该请求头引用的安全凭据（凭据存储读取失败）',
    );
  }

  final BuiltDeclarativeRequest request;
  try {
    request = buildDeclarativeRequest(
      spec: spec,
      inputs: inputs,
      credential: credential,
      headerCredentials: headerCredentials,
    );
  } on DeclarativeRequestException catch (error) {
    // 请求都没构造出来：这是**配置**问题，不是服务问题。
    return DeclarativeExecutionResult._(
      stage: DeclarativeExecutionStage.notSent,
      failureReason: error.safeMessage,
    );
  }

  // 请求摘要在**发出去之前**就记下来：失败时它是唯一的排查依据。
  final summary = describeDeclarativeRequest(request);

  final DeclarativeHttpResponse response;
  try {
    response = await transport.send(request, cancelToken: token);
  } catch (error) {
    // F3-S2（P-50 / D-F3-4）：**读出**底层异常类型，把超时 / 无法连接 / DNS / TLS /
    // 取消分开写进诊断。判据与顶层类别都不变（仍然都在"传输失败"大类下），
    // 但"超时"与"域名打错"不再显示成同一句"网络不可达"。
    final failure = classifyTransportFailure(error);
    if (failure == DeclarativeTransportFailure.notTransport) {
      // 编程错误/非传输异常**不得**吞成"网络不可达"（D-F3-4 明令）。
      return DeclarativeExecutionResult._(
        stage: DeclarativeExecutionStage.sent,
        requestSummary: summary,
        transportFailure: failure,
        failureKind: OnlineMusicErrorKind.unknown,
        failureReason: '请求失败（非传输异常：${error.runtimeType}）',
      );
    }
    if (failure == DeclarativeTransportFailure.cancelled) {
      return DeclarativeExecutionResult._(
        stage: DeclarativeExecutionStage.sent,
        requestSummary: summary,
        transportFailure: failure,
        failureKind: OnlineMusicErrorKind.cancelled,
        failureReason: '请求失败（已取消）',
      );
    }
    return DeclarativeExecutionResult._(
      stage: DeclarativeExecutionStage.sent,
      requestSummary: summary,
      transportFailure: failure,
      failureKind: OnlineMusicErrorKind.network,
      failureReason: '请求失败（${declarativeTransportFailureLabel(failure)}）',
    );
  }

  final preview = redactResponsePreview(response.data);
  final passed = declarativeResponseIsSuccess(
    spec: success,
    statusCode: response.statusCode,
    body: response.data,
  );
  if (passed) {
    return DeclarativeExecutionResult._(
      stage: DeclarativeExecutionStage.sent,
      statusCode: response.statusCode,
      body: response.data,
      requestSummary: summary,
      responsePreview: preview,
    );
  }

  return DeclarativeExecutionResult._(
    stage: DeclarativeExecutionStage.sent,
    statusCode: response.statusCode,
    body: response.data,
    requestSummary: summary,
    responsePreview: preview,
    failureKind: classifyDeclarativeUnsuccessfulResponse(
      response.statusCode,
      response.data,
    ),
    failureReason: '成功判定未通过（HTTP ${response.statusCode}）',
  );
}
