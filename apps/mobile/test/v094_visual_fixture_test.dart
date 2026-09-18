import 'package:agent_sessions_mobile/app/local_visual_fixture.dart';
import 'package:flutter_test/flutter_test.dart';

/// V094 P0（计划 §4-P0）：将截图评审场景固化为确定性 fixture。
///
/// 环境基线契约（可见 gate/录屏 manifest 必须按此记录）：
/// - 设备逻辑尺寸：360×800 dp（基线）；补测 320/430/1280 与 200% 字号。
/// - 字号 textScale：1.0（基准）；大字补测 2.0。
/// - 主题：亮/暗双主题必测。
/// - 时钟：fixture 冻结时钟（2026-08-14 12:00 UTC），保证逐帧可复现。
/// - 文本：全部为公开 fixture 文本，不含真实用户内容。
void main() {
  test('V094 baseline fixture：富 Markdown 历史（表格/代码块/行内代码/列表）', () async {
    final fixture = await LocalVisualFixture.create('v094-session-ui-baseline');
    expect(fixture, isNotNull);
    expect(fixture!.scenario, LocalVisualScenario.v094SessionUiBaseline);
    expect(fixture.sessionId, isNotNull);

    final snapshot = await fixture.relay.getSessionSnapshot(fixture.sessionId!);
    final kinds = snapshot.events.map((e) => e.eventType).toList();
    expect(kinds, contains('message.user'), reason: '必须预置用户消息');
    expect(kinds, contains('message.assistant'), reason: '必须预置助手回复');
    final assistant = snapshot.events
        .map((e) => e.envelope['fixture_payload'])
        .whereType<Map<dynamic, dynamic>>()
        .firstWhere(
          (payload) => payload['kind'] == 'assistant_message',
          orElse: () => throw StateError('缺少 assistant_message'),
        );
    final text = assistant['text'] as String;
    // 富 Markdown 锚点：GFM 表格、围栏代码块、行内代码、列表。
    expect(text, contains('| 模块 | 状态 | 说明 |'));
    expect(text, contains('```bash'));
    expect(text, contains('`flutter analyze`'));
    expect(text, contains('- 气泡不等于送达'));
  });

  test('V094 recovery fixture：结构化错误 notice + 自动恢复历史', () async {
    final fixture = await LocalVisualFixture.create('v094-session-ui-recovery');
    expect(fixture, isNotNull);
    expect(fixture!.scenario, LocalVisualScenario.v094SessionUiRecovery);

    final snapshot = await fixture.relay.getSessionSnapshot(fixture.sessionId!);
    final payloads = snapshot.events
        .map((e) => e.envelope['fixture_payload'])
        .whereType<Map<dynamic, dynamic>>()
        .toList(growable: false);
    // 结构化错误事实（V094-03/18 锚点）：error_code 与用户语言提示分离。
    // 注意：createSession 自动 start 会追加无错误码的启动 notice，需按 error_code 过滤。
    final notice = payloads.firstWhere(
      (payload) =>
          payload['kind'] == 'system_notice' &&
          payload['error_code'] == 'LOCAL_STATE_MISSING',
      orElse: () => throw StateError('缺少 LOCAL_STATE_MISSING 错误 notice'),
    );
    expect(notice['error_code'], 'LOCAL_STATE_MISSING');
    expect(notice['text'], isA<String>());
    expect(
      (notice['text'] as String).contains('自动恢复'),
      isTrue,
      reason: '错误提示必须使用用户语言，而不是裸技术术语',
    );
    // 恢复后的助手回复存在（已恢复错误可折叠为历史详情）。
    expect(
      payloads.any(
        (payload) =>
            payload['kind'] == 'assistant_message' &&
            (payload['text'] as String).contains('自动重试 1/1'),
      ),
      isTrue,
    );
  });

  test('V094 config fixture：长模型名 + 完全访问 + 展示目录', () async {
    final fixture = await LocalVisualFixture.create('v094-session-ui-config');
    expect(fixture, isNotNull);
    expect(fixture!.scenario, LocalVisualScenario.v094SessionUiConfig);

    final controls = await fixture.relay.getSessionControls(fixture.sessionId!);
    // 长模型名（UI-15：显示名缺失时保守缩略 + 详情完整 ID）。
    expect(controls.model, 'deepseek-v4.1-flash-128k-context-preview');
    // 完全访问徽标 + 风险确认门（UI-16：警示不缩小、勾选确认保留）。
    expect(controls.permissionMode, 'danger-full-access');
    expect(controls.availablePermissionModes, contains('danger-full-access'));
    // 展示目录（V094-26）：完整访问保留说明；目录与 ID 数组同构。
    expect(controls.availablePermissionModeDetails, hasLength(4));
    final fullAccess = controls.availablePermissionModeDetails
        .firstWhere((detail) => detail.id == 'danger-full-access');
    expect(fullAccess.name, '完整访问');
    expect(fullAccess.description, isNotEmpty);
  });
}
