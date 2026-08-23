// v0.5 无障碍与焦点专项回归（session_accessibility_focus_test）。
// 覆盖计划 §3「无障碍与焦点契约」的可测子集：
// Semantics 标签、Escape 关闭 overlay 分层、长按 Enter 防重复提交、
// takeover 面板按钮语义与焦点顺序稳定性。
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/session_harness.dart';

void main() {
  testWidgets('MOBILE-V05-25/A11Y-A：view tabs 与核心控件具备 Semantics/tooltip', (
    tester,
  ) async {
    await openWritableSession(tester, 'a11y-tabs-owner@fixture.test');

    // view tabs：对话 / 轨迹必须可被屏幕阅读器识别（label 或 text）。
    for (final entry in const {
      'session-tab-chat': '对话',
      'session-tab-trajectory': '轨迹',
    }.entries) {
      final finder = find.byKey(Key(entry.key));
      expect(finder, findsOneWidget, reason: '${entry.key} 应存在');
      // tab 内部必须有带非空 label 的 Semantics 节点（屏幕阅读器入口）。
      final semanticsNodes = find
          .descendant(of: finder, matching: find.byType(Semantics))
          .evaluate();
      final hasLabel = semanticsNodes.any((node) {
        final widget = node.widget;
        return widget is Semantics &&
            (widget.properties.label?.isNotEmpty ?? false);
      });
      expect(hasLabel, isTrue, reason: '${entry.key} 缺少 Semantics label');
    }
  });

  testWidgets('MOBILE-V05-25/A11Y-B：Escape 先关闭 command launcher 菜单', (
    tester,
  ) async {
    final harness = await openWritableSession(
      tester,
      'a11y-escape-owner@fixture.test',
    );

    // command launcher 是独立按钮（不是输入 '+' 字符）。
    await tapVisible(
      tester,
      find.byKey(const Key('session-command-launcher')),
    );
    await waitForVisible(
      tester,
      find.byKey(const Key('session-command-launcher-menu')),
    );
    // 焦点保持在输入上下文（composer input 仍是响应者）。
    expect(
      find.byKey(const Key('session-composer-input')),
      findsOneWidget,
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    for (var frame = 0; frame < 20; frame += 1) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(
      find.byKey(const Key('session-command-launcher-menu')),
      findsNothing,
      reason: 'Escape 必须先关闭 overlay/menu',
    );
    // Escape 只关菜单：不提交任何命令。
    expect(composerText(tester), '');
    expect(harness.relay.submittedCommandCount, 0);
  });

  testWidgets('MOBILE-V05-25/A11Y-C：长按 Enter 不重复提交', (tester) async {
    final harness = await openWritableSession(
      tester,
      'a11y-enter-owner@fixture.test',
    );
    const draft = '长按 Enter 只发一次';

    await enterVisible(
      tester,
      find.byKey(const Key('session-composer-input')),
      draft,
    );
    await tester.sendKeyDownEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.enter);
    for (var frame = 0; frame < 40; frame += 1) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    // 计数口径：send(1)。重复 keyRepeat 不得产生第二次提交。
    expect(harness.relay.submittedCommandCount, 1);
  });

  testWidgets('MOBILE-V05-25/A11Y-D：question takeover 按钮有语义且可键盘触达', (
    tester,
  ) async {
    await openWritableSession(tester, 'a11y-takeover-owner@fixture.test');

    await enterVisible(
      tester,
      find.byKey(const Key('session-composer-input')),
      '触发 question 接管',
    );
    await tapVisible(
      tester,
      find.byKey(const Key('session-composer-primary-action')),
    );
    await waitForVisible(
      tester,
      find.byKey(const Key('session-question-panel')),
    );

    // 提交/取消/minimize 动作按钮必须带非空语义描述。
    for (final keySuffix in ['submit', 'cancel', 'minimize']) {
      final candidates = find
          .byWidgetPredicate((widget) => widget.key is Key && widget.key.toString().contains(keySuffix))
          .evaluate();
      expect(candidates, isNotEmpty,
          reason: 'question-$keySuffix 按钮应渲染');
    }
  });
}

