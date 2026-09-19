import 'package:agent_sessions_mobile/domain/session_models.dart';
import 'package:agent_sessions_mobile/relay/fixture_relay_repository.dart';
import 'package:agent_sessions_mobile/state/session_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'support/fixture_owner.dart';

/// V094 收口（真机观察项修复回归）：思考流的跨节点折叠。
///
/// 真实链路（localdev 明文编码器/真实桥）的 thought_delta 不携带 message_id，
/// 且思考流中间穿插 assistant completed 消息——旧的相邻折叠判不到，
/// 时间线出现两个「思考中」节点。修复后同回合内（中间无 user message /
/// turn 终态）最后一条 streaming thought 被后续 thought_delta 整体替换。
void main() {
  test('同回合内 thought → assistant completed → thought 折叠为单节点', () async {
    final relay = FixtureRelayRepository();
    final owner = await bootstrapFixtureOwner(relay);
    final controller = SessionController(relay: relay);
    await controller.initialize();
    await controller.createSession(
      workspaceId: 'fixture-workspace',
      provider: 'codex',
      deviceId: owner.deviceId,
      canWrite: true,
      autoStart: false,
    );
    final sessionId = (await relay.listSessions()).single.id;

    // 直接以 canonical 事件序列构造真实桥形态（无 message_id）：
    // thought(streaming) → assistant completed → thought(streaming 演进)。
    final state = relay.debugSessionState(sessionId);
    final now = DateTime.utc(2026, 9, 19, 12);
    state.append(
      eventType: 'message.thought_delta',
      payload: const {
        'kind': 'assistant_thought',
        'label': '思考中',
        'text': '第一段思考。',
        'streaming': true,
      },
      now: now,
    );
    state.append(
      eventType: 'message.completed',
      payload: const {
        'kind': 'assistant_message',
        'label': 'Assistant',
        'text': '中间的助手消息。',
        'streaming': false,
      },
      now: now,
    );
    state.append(
      eventType: 'message.thought_delta',
      payload: const {
        'kind': 'assistant_thought',
        'label': '思考中',
        'text': '第一段思考。第二段思考。',
        'streaming': true,
      },
      now: now,
    );

    final snapshot = await relay.getSessionSnapshot(sessionId);
    controller.debugMergeSnapshotForTest(sessionId, snapshot);

    final thoughts = controller.timeline
        .where((event) => event.kind == SessionTimelineKind.assistantThought)
        .toList(growable: false);
    expect(
      thoughts,
      hasLength(1),
      reason: '同回合内的思考流必须折叠为单节点（真机出现两个「思考中」的回归）',
    );
    expect(thoughts.single.text, '第一段思考。第二段思考。');
    expect(thoughts.single.isStreaming, isTrue);
    // 中间插入的 assistant completed 消息保持完整（不丢内容）。
    expect(
      controller.timeline.any((event) => event.text == '中间的助手消息。'),
      isTrue,
    );
  });

  test('回合边界后的新思考流另起新节点（不跨回合合并）', () async {
    final relay = FixtureRelayRepository();
    final owner = await bootstrapFixtureOwner(relay);
    final controller = SessionController(relay: relay);
    await controller.initialize();
    await controller.createSession(
      workspaceId: 'fixture-workspace',
      provider: 'codex',
      deviceId: owner.deviceId,
      canWrite: true,
      autoStart: false,
    );
    final sessionId = (await relay.listSessions()).single.id;
    final state = relay.debugSessionState(sessionId);
    final now = DateTime.utc(2026, 9, 19, 12);
    state.append(
      eventType: 'message.thought_delta',
      payload: const {
        'kind': 'assistant_thought',
        'label': '思考中',
        'text': '上一回合思考。',
        'streaming': true,
      },
      now: now,
    );
    // 新一轮用户输入 = 回合边界。
    state.append(
      eventType: 'message.user',
      payload: const {
        'kind': 'user_message',
        'label': '你',
        'text': '再问一句',
      },
      now: now,
    );
    state.append(
      eventType: 'message.thought_delta',
      payload: const {
        'kind': 'assistant_thought',
        'label': '思考中',
        'text': '新回合思考。',
        'streaming': true,
      },
      now: now,
    );

    final snapshot = await relay.getSessionSnapshot(sessionId);
    controller.debugMergeSnapshotForTest(sessionId, snapshot);

    final thoughts = controller.timeline
        .where((event) => event.kind == SessionTimelineKind.assistantThought)
        .toList(growable: false);
    expect(
      thoughts,
      hasLength(2),
      reason: '跨越 user message 边界的思考流是新一轮思考，不得合并',
    );
  });
}
