import 'package:agent_sessions_mobile/domain/session_models.dart';
import 'package:agent_sessions_mobile/domain/session_projection_models.dart';
import 'package:agent_sessions_mobile/domain/control_models.dart';
import 'package:agent_sessions_mobile/state/session_projection_controller.dart';
import 'package:flutter_test/flutter_test.dart';

/// v0.8.4（V084-09 投影层，ADR-015 §3/§5）：
/// thought 独立通道投影、turn_phase 状态提取与未知值 fail-closed。

RelaySessionEvent _eventOf(
  int sequence,
  Map<String, dynamic> fixture,
) => RelaySessionEvent(
  sequence: sequence,
  eventType: 'command.updated',
  envelope: {'fixture_payload': fixture},
);

SessionControlState _controls() => const SessionControlState(
  model: 'mock',
  effort: 'medium',
);

void main() {
  group('v0.8.4 thought 与 phase 解析', () {
    test('assistant_thought 解析为独立 thought 事件并携带 visibility', () {
      final event = SessionTimelineEvent.fromRelayEvent(_eventOf(1, {
        'kind': 'assistant_thought',
        'label': '思考中',
        'text': '推理片段',
        'streaming': true,
        'visibility': 'raw',
        'message_id': 't1s1',
      }));
      expect(event.kind, SessionTimelineKind.assistantThought);
      expect(event.text, '推理片段');
      expect(event.isStreaming, isTrue);
      expect(event.thoughtVisibility, 'raw');
      expect(event.messageId, 't1s1');
      // thought 永远不是 assistant 消息：两类事件在 kind 层面即分离。
      expect(event.kind, isNot(SessionTimelineKind.assistantMessage));
    });

    test('thought-summary 帧解析 summary 标记', () {
      final event = SessionTimelineEvent.fromRelayEvent(_eventOf(2, {
        'kind': 'assistant_thought',
        'text': '内部推理已折叠：2 段增量 / 9 字符',
        'visibility': 'summary',
        'summary': true,
      }));
      expect(event.kind, SessionTimelineKind.assistantThought);
      expect(event.thoughtSummary, isTrue);
      expect(event.thoughtVisibility, 'summary');
      expect(event.isStreaming, isFalse);
    });

    test('turn_phase 解析 phase/reason/revision，未知 phase 归 unknown', () {
      final event = SessionTimelineEvent.fromRelayEvent(_eventOf(3, {
        'kind': 'turn_phase',
        'phase': 'streaming',
        'reason': 'first_text_delta',
        'revision': 3,
        'turn_id': '1',
      }));
      expect(event.kind, SessionTimelineKind.turnPhase);
      expect(event.phase, TurnPhase.streaming);
      expect(event.phaseReason, 'first_text_delta');
      expect(event.phaseRevision, 3);
    });

    test('未知 phase wire 值 fail-closed 归 TurnPhase.unknown', () {
      final event = SessionTimelineEvent.fromRelayEvent(_eventOf(4, {
        'kind': 'turn_phase',
        'phase': 'hyperspace',
        'revision': 1,
      }));
      expect(event.phase, TurnPhase.unknown);
    });

    test('TurnPhase 全量 wire 值往返与终态判定', () {
      for (final phase in TurnPhase.values) {
        if (phase == TurnPhase.unknown) continue;
        expect(
          TurnPhase.fromWire(phase.wireValue),
          phase,
          reason: phase.wireValue,
        );
      }
      expect(TurnPhase.unknown.isTerminal, isFalse);
      expect(TurnPhase.completed.isTerminal, isTrue);
      expect(TurnPhase.failed.isTerminal, isTrue);
      expect(TurnPhase.cancelled.isTerminal, isTrue);
    });
  });

  group('v0.8.4 投影层', () {
    test('thought 投影为一等 reasoning 节点，文本不并入 assistant 节点', () {
      final snapshot = const SessionProjectionController().buildSnapshot(
        timeline: [
          SessionTimelineEvent.fromRelayEvent(_eventOf(1, {
            'kind': 'assistant_thought',
            'text': '推理中',
            'streaming': true,
            'visibility': 'raw',
          })),
          SessionTimelineEvent.fromRelayEvent(_eventOf(2, {
            'kind': 'assistant_message',
            'text': '正文回答',
            'streaming': false,
            'copy_text': '正文回答',
            'completed_turn': false,
          })),
        ],
        controls: _controls(),
      );
      final reasoning = snapshot.chatNodes
          .where((node) => node.kind == ConversationNodeKind.reasoning)
          .toList();
      final assistant = snapshot.chatNodes
          .where((node) => node.kind == ConversationNodeKind.assistant)
          .toList();
      expect(reasoning, hasLength(1));
      expect(reasoning.single.text, '推理中');
      expect(assistant.single.text, '正文回答');
      // 分离断言：thought 文本不出现在任何 assistant 节点里。
      expect(
        assistant.any((node) => (node.text ?? '').contains('推理中')),
        isFalse,
      );
    });

    test('turn_phase 不渲染气泡，快照按 revision 单调携带最新相位', () {
      final snapshot = const SessionProjectionController().buildSnapshot(
        timeline: [
          SessionTimelineEvent.fromRelayEvent(_eventOf(1, {
            'kind': 'turn_phase',
            'phase': 'thinking',
            'revision': 1,
          })),
          SessionTimelineEvent.fromRelayEvent(_eventOf(2, {
            'kind': 'assistant_message',
            'text': '部分回答',
            'streaming': true,
          })),
          // 迟到的旧 revision 帧：丢弃，不得回退相位。
          SessionTimelineEvent.fromRelayEvent(_eventOf(3, {
            'kind': 'turn_phase',
            'phase': 'queued',
            'revision': 0,
          })),
          SessionTimelineEvent.fromRelayEvent(_eventOf(4, {
            'kind': 'turn_phase',
            'phase': 'streaming',
            'revision': 2,
          })),
        ],
        controls: _controls(),
      );
      expect(
        snapshot.chatNodes
            .where((node) => node.kind == ConversationNodeKind.notice)
            .where((node) => (node.text ?? '').isEmpty),
        isEmpty,
      );
      expect(snapshot.turnPhase, TurnPhase.streaming);
      expect(
        snapshot.chatNodes.any((node) => node.text == 'streaming'),
        isFalse,
      );
    });

    test('无 phase 投影时快照 turnPhase 为 null（旧会话回退路径）', () {
      final snapshot = const SessionProjectionController().buildSnapshot(
        timeline: [
          SessionTimelineEvent.fromRelayEvent(_eventOf(1, {
            'kind': 'assistant_message',
            'text': '历史回答',
          })),
        ],
        controls: _controls(),
      );
      expect(snapshot.turnPhase, isNull);
    });

    test('高频 phase 帧折叠为单值：200 帧投影只保留最新相位', () {
      final timeline = <SessionTimelineEvent>[];
      for (var index = 0; index < 200; index++) {
        timeline.add(
          SessionTimelineEvent.fromRelayEvent(_eventOf(index + 1, {
            'kind': 'turn_phase',
            'phase': index.isEven ? 'thinking' : 'streaming',
            'revision': index + 1,
          })),
        );
      }
      final snapshot = const SessionProjectionController().buildSnapshot(
        timeline: timeline,
        controls: _controls(),
      );
      expect(snapshot.turnPhase, TurnPhase.streaming);
      // phase 事件不产生聊天节点：高频帧不会撑爆节点列表。
      expect(snapshot.chatNodes, isEmpty);
    });
  });

/// R17 回归：真机录屏实测——同回合的 message.delta（streaming=true）与
/// message.completed（streaming=false）帧被投影成两个 assistant 节点，
/// 用户看到同一回复渲染两次（一次「运行中」、一次「已完成」）。
/// 修复后：completed 帧取代 streaming 帧，turn.completed 标记并入该气泡。
test('R17：同回合 delta 与 completed 帧收敛为单条 assistant 气泡（已完成）', () {
  final timeline = [
    _eventOf(2, {
      'kind': 'user_message',
      'text': 'Say OK. One word reply.',
    }),
    _eventOf(3, {'kind': 'turn_phase', 'phase': 'preparing', 'revision': 1}),
    _eventOf(4, {'kind': 'turn_phase', 'phase': 'streaming', 'revision': 2}),
    _eventOf(5, {
      'kind': 'assistant_message',
      'label': 'Assistant',
      'streaming': true,
      'text': 'OK',
    }),
    _eventOf(6, {
      'kind': 'assistant_message',
      'label': 'Assistant',
      'streaming': false,
      'copy_text': 'OK',
      'text': 'OK',
    }),
    _eventOf(7, {'kind': 'turn_phase', 'phase': 'finishing', 'revision': 3}),
    _eventOf(8, {'kind': 'turn_phase', 'phase': 'completed', 'revision': 4}),
    _eventOf(9, {
      'kind': 'assistant_message',
      'completed_turn': true,
      'label': 'Assistant',
    }),
  ].map(SessionTimelineEvent.fromRelayEvent).toList();

  final snapshot = const SessionProjectionController().buildSnapshot(
    timeline: timeline,
    controls: _controls(),
  );

  final assistantNodes = snapshot.chatNodes
      .where((node) => node.kind == ConversationNodeKind.assistant)
      .toList();
  expect(assistantNodes.length, 1,
      reason: '同一条回复不得渲染成「运行中」+「已完成」两个气泡');
  final node = assistantNodes.single;
  expect(node.isStreaming, isFalse);
  expect(node.completedTurn, isTrue, reason: 'completed_turn 标记并入该气泡');
  expect(node.text, 'OK');
});

}