/// V090-03 事故回放 fixture：2026-09-06 会话在 seq 48 停滞的脱敏时间线。
///
/// 事故事实（迭代计划 v0.9.0 §1.1，敏感字段全部替换为合成值）：
/// - 23:05:39 用户发送提问，回合开始（fixture 以 seq 1 的 user_message 表达）。
/// - 23:06:44 App 收到最后一条事件 seq 48，随后本地约 2 分钟轮询窗口耗尽，
///   客户端显示超时并**停止拉取**（v0.8.6 A① 的耗尽分支缺陷）。
/// - 23:07:36 起执行端从 seq 49 恢复上行事件（fixture 以 seq 49..62 表达），
///   App 未再接收。
/// - 23:13:35 Relay 收到 seq 460 `turn.completed`，会话转 idle（fixture 保留
///   seq 460 的缺口，与真实 receipt 序号一致；中间事件与正文一概不入 fixture）。
///
/// 脱敏红线：不包含真实会话 id、正文、token、密文或本机路径；文本全部为
/// 合成占位文案。fixture 只服务 V090 回放测试，不进入生产代码。
library;

import 'package:agent_sessions_mobile/domain/session_models.dart';

/// 会话 id 使用合成前缀，杜绝与真实 Relay 数据混淆。
const String v090IncidentSessionId = 'sess-v090fixture-seq48';

/// seq 460 终态事件：与事故证据 receipt 序号一致（时间线压缩表示）。
const int v090IncidentTerminalSeq = 460;

/// App 停滞前看到的最后一个事件序号。
const int v090IncidentStallSeq = 48;

/// 执行端恢复上行但 App 未接收的窗口（真实事故为 seq 49-62）。
const int v090IncidentRecoveryStartSeq = 49;
const int v090IncidentRecoveryEndSeq = 62;

/// 构造一条合成 Relay 事件。envelope 走 fixture_payload 通道，
/// 与 FixtureRelayRepository 的既有事件形状保持同一口径。
RelaySessionEvent _event(
  int seq,
  Map<String, dynamic> payload,
) => RelaySessionEvent(
  sequence: seq,
  eventType: payload['kind'] as String? ?? 'session.event',
  envelope: {'fixture_payload': payload},
);

/// 用户提问（合成文案，语义对齐事故中的"长问题"）。
RelaySessionEvent get _userQuestion => _event(1, {
  'kind': 'user_message',
  'text': 'V090-FIXTURE-QUESTION（合成占位：用于事故回放的用户提问）',
  'label': '用户',
});

/// seq 2..48：App 停滞前已收到的流式增量帧（合成文本）。
List<RelaySessionEvent> get _stallWindowEvents => [
  for (var seq = 2; seq <= v090IncidentStallSeq; seq++)
    _event(seq, {
      'kind': 'assistant_message',
      'message_id': 'msg-v090fixture-answer',
      'streaming': true,
      'text': 'V090-FIXTURE-DELTA-$seq（合成占位：停滞窗口内的流式增量）',
      'label': '助手',
    }),
];

/// seq 49..62：执行端恢复上行、App 未接收的流式增量帧（合成文本）。
List<RelaySessionEvent> get _recoveryWindowEvents => [
  for (var seq = v090IncidentRecoveryStartSeq;
      seq <= v090IncidentRecoveryEndSeq;
      seq++)
    _event(seq, {
      'kind': 'assistant_message',
      'message_id': 'msg-v090fixture-answer',
      'streaming': true,
      'text': 'V090-FIXTURE-RECOVERY-$seq（合成占位：恢复窗口内被错过的增量）',
      'label': '助手',
    }),
];

/// seq 460：迟到的 canonical 终态。完整答案文本在此事件一次性落定，
/// 会话转 idle——真实事故中 App 直到人工刷新才看到该事实。
RelaySessionEvent get _terminalEvent => _event(v090IncidentTerminalSeq, {
  'kind': 'assistant_message',
  'message_id': 'msg-v090fixture-answer',
  'streaming': false,
  'completed_turn': true,
  'fork_available': true,
  'text': 'V090-FIXTURE-FULL-ANSWER（合成占位：迟到 6 分钟才到达的完整答案）',
  'label': '助手',
});

/// 事故时间线的三个阶段快照。
/// [SessionSnapshot.session.lastSequence] 与状态始终按服务端事实给出，
/// 允许回放测试断言"本地已停更、服务端仍在前进"的错位。
class V090IncidentFixture {
  const V090IncidentFixture();

  String get sessionId => v090IncidentSessionId;

  MobileSession _session({
    required MobileSessionStatus status,
    required int lastSeq,
  }) => MobileSession(
    id: sessionId,
    workspaceId: 'ws-v090fixture',
    status: status,
    provider: 'dsh',
    lastSequence: lastSeq,
    model: 'v090-fixture-model',
    displayName: 'V090 事故回放（合成）',
  );

  /// 阶段一：App 停滞窗口。服务端事实 last_seq=48、仍 streaming；
  /// 客户端 cursor 同为 48，随后本地轮询耗尽（缺陷分支）。
  SessionSnapshot get stallSnapshot => SessionSnapshot(
    session: _session(status: MobileSessionStatus.streaming, lastSeq: 48),
    events: [_userQuestion, ..._stallWindowEvents],
  );

  /// 阶段二：执行端恢复上行（seq 49..62 已落库，status 仍 streaming）。
  /// [afterSeq] 只支持 0/48 两种口径，超范围按整段返回，保持 fixture 无状态。
  SessionSnapshot recoverySnapshot({int afterSeq = 0}) => SessionSnapshot(
    session: _session(
      status: MobileSessionStatus.streaming,
      lastSeq: v090IncidentRecoveryEndSeq,
    ),
    events: [
      if (afterSeq < 1) _userQuestion,
      ..._stallWindowEvents.where((event) => event.sequence > afterSeq),
      ..._recoveryWindowEvents,
    ],
  );

  /// 阶段三：seq 460 终态到达，会话转 idle。缺口语号与事故一致：
  /// 合并逻辑按 sequence 去重排序，63..459 的缺口不参与断言。
  SessionSnapshot get finalSnapshot => SessionSnapshot(
    session: _session(status: MobileSessionStatus.idle, lastSeq: v090IncidentTerminalSeq),
    events: [
      _userQuestion,
      ..._stallWindowEvents,
      ..._recoveryWindowEvents,
      _terminalEvent,
    ],
  );
}
