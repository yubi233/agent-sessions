import 'package:agent_sessions_mobile/attachments/attachment_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/app_harness.dart';

void main() {
  testWidgets('MOBILE-08：composer 模型/effort 切换走 lease 命令，usage 只展示脱敏计数', (
    tester,
  ) async {
    final harness = MobileAppHarness();
    await tester.pumpWidget(harness.build());
    await _registerOwner(tester, 'composer-controls@fixture.test');
    await _createAndAcquireLease(tester);

    // 控制条出现：模型/effort 下拉 + usage 计数。
    await _waitForVisible(
      tester,
      find.byKey(const Key('composer-control-strip')),
    );
    await _waitForVisible(
      tester,
      find.byKey(const Key('composer-model-select')),
    );
    await _waitForVisible(
      tester,
      find.byKey(const Key('composer-effort-select')),
    );
    await _waitForVisible(tester, find.byKey(const Key('composer-usage-chip')));
    // usage 只展示计数，不包含 prompt 或回复正文。
    expect(find.textContaining('↑12.5k'), findsOneWidget);
    expect(find.textContaining('上下文 92.0k'), findsOneWidget);
    expect(find.textContaining('fixture-model-a'), findsWidgets);

    // 切换模型：提交 session.model_select 命令并乐观更新。
    await _tapVisible(tester, find.byKey(const Key('composer-model-select')));
    await _waitForVisible(tester, find.text('fixture-model-b').last);
    await tester.tap(find.text('fixture-model-b').last);
    await _waitForVisible(tester, find.textContaining('已切换模型'));
    final snapshot = await harness.relay.getSessionSnapshot(
      (await harness.relay.listSessions()).single.id,
    );
    expect(
      snapshot.events.any(
        (event) => event.eventType == 'session.model_selected',
      ),
      isTrue,
    );

    // 切换 effort。
    await _tapVisible(tester, find.byKey(const Key('composer-effort-select')));
    await _waitForVisible(tester, find.text('中').last);
    await tester.tap(find.text('中').last);
    await _waitForVisible(tester, find.textContaining('已切换 effort'));
  });

  testWidgets('MOBILE-V05-21：danger-full-access 必须先勾选风险确认，取消不提交', (
    tester,
  ) async {
    final harness = MobileAppHarness();
    await tester.pumpWidget(harness.build());
    await _registerOwner(tester, 'permission-danger@fixture.test');
    await _createAndAcquireLease(tester);

    await _waitForVisible(
      tester,
      find.byKey(const Key('composer-permission-mode-select')),
    );
    // 打开权限下拉并选择 danger-full-access。
    await tester.tap(find.byKey(const Key('composer-permission-mode-select')));
    await _waitForVisible(tester, find.text('danger-full-access').last);
    await tester.tap(find.text('danger-full-access').last);
    await _waitForVisible(
      tester,
      find.byKey(const Key('session-permission-risk-confirm')),
    );

    // 未勾选时提交按钮禁用。
    final submit = tester.widget<FilledButton>(
      find.byKey(const Key('session-permission-risk-submit')),
    );
    expect(submit.onPressed, isNull);

    // 取消：不提交任何命令。
    await tester.tap(find.byKey(const Key('session-permission-risk-cancel')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('session-permission-risk-confirm')),
      findsNothing,
    );
    expect(harness.relay.submittedCommandCount, 0);

    // 重新选择并勾选确认后再提交。
    await tester.tap(find.byKey(const Key('composer-permission-mode-select')));
    await _waitForVisible(tester, find.text('danger-full-access').last);
    await tester.tap(find.text('danger-full-access').last);
    await _waitForVisible(
      tester,
      find.byKey(const Key('session-permission-risk-confirm')),
    );
    await tester.tap(find.byKey(const Key('session-permission-risk-checkbox')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('session-permission-risk-submit')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('session-permission-risk-confirm')),
      findsNothing,
    );
    // 确认后提交了 permission_mode 命令。
    expect(harness.relay.submittedCommandCount, greaterThan(0));
  });

  testWidgets('MOBILE-08：无 capability 时模型/effort 下拉禁用且不提交命令', (tester) async {
    final harness = MobileAppHarness();
    await tester.pumpWidget(harness.build());
    await _registerOwner(tester, 'composer-blocked@fixture.test');
    await _createAndAcquireLease(tester, provider: 'opencode');

    // opencode fixture 未声明 model_select/effort_select：控制条仍显示（说明原因）但不可交互。
    await _waitForVisible(
      tester,
      find.byKey(const Key('composer-control-strip')),
    );
    final modelDropdown = tester.widget<DropdownButtonFormField<String>>(
      find.byKey(const Key('composer-model-select')),
    );
    expect(modelDropdown.onChanged, isNull);
    final effortDropdown = tester.widget<DropdownButtonFormField<String>>(
      find.byKey(const Key('composer-effort-select')),
    );
    expect(effortDropdown.onChanged, isNull);
    expect(harness.relay.submittedCommandCount, 0);
  });

  testWidgets('MOBILE-08：@ 补全给文件建议并应用，越权查询不产生建议', (tester) async {
    final harness = MobileAppHarness();
    await tester.pumpWidget(harness.build());
    await _registerOwner(tester, 'completion@fixture.test');
    await _createAndAcquireLease(tester);

    await _enterVisible(
      tester,
      find.byKey(const Key('session-composer-input')),
      '@readme',
    );
    await _waitForVisible(
      tester,
      find.byKey(const Key('composer-suggestions')),
    );
    await _waitForVisible(
      tester,
      find.byKey(const Key('completion-suggestion-文件 · README.md')),
    );
    // 应用建议：输入框填入 @README.md。
    await _tapVisible(
      tester,
      find.byKey(const Key('completion-suggestion-文件 · README.md')),
    );
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('session-composer-input')))
          .controller!
          .text,
      contains('@README.md'),
    );

    // 越权查询（..）不产生建议：显示空态说明。
    await tester.enterText(
      find.byKey(const Key('session-composer-input')),
      '@../etc',
    );
    await tester.pump(const Duration(milliseconds: 100));
    await _waitForVisible(
      tester,
      find.byKey(const Key('composer-suggestions-empty')),
    );
  });

  testWidgets('MOBILE-08：/ 补全给 Skill 建议并应用', (tester) async {
    final harness = MobileAppHarness();
    await tester.pumpWidget(harness.build());
    await _registerOwner(tester, 'skill-completion@fixture.test');
    await _createAndAcquireLease(tester);

    await _enterVisible(
      tester,
      find.byKey(const Key('session-composer-input')),
      '/检查',
    );
    await _waitForVisible(
      tester,
      find.byKey(const Key('composer-suggestions')),
    );
    await _waitForVisible(
      tester,
      find.byKey(const Key('completion-suggestion-Skill · 检查会话控制')),
    );
    await _tapVisible(
      tester,
      find.byKey(const Key('completion-suggestion-Skill · 检查会话控制')),
    );
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('session-composer-input')))
          .controller!
          .text,
      contains('/检查会话控制'),
    );
  });

  testWidgets('MOBILE-V05-08：URL 与 user@host 中的 trigger 不弹候选', (tester) async {
    final harness = MobileAppHarness();
    await tester.pumpWidget(harness.build());
    await _registerOwner(tester, 'trigger-boundary@fixture.test');
    await _createAndAcquireLease(tester);

    // URL 中的 / 不是 trigger：不弹 slash/skill 候选，也不出现空态。
    await _enterVisible(
      tester,
      find.byKey(const Key('session-composer-input')),
      '请看 https://example.com/path',
    );
    await tester.pump(const Duration(milliseconds: 120));
    expect(find.byKey(const Key('composer-suggestions')), findsNothing);

    // user@host 中的 @ 不是引用 trigger：不弹候选。
    await tester.enterText(
      find.byKey(const Key('session-composer-input')),
      '发信给 user@example.com',
    );
    await tester.pump(const Duration(milliseconds: 120));
    expect(find.byKey(const Key('composer-suggestions')), findsNothing);

    // 真正的 / trigger 应仍弹出候选（验证探测没有整体失效）。
    await tester.enterText(
      find.byKey(const Key('session-composer-input')),
      '/检查',
    );
    await _waitForVisible(
      tester,
      find.byKey(const Key('composer-suggestions')),
    );
  });

  testWidgets('MOBILE-V05-08：@ 引用只替换 trigger span，不重建整段草稿', (tester) async {
    final harness = MobileAppHarness();
    await tester.pumpWidget(harness.build());
    await _registerOwner(tester, 'trigger-span@fixture.test');
    await _createAndAcquireLease(tester);

    // 在行中触发 @ 后应用：只替换 @...+查询，保留前后文本。
    // enterText 会把 caret 放到文末，这里显式把 caret 移到 @re 之后模拟真实输入位置。
    const draft = '先写一段 @re 再继续';
    await _enterVisible(
      tester,
      find.byKey(const Key('session-composer-input')),
      draft,
    );
    // 用 testTextInput.updateEditingValue 模拟“光标移动到 @re 之后”这一编辑更新，
    // 触发 TextField 的 onSelectionChanged 重新探测 trigger。
    tester.testTextInput.updateEditingValue(
      TextEditingValue(
        text: draft,
        selection: TextSelection.collapsed(offset: '先写一段 @re'.length),
      ),
    );
    await tester.pump(const Duration(milliseconds: 80));
    await _waitForVisible(
      tester,
      find.byKey(const Key('composer-suggestions')),
    );
    await _waitForVisible(
      tester,
      find.byKey(const Key('completion-suggestion-文件 · README.md')),
    );
    await _tapVisible(
      tester,
      find.byKey(const Key('completion-suggestion-文件 · README.md')),
    );
    final text = tester
        .widget<TextField>(find.byKey(const Key('session-composer-input')))
        .controller!
        .text;
    expect(text, contains('先写一段 @README.md 再继续'));
  });

  testWidgets('MOBILE-08：有会话 DEK 时选附件进入密文队列；无 DEK 时按钮禁用', (tester) async {
    // 有 DEK：fixture picker 被注入，点击后草稿进入既有密文队列。
    final harness = MobileAppHarness(
      attachmentPicker: const FixtureAttachmentPicker(),
    );
    await tester.pumpWidget(harness.build());
    await _registerOwner(tester, 'pick-attach@fixture.test');
    await _createAndAcquireLease(tester);

    await _waitForVisible(
      tester,
      find.byKey(const Key('session-attachment-add-button')),
    );
    expect(
      tester
          .widget<IconButton>(
            find.byKey(const Key('session-attachment-add-button')),
          )
          .onPressed,
      isNotNull,
      reason: 'fixture 声明 DEK 可用后选附件入口必须启用',
    );
    await _tapVisible(
      tester,
      find.byKey(const Key('session-attachment-add-button')),
    );
    await _waitForVisible(
      tester,
      find.byKey(const Key('session-attachment-queue')),
    );
    expect(find.text('fixture-picked.png'), findsOneWidget);
  });

  testWidgets('MOBILE-08：无会话 DEK 时附件按钮禁用并说明原因，不触发选择器', (tester) async {
    final harness = MobileAppHarness(
      attachmentPicker: const FixtureAttachmentPicker(),
    )..relay.contentKeysReady = false;
    await tester.pumpWidget(harness.build());
    await _registerOwner(tester, 'pick-blocked@fixture.test');
    await _createAndAcquireLease(tester);

    await _waitForVisible(
      tester,
      find.byKey(const Key('session-attachment-add-button')),
    );
    expect(
      tester
          .widget<IconButton>(
            find.byKey(const Key('session-attachment-add-button')),
          )
          .onPressed,
      isNull,
      reason: '无会话 DEK 时附件入口必须 fail-closed',
    );
    // 原因通过 tooltip 表达；队列保持为空。
    expect(find.byKey(const Key('session-attachment-queue')), findsNothing);
  });

  testWidgets('MOBILE-10：permission mode 切换走 lease 命令并落事件', (tester) async {
    final harness = MobileAppHarness();
    await tester.pumpWidget(harness.build());
    await _registerOwner(tester, 'permission-mode@fixture.test');
    await _createAndAcquireLease(tester);

    // 控制条第二行出现权限下拉。
    await _waitForVisible(
      tester,
      find.byKey(const Key('composer-permission-mode-select')),
    );
    await _tapVisible(
      tester,
      find.byKey(const Key('composer-permission-mode-select')),
    );
    await _waitForVisible(tester, find.text('acceptEdits').last);
    await tester.tap(find.text('acceptEdits').last);
    await _waitForVisible(tester, find.textContaining('已切换 permission mode'));

    final snapshot = await harness.relay.getSessionSnapshot(
      (await harness.relay.listSessions()).single.id,
    );
    expect(
      snapshot.events.any(
        (event) => event.eventType == 'session.permission_mode_selected',
      ),
      isTrue,
    );
  });

  testWidgets('MOBILE-10：无 permission_mode capability 时下拉禁用且不提交命令', (
    tester,
  ) async {
    final harness = MobileAppHarness();
    await tester.pumpWidget(harness.build());
    await _registerOwner(tester, 'permission-mode-blocked@fixture.test');
    // opencode 未声明 permission_mode：选择器不可交互。
    await _createAndAcquireLease(tester, provider: 'opencode');

    await _waitForVisible(
      tester,
      find.byKey(const Key('composer-permission-mode-select')),
    );
    final dropdown = tester.widget<DropdownButtonFormField<String>>(
      find.byKey(const Key('composer-permission-mode-select')),
    );
    expect(dropdown.onChanged, isNull);
    expect(harness.relay.submittedCommandCount, 0);
  });

  testWidgets('MOBILE-12：usage 展示 cache 计数并在 context 超阈值时给出警告', (tester) async {
    final harness = MobileAppHarness();
    await tester.pumpWidget(harness.build());
    await _registerOwner(tester, 'usage-depth@fixture.test');
    await _createAndAcquireLease(tester);

    // cache 计数合并展示。
    await _waitForVisible(tester, find.byKey(const Key('composer-usage-chip')));
    expect(find.textContaining('缓存 61.8k'), findsOneWidget);
    // fixture context 92000/100000 = 92%：显示脱敏警告。
    await _waitForVisible(
      tester,
      find.byKey(const Key('composer-context-warning')),
    );
    expect(find.textContaining('上下文占用 92%'), findsOneWidget);
    // 不渲染 prompt 或回复正文。
    expect(find.textContaining('提示词'), findsNothing);
  });
}

Future<void> _registerOwner(WidgetTester tester, String _) async {
  await _tapVisible(tester, find.byKey(const Key('device-connect-submit')));
  await _waitForVisible(tester, find.byKey(const Key('owner-ready-state')));
}

Future<void> _createAndAcquireLease(
  WidgetTester tester, {
  String provider = 'codex',
}) async {
  await _tapVisible(tester, find.byKey(const Key('session-new-button')));
  await _waitForVisible(
    tester,
    find.byKey(const Key('new-session-workspace-input')),
  );
  if (provider != 'codex') {
    await _tapVisible(
      tester,
      find.byKey(const Key('new-session-provider-select')),
    );
    await _waitForVisible(tester, find.text('OpenCode').last);
    await tester.tap(find.text('OpenCode').last);
  }
  await _tapVisible(tester, find.byKey(const Key('new-session-create-button')));
  await _waitForVisible(tester, find.byKey(const Key('session-detail-screen')));
  await _tapVisible(
    tester,
    find.byKey(const Key('session-acquire-lease-button')),
  );
  await _waitForVisible(tester, find.text('已获得控制权'));
}

Future<void> _waitForVisible(
  WidgetTester tester,
  Finder finder, {
  int maxFrames = 100,
}) async {
  for (var frame = 0; frame < maxFrames; frame += 1) {
    await tester.pump(const Duration(milliseconds: 50));
    if (finder.evaluate().isNotEmpty) return;
  }
  expect(finder, findsOneWidget);
}

Future<void> _tapVisible(WidgetTester tester, Finder finder) async {
  await _waitForVisible(tester, finder);
  await tester.ensureVisible(finder);
  for (var frame = 0; frame < 3; frame += 1) {
    await tester.pump(const Duration(milliseconds: 50));
  }
  await tester.tap(finder);
}

Future<void> _enterVisible(
  WidgetTester tester,
  Finder finder,
  String value,
) async {
  await _waitForVisible(tester, finder);
  await tester.ensureVisible(finder);
  await tester.pump();
  await tester.enterText(finder, value);
}
