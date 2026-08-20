import 'package:agent_sessions_mobile/app/providers.dart';
import 'package:agent_sessions_mobile/domain/models.dart';
import 'package:agent_sessions_mobile/domain/session_models.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/app_harness.dart';
import 'support/fixture_owner.dart';

void main() {
  testWidgets('MOBILE-02：owner 可完成新会话、lease、流式、确认、回答和停止', (tester) async {
    final harness = MobileAppHarness();
    await tester.pumpWidget(harness.build());
    await _waitForVisible(
      tester,
      find.byKey(const Key('device-connect-submit')),
    );
    await _registerOwner(tester, 'session-ui-owner@fixture.test');

    expect(find.byKey(const Key('session-empty-state')), findsOneWidget);
    await _tapVisible(tester, find.byKey(const Key('session-new-button')));
    await _waitForVisible(
      tester,
      find.byKey(const Key('new-session-workspace-input')),
    );
    await _enterVisible(
      tester,
      find.byKey(const Key('new-session-workspace-input')),
      'fixture-workspace',
    );
    await _tapVisible(
      tester,
      find.byKey(const Key('new-session-create-button')),
    );
    await _waitForVisible(
      tester,
      find.byKey(const Key('session-detail-screen')),
    );
    expect(find.byKey(const Key('happy-session-header')), findsOneWidget);
    expect(
      find.byKey(const Key('happy-session-provider-avatar')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('happy-session-empty-state')), findsOneWidget);
    expect(find.text('No messages yet'), findsOneWidget);
    expect(find.text('输入消息...'), findsOneWidget);
    expect(find.byKey(const Key('happy-session-model-row')), findsOneWidget);
    expect(find.textContaining('邮箱'), findsNothing);
    expect(find.textContaining('密码'), findsNothing);
    expect(
      find.byKey(const Key('session-composer-blocked-reason')),
      findsOneWidget,
    );

    await _tapVisible(
      tester,
      find.byKey(const Key('session-acquire-lease-button')),
    );
    await _waitForVisible(tester, find.text('已获得控制权'));
    await _enterVisible(
      tester,
      find.byKey(const Key('session-composer-input')),
      '请验证 fixture 会话',
    );
    await _tapVisible(
      tester,
      find.byKey(const Key('session-composer-primary-action')),
    );
    await _waitForVisible(
      tester,
      find.byKey(const Key('assistant-streaming-indicator')),
    );

    final timeline = (await harness.relay.getSessionSnapshot(
      (await harness.relay.listSessions()).single.id,
    )).events.map(SessionTimelineEvent.fromRelayEvent).toList();
    final permission = timeline
        .firstWhere((event) => event.permission != null)
        .permission!;
    final question = timeline
        .firstWhere((event) => event.question != null)
        .question!;

    await _waitForVisible(
      tester,
      find.byKey(Key('question-freeform-${question.requestId}')),
    );
    await _enterVisible(
      tester,
      find.byKey(Key('question-freeform-${question.requestId}')),
      '继续 fixture',
    );
    await _tapVisible(
      tester,
      find.byKey(Key('question-submit-${question.requestId}')),
    );
    await _waitForGone(
      tester,
      find.byKey(Key('question-submit-${question.requestId}')),
    );
    await _waitForVisible(
      tester,
      find.byKey(Key('permission-approve-${permission.requestId}')),
    );
    await _tapVisible(
      tester,
      find.byKey(Key('permission-approve-${permission.requestId}')),
    );

    await _waitForEnabledIconButton(tester, const Key('session-stop-button'));
    await _tapVisible(tester, find.byKey(const Key('session-stop-button')));
    await _waitForVisible(tester, find.text('已停止'));
  });

  testWidgets('MOBILE-02 CTRL-01：未绑定设备 token 能查看 fixture 会话，但所有写入口禁用', (
    tester,
  ) async {
    final harness = MobileAppHarness();
    await bootstrapFixtureOwner(harness.relay);
    await harness.relay.createSession(
      const CreateMobileSessionInput(
        workspaceId: 'readonly-workspace',
        provider: 'codex',
        deviceId: 'android-owner-fixture',
      ),
    );
    await harness.tokens.write(
      await harness.relay.login(
        const LoginCredentials(
          email: 'readonly-session@fixture.test',
          password: 'fixture-password',
        ),
      ),
    );
    await tester.pumpWidget(harness.build());
    await _waitForVisible(
      tester,
      find.byKey(const Key('session-readonly-banner')),
    );

    final sessionId = (await harness.relay.listSessions()).single.id;
    await _tapVisible(tester, find.byKey(Key('session-row-$sessionId')));
    await _waitForVisible(
      tester,
      find.byKey(const Key('session-detail-screen')),
    );
    expect(
      find.byKey(const Key('session-composer-blocked-reason')),
      findsOneWidget,
    );
    final action = tester.widget<IconButton>(
      find.byKey(const Key('session-composer-primary-action')),
    );
    expect(action.onPressed, isNull);
    final lease = tester.widget<IconButton>(
      find.byKey(const Key('session-acquire-lease-button')),
    );
    expect(lease.onPressed, isNull);
  });

  testWidgets('MOBILE-04：会话详情通过只读 Git 入口打开 DiffView', (tester) async {
    final harness = MobileAppHarness();
    await tester.pumpWidget(harness.build());
    await _waitForVisible(
      tester,
      find.byKey(const Key('device-connect-submit')),
    );
    await _registerOwner(tester, 'git-entry-owner@fixture.test');

    await _tapVisible(tester, find.byKey(const Key('session-new-button')));
    await _waitForVisible(
      tester,
      find.byKey(const Key('new-session-workspace-input')),
    );
    await _tapVisible(
      tester,
      find.byKey(const Key('new-session-create-button')),
    );
    await _waitForVisible(
      tester,
      find.byKey(const Key('session-detail-screen')),
    );

    await _tapVisible(
      tester,
      find.byKey(const Key('session-quick-menu-button')),
    );
    await _tapVisible(tester, find.byKey(const Key('session-open-git-button')));
    await _waitForVisible(tester, find.byKey(const Key('git-diff-screen')));
    await _waitForVisible(
      tester,
      find.byKey(const Key('git-diff-file-lib-state-session-controller-dart')),
    );
  });

  testWidgets('MOBILE-07：快捷菜单展示详情/恢复/文件/归档，capability 驱动禁用', (tester) async {
    final harness = MobileAppHarness();
    await tester.pumpWidget(harness.build());
    await _waitForVisible(
      tester,
      find.byKey(const Key('device-connect-submit')),
    );
    await _registerOwner(tester, 'quick-menu-owner@fixture.test');

    await _tapVisible(tester, find.byKey(const Key('session-new-button')));
    await _waitForVisible(
      tester,
      find.byKey(const Key('new-session-workspace-input')),
    );
    await _tapVisible(
      tester,
      find.byKey(const Key('new-session-create-button')),
    );
    await _waitForVisible(
      tester,
      find.byKey(const Key('session-detail-screen')),
    );

    // 未获取 lease 时 resume 必须禁用并给出中文原因，不能发送命令。
    await _tapVisible(
      tester,
      find.byKey(const Key('session-quick-menu-button')),
    );
    await _waitForVisible(
      tester,
      find.byKey(const Key('session-quick-resume')),
    );
    await _waitForVisible(tester, find.text('等待获取会话控制权'));
    expect(
      tester
          .widget<PopupMenuItem<String>>(
            find.byKey(const Key('session-start-button')),
          )
          .enabled,
      isFalse,
    );
    // fork/archive 未声明能力：入口禁用并说明原因。
    await _waitForVisible(tester, find.text('Provider 未声明 fork 能力'));
    await _waitForVisible(tester, find.text('Provider 未声明归档能力'));
    // 关闭菜单（点遮罩并多帧推进）。
    await _tapAway(tester);

    // 详情入口打开详情底表，只展示白名单元数据。
    await _tapVisible(
      tester,
      find.byKey(const Key('session-quick-menu-button')),
    );
    await _tapVisible(tester, find.byKey(const Key('session-quick-details')));
    await _waitForVisible(
      tester,
      find.byKey(const Key('session-details-sheet')),
    );
    await _waitForVisible(tester, find.text('会话详情'));
    await _tapAway(tester);

    // 获取 lease 后 resume 可点：提交 session.resume 命令并追加系统通知事件。
    await _tapVisible(
      tester,
      find.byKey(const Key('session-acquire-lease-button')),
    );
    await _waitForVisible(tester, find.text('已获得控制权'));
    await _tapVisible(
      tester,
      find.byKey(const Key('session-quick-menu-button')),
    );
    await _waitForVisible(
      tester,
      find.byKey(const Key('session-quick-resume')),
    );
    // 有 lease 后不再显示阻断原因。
    expect(find.text('等待获取会话控制权'), findsNothing);
    await _tapVisible(tester, find.byKey(const Key('session-quick-resume')));

    final snapshot = (await harness.relay.getSessionSnapshot(
      (await harness.relay.listSessions()).single.id,
    ));
    expect(
      snapshot.events.any((event) => event.eventType == 'session.resumed'),
      isTrue,
      reason: 'resume 命令必须落为事件，而不是仅本地弹提示',
    );

    await _tapAway(tester);
    await _tapVisible(
      tester,
      find.byKey(const Key('session-quick-menu-button')),
    );
    await _tapVisible(tester, find.byKey(const Key('session-start-button')));
    final startedSnapshot = await harness.relay.getSessionSnapshot(
      (await harness.relay.listSessions()).single.id,
    );
    expect(
      startedSnapshot.events.any(
        (event) => event.eventType == 'session.started',
      ),
      isTrue,
    );
    await _tapVisible(
      tester,
      find.byKey(const Key('session-quick-menu-button')),
    );
    await _tapVisible(tester, find.byKey(const Key('session-kill-button')));
    await _waitForVisible(
      tester,
      find.byKey(const Key('session-kill-confirm')),
    );
    await _tapVisible(tester, find.byKey(const Key('session-kill-confirm')));
    final killedSnapshot = await harness.relay.getSessionSnapshot(
      (await harness.relay.listSessions()).single.id,
    );
    expect(killedSnapshot.session.status, MobileSessionStatus.stopped);
    expect(
      killedSnapshot.events.any((event) => event.eventType == 'session.killed'),
      isTrue,
    );
  });

  testWidgets('MOBILE-07：resume 未声明 capability 时禁用并给出中文原因', (tester) async {
    final harness = MobileAppHarness();
    await tester.pumpWidget(harness.build());
    await _waitForVisible(
      tester,
      find.byKey(const Key('device-connect-submit')),
    );
    await _registerOwner(tester, 'resume-blocked-owner@fixture.test');

    // 用 opencode 创建会话：fixture 未声明 resume（fail-closed）。
    await _tapVisible(tester, find.byKey(const Key('session-new-button')));
    await _waitForVisible(
      tester,
      find.byKey(const Key('new-session-workspace-input')),
    );
    await _enterVisible(
      tester,
      find.byKey(const Key('new-session-workspace-input')),
      'fixture-workspace',
    );
    // 切换到 opencode：fixture 未声明 resume（fail-closed）。
    await _tapVisible(
      tester,
      find.byKey(const Key('new-session-provider-select')),
    );
    await _waitForVisible(tester, find.text('OpenCode').last);
    await tester.tap(find.text('OpenCode').last);
    await _tapVisible(
      tester,
      find.byKey(const Key('new-session-create-button')),
    );
    await _waitForVisible(
      tester,
      find.byKey(const Key('session-detail-screen')),
    );

    await _tapVisible(
      tester,
      find.byKey(const Key('session-quick-menu-button')),
    );
    await _waitForVisible(
      tester,
      find.byKey(const Key('session-quick-resume')),
    );
    await _waitForVisible(tester, find.textContaining('不可用'));
    // 未发送任何 resume 命令：时间线只有创建通知，没有 session.resumed 事件。
    final snapshot = await harness.relay.getSessionSnapshot(
      (await harness.relay.listSessions()).single.id,
    );
    expect(
      snapshot.events.any((event) => event.eventType == 'session.resumed'),
      isFalse,
    );
    await _tapAway(tester);
  });

  testWidgets('MOBILE-07：composer 草稿跨会话内存保存且发送后清除', (tester) async {
    final harness = MobileAppHarness();
    await tester.pumpWidget(harness.build());
    await _waitForVisible(
      tester,
      find.byKey(const Key('device-connect-submit')),
    );
    await _registerOwner(tester, 'draft-owner@fixture.test');

    // 创建两个会话。
    await _tapVisible(tester, find.byKey(const Key('session-new-button')));
    await _waitForVisible(
      tester,
      find.byKey(const Key('new-session-workspace-input')),
    );
    await _enterVisible(
      tester,
      find.byKey(const Key('new-session-workspace-input')),
      'fixture-workspace',
    );
    await _tapVisible(
      tester,
      find.byKey(const Key('new-session-create-button')),
    );
    await _waitForVisible(
      tester,
      find.byKey(const Key('session-detail-screen')),
    );
    final firstId = (await harness.relay.listSessions()).single.id;

    // composer 无 lease 时禁用（不会触发 onChanged 保存草稿）；先获取控制权再输入。
    await _tapVisible(
      tester,
      find.byKey(const Key('session-acquire-lease-button')),
    );
    await _waitForVisible(tester, find.text('已获得控制权'));
    await _enterVisible(
      tester,
      find.byKey(const Key('session-composer-input')),
      '第一条草稿内容',
    );
    await tester.pump();
    await _tapVisible(
      tester,
      find.byKey(const Key('session-detail-back-button')).first,
    );
    await _waitForVisible(tester, find.byKey(const Key('session-home-screen')));
    await _tapVisible(tester, find.byKey(const Key('session-new-button')));
    await _waitForVisible(
      tester,
      find.byKey(const Key('new-session-workspace-input')),
    );
    await _enterVisible(
      tester,
      find.byKey(const Key('new-session-workspace-input')),
      'fixture-workspace',
    );
    await _tapVisible(
      tester,
      find.byKey(const Key('new-session-create-button')),
    );
    await _waitForVisible(
      tester,
      find.byKey(const Key('session-detail-screen')),
    );
    final secondId = (await harness.relay.listSessions())
        .map((item) => item.id)
        .where((id) => id != firstId)
        .single;

    // 第二个会话 composer 应为空（草稿按会话隔离）。
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('session-composer-input')))
          .controller!
          .text,
      isEmpty,
    );

    // 切回第一个会话，草稿恢复。
    await _tapVisible(
      tester,
      find.byKey(const Key('session-detail-back-button')).first,
    );
    await _waitForVisible(tester, find.byKey(const Key('session-home-screen')));
    await _tapVisible(tester, find.byKey(Key('session-row-$secondId')));
    await _waitForVisible(
      tester,
      find.byKey(const Key('session-detail-screen')),
    );
    await _tapVisible(
      tester,
      find.byKey(const Key('session-detail-back-button')).first,
    );
    await _waitForVisible(tester, find.byKey(const Key('session-home-screen')));
    await _waitForGone(tester, find.byKey(const Key('session-detail-screen')));
    await _tapVisible(tester, find.byKey(Key('session-row-$firstId')));
    await _waitForVisible(
      tester,
      find.byKey(const Key('session-detail-screen')),
    );
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('session-composer-input')))
          .controller!
          .text,
      '第一条草稿内容',
    );
  });

  testWidgets('MOBILE-V05-07/P3-A：streaming queue 不自动 flush，需显式发送', (
    tester,
  ) async {
    final harness = MobileAppHarness();
    await tester.pumpWidget(harness.build());
    await _waitForVisible(
      tester,
      find.byKey(const Key('device-connect-submit')),
    );
    await _registerOwner(tester, 'composer-queue-owner@fixture.test');

    await _tapVisible(tester, find.byKey(const Key('session-new-button')));
    await _waitForVisible(
      tester,
      find.byKey(const Key('new-session-workspace-input')),
    );
    await _enterVisible(
      tester,
      find.byKey(const Key('new-session-workspace-input')),
      'fixture-workspace',
    );
    await _tapVisible(
      tester,
      find.byKey(const Key('new-session-create-button')),
    );
    await _waitForVisible(
      tester,
      find.byKey(const Key('session-detail-screen')),
    );
    final sessionId = (await harness.relay.listSessions()).single.id;

    await _tapVisible(
      tester,
      find.byKey(const Key('session-acquire-lease-button')),
    );
    await _waitForVisible(tester, find.text('已获得控制权'));
    await _enterVisible(
      tester,
      find.byKey(const Key('session-composer-input')),
      '先让会话进入 streaming',
    );
    await _tapVisible(
      tester,
      find.byKey(const Key('session-composer-primary-action')),
    );
    await _waitForVisible(
      tester,
      find.byKey(const Key('assistant-streaming-indicator')),
    );
    expect(harness.relay.submittedCommandCount, 1);

    const queuedText = '这条消息只进入本地 queue';
    await _enterVisible(
      tester,
      find.byKey(const Key('session-composer-input')),
      queuedText,
    );
    await _tapVisible(
      tester,
      find.byKey(const Key('session-composer-primary-action')),
    );
    await _waitForVisible(tester, find.byKey(const Key('session-queue-dock')));
    expect(find.text(queuedText), findsOneWidget);
    expect(harness.relay.submittedCommandCount, 1);
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('session-composer-input')))
          .controller!
          .text,
      isEmpty,
    );

    await _waitForEnabledIconButton(tester, const Key('session-stop-button'));
    await _tapVisible(tester, find.byKey(const Key('session-stop-button')));
    await _waitForVisible(tester, find.text('已停止'));
    await _waitForVisible(tester, find.byKey(const Key('session-queue-dock')));
    final stoppedSnapshot = await harness.relay.getSessionSnapshot(sessionId);
    expect(_snapshotContainsText(stoppedSnapshot, queuedText), isFalse);

    await _tapVisible(tester, find.byKey(const Key('session-queue-send-all')));
    await _waitForGone(tester, find.byKey(const Key('session-queue-dock')));
    final sentSnapshot = await harness.relay.getSessionSnapshot(sessionId);
    expect(_snapshotContainsText(sentSnapshot, queuedText), isTrue);
    expect(harness.relay.submittedCommandCount, 3);
  });

  testWidgets('MOBILE-V05-04/P3-B：提交失败显示 notice 且保留草稿', (tester) async {
    final harness = MobileAppHarness();
    await tester.pumpWidget(harness.build());
    await _waitForVisible(
      tester,
      find.byKey(const Key('device-connect-submit')),
    );
    await _registerOwner(tester, 'composer-failure-owner@fixture.test');

    await _tapVisible(tester, find.byKey(const Key('session-new-button')));
    await _waitForVisible(
      tester,
      find.byKey(const Key('new-session-workspace-input')),
    );
    await _enterVisible(
      tester,
      find.byKey(const Key('new-session-workspace-input')),
      'fixture-workspace',
    );
    await _tapVisible(
      tester,
      find.byKey(const Key('new-session-create-button')),
    );
    await _waitForVisible(
      tester,
      find.byKey(const Key('session-detail-screen')),
    );

    await _tapVisible(
      tester,
      find.byKey(const Key('session-acquire-lease-button')),
    );
    await _waitForVisible(tester, find.text('已获得控制权'));

    const failedDraft = '这条提交应该保留在草稿里';
    await _enterVisible(
      tester,
      find.byKey(const Key('session-composer-input')),
      failedDraft,
    );
    harness.relay.setNetworkAvailable(false);
    addTearDown(() => harness.relay.setNetworkAvailable(true));

    await _tapVisible(
      tester,
      find.byKey(const Key('session-composer-primary-action')),
    );
    await _waitForVisible(
      tester,
      find.byKey(const Key('session-composer-machine-notice')),
    );
    final notice = tester.widget<Text>(
      find.byKey(const Key('session-composer-machine-notice')),
    );
    expect(notice.data, contains('本地 Relay fixture 当前不可用'));
    expect(harness.relay.submittedCommandCount, 0);
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('session-composer-input')))
          .controller!
          .text,
      failedDraft,
    );
  });

  testWidgets('MOBILE-V05-04/P3-C：idle 硬件 Enter 提交消息', (tester) async {
    final harness = await _openWritableSession(
      tester,
      'composer-enter-idle-owner@fixture.test',
    );

    const draft = '硬件 Enter 应该发送这条消息';
    await _enterVisible(
      tester,
      find.byKey(const Key('session-composer-input')),
      draft,
    );
    await _pressEnter(tester);
    await _waitForVisible(
      tester,
      find.byKey(const Key('assistant-streaming-indicator')),
    );

    expect(harness.relay.submittedCommandCount, 1);
    final snapshot = await harness.relay.getSessionSnapshot(
      (await harness.relay.listSessions()).single.id,
    );
    expect(_snapshotContainsText(snapshot, draft), isTrue);
    expect(_composerText(tester), isEmpty);
  });

  testWidgets('MOBILE-V05-07/P3-C：streaming 硬件 Enter 只入队', (tester) async {
    final harness = await _openWritableSession(
      tester,
      'composer-enter-queue-owner@fixture.test',
    );

    await _enterVisible(
      tester,
      find.byKey(const Key('session-composer-input')),
      '先进入 streaming',
    );
    await _tapVisible(
      tester,
      find.byKey(const Key('session-composer-primary-action')),
    );
    await _waitForVisible(
      tester,
      find.byKey(const Key('assistant-streaming-indicator')),
    );
    expect(harness.relay.submittedCommandCount, 1);

    const queued = '硬件 Enter 运行中只进入 queue';
    await _enterVisible(
      tester,
      find.byKey(const Key('session-composer-input')),
      queued,
    );
    await _pressEnter(tester);
    await _waitForVisible(tester, find.byKey(const Key('session-queue-dock')));

    expect(find.text(queued), findsOneWidget);
    expect(harness.relay.submittedCommandCount, 1);
    expect(_composerText(tester), isEmpty);
  });

  testWidgets('MOBILE-V05-08/P3-C：Shift、IME 与 repeat Enter 不重复提交', (
    tester,
  ) async {
    final harness = await _openWritableSession(
      tester,
      'composer-enter-guard-owner@fixture.test',
    );

    await _enterVisible(
      tester,
      find.byKey(const Key('session-composer-input')),
      'Shift Enter 只应保留草稿',
    );
    await _pressEnter(tester, shift: true);
    await tester.pump(const Duration(milliseconds: 80));
    expect(harness.relay.submittedCommandCount, 0);
    expect(_composerText(tester), contains('Shift Enter 只应保留草稿'));

    const composingDraft = '拼音候选确认';
    final composerController = tester
        .widget<TextField>(find.byKey(const Key('session-composer-input')))
        .controller!;
    composerController.value = const TextEditingValue(
      text: composingDraft,
      selection: TextSelection.collapsed(offset: composingDraft.length),
      composing: TextRange(start: 0, end: 2),
    );
    await tester.pump();
    expect(composerController.value.composing.isValid, isTrue);
    await _pressEnter(tester);
    await tester.pump(const Duration(milliseconds: 80));
    expect(harness.relay.submittedCommandCount, 0);
    expect(_composerText(tester), composingDraft);

    const repeatDraft = '长按 Enter 只能提交一次';
    await _enterVisible(
      tester,
      find.byKey(const Key('session-composer-input')),
      repeatDraft,
    );
    await tester.sendKeyDownEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.enter);
    await _waitForVisible(
      tester,
      find.byKey(const Key('assistant-streaming-indicator')),
    );
    expect(harness.relay.submittedCommandCount, 1);
    final snapshot = await harness.relay.getSessionSnapshot(
      (await harness.relay.listSessions()).single.id,
    );
    expect(_snapshotContainsText(snapshot, repeatDraft), isTrue);
  });

  testWidgets('MOBILE-V05-05/P4-A：Question 优先接管，完成后 re-arm Approval', (
    tester,
  ) async {
    final harness = await _openWritableSession(
      tester,
      'composer-chain-owner@fixture.test',
    );

    await _enterVisible(
      tester,
      find.byKey(const Key('session-composer-input')),
      '触发 question 和 approval',
    );
    await _tapVisible(
      tester,
      find.byKey(const Key('session-composer-primary-action')),
    );
    await _waitForVisible(
      tester,
      find.byKey(const Key('assistant-streaming-indicator')),
    );

    final timeline = (await harness.relay.getSessionSnapshot(
      (await harness.relay.listSessions()).single.id,
    )).events.map(SessionTimelineEvent.fromRelayEvent).toList();
    final permission = timeline
        .firstWhere((event) => event.permission != null)
        .permission!;
    final question = timeline
        .firstWhere((event) => event.question != null)
        .question!;

    await _waitForVisible(
      tester,
      find.byKey(const Key('session-composer-chain')),
    );
    expect(find.byKey(const Key('session-question-panel')), findsOneWidget);
    expect(find.byKey(const Key('session-approval-panel')), findsNothing);
    expect(
      find.byKey(Key('permission-approve-${permission.requestId}')),
      findsNothing,
    );

    const fallbackDraft = 'pending takeover 不应清空输入草稿';
    await _enterVisible(
      tester,
      find.byKey(const Key('session-composer-input')),
      fallbackDraft,
    );
    await _enterVisible(
      tester,
      find.byKey(Key('question-freeform-${question.requestId}')),
      '先回答 question',
    );
    await _tapVisible(
      tester,
      find.byKey(Key('question-submit-${question.requestId}')),
    );
    await _waitForVisible(
      tester,
      find.byKey(const Key('session-approval-panel')),
    );

    expect(find.byKey(const Key('session-question-panel')), findsNothing);
    expect(_composerText(tester), fallbackDraft);
    await _tapVisible(
      tester,
      find.byKey(Key('permission-approve-${permission.requestId}')),
    );
    await _waitForGone(tester, find.byKey(const Key('session-composer-chain')));
  });

  testWidgets('MOBILE-V05-05/P4-B：Question 本地状态校验、折叠和新 key 重置', (tester) async {
    final harness = await _openWritableSession(
      tester,
      'composer-question-state-owner@fixture.test',
    );

    await _enterVisible(
      tester,
      find.byKey(const Key('session-composer-input')),
      '触发第一个 question',
    );
    await _tapVisible(
      tester,
      find.byKey(const Key('session-composer-primary-action')),
    );
    await _waitForVisible(
      tester,
      find.byKey(const Key('assistant-streaming-indicator')),
    );

    final sessionId = (await harness.relay.listSessions()).single.id;
    var timeline = (await harness.relay.getSessionSnapshot(
      sessionId,
    )).events.map(SessionTimelineEvent.fromRelayEvent).toList();
    final firstPermission = timeline
        .firstWhere((event) => event.permission != null)
        .permission!;
    final firstQuestion = timeline
        .firstWhere((event) => event.question != null)
        .question!;

    await _tapVisible(
      tester,
      find.byKey(Key('question-submit-${firstQuestion.requestId}')),
    );
    await _waitForVisible(
      tester,
      find.byKey(Key('question-validation-${firstQuestion.requestId}')),
    );
    expect(harness.relay.submittedCommandCount, 1);

    await _enterVisible(
      tester,
      find.byKey(Key('question-freeform-${firstQuestion.requestId}')),
      '第一个 question 的本地草稿',
    );
    await _waitForGone(
      tester,
      find.byKey(Key('question-validation-${firstQuestion.requestId}')),
    );
    await _tapVisible(
      tester,
      find.byKey(Key('question-minimize-${firstQuestion.requestId}')),
    );
    await _waitForVisible(
      tester,
      find.byKey(Key('question-minimized-${firstQuestion.requestId}')),
    );
    await _tapVisible(
      tester,
      find.byKey(Key('question-restore-${firstQuestion.requestId}')),
    );
    await _waitForVisible(
      tester,
      find.byKey(Key('question-freeform-${firstQuestion.requestId}')),
    );
    expect(
      tester
          .widget<TextField>(
            find.byKey(Key('question-freeform-${firstQuestion.requestId}')),
          )
          .controller!
          .text,
      '第一个 question 的本地草稿',
    );

    await _tapVisible(
      tester,
      find.byKey(Key('question-submit-${firstQuestion.requestId}')),
    );
    await _waitForVisible(
      tester,
      find.byKey(const Key('session-approval-panel')),
    );
    await _tapVisible(
      tester,
      find.byKey(Key('permission-approve-${firstPermission.requestId}')),
    );
    await _waitForGone(tester, find.byKey(const Key('session-composer-chain')));
    await _waitForEnabledIconButton(tester, const Key('session-stop-button'));
    await _tapVisible(tester, find.byKey(const Key('session-stop-button')));
    await _waitForVisible(tester, find.text('已停止'));

    await _enterVisible(
      tester,
      find.byKey(const Key('session-composer-input')),
      '触发第二个 question',
    );
    await _tapVisible(
      tester,
      find.byKey(const Key('session-composer-primary-action')),
    );
    await _waitForVisible(
      tester,
      find.byKey(const Key('assistant-streaming-indicator')),
    );
    timeline = (await harness.relay.getSessionSnapshot(
      sessionId,
    )).events.map(SessionTimelineEvent.fromRelayEvent).toList();
    final secondQuestion = timeline
        .where((event) => event.question != null)
        .last
        .question!;
    expect(secondQuestion.requestId, isNot(firstQuestion.requestId));
    await _waitForVisible(
      tester,
      find.byKey(Key('question-freeform-${secondQuestion.requestId}')),
    );
    expect(
      tester
          .widget<TextField>(
            find.byKey(Key('question-freeform-${secondQuestion.requestId}')),
          )
          .controller!
          .text,
      isEmpty,
    );
  });

  testWidgets('MOBILE-V05-05/P4-C：Question skip 与本机 cancel 边界', (tester) async {
    final harness = await _openWritableSession(
      tester,
      'composer-question-skip-owner@fixture.test',
    );

    await _enterVisible(
      tester,
      find.byKey(const Key('session-composer-input')),
      '触发可跳过 question',
    );
    await _tapVisible(
      tester,
      find.byKey(const Key('session-composer-primary-action')),
    );
    await _waitForVisible(
      tester,
      find.byKey(const Key('assistant-streaming-indicator')),
    );

    final sessionId = (await harness.relay.listSessions()).single.id;
    final timeline = (await harness.relay.getSessionSnapshot(
      sessionId,
    )).events.map(SessionTimelineEvent.fromRelayEvent).toList();
    final question = timeline
        .firstWhere((event) => event.question != null)
        .question!;

    await _tapVisible(
      tester,
      find.byKey(Key('question-cancel-${question.requestId}')),
    );
    await _waitForVisible(
      tester,
      find.byKey(Key('question-local-cancelled-${question.requestId}')),
    );
    expect(find.textContaining('未向 Host 发送取消命令'), findsOneWidget);
    expect(harness.relay.submittedCommandCount, 1);

    await _tapVisible(
      tester,
      find.byKey(Key('question-cancel-restore-${question.requestId}')),
    );
    await _waitForVisible(
      tester,
      find.byKey(Key('question-skip-${question.requestId}')),
    );
    await _tapVisible(
      tester,
      find.byKey(Key('question-skip-${question.requestId}')),
    );
    await _waitForVisible(
      tester,
      find.byKey(const Key('session-approval-panel')),
    );

    expect(harness.relay.submittedCommandCount, 2);
    final snapshot = await harness.relay.getSessionSnapshot(sessionId);
    expect(_snapshotContainsLabel(snapshot, '已跳过'), isTrue);
  });

  testWidgets('MOBILE-V05-05/P4-C：Question 提交失败后保留草稿并 re-arm', (tester) async {
    final harness = await _openWritableSession(
      tester,
      'composer-question-retry-owner@fixture.test',
    );

    await _enterVisible(
      tester,
      find.byKey(const Key('session-composer-input')),
      '触发失败重试 question',
    );
    await _tapVisible(
      tester,
      find.byKey(const Key('session-composer-primary-action')),
    );
    await _waitForVisible(
      tester,
      find.byKey(const Key('assistant-streaming-indicator')),
    );

    final sessionId = (await harness.relay.listSessions()).single.id;
    final timeline = (await harness.relay.getSessionSnapshot(
      sessionId,
    )).events.map(SessionTimelineEvent.fromRelayEvent).toList();
    final question = timeline
        .firstWhere((event) => event.question != null)
        .question!;
    const retryDraft = '失败后应该保留的回答';
    await _enterVisible(
      tester,
      find.byKey(Key('question-freeform-${question.requestId}')),
      retryDraft,
    );

    harness.relay.setNetworkAvailable(false);
    await _tapVisible(
      tester,
      find.byKey(Key('question-submit-${question.requestId}')),
    );
    await _waitForVisible(
      tester,
      find.byKey(Key('question-submit-error-${question.requestId}')),
    );
    expect(harness.relay.submittedCommandCount, 1);
    expect(
      tester
          .widget<TextField>(
            find.byKey(Key('question-freeform-${question.requestId}')),
          )
          .controller!
          .text,
      retryDraft,
    );

    harness.relay.setNetworkAvailable(true);
    await _tapVisible(
      tester,
      find.byKey(Key('question-submit-${question.requestId}')),
    );
    await _waitForVisible(
      tester,
      find.byKey(const Key('session-approval-panel')),
    );
    expect(harness.relay.submittedCommandCount, 2);
  });

  testWidgets(
    'MOBILE-V05-01/P1：resident header、view ring 与 composer seat 保持稳定',
    (tester) async {
      final harness = MobileAppHarness();
      await tester.pumpWidget(harness.build());
      await _waitForVisible(
        tester,
        find.byKey(const Key('device-connect-submit')),
      );
      await _registerOwner(tester, 'resident-shell-owner@fixture.test');

      await _tapVisible(tester, find.byKey(const Key('session-new-button')));
      await _waitForVisible(
        tester,
        find.byKey(const Key('new-session-workspace-input')),
      );
      await _tapVisible(
        tester,
        find.byKey(const Key('new-session-create-button')),
      );
      await _waitForVisible(
        tester,
        find.byKey(const Key('session-detail-screen')),
      );
      final sessionId = (await harness.relay.listSessions()).single.id;

      expect(
        find.byKey(const Key('session-conversation-root')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('session-strict-header')), findsOneWidget);
      expect(
        find.byKey(const Key('session-conversation-scroll-owner')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('session-composer-seat')), findsOneWidget);

      await _tapVisible(
        tester,
        find.byKey(const Key('session-acquire-lease-button')),
      );
      await _waitForVisible(tester, find.text('已获得控制权'));
      await _enterVisible(
        tester,
        find.byKey(const Key('session-composer-input')),
        'P1 resident shell 草稿',
      );
      await tester.pump();

      await _tapVisible(
        tester,
        find.byKey(const Key('session-tab-trajectory')),
      );
      await _waitForVisible(
        tester,
        find.byKey(const Key('session-trajectory-view')),
      );
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('session-composer-input')))
            .controller!
            .text,
        'P1 resident shell 草稿',
      );

      await _tapVisible(
        tester,
        find.byKey(const Key('session-detail-back-button')).first,
      );
      await _waitForVisible(
        tester,
        find.byKey(const Key('session-home-screen')),
      );
      await _tapVisible(tester, find.byKey(Key('session-row-$sessionId')));
      await _waitForVisible(
        tester,
        find.byKey(const Key('session-detail-screen')),
      );
      await _waitForVisible(
        tester,
        find.byKey(const Key('session-trajectory-view')),
      );
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('session-composer-input')))
            .controller!
            .text,
        'P1 resident shell 草稿',
      );
    },
  );

  testWidgets('MOBILE-V05-18/P2-C：Chat 工具 Inspect 一次性切到 Trajectory', (
    tester,
  ) async {
    final harness = MobileAppHarness();
    await tester.pumpWidget(harness.build());
    await _waitForVisible(
      tester,
      find.byKey(const Key('device-connect-submit')),
    );
    await _registerOwner(tester, 'inspect-handoff-owner@fixture.test');

    await _tapVisible(tester, find.byKey(const Key('session-new-button')));
    await _waitForVisible(
      tester,
      find.byKey(const Key('new-session-workspace-input')),
    );
    await _enterVisible(
      tester,
      find.byKey(const Key('new-session-workspace-input')),
      'fixture-workspace',
    );
    await _tapVisible(
      tester,
      find.byKey(const Key('new-session-create-button')),
    );
    await _waitForVisible(
      tester,
      find.byKey(const Key('session-detail-screen')),
    );

    await _tapVisible(
      tester,
      find.byKey(const Key('session-acquire-lease-button')),
    );
    await _waitForVisible(tester, find.text('已获得控制权'));
    await _enterVisible(
      tester,
      find.byKey(const Key('session-composer-input')),
      '请生成 P2-C inspect handoff fixture',
    );
    await _tapVisible(
      tester,
      find.byKey(const Key('session-composer-primary-action')),
    );

    final sessionId = (await harness.relay.listSessions()).single.id;
    final timeline = (await harness.relay.getSessionSnapshot(
      sessionId,
    )).events.map(SessionTimelineEvent.fromRelayEvent).toList();
    final tool = timeline.firstWhere(
      (event) => event.kind == SessionTimelineKind.toolActivity,
    );
    expect(tool.toolInput, isNotNull);
    expect(tool.inspectTarget, isNotNull);

    final toolDetails = find.byKey(
      Key('session-tool-details-${tool.sequence}'),
    );
    await _scrollChatUntilVisible(tester, toolDetails);
    await _tapVisible(tester, toolDetails);
    final inspectButton = find.byKey(
      Key('session-tool-inspect-${tool.sequence}'),
    );
    await _scrollChatUntilVisible(tester, inspectButton);
    await _tapVisible(tester, inspectButton);
    await _waitForVisible(
      tester,
      find.byKey(const Key('session-trajectory-inspect-target')),
    );
    expect(find.byKey(const Key('session-trajectory-view')), findsOneWidget);
    expect(find.textContaining(tool.inspectTarget!), findsOneWidget);

    // Inspect target 是一次性 view-store handoff；应用一帧后必须清空，避免 tab 往返重复选中。
    await tester.pump();
    await _waitForGone(
      tester,
      find.byKey(const Key('session-trajectory-inspect-target')),
    );
  });

  testWidgets('MOBILE-07：文件浏览入口打开只读工作区文件页', (tester) async {
    final harness = MobileAppHarness();
    await tester.pumpWidget(harness.build());
    await _waitForVisible(
      tester,
      find.byKey(const Key('device-connect-submit')),
    );
    await _registerOwner(tester, 'files-entry-owner@fixture.test');

    await _tapVisible(tester, find.byKey(const Key('session-new-button')));
    await _waitForVisible(
      tester,
      find.byKey(const Key('new-session-workspace-input')),
    );
    await _tapVisible(
      tester,
      find.byKey(const Key('new-session-create-button')),
    );
    await _waitForVisible(
      tester,
      find.byKey(const Key('session-detail-screen')),
    );

    await _tapVisible(
      tester,
      find.byKey(const Key('session-quick-menu-button')),
    );
    await _waitForVisible(tester, find.byKey(const Key('session-quick-files')));
    await _tapVisible(tester, find.byKey(const Key('session-quick-files')));
    await _waitForVisible(
      tester,
      find.byKey(const Key('workspace-files-screen')),
    );
    await _waitForVisible(
      tester,
      find.byKey(const Key('workspace-files-list')),
    );
  });

  testWidgets('MOBILE-11：goal 文本编辑提交 goal.edit 命令并乐观更新', (tester) async {
    final harness = MobileAppHarness();
    await tester.pumpWidget(harness.build());
    await _waitForVisible(
      tester,
      find.byKey(const Key('device-connect-submit')),
    );
    await _registerOwner(tester, 'goal-edit-owner@fixture.test');

    await _tapVisible(tester, find.byKey(const Key('session-new-button')));
    await _waitForVisible(
      tester,
      find.byKey(const Key('new-session-workspace-input')),
    );
    await _tapVisible(
      tester,
      find.byKey(const Key('new-session-create-button')),
    );
    await _waitForVisible(
      tester,
      find.byKey(const Key('session-detail-screen')),
    );

    // goal 编辑需要当前 lease（与其它写命令一致）。
    await _tapVisible(
      tester,
      find.byKey(const Key('session-acquire-lease-button')),
    );
    await _waitForVisible(tester, find.text('已获得控制权'));

    // 打开编辑对话框，修改目标文本并保存。
    await _waitForVisible(
      tester,
      find.byKey(const Key('session-goal-edit-button')),
    );
    await _tapVisible(
      tester,
      find.byKey(const Key('session-goal-edit-button')),
    );
    await _waitForVisible(tester, find.byKey(const Key('goal-edit-dialog')));
    await _enterVisible(
      tester,
      find.byKey(const Key('goal-edit-input')),
      '先交付回归再优化文案',
    );
    await _tapVisible(tester, find.byKey(const Key('goal-edit-submit')));
    // 目标卡片标题乐观更新。
    await _waitForVisible(tester, find.text('先交付回归再优化文案'));

    final snapshot = await harness.relay.getSessionSnapshot(
      (await harness.relay.listSessions()).single.id,
    );
    expect(
      snapshot.events.any((event) => event.eventType == 'session.goal_edited'),
      isTrue,
    );
  });

  testWidgets('MOBILE-13：状态条展示 Provider 版本与连接态（fail-closed 原因）', (
    tester,
  ) async {
    final harness = MobileAppHarness();
    await tester.pumpWidget(harness.build());
    await _waitForVisible(
      tester,
      find.byKey(const Key('device-connect-submit')),
    );
    await _registerOwner(tester, 'provider-status@fixture.test');

    await _tapVisible(tester, find.byKey(const Key('session-new-button')));
    await _waitForVisible(
      tester,
      find.byKey(const Key('new-session-workspace-input')),
    );
    await _tapVisible(
      tester,
      find.byKey(const Key('new-session-create-button')),
    );
    await _waitForVisible(
      tester,
      find.byKey(const Key('session-detail-screen')),
    );

    // codex fixture 可用且带版本：展示「已连接 · v...」。
    await _waitForVisible(
      tester,
      find.byKey(const Key('session-provider-version-chip')),
    );
    expect(find.textContaining('已连接'), findsOneWidget);

    // 探测失败路径：全部 Provider unavailable -> 状态条 fail-closed 展示。
    harness.relay.providersUnavailable = true;
    final container = ProviderScope.containerOf(
      tester.element(find.byKey(const Key('session-detail-screen'))),
    );
    await container.read(sessionControllerProvider).refreshCapabilities();
    await tester.pump(const Duration(milliseconds: 100));
    await _waitForVisible(
      tester,
      find.byKey(const Key('session-provider-version-chip')),
    );
    expect(find.text('未连接'), findsOneWidget);
    // 失败原因通过 chip 的 Tooltip 表达（白名单 reason）。
    final tooltip = tester.widget<Tooltip>(
      find
          .ancestor(
            of: find.byKey(const Key('session-provider-version-chip')),
            matching: find.byType(Tooltip),
          )
          .first,
    );
    expect(tooltip.message, contains('探测失败'));
  });

  testWidgets('MOBILE-14：duplicate 按 capability fail-closed，details 复制白名单字段', (
    tester,
  ) async {
    final harness = MobileAppHarness();
    await tester.pumpWidget(harness.build());
    await _waitForVisible(
      tester,
      find.byKey(const Key('device-connect-submit')),
    );
    await _registerOwner(tester, 'duplicate-entry@fixture.test');

    await _tapVisible(tester, find.byKey(const Key('session-new-button')));
    await _waitForVisible(
      tester,
      find.byKey(const Key('new-session-workspace-input')),
    );
    await _tapVisible(
      tester,
      find.byKey(const Key('new-session-create-button')),
    );
    await _waitForVisible(
      tester,
      find.byKey(const Key('session-detail-screen')),
    );
    final sessionId = (await harness.relay.listSessions()).single.id;

    // duplicate 未声明能力：菜单项禁用并说明原因。
    await _tapVisible(
      tester,
      find.byKey(const Key('session-quick-menu-button')),
    );
    await _waitForVisible(
      tester,
      find.byKey(const Key('session-quick-duplicate')),
    );
    await _waitForVisible(tester, find.text('Provider 未声明 duplicate 能力'));
    await _tapAway(tester);

    // details 底表复制按钮只处理白名单字段（剪贴板用 mock 通道断言，避免真实平台挂起）。
    final clipboardValues = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') {
            clipboardValues.add((call.arguments as Map)['text'] as String);
          }
          return null;
        });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
    });

    await _tapVisible(
      tester,
      find.byKey(const Key('session-quick-menu-button')),
    );
    await _tapVisible(tester, find.byKey(const Key('session-quick-details')));
    await _waitForVisible(
      tester,
      find.byKey(const Key('session-details-sheet')),
    );
    await _tapVisible(tester, find.byKey(const Key('session-copy-id-button')));
    await _tapVisible(
      tester,
      find.byKey(const Key('session-copy-provider-button')),
    );
    expect(clipboardValues, [sessionId, 'codex']);
  });
}

bool _snapshotContainsText(SessionSnapshot snapshot, String text) {
  return snapshot.events.any((event) {
    final payload = event.envelope['fixture_payload'];
    return payload is Map && payload['text'] == text;
  });
}

bool _snapshotContainsLabel(SessionSnapshot snapshot, String label) {
  return snapshot.events.any((event) {
    final payload = event.envelope['fixture_payload'];
    return payload is Map && payload['label'] == label;
  });
}

Future<MobileAppHarness> _openWritableSession(
  WidgetTester tester,
  String ownerEmail,
) async {
  final harness = MobileAppHarness();
  await tester.pumpWidget(harness.build());
  await _waitForVisible(tester, find.byKey(const Key('device-connect-submit')));
  await _registerOwner(tester, ownerEmail);

  await _tapVisible(tester, find.byKey(const Key('session-new-button')));
  await _waitForVisible(
    tester,
    find.byKey(const Key('new-session-workspace-input')),
  );
  await _enterVisible(
    tester,
    find.byKey(const Key('new-session-workspace-input')),
    'fixture-workspace',
  );
  await _tapVisible(tester, find.byKey(const Key('new-session-create-button')));
  await _waitForVisible(tester, find.byKey(const Key('session-detail-screen')));
  await _tapVisible(
    tester,
    find.byKey(const Key('session-acquire-lease-button')),
  );
  await _waitForVisible(tester, find.text('已获得控制权'));
  return harness;
}

Future<void> _registerOwner(WidgetTester tester, String _) async {
  await _tapVisible(tester, find.byKey(const Key('device-connect-submit')));
  await _waitForVisible(tester, find.byKey(const Key('owner-ready-state')));
}

String _composerText(WidgetTester tester) {
  return tester
      .widget<TextField>(find.byKey(const Key('session-composer-input')))
      .controller!
      .text;
}

Future<void> _pressEnter(WidgetTester tester, {bool shift = false}) async {
  if (shift) {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
  }
  await tester.sendKeyDownEvent(LogicalKeyboardKey.enter);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.enter);
  if (shift) {
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
  }
  await tester.pump(const Duration(milliseconds: 50));
}

/// TextField 光标会让 macOS/live binding 持续产帧；回归只等待下一项用户可见契约。
Future<void> _waitForVisible(
  WidgetTester tester,
  Finder finder, {
  int maxFrames = 80,
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
  // ensureVisible 可能触发滚动/布局；多 pump 几帧让 RenderBox 完成布局与绘制，
  // 否则 hit test 使用陈旧偏移会被遮罩或滚动区吞掉。
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

Future<void> _waitForEnabledIconButton(WidgetTester tester, Key key) async {
  final finder = find.byKey(key);
  for (var frame = 0; frame < 80; frame += 1) {
    await tester.pump(const Duration(milliseconds: 50));
    if (finder.evaluate().isEmpty) continue;
    final button = tester.widget<IconButton>(finder);
    if (button.onPressed != null) return;
  }
  expect(finder, findsOneWidget);
  expect(tester.widget<IconButton>(finder).onPressed, isNotNull);
}

Future<void> _scrollChatUntilVisible(WidgetTester tester, Finder finder) async {
  await tester.scrollUntilVisible(
    finder,
    120,
    scrollable: find.descendant(
      of: find.byKey(const Key('session-chat-view')),
      matching: find.byType(Scrollable),
    ),
    maxScrolls: 24,
  );
  for (var frame = 0; frame < 3; frame += 1) {
    await tester.pump(const Duration(milliseconds: 50));
  }
  expect(finder, findsOneWidget);
}

/// 等待元素完全消失（页面过渡完成后再操作列表，避免 Offstage 阶段命中失败）。
Future<void> _waitForGone(WidgetTester tester, Finder finder) async {
  for (var frame = 0; frame < 60; frame += 1) {
    await tester.pump(const Duration(milliseconds: 50));
    if (finder.evaluate().isEmpty) return;
  }
  expect(finder, findsNothing);
}

/// 点击遮罩关闭菜单/底表：菜单在右上、底表在底部，取二者都覆盖不到的遮罩区域（中部偏上）。
Future<void> _tapAway(WidgetTester tester) async {
  await tester.tapAt(const Offset(400, 150));
  for (var frame = 0; frame < 8; frame += 1) {
    await tester.pump(const Duration(milliseconds: 80));
  }
}
