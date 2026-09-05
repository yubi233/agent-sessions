/// 流式埋点（v0.8.7 门禁 2 的唯一证据源）。
///
/// 打字机式流式传输的可证明性：本 sink 记录「delta 何时到达、每次增长多少、
/// 首字延迟、终态对账是否一致」，导出为 schema v1 JSON 供 V087-09 门禁判定。
/// 临时 print / 调试脚本不作为门禁证据（计划 §6.2）。
///
/// 审计红线（V087-03 以注入正文子串零命中锁定）：任何字段只允许元数据——
/// 序号、通道、消息身份、字符长度与时间差；禁止记录消息正文、工具输入输出
/// 原文、内部路径或错误码原文。
library;

/// 导出 schema 版本；字段演进必须升版本，消费方按版本判读。
const int kStreamingTelemetrySchemaVersion = 1;

/// ring buffer 默认容量：覆盖约 2 分钟在途窗口（240 次轮询 + delta + 对账）。
const int kStreamingTelemetryDefaultCapacity = 2000;

/// 单条流式埋点事件。[fields] 一律为可 JSON 序列化的元数据标量。
class StreamingTelemetryEvent {
  StreamingTelemetryEvent({
    required this.type,
    required this.ts,
    required Map<String, Object?> fields,
  }) : fields = Map<String, Object?>.unmodifiable(fields);

  /// 事件类型（schema v1 冻结清单）：stream_first_delta / stream_delta /
  /// stream_completed_reconcile / stream_poll。
  final String type;

  /// 观测时刻（来自控制器注入时钟，测试可步进保证单调）。
  final DateTime ts;

  /// 类型相关元数据字段。
  final Map<String, Object?> fields;

  Map<String, Object?> toJson() => <String, Object?>{
    'type': type,
    'ts': ts.toIso8601String(),
    ...fields,
  };
}

/// 同一消息身份（kind + messageId）的帧累积状态，用于计算增量与终态对账。
class _FrameState {
  int cumulativeChars;
  int lastStreamChars;
  DateTime lastTs;

  _FrameState({
    required this.cumulativeChars,
    required this.lastStreamChars,
    required this.lastTs,
  });
}

/// 流式埋点 sink：内存 ring buffer + schema v1 导出。
///
/// 生命周期：`observeSendAccepted` 即新回合基线（清上一回合帧状态、记受理
/// 时刻）；此后每条 assistant/thought 时间线帧经 `observeStreamingFrame` 喂入；
/// 快照轮询批次经 `observePoll` 采样。帧去重以会话级 seq 高水位为准——快照
/// 全量重解析或网络重复投递不会产生重复埋点。
class StreamingTelemetry {
  StreamingTelemetry({
    this.capacity = kStreamingTelemetryDefaultCapacity,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  /// 容量上限；超出时丢弃最旧事件（保形不保量，门禁判定只看在途回合窗口）。
  final int capacity;
  final DateTime Function() _now;

  final List<StreamingTelemetryEvent> _events = <StreamingTelemetryEvent>[];
  DateTime? _sendAcceptedAt;

  /// 身份 -> 帧状态；completed 对账或新回合基线时清理。
  final Map<String, _FrameState> _frames = <String, _FrameState>{};

  /// 会话 -> 已观测最大 seq（去重高水位）。
  final Map<String, int> _seqHighWater = <String, int>{};

  int get length => _events.length;
  bool get isEmpty => _events.isEmpty;
  List<StreamingTelemetryEvent> get events => List.unmodifiable(_events);

  /// send 受理：新回合基线。首字延迟从该时刻起算；上一回合未对账的帧状态
  /// 在此强制清零，避免跨回合把上一轮长度算进本轮增量。
  void observeSendAccepted() {
    _sendAcceptedAt = _now();
    _frames.clear();
  }

  /// 喂入一条 assistant/thought 时间线帧（localdev 契约：流式帧携带全量已收
  /// 文本；completed 帧携带权威全文且 streaming=false）。
  ///
  /// [kind] 只接受 'assistant' 与 'thought'（whitelist），其它通道（工具、
  /// 相位、权限等）与流式无关，直接忽略。
  void observeStreamingFrame({
    required String sessionId,
    required int seq,
    required String kind,
    required String? messageId,
    required String? text,
    required bool streaming,
  }) {
    if (kind != 'assistant' && kind != 'thought') return;
    final highWater = _seqHighWater[sessionId] ?? 0;
    if (seq <= highWater) return;
    _seqHighWater[sessionId] = seq;
    if (text == null) return;
    if (_sendAcceptedAt == null) {
      // 回合基线之外的帧（历史加载、非本端受理路径）不进埋点、不建帧状态；
      // 高水位照常推进，保证回合内的全量快照重解析不会把它们当新 delta。
      return;
    }

    final key = '$kind|${messageId ?? ''}';
    final now = _now();
    final identity = <String, Object?>{
      'seq': seq,
      'kind': kind,
      'message_id': messageId,
    };

    if (streaming) {
      final state = _frames[key];
      if (state == null) {
        // 首条流式帧：记录相对 send 受理的首字延迟（基线此时必然在位）。
        _frames[key] = _FrameState(
          cumulativeChars: text.length,
          lastStreamChars: text.length,
          lastTs: now,
        );
        _record('stream_first_delta', {
          ...identity,
          'latency_ms': now.difference(_sendAcceptedAt!).inMilliseconds,
        });
      } else {
        _record('stream_delta', {
          ...identity,
          'delta_chars': text.length - state.cumulativeChars,
          'cumulative_chars': text.length,
          'since_last_ms': now.difference(state.lastTs).inMilliseconds,
        });
        state
          ..cumulativeChars = text.length
          ..lastStreamChars = text.length
          ..lastTs = now;
      }
      return;
    }

    // 非流式全文帧：仅在观测过流式帧的身份上做终态对账（普通历史 completed
    // 不产生噪声）。对账后清理身份状态。
    final state = _frames[key];
    if (state != null) {
      _record('stream_completed_reconcile', {
        ...identity,
        'final_chars': text.length,
        'last_stream_chars': state.lastStreamChars,
        'consistent': text.length == state.lastStreamChars,
      });
      _frames.remove(key);
    }
  }

  /// 快照轮询批次采样：记录轮询节奏与新事件量（门禁 2 的到达节奏佐证）。
  void observePoll({
    required String sessionId,
    required int attempt,
    required int newEvents,
    required int fetchMs,
  }) {
    _record('stream_poll', {
      'session_id': sessionId,
      'attempt': attempt,
      'new_events': newEvents,
      'fetch_ms': fetchMs,
    });
  }

  /// 导出 schema v1 JSON 负载（V087-09 门禁判定与 evidence 留档格式）。
  Map<String, Object?> export() => <String, Object?>{
    'schema_version': kStreamingTelemetrySchemaVersion,
    'exported_at': _now().toIso8601String(),
    'events': <Object?>[for (final event in _events) event.toJson()],
  };

  /// 清空全部事件与状态（测试隔离 / 导出后归档用）。
  void clear() {
    _events.clear();
    _frames.clear();
    _seqHighWater.clear();
    _sendAcceptedAt = null;
  }

  void _record(String type, Map<String, Object?> fields) {
    _events.add(
      StreamingTelemetryEvent(type: type, ts: _now(), fields: fields),
    );
    if (_events.length > capacity) {
      _events.removeRange(0, _events.length - capacity);
    }
  }
}
