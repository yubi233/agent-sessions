import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';

/// v0.9.0 C5/C6：会话级 SSE 传输原语——帧解析、typed 失败与专用 streaming client。
/// 事件帧仅作失效通知（id=session event_seq、event=invalidated、data={}），
/// 本层永不解析 canonical envelope；快照仍是内容与状态的唯一事实源。

/// SSE 的一帧（失效通知）。[id] 为 session-local event_seq（wake watermark）。
class SessionSseFrame {
  const SessionSseFrame({required this.id, required this.event, required this.data});

  final int id;
  final String event;
  final String data;
}

/// 建流失败 / 流内致命失败的 typed 分类（C6）。
/// 客户端绝不能只按 HTTP 403 做全局退出判断，必须按稳定 code 分支。
enum SessionSseFailureKind {
  /// 网络错误 / EOF / watchdog / 握手超时：临时错误，指数退避重连，轮询托底。
  network,

  /// 401/UNAUTHENTICATED：复用既有 single-flight refresh，一条失败链最多一次。
  unauthorized,

  /// 403 + DEVICE_REVOKED：本机设备被撤销，终止认证态。
  deviceRevoked,

  /// 403 + SCOPE_DENIED：只终止该资源，不得注销仍有效的账号。
  scopeDenied,

  /// 404：不能直接等同旧 Relay 不支持——必须做同会话 snapshot 探测后分类。
  notFound,

  /// 405 / 501/CAPABILITY_UNSUPPORTED / 显式 poll_only：直接固定回落轮询。
  capabilityUnsupported,

  /// 重复协议错误（非法 frame 等）：固定回落并留下脱敏诊断。
  protocol,
}

/// 建流失败的稳定错误码载荷（403 时携带服务端 code）。
class SessionSseHandshakeFailure implements Exception {
  const SessionSseHandshakeFailure(this.kind, {this.serverCode, this.status});

  final SessionSseFailureKind kind;

  /// 服务端稳定错误码（如 DEVICE_REVOKED/SCOPE_DENIED/CAPABILITY_UNSUPPORTED）。
  final String? serverCode;

  final int? status;

  @override
  String toString() =>
      'SessionSseHandshakeFailure(${kind.name}, status=$status, code=$serverCode)';
}

/// 会话级 snapshot 探测结论（C6 404 判定）：
/// reachable=旧 Relay 无该路由（pollFallback）；missing/forbidden=资源级失效；
/// unknown=探测遇到网络/429/5xx，结论未知保持退避。
enum SessionSnapshotProbeResult { reachable, missing, forbidden, unknown }

/// SSE 增量解析器：字节块 → 行 → 帧。注释行（`: xxx`）只喂 watchdog，
/// 不产生帧；空行触发帧投递。非法 id 的帧按协议错误上抛（C6：全量快照重试一次）。
class SessionSseParser {
  final StringBuffer _lineBuffer = StringBuffer();
  String? _id;
  String? _event;
  String? _data;

  /// 最近一次 addBytes 是否出现过任何字节（watchdog 由传输层按字节块重置，
  /// 这里只保留接口语义）。
  bool sawBytes = false;

  /// 是否已看到首个“正式生命迹象”（除初始 connected 注释外的任何行）。
  /// C6：连接 flush 注释不清零退避，首个正式 heartbeat/事件才算 live。
  bool sawSignOfLife = false;
  bool _sawConnectedComment = false;

  /// 解析一个字节块，返回其中累积完成的帧。非法 id 抛 [SessionSseProtocolError]。
  List<SessionSseFrame> addBytes(Uint8List bytes) {
    sawBytes = true;
    final frames = <SessionSseFrame>[];
    final text = utf8.decode(bytes, allowMalformed: true);
    for (var i = 0; i < text.length; i++) {
      if (text.codeUnitAt(i) == 0x0A) {
        final line = _lineBuffer.toString();
        _lineBuffer.clear();
        final frame = _consumeLine(line);
        if (frame != null) frames.add(frame);
      } else {
        _lineBuffer.writeCharCode(text.codeUnitAt(i));
      }
    }
    return frames;
  }

  SessionSseFrame? _consumeLine(String raw) {
    final line = raw.endsWith('\r') ? raw.substring(0, raw.length - 1) : raw;
    if (line.isEmpty) {
      final id = _id;
      if (id == null) {
        _event = null;
        _data = null;
        return null;
      }
      final seq = int.tryParse(id);
      if (seq == null || seq < 0) {
        _id = null;
        _event = null;
        _data = null;
        throw SessionSseProtocolError('invalid sse id: $id');
      }
      final frame = SessionSseFrame(
        id: seq,
        event: _event ?? 'message',
        data: _data ?? '',
      );
      _id = null;
      _event = null;
      _data = null;
      return frame;
    }
    if (line.startsWith(':')) {
      // 注释：初始 connected 注释不清零退避；其余注释（如 heartbeat）视为生命迹象。
      if (!_sawConnectedComment && line.startsWith(': connected')) {
        _sawConnectedComment = true;
      } else {
        sawSignOfLife = true;
      }
      return null;
    }
    sawSignOfLife = true;
    final colon = line.indexOf(':');
    final field = colon < 0 ? line : line.substring(0, colon);
    var value = colon < 0 ? '' : line.substring(colon + 1);
    if (value.startsWith(' ')) value = value.substring(1);
    switch (field) {
      case 'id':
        _id = value;
      case 'event':
        _event = value;
      case 'data':
        _data = _data == null ? value : '$_data\n$value';
    }
    return null;
  }
}

/// 协议错误（非法 frame）；C6：先强制 after_seq=0 全量快照并重试一次，
/// 重复失败按协议错误固定回落轮询并留下脱敏诊断。
class SessionSseProtocolError implements Exception {
  const SessionSseProtocolError(this.sanitizedMessage);
  final String sanitizedMessage;
  @override
  String toString() => 'SessionSseProtocolError($sanitizedMessage)';
}

/// 会话事件流 source 抽象：真实实现走 Dio streaming；测试注入脚本化假 source。
abstract interface class SessionEventStreamSource {
  /// 建流；失败以 [SessionSseHandshakeFailure] typed 抛出。
  Future<Stream<Uint8List>> open({
    required String sessionId,
    required int? lastEventId,
  });
}

/// 专用 streaming client（C6）：以 Dio ResponseType.stream 建流。
/// - TCP 建连与收到 SSE headers/首次 flush 的 handshake 各自最多 10 秒
///   （connectTimeout 由注入的 Dio 配置；headers+首字节由本层 timeout 兜底）；
/// - 建流后禁用普通 REST 的 12 秒 receive timeout（ResponseBody 流本身无超时），
///   40 秒无字节 watchdog 在 transport 层接管。
class DioSessionEventStreamSource implements SessionEventStreamSource {
  DioSessionEventStreamSource({
    required this.dio,
    this.handshakeTimeout = const Duration(seconds: 10),
    this.tokenProvider,
  });

  final Dio dio;
  final Duration handshakeTimeout;

  /// 每次建流时读取最新 access token（401 refresh 后重连要用新 token）。
  final Future<String?> Function()? tokenProvider;

  @override
  Future<Stream<Uint8List>> open({
    required String sessionId,
    required int? lastEventId,
  }) async {
    final token = await tokenProvider?.call();
    final Response<ResponseBody> response;
    try {
      response = await dio
          .request<ResponseBody>(
            '/v1/sessions/$sessionId/events',
            queryParameters: lastEventId == null
                ? null
                : {'after_seq': lastEventId},
            options: Options(
              method: 'GET',
              responseType: ResponseType.stream,
              headers: {
                if (token != null) 'Authorization': 'Bearer $token',
                'Accept': 'text/event-stream',
                // 建流后由 watchdog 接管；禁用 REST 的 receive timeout 语义。
                'receive-timeout-disabled': '1',
              },
              receiveTimeout: null,
              // 401/403/404 的 typed 分类在本层按状态码完成，不抛 DioException。
              validateStatus: (status) => status != null && status < 500,
            ),
          )
          .timeout(handshakeTimeout);
    } on DioException catch (error) {
      throw SessionSseHandshakeFailure(
        SessionSseFailureKind.network,
        status: error.response?.statusCode,
      );
    } on TimeoutException {
      throw const SessionSseHandshakeFailure(SessionSseFailureKind.network);
    }

    final status = response.statusCode ?? 0;
    if (status != 200) {
      // 读取脱敏错误码后关闭流（不解析正文，只取稳定 code）。
      String? serverCode;
      try {
        final body = await response.data!.stream
            .cast<List<int>>()
            .transform(const Utf8Decoder())
            .first;
        serverCode = _extractErrorCode(body);
      } catch (_) {
        serverCode = null;
      }
      throw _classify(status, serverCode);
    }
    return response.data!.stream.cast<Uint8List>();
  }

  SessionSseHandshakeFailure _classify(int status, String? serverCode) {
    switch (status) {
      case 401:
        return SessionSseHandshakeFailure(
          SessionSseFailureKind.unauthorized,
          status: status,
          serverCode: serverCode,
        );
      case 403:
        if (serverCode == 'DEVICE_REVOKED') {
          return SessionSseHandshakeFailure(
            SessionSseFailureKind.deviceRevoked,
            status: status,
            serverCode: serverCode,
          );
        }
        if (serverCode == 'SCOPE_DENIED') {
          return SessionSseHandshakeFailure(
            SessionSseFailureKind.scopeDenied,
            status: status,
            serverCode: serverCode,
          );
        }
        // 未知 403 code 一律按资源级处理，绝不全局注销。
        return SessionSseHandshakeFailure(
          SessionSseFailureKind.scopeDenied,
          status: status,
          serverCode: serverCode,
        );
      case 404:
        return SessionSseHandshakeFailure(
          SessionSseFailureKind.notFound,
          status: status,
          serverCode: serverCode,
        );
      case 405:
      case 501:
        return SessionSseHandshakeFailure(
          SessionSseFailureKind.capabilityUnsupported,
          status: status,
          serverCode: serverCode,
        );
      case 429:
      case 500:
      case 502:
      case 503:
      case 504:
        return SessionSseHandshakeFailure(
          SessionSseFailureKind.network,
          status: status,
        );
      default:
        return SessionSseHandshakeFailure(
          SessionSseFailureKind.protocol,
          status: status,
          serverCode: serverCode,
        );
    }
  }

  /// 从错误体提取稳定 code（脱敏：只返回 code，不保留 message/正文）。
  String? _extractErrorCode(String body) {
    final match = RegExp(r'"code"\s*:\s*"([A-Z_]+)"').firstMatch(body);
    return match?.group(1);
  }
}
