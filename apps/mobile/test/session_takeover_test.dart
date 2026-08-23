// v0.5 P4 Composer Chain 接管专项回归（session_takeover_test）。
// 与 session_screens_test.dart 的 P4-A/P4-F 全链路用例互补，聚焦：
// minimize/collapse 不触发 cancel、提交失败保留草稿并 re-arm、approval 恢复草稿。
import 'package:agent_sessions_mobile/domain/session_models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/session_harness.dart';

/// 在 question 单选下拉中选择指定 label（dropdown 菜单项渲染在 overlay route 中）。
Future<void> _selectDropdown(
  WidgetTester tester,
  Key fieldKey,
  String label,
) async {
  await tapVisible(tester, find.byKey(fieldKey));
  // 光标/流式时钟会持续产帧，不能 pumpAndSettle；下拉动画约 150ms。
  for (var frame = 0; frame < 8; frame += 1) {
    await tester.pump(const Duration(milliseconds: 50));
  }
  // 面板展示时会剥掉 “(推荐)” 后缀，菜单项文本与原始 label 不同。
  final displayLabel = label.replaceAll(RegExp(r'\s*\((推荐|recommended)\)\s*$'), '');
  var tapped = false;
  for (var frame = 0; frame < 10 && !tapped; frame += 1) {
    final items = find.text(displayLabel).evaluate();
    if (items.isNotEmpty) {
      await tester.tap(find.text(displayLabel).last);
      tapped = true;
    } else {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }
  expect(tapped, isTrue, reason: '下拉项未出现：$displayLabel');
  for (var frame = 0; frame < 8; frame += 1) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  testWidgets('MOBILE-V05-05/P4-G：question minimize 只折叠面板，不触发 cancel', (
    tester,
  ) async {
    final harness = await openWritableSession(
      tester,
      'takeover-minimize-owner@fixture.test',
    );

    await enterVisible(
      tester,
      find.byKey(const Key('session-composer-input')),
      '触发 question 面板',
    );
    await tapVisible(
      tester,
      find.byKey(const Key('session-composer-primary-action')),
    );
    await waitForVisible(
      tester,
      find.byKey(const Key('assistant-streaming-indicator')),
    );

    await waitForVisible(
      tester,
      find.byKey(const Key('session-question-panel')),
    );
    final sessionId = (await harness.relay.listSessions()).single.id;
    final timeline = (await harness.relay.getSessionSnapshot(
      sessionId,
    )).events.map(SessionTimelineEvent.fromRelayEvent).toList();
    final question = timeline.firstWhere((e) => e.question != null).question!;

    // 先选择一个选项再折叠：恢复时已选答案必须保留。
    await _selectDropdown(
      tester,
      Key('question-options-${question.requestId}'),
      question.options.first,
    );
    await tapVisible(
      tester,
      find.byKey(Key('question-minimize-${question.requestId}')),
    );
    await waitForVisible(
      tester,
      find.byKey(Key('question-minimized-${question.requestId}')),
    );
    // 折叠态不渲染操作按钮，也没有发出 cancel（面板仍挂在 composer chain 上）。
    expect(
      find.byKey(Key('question-cancel-${question.requestId}')),
      findsNothing,
    );
    expect(find.byKey(const Key('session-question-panel')), findsOneWidget);

    await tapVisible(
      tester,
      find.byKey(Key('question-restore-${question.requestId}')),
    );
    await waitForVisible(
      tester,
      find.byKey(Key('question-freeform-${question.requestId}')),
    );
    expect(
      tester
          .widget<DropdownButtonFormField<String>>(
            find.byKey(Key('question-options-${question.requestId}')),
          )
          .initialValue,
      question.options.first,
    );
  });

  testWidgets('MOBILE-V05-05/P4-H：提交失败保留本地状态，恢复后重试成功', (
    tester,
  ) async {
    final harness = await openWritableSession(
      tester,
      'takeover-retry-owner@fixture.test',
    );

    await enterVisible(
      tester,
      find.byKey(const Key('session-composer-input')),
      '触发 question 重试',
    );
    await tapVisible(
      tester,
      find.byKey(const Key('session-composer-primary-action')),
    );
    await waitForVisible(
      tester,
      find.byKey(const Key('assistant-streaming-indicator')),
    );

    await waitForVisible(
      tester,
      find.byKey(const Key('session-question-panel')),
    );
    final sessionId = (await harness.relay.listSessions()).single.id;
    final timeline = (await harness.relay.getSessionSnapshot(
      sessionId,
    )).events.map(SessionTimelineEvent.fromRelayEvent).toList();
    final question = timeline.firstWhere((e) => e.question != null).question!;
    final stepId = question.requestId; // 单题合成 step 的 id 即 requestId

    await waitForVisible(
      tester,
      find.byKey(Key('question-submit-${question.requestId}')),
    );
    await _selectDropdown(
      tester,
      Key('question-options-$stepId'),
      question.options.first,
    );

    harness.relay.setNetworkAvailable(false);
    addTearDown(() => harness.relay.setNetworkAvailable(true));
    await tapVisible(
      tester,
      find.byKey(Key('question-submit-${question.requestId}')),
    );
    // 离线提交失败：面板内出现错误行（文案来自 controller errorMessage 或固定兜底）。
    await waitForVisible(
      tester,
      find.byKey(Key('question-submit-error-${question.requestId}')),
    );

    // 失败后：面板仍在、已选答案保留，可重新提交。
    expect(find.byKey(const Key('session-question-panel')), findsOneWidget);
    expect(
      tester
          .widget<DropdownButtonFormField<String>>(
            find.byKey(Key('question-options-$stepId')),
          )
          .initialValue,
      question.options.first,
    );

    harness.relay.setNetworkAvailable(true);
    await tapVisible(
      tester,
      find.byKey(Key('question-submit-${question.requestId}')),
    );
    await waitForGone(tester, find.byKey(const Key('session-question-panel')));
    expect(
      find.byKey(Key('question-submit-${question.requestId}')),
      findsNothing,
    );
  });
}
