import 'package:agent_sessions_mobile/domain/control_models.dart';
import 'package:agent_sessions_mobile/domain/session_models.dart';
import 'package:agent_sessions_mobile/state/session_projection_controller.dart';
import 'package:flutter_test/flutter_test.dart';

/// v0.9.5 P1（预览/回放合一）先红回归。
///
/// 导入预览（assistant 携 `imported-<seq>` messageId；user 由导入侧补
/// `imported-u-<seq>`）与 resume 回放的 canonical 事件描述**同一段** DSH 历史，
/// 语义上必须渲染为同一条气泡：canonical 节点到达时折叠更早的 imported 预览节点。
/// 此前客户端按 messageId 去重，两侧 id 不同 → 回放后出现双气泡。
void main() {
  const projection = SessionProjectionController();

  test('canonical 回放节点到达时折叠同文 imported 预览节点', () {
    final snapshot = projection.buildSnapshot(
      timeline: const [
        // 导入预览块（导入时刻写入，event_seq 靠前）。
        SessionTimelineEvent(
          sequence: 1,
          kind: SessionTimelineKind.userMessage,
          label: '你',
          text: '旧问题',
          messageId: 'imported-u-1',
        ),
        SessionTimelineEvent(
          sequence: 2,
          kind: SessionTimelineKind.assistantMessage,
          label: 'Assistant',
          text: '旧回答',
          messageId: 'imported-2',
        ),
        // resume 回放块（桥原生 id，event_seq 靠后）。
        SessionTimelineEvent(
          sequence: 3,
          kind: SessionTimelineKind.userMessage,
          label: '你',
          text: '旧问题',
        ),
        SessionTimelineEvent(
          sequence: 4,
          kind: SessionTimelineKind.assistantMessage,
          label: 'Assistant',
          text: '旧回答',
          messageId: 'real-bridge-1',
        ),
      ],
      controls: const SessionControlState.empty(),
    );

    expect(snapshot.chatNodes, hasLength(2),
        reason: '导入预览与回放必须合一，不得出现双气泡');
    // 保留的是 canonical（回放）节点：user 无 messageId、assistant 为桥原生 id。
    expect(snapshot.chatNodes[0].sequence, 3);
    expect(snapshot.chatNodes[1].messageId, 'real-bridge-1');
  });

  test('只有 imported 预览（未回放）时原样保留', () {
    final snapshot = projection.buildSnapshot(
      timeline: const [
        SessionTimelineEvent(
          sequence: 1,
          kind: SessionTimelineKind.userMessage,
          label: '你',
          text: '旧问题',
          messageId: 'imported-u-1',
        ),
        SessionTimelineEvent(
          sequence: 2,
          kind: SessionTimelineKind.assistantMessage,
          label: 'Assistant',
          text: '旧回答',
          messageId: 'imported-2',
        ),
      ],
      controls: const SessionControlState.empty(),
    );

    expect(snapshot.chatNodes, hasLength(2), reason: '尚未回放时预览是唯一可见历史');
  });

  test('同文 canonical 但无 imported 前缀的历史节点不互相折叠', () {
    // 两次真实发送同文（如「ping」）是合法历史，预览折叠只针对 imported-*。
    final snapshot = projection.buildSnapshot(
      timeline: const [
        SessionTimelineEvent(
          sequence: 1,
          kind: SessionTimelineKind.userMessage,
          label: '你',
          text: 'ping',
        ),
        SessionTimelineEvent(
          sequence: 2,
          kind: SessionTimelineKind.userMessage,
          label: '你',
          text: 'ping',
        ),
      ],
      controls: const SessionControlState.empty(),
    );

    expect(snapshot.chatNodes, hasLength(2), reason: '无 imported 前缀的同文历史不得折叠');
  });
}
