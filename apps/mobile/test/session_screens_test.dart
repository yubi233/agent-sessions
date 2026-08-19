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

    await _tapVisible(
      tester,
      find.byKey(Key('permission-approve-${permission.requestId}')),
    );
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

Future<void> _registerOwner(WidgetTester tester, String _) async {
  await _tapVisible(tester, find.byKey(const Key('device-connect-submit')));
  await _waitForVisible(tester, find.byKey(const Key('owner-ready-state')));
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
