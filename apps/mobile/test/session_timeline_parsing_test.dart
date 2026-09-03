import 'package:agent_sessions_mobile/domain/session_models.dart';
import 'package:flutter_test/flutter_test.dart';

/// daemon 本地开发编码器（localdev_encoder）产出的每种 fixture_payload 形状
/// 都必须有稳定的时间线解析契约；未知 kind 不得崩溃，降级为占位或系统通知。
void main() {
  SessionTimelineEvent parse(int seq, String type, Map<String, dynamic> payload) =>
      SessionTimelineEvent.fromRelayEvent(
        RelaySessionEvent(
          sequence: seq,
          eventType: type,
          envelope: {'fixture_payload': payload},
        ),
      );

  test('user_message 解析文本与复制负载', () {
    final event = parse(1, 'user.message', {
      'kind': 'user_message',
      'label': '你',
      'text': '你好',
      'streaming': false,
      'copy_text': '你好',
    });
    expect(event.kind, SessionTimelineKind.userMessage);
    expect(event.label, '你');
    expect(event.text, '你好');
    expect(event.copyText, '你好');
    expect(event.isStreaming, isFalse);
  });

  test('assistant_message 全文与 completed_turn 终态标记', () {
    final message = parse(2, 'message.completed', {
      'kind': 'assistant_message',
      'label': 'Assistant',
      'text': '回复正文',
      'streaming': false,
    });
    expect(message.kind, SessionTimelineKind.assistantMessage);
    expect(message.text, '回复正文');
    expect(message.completedTurn, isFalse);

    final terminal = parse(3, 'turn.completed', {
      'kind': 'assistant_message',
      'label': 'Assistant',
      'completed_turn': true,
    });
    expect(terminal.kind, SessionTimelineKind.assistantMessage);
    expect(terminal.completedTurn, isTrue);
  });

  test('tool_activity 解析状态与输出', () {
    final event = parse(4, 'tool', {
      'kind': 'tool_activity',
      'label': '编辑文件',
      'tool_status': '已完成',
      'tool_output': 'ok',
    });
    expect(event.kind, SessionTimelineKind.toolActivity);
    expect(event.toolStatus, '已完成');
    expect(event.label, '编辑文件');
  });

  test('system_notice 承载 Provider 错误等系统提示', () {
    final event = parse(5, 'session.error', {
      'kind': 'system_notice',
      'label': 'Provider 错误',
      'text': 'Provider 发送失败，详情仅限本机诊断。',
    });
    expect(event.kind, SessionTimelineKind.systemNotice);
    expect(event.label, 'Provider 错误');
    expect(event.text, contains('Provider 发送失败'));
  });
  test('system_notice 透传上游结构化错误码', () {
    final event = parse(8, 'session.error', {
      'kind': 'system_notice',
      'label': 'Provider 错误',
      'text': '模型回合失败：quota',
      'error_code': 'RATE_LIMIT',
      'http_status': 429,
    });
    expect(event.kind, SessionTimelineKind.systemNotice);
    expect(event.errorCode, 'RATE_LIMIT');
    expect(event.httpStatus, 429);
    // 缺省形状：无结构化字段不补零值猜测。
    final plain = parse(9, 'session.error', {
      'kind': 'system_notice',
      'label': 'Provider 错误',
      'text': 'x',
    });
    expect(plain.errorCode, isNull);
    expect(plain.httpStatus, 0);
  });

  test('未知 kind 与缺失 fixture 不崩溃并统一降级为占位', () {
    final unknown = parse(6, 'future.event', {
      'kind': 'hologram_message',
      'text': '来自未来',
    });
    expect(unknown.kind, SessionTimelineKind.encryptedPlaceholder);
    // 解析层如实保留字段，占位 kind 由渲染层决定不展示正文。
    expect(unknown.text, '来自未来');

    final encrypted = parse(7, 'user.message', {
      'alg': 'AES-256-GCM',
      'ciphertext': 'x',
    });
    expect(encrypted.kind, SessionTimelineKind.encryptedPlaceholder);
  });
}
