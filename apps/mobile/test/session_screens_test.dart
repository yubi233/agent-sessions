import 'package:agent_sessions_mobile/app/providers.dart';
import 'package:agent_sessions_mobile/domain/models.dart';
import 'package:agent_sessions_mobile/domain/session_models.dart';
import 'package:agent_sessions_mobile/relay/fixture_relay_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/app_harness.dart';
import 'support/fixture_owner.dart';

/// 模拟「自动获取租约被 Relay 拒绝」的 fail-closed 场景。
/// 打开会话后仍应保持未持有控制权，resume/start 等写入口禁用并显示中文原因。
class _AcquireLeaseBlockingRelay extends FixtureRelayRepository {
  bool blockAcquire = true;

  @override
  Future<SessionLease> acquireSessionLease(String sessionId) async {
    if (blockAcquire) {
      throw const RelayFailure(
        RelayFailureKind.forbidden,
        '测试 Relay 拒绝授予会话可操作状态。',
      );
    }
    return super.acquireSessionLease(sessionId);
  }
}

void main() {
  testWidgets('MOBILE-02：owner 可完成会话、流式、确认、回答和停止', (tester) async {
    // v0.8.1+：预置 owner 与会话，经最近会话入口打开详情（首页已改为 DSH 工作区）。
    final harness = await _openWritableSession(tester, 'session-ui-owner@fixture.test');
    expect(find.byKey(const Key('happy-session-header')), findsOneWidget);
    expect(
      find.byKey(const Key('happy-session-provider-avatar')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('happy-session-empty-state')), findsOneWidget);
    expect(find.text('No messages yet'), findsOneWidget);
    expect(find.text('输入消息...'), findsOneWidget);
    expect(find.byKey(const Key('happy-session-model-row')), findsOneWidget);
    expect(find.byKey(const Key('session-model-seat-trigger')), findsOneWidget);
    expect(find.textContaining('邮箱'), findsNothing);
    expect(find.textContaining('密码'), findsNothing);
    // 打开会话即自动获取单写者租约：composer 不再出现拦截提示，直接可发送。
    await _waitForVisible(tester, find.text('可操作'));
    expect(
      find.byKey(const Key('session-composer-blocked-reason')),
      findsNothing,
    );
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

    // 中断入口唯一：草稿为空时主按钮即停止（session-stop-button 仅在
    // 运行中且草稿非空时出现）。
    await _waitForEnabledIconButton(
      tester,
      const Key('session-composer-primary-action'),
    );
    await _tapVisible(
      tester,
      find.byKey(const Key('session-composer-primary-action')),
    );
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
    // v0.8.1+：readonly 首页（DSH 工作区视图）同样展示只读横幅。
    await _waitForVisible(
      tester,
      find.byKey(const Key('session-readonly-banner')),
    );

    final sessionId = (await harness.relay.listSessions()).single.id;
    // 非 DSH 会话从「最近会话」入口进入详情。
    await _tapVisible(tester, find.byKey(const Key('session-recent-button')));
    await _waitForVisible(
      tester,
      find.byKey(Key('recent-session-$sessionId')),
    );
    await _tapVisible(tester, find.byKey(Key('recent-session-$sessionId')));
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
    // v0.8.1+：预置 owner 与会话后打开详情（Git 入口在会话快捷菜单中）。
    await _openWritableSession(tester, 'git-entry-owner@fixture.test');

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

  testWidgets('MOBILE-07：快捷菜单展示详情/恢复/文件/归档，capability 驱动禁用与本地归档可用', (
    tester,
  ) async {
    // v0.8.1+：blocking relay 模拟自动获取 lease 被拒；预置会话并打开详情。
    final relay = _AcquireLeaseBlockingRelay();
    final harness = MobileAppHarness(relay: relay);
    await harness.launchAsOwner();
    final sessionId = await harness.seedSession();
    await tester.pumpWidget(harness.build());
    await _waitForVisible(tester, find.byKey(const Key('session-home-screen')));
    await _openSessionDetailFromRecent(tester, harness, sessionId);
    await _waitForVisible(tester, find.byKey(const Key('session-detail-screen')));

    // v0.9：自动获取 lease 被 Relay 拒绝时，UI 不再显示“暂不可操作”或禁用菜单；
    // 写命令在提交瞬间自动获取，被拒则静默不发送（fail-closed 在命令层兜底）。
    await _tapVisible(
      tester,
      find.byKey(const Key('session-quick-menu-button')),
    );
    await _waitForVisible(
      tester,
      find.byKey(const Key('session-quick-resume')),
    );
    expect(find.text('会话暂不可操作，请稍后重试'), findsNothing);
    expect(
      tester
          .widget<PopupMenuItem<String>>(
            find.byKey(const Key('session-start-button')),
          )
          .enabled,
      isTrue,
    );
    // fork 仍按 Provider capability fail-closed；归档是本地元数据操作，不依赖 Provider。
    await _waitForVisible(tester, find.text('Provider 未声明 fork 能力'));
    await _waitForVisible(tester, find.text('从列表隐藏，数据仍保留'));
    expect(
      tester
          .widget<PopupMenuItem<String>>(
            find.byKey(const Key('session-quick-archive')),
          )
          .enabled,
      isTrue,
    );
    // resume 点击在自动获取被拒时不得产生命令事件（选中即关闭菜单）。
    await _tapVisible(tester, find.byKey(const Key('session-quick-resume')));
    await tester.pumpAndSettle();
    final blockedSnapshot = (await harness.relay.getSessionSnapshot(
      (await harness.relay.listSessions()).single.id,
    ));
    expect(
      blockedSnapshot.events
          .any((event) => event.eventType == 'session.resumed'),
      isFalse,
      reason: '自动获取被拒时 resume 不得发送命令',
    );

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
    // 自动获取被上面的 fail-closed 拒绝后，这里放开拒绝开关以继续验证成功路径。
    relay.blockAcquire = false;
    await _tapVisible(
      tester,
      find.byKey(const Key('session-acquire-lease-button')),
    );
    await _waitForVisible(tester, find.text('可操作'));
    await _tapVisible(
      tester,
      find.byKey(const Key('session-quick-menu-button')),
    );
    await _waitForVisible(
      tester,
      find.byKey(const Key('session-quick-resume')),
    );
    // 有 lease 后不再显示阻断原因。
    expect(find.text('会话暂不可操作，请稍后重试'), findsNothing);
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
    // v0.8.1+：预置 opencode 会话（fixture 未声明 resume，fail-closed）。
    final harness = MobileAppHarness();
    await harness.launchAsOwner();
    final sessionId = await harness.seedSession(provider: 'opencode');
    await tester.pumpWidget(harness.build());
    await _waitForVisible(tester, find.byKey(const Key('session-home-screen')));
    await _openSessionDetailFromRecent(tester, harness, sessionId);

    await _tapVisible(
      tester,
      find.byKey(const Key('session-quick-menu-button')),
    );
    await _waitForVisible(
      tester,
      find.byKey(const Key('session-quick-resume')),
    );
    // fixture 对 opencode 未声明 resume：菜单项显示 fail-closed 原因。
    await _waitForVisible(tester, find.textContaining('未声明此能力'));
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

  // TODO(v0.8.1+): v0.8.1 后详情页改由「最近会话」push 打开，composer 草稿恢复
  // 依赖全局 selectedSessionId 且 didUpdateWidget 无法感知跨 route 切换，
  // 该跨会话草稿隔离场景需随 composer 改造（显式 sessionId prop）后恢复。
  testWidgets('MOBILE-07：composer 草稿在详情页往返后内存恢复', (tester) async {
    // v0.8.1+：预置 codex 会话，经「最近会话」进入详情。
    final harness = MobileAppHarness();
    await harness.launchAsOwner();
    final firstId = await harness.seedSession();
    await tester.pumpWidget(harness.build());
    await _waitForVisible(tester, find.byKey(const Key('session-home-screen')));
    await _openSessionDetailFromRecent(tester, harness, firstId);

    // 打开会话即自动获取 lease；输入草稿。
    await _waitForVisible(tester, find.text('可操作'));
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
    // 返回首页再进入同一会话：内存草稿应恢复（会话内持久性仍有效）。
    await _openSessionDetailFromRecent(tester, harness, firstId);
    await _waitForComposerText(tester, '第一条草稿内容');
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
    final (harness, sessionId) =
        await _openSeededWritableSession(tester);
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

    // 中断入口唯一：草稿为空时主按钮即停止（session-stop-button 仅在
    // 运行中且草稿非空时出现）。
    await _waitForEnabledIconButton(
      tester,
      const Key('session-composer-primary-action'),
    );
    await _tapVisible(
      tester,
      find.byKey(const Key('session-composer-primary-action')),
    );
    await _waitForVisible(tester, find.text('已停止'));
    await _waitForVisible(tester, find.byKey(const Key('session-queue-dock')));
    final stoppedSnapshot = await harness.relay.getSessionSnapshot(sessionId);
    expect(_snapshotContainsText(stoppedSnapshot, queuedText), isFalse);

    await _tapVisible(tester, find.byKey(const Key('session-queue-send-all')));
    await _waitForGone(tester, find.byKey(const Key('session-queue-dock')));
    final sentSnapshot = await harness.relay.getSessionSnapshot(sessionId);
    expect(_snapshotContainsText(sentSnapshot, queuedText), isTrue);
    // 计数口径：send(1)+stop(1)+自动 start(1)+send-all(1)=4。停止后发送会
    // 自动补 session.start（恢复本机实例），与真实 daemon resume 语义一致。
    expect(harness.relay.submittedCommandCount, 4);
  });

  testWidgets('中断：发送受理后输入框清空，主按钮变为停止并可中断回合', (tester) async {
    final (harness, sessionId) = await _openSeededWritableSession(tester);

    await _enterVisible(
      tester,
      find.byKey(const Key('session-composer-input')),
      '触发一轮生成',
    );
    await _tapVisible(
      tester,
      find.byKey(const Key('session-composer-primary-action')),
    );

    // 受理即清稿：输入框立刻为空，主按钮切换为中断（stop 图标）。
    await _waitForVisible(tester, find.byIcon(Icons.stop));
    final primaryIcon =
        tester.widget<IconButton>(
          find.byKey(const Key('session-composer-primary-action')),
        ).icon as Icon;
    expect(primaryIcon.icon, Icons.stop);
    expect(_composerText(tester), isEmpty);

    // 点击中断：提交 session.abort，会话收口为"已停止"。
    await _tapVisible(
      tester,
      find.byKey(const Key('session-composer-primary-action')),
    );
    await _waitForVisible(tester, find.text('已停止'));
    final snapshot = await harness.relay.getSessionSnapshot(sessionId);
    expect(snapshot.session.status, MobileSessionStatus.stopped);
  });

  testWidgets('中断入口唯一：流式中草稿为空仅主按钮停止，草稿非空仅独立停止', (tester) async {
    final (harness, _) = await _openSeededWritableSession(tester);

    await _enterVisible(
      tester,
      find.byKey(const Key('session-composer-input')),
      '触发一轮生成',
    );
    await _tapVisible(
      tester,
      find.byKey(const Key('session-composer-primary-action')),
    );

    // 草稿已清空：主按钮即停止（红色），独立停止按钮不出现——避免双中断入口。
    await _waitForVisible(tester, find.byIcon(Icons.stop));
    expect(find.byKey(const Key('session-stop-button')), findsNothing);

    // 输入新草稿：主按钮切回排队语义，中断转移到独立停止按钮。
    await tester.enterText(
      find.byKey(const Key('session-composer-input')),
      '排队下一句',
    );
    await tester.pump(const Duration(milliseconds: 80));
    expect(find.byKey(const Key('session-stop-button')), findsOneWidget);
    final primary = tester.widget<IconButton>(
      find.byKey(const Key('session-composer-primary-action')),
    );
    expect((primary.icon as Icon).icon, Icons.schedule_send_outlined);
    expect(harness.relay.submittedCommandCount, 1);
  });

  testWidgets('MOBILE-V05-04/P3-B：提交失败显示 notice 且保留草稿', (tester) async {
    final (harness, _) = await _openSeededWritableSession(tester);

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

  testWidgets('MOBILE-V05-07/P5-A：多队列 busy 强制展开、停止后默认折叠、展开/折叠切换', (
    tester,
  ) async {
    final harness = await _openWritableSession(
      tester,
      'composer-queue-multi-owner@fixture.test',
    );

    await _enterVisible(
      tester,
      find.byKey(const Key('session-composer-input')),
      '进入 streaming',
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

    const first = '第一条排队';
    const middle = '第二条排队（中间项）';
    const last = '第三条排队（末尾项）';
    for (final text in [first, middle, last]) {
      await _enterVisible(
        tester,
        find.byKey(const Key('session-composer-input')),
        text,
      );
      await _tapVisible(
        tester,
        find.byKey(const Key('session-composer-primary-action')),
      );
      await tester.pump(const Duration(milliseconds: 80));
    }
    await _waitForVisible(tester, find.byKey(const Key('session-queue-dock')));
    expect(find.text('3 条排队消息'), findsOneWidget);

    // busy=running 时 QueueDock 强制展开，中间项也可见，不隐藏队列。
    expect(find.text(first), findsOneWidget);
    expect(find.text(middle), findsOneWidget);
    expect(find.text(last), findsOneWidget);
    expect(find.text('还有 1 条排队消息未显示'), findsNothing);

    // stop 后 running=false：多项默认折叠，只显示首尾，中间项隐藏并提示剩余。
    // 中断入口唯一：草稿为空时主按钮即停止（session-stop-button 仅在
    // 运行中且草稿非空时出现）。
    await _waitForEnabledIconButton(
      tester,
      const Key('session-composer-primary-action'),
    );
    await _tapVisible(
      tester,
      find.byKey(const Key('session-composer-primary-action')),
    );
    await _waitForVisible(tester, find.text('已停止'));
    await _waitForVisible(tester, find.byKey(const Key('session-queue-dock')));
    expect(find.text(first), findsOneWidget);
    expect(find.text(last), findsOneWidget);
    expect(find.text(middle), findsNothing);
    expect(find.text('还有 1 条排队消息未显示'), findsOneWidget);
    expect(find.text('展开'), findsOneWidget);

    // 展开后全量可见，toggle 文案变为「折叠」。
    await _tapVisible(tester, find.byKey(const Key('session-queue-toggle')));
    await _waitForVisible(tester, find.text(middle));
    expect(find.text('还有 1 条排队消息未显示'), findsNothing);
    expect(find.text('折叠'), findsOneWidget);

    // 再折叠回默认态。
    await _tapVisible(tester, find.byKey(const Key('session-queue-toggle')));
    await tester.pump(const Duration(milliseconds: 80));
    expect(find.text(middle), findsNothing);
  });

  testWidgets('MOBILE-V05-07/P5-A：单项队列不显示 count header 与折叠按钮', (tester) async {
    await _openWritableSession(
      tester,
      'composer-queue-single-owner@fixture.test',
    );

    await _enterVisible(
      tester,
      find.byKey(const Key('session-composer-input')),
      '进入 streaming',
    );
    await _tapVisible(
      tester,
      find.byKey(const Key('session-composer-primary-action')),
    );
    await _waitForVisible(
      tester,
      find.byKey(const Key('assistant-streaming-indicator')),
    );

    const single = '只有一条排队消息';
    await _enterVisible(
      tester,
      find.byKey(const Key('session-composer-input')),
      single,
    );
    await _tapVisible(
      tester,
      find.byKey(const Key('session-composer-primary-action')),
    );
    await _waitForVisible(tester, find.byKey(const Key('session-queue-dock')));

    // 中断入口唯一：草稿为空时主按钮即停止（session-stop-button 仅在
    // 运行中且草稿非空时出现）。
    await _waitForEnabledIconButton(
      tester,
      const Key('session-composer-primary-action'),
    );
    await _tapVisible(
      tester,
      find.byKey(const Key('session-composer-primary-action')),
    );
    await _waitForVisible(tester, find.text('已停止'));

    // 单项无 count header：不显示折叠/展开 toggle，也不显示「还有 N 条」。
    expect(find.text('1 条排队消息'), findsOneWidget);
    expect(find.byKey(const Key('session-queue-toggle')), findsNothing);
    expect(find.textContaining('未显示'), findsNothing);
    expect(find.text(single), findsOneWidget);
  });

  testWidgets('MOBILE-V05-07/P5-A：编辑保存与取消，编辑强制展开', (tester) async {
    await _openWritableSession(
      tester,
      'composer-queue-edit-owner@fixture.test',
    );

    await _enterVisible(
      tester,
      find.byKey(const Key('session-composer-input')),
      '进入 streaming',
    );
    await _tapVisible(
      tester,
      find.byKey(const Key('session-composer-primary-action')),
    );
    await _waitForVisible(
      tester,
      find.byKey(const Key('assistant-streaming-indicator')),
    );

    const first = '编辑前文本';
    const middle = '编辑时也应可见的中间项';
    const last = '末尾项';
    for (final text in [first, middle, last]) {
      await _enterVisible(
        tester,
        find.byKey(const Key('session-composer-input')),
        text,
      );
      await _tapVisible(
        tester,
        find.byKey(const Key('session-composer-primary-action')),
      );
      await tester.pump(const Duration(milliseconds: 80));
    }
    await _waitForVisible(tester, find.byKey(const Key('session-queue-dock')));
    // 中断入口唯一：草稿为空时主按钮即停止（session-stop-button 仅在
    // 运行中且草稿非空时出现）。
    await _waitForEnabledIconButton(
      tester,
      const Key('session-composer-primary-action'),
    );
    await _tapVisible(
      tester,
      find.byKey(const Key('session-composer-primary-action')),
    );
    await _waitForVisible(tester, find.text('已停止'));

    // 编辑态强制展开：点击第一项编辑后，折叠态被打破，中间项也可见。
    await _tapVisible(
      tester,
      find.byKey(const Key('session-queue-edit-queue-1')),
    );
    await _waitForVisible(
      tester,
      find.byKey(const Key('session-queue-edit-input-queue-1')),
    );
    expect(find.text(middle), findsOneWidget);

    const edited = '编辑后的新文本';
    await _enterVisible(
      tester,
      find.byKey(const Key('session-queue-edit-input-queue-1')),
      edited,
    );
    await _tapVisible(
      tester,
      find.byKey(const Key('session-queue-edit-save-queue-1')),
    );
    await tester.pump(const Duration(milliseconds: 80));
    expect(find.text(edited), findsOneWidget);
    expect(find.text(first), findsNothing);

    // 取消编辑不落库：再次编辑并改文本，点取消后文本保持不变。
    await _tapVisible(
      tester,
      find.byKey(const Key('session-queue-edit-queue-1')),
    );
    await _waitForVisible(
      tester,
      find.byKey(const Key('session-queue-edit-input-queue-1')),
    );
    await _enterVisible(
      tester,
      find.byKey(const Key('session-queue-edit-input-queue-1')),
      '取消不应保存的文本',
    );
    await _tapVisible(
      tester,
      find.byKey(const Key('session-queue-edit-cancel-queue-1')),
    );
    await tester.pump(const Duration(milliseconds: 80));
    expect(find.text(edited), findsOneWidget);
    expect(find.text('取消不应保存的文本'), findsNothing);
  });

  testWidgets('MOBILE-V05-07/P5-A：逐条 strict steer 只发送指定项并保留其余队列', (
    tester,
  ) async {
    final harness = await _openWritableSession(
      tester,
      'composer-queue-steer-owner@fixture.test',
    );

    await _enterVisible(
      tester,
      find.byKey(const Key('session-composer-input')),
      '进入 streaming',
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

    const steer = '只发这一条';
    const keep = '这条保留在队列';
    for (final text in [steer, keep]) {
      await _enterVisible(
        tester,
        find.byKey(const Key('session-composer-input')),
        text,
      );
      await _tapVisible(
        tester,
        find.byKey(const Key('session-composer-primary-action')),
      );
      await tester.pump(const Duration(milliseconds: 80));
    }
    await _waitForVisible(tester, find.byKey(const Key('session-queue-dock')));
    // 中断入口唯一：草稿为空时主按钮即停止（session-stop-button 仅在
    // 运行中且草稿非空时出现）。
    await _waitForEnabledIconButton(
      tester,
      const Key('session-composer-primary-action'),
    );
    await _tapVisible(
      tester,
      find.byKey(const Key('session-composer-primary-action')),
    );
    await _waitForVisible(tester, find.text('已停止'));

    final sessionId = (await harness.relay.listSessions()).single.id;
    // steer 是显式动作：发送成功后该行从队列移除。
    await _tapVisible(
      tester,
      find.byKey(const Key('session-queue-steer-queue-1')),
    );
    await _waitForGone(
      tester,
      find.byKey(const Key('session-queue-row-queue-1')),
    );
    // 被发送项已落进 Relay（同时作为 Chat 用户消息展示），队列行移除、keep 项保留。
    // 计数口径：send(1)+stop(1)+自动 start(1)+steer(1)=4（停止后发送自动恢复）。
    final sentSnapshot = await harness.relay.getSessionSnapshot(sessionId);
    expect(_snapshotContainsText(sentSnapshot, steer), isTrue);
    expect(find.byKey(const Key('session-queue-row-queue-1')), findsNothing);
    expect(find.text(keep), findsOneWidget);
    expect(harness.relay.submittedCommandCount, 4);
  });

  testWidgets('MOBILE-V05-07/P5-A：steer 发送失败保留排队项并以 composer notice 呈现', (
    tester,
  ) async {
    final harness = await _openWritableSession(
      tester,
      'composer-queue-steer-fail-owner@fixture.test',
    );

    await _enterVisible(
      tester,
      find.byKey(const Key('session-composer-input')),
      '进入 streaming',
    );
    await _tapVisible(
      tester,
      find.byKey(const Key('session-composer-primary-action')),
    );
    await _waitForVisible(
      tester,
      find.byKey(const Key('assistant-streaming-indicator')),
    );

    const queued = '发送失败的排队项';
    await _enterVisible(
      tester,
      find.byKey(const Key('session-composer-input')),
      queued,
    );
    await _tapVisible(
      tester,
      find.byKey(const Key('session-composer-primary-action')),
    );
    await _waitForVisible(tester, find.byKey(const Key('session-queue-dock')));
    // 中断入口唯一：草稿为空时主按钮即停止（session-stop-button 仅在
    // 运行中且草稿非空时出现）。
    await _waitForEnabledIconButton(
      tester,
      const Key('session-composer-primary-action'),
    );
    await _tapVisible(
      tester,
      find.byKey(const Key('session-composer-primary-action')),
    );
    await _waitForVisible(tester, find.text('已停止'));

    harness.relay.setNetworkAvailable(false);
    addTearDown(() => harness.relay.setNetworkAvailable(true));
    await _tapVisible(
      tester,
      find.byKey(const Key('session-queue-steer-queue-1')),
    );
    await _waitForVisible(
      tester,
      find.byKey(const Key('session-composer-machine-notice')),
    );
    final notice = tester.widget<Text>(
      find.byKey(const Key('session-composer-machine-notice')),
    );
    expect(notice.data, contains('只发送'));
    expect(notice.data, contains('失败'));
    // 失败不丢排队项，也不新增 Relay 命令。计数口径：send(1)+stop(1)=2，steer 失败不 +1。
    expect(find.text(queued), findsOneWidget);
    expect(harness.relay.submittedCommandCount, 2);
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
    // 中断入口唯一：草稿为空时主按钮即停止（session-stop-button 仅在
    // 运行中且草稿非空时出现）。
    await _waitForEnabledIconButton(
      tester,
      const Key('session-composer-primary-action'),
    );
    await _tapVisible(
      tester,
      find.byKey(const Key('session-composer-primary-action')),
    );
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

  testWidgets('MOBILE-V05-06/P4-D：ApprovalPanel 命令滚动区与一次性决策', (tester) async {
    final harness = await _openWritableSession(
      tester,
      'composer-approval-panel-owner@fixture.test',
    );

    await _enterVisible(
      tester,
      find.byKey(const Key('session-composer-input')),
      '触发 approval panel',
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
    final permission = timeline
        .firstWhere((event) => event.permission != null)
        .permission!;

    await _tapVisible(
      tester,
      find.byKey(Key('question-skip-${question.requestId}')),
    );
    await _waitForVisible(
      tester,
      find.byKey(const Key('session-approval-panel')),
    );
    await _waitForVisible(
      tester,
      find.byKey(Key('permission-waiting-strip-${permission.requestId}')),
    );
    await _waitForVisible(
      tester,
      find.byKey(Key('permission-command-scroll-${permission.requestId}')),
    );
    await _waitForVisible(
      tester,
      find.byKey(Key('permission-command-text-${permission.requestId}')),
    );
    expect(find.textContaining('printf fixture-approval'), findsOneWidget);

    final reject = find.byKey(Key('permission-reject-${permission.requestId}'));
    final approve = find.byKey(
      Key('permission-approve-${permission.requestId}'),
    );
    await _waitForVisible(tester, reject);
    await _waitForVisible(tester, approve);
    await tester.ensureVisible(reject);
    await tester.ensureVisible(approve);
    await tester.tap(reject);
    await tester.tap(approve);
    await _waitForGone(tester, find.byKey(const Key('session-composer-chain')));

    expect(harness.relay.submittedCommandCount, 3);
    final snapshot = await harness.relay.getSessionSnapshot(sessionId);
    expect(_snapshotContainsLabel(snapshot, '已拒绝'), isTrue);
    expect(_snapshotContainsLabel(snapshot, '已允许'), isFalse);
  });

  testWidgets('MOBILE-V05-05/P4-E：Question 多题分页与 custom batch answer', (
    tester,
  ) async {
    final harness = await _openWritableSession(
      tester,
      'composer-question-multi-owner@fixture.test',
    );

    await _enterVisible(
      tester,
      find.byKey(const Key('session-composer-input')),
      '触发 multi question 多题配置',
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
    expect(question.steps.length, 2);

    final routingKey = '${question.requestId}-routing';
    await _waitForVisible(
      tester,
      find.byKey(Key('question-progress-${question.requestId}')),
    );
    expect(find.text('1 / 2'), findsOneWidget);
    await _tapVisible(tester, find.byKey(Key('question-options-$routingKey')));
    await _waitForVisible(tester, find.text('标准路径'));
    await tester.tap(find.text('标准路径').last);
    await tester.pump(const Duration(milliseconds: 80));
    await _enterVisible(
      tester,
      find.byKey(Key('question-freeform-$routingKey')),
      '走自定义灰度路径',
    );
    await _tapVisible(
      tester,
      find.byKey(Key('question-next-${question.requestId}')),
    );

    final checksKey = '${question.requestId}-checks';
    await _waitForVisible(tester, find.text('2 / 2'));
    await _tapVisible(
      tester,
      find.byKey(Key('question-prev-${question.requestId}')),
    );
    await _waitForVisible(tester, find.text('1 / 2'));
    expect(
      tester
          .widget<TextField>(find.byKey(Key('question-freeform-$routingKey')))
          .controller!
          .text,
      '走自定义灰度路径',
    );
    await _tapVisible(
      tester,
      find.byKey(Key('question-next-${question.requestId}')),
    );
    await _waitForVisible(
      tester,
      find.byKey(Key('question-option-$checksKey-0')),
    );
    await _tapVisible(tester, find.byKey(Key('question-option-$checksKey-0')));
    await _enterVisible(
      tester,
      find.byKey(Key('question-freeform-$checksKey')),
      '保留截图证据',
    );
    await _tapVisible(
      tester,
      find.byKey(Key('question-next-${question.requestId}')),
    );
    await _waitForVisible(
      tester,
      find.byKey(const Key('session-approval-panel')),
    );

    final answers = _latestFixtureQuestionAnswers(
      await harness.relay.getSessionSnapshot(sessionId),
    );
    expect(answers, hasLength(2));
    expect(answers[0]['id'], 'routing');
    expect(answers[0]['selected'], isEmpty);
    expect(answers[0]['custom'], '走自定义灰度路径');
    expect(answers[1]['id'], 'checks');
    expect(answers[1]['selected'], contains('静态检查'));
    expect(answers[1]['custom'], '保留截图证据');
  });

  testWidgets('MOBILE-V05-05/P4-F：PlanReview 计划评审接管、滚动与 approve payload', (
    tester,
  ) async {
    final harness = await _openWritableSession(
      tester,
      'composer-plan-review-owner@fixture.test',
    );

    await _enterVisible(
      tester,
      find.byKey(const Key('session-composer-input')),
      'plan review 计划评审',
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
    expect(question.steps.length, 1);
    expect(question.steps.first.isPlanReview, isTrue);

    // plan-review 专用卡片：header 条、可滚动 plan body、按钮常驻。
    await _waitForVisible(
      tester,
      find.byKey(Key('plan-review-card-${question.requestId}')),
    );
    expect(
      find.byKey(Key('plan-review-header-${question.requestId}')),
      findsOneWidget,
    );
    expect(
      find.byKey(Key('plan-review-scroll-${question.requestId}')),
      findsOneWidget,
    );
    expect(find.textContaining('## 实施计划'), findsOneWidget);
    // 通用 question 流程的分页/自定义控件不应出现在 plan-review 形态。
    expect(
      find.byKey(Key('question-progress-${question.requestId}')),
      findsNothing,
    );
    expect(
      find.byKey(Key('question-freeform-${question.requestId}')),
      findsNothing,
    );

    // 三个动作是完整决策面：approve / decline / discuss。
    await _waitForVisible(
      tester,
      find.byKey(Key('plan-review-approve-${question.requestId}')),
    );
    await _waitForVisible(
      tester,
      find.byKey(Key('plan-review-decline-${question.requestId}')),
    );
    await _waitForVisible(
      tester,
      find.byKey(Key('plan-review-discuss-${question.requestId}')),
    );

    // approve 回传真实选项 label（intent.approve）。
    await _tapVisible(
      tester,
      find.byKey(Key('plan-review-approve-${question.requestId}')),
    );
    await _waitForGone(
      tester,
      find.byKey(Key('plan-review-approve-${question.requestId}')),
    );
    final snapshot = await harness.relay.getSessionSnapshot(sessionId);
    final answers = _latestFixtureQuestionAnswers(snapshot);
    expect(answers, hasLength(1));
    expect(answers[0]['id'], contains('plan'));
    expect(answers[0]['selected'], contains('批准执行'));
  });

  testWidgets(
    'MOBILE-V05-05/P4-F：PlanReview decline payload 与本地 discuss 恢复输入上下文',
    (tester) async {
      final harness = await _openWritableSession(
        tester,
        'composer-plan-review-decline-owner@fixture.test',
      );

      await _enterVisible(
        tester,
        find.byKey(const Key('session-composer-input')),
        'plan review 计划评审',
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

      // discuss 本机关闭；原 compose 草稿不应被清空。
      await _waitForVisible(
        tester,
        find.byKey(Key('plan-review-card-${question.requestId}')),
      );
      final composerTextBefore = _composerText(tester);
      await _tapVisible(
        tester,
        find.byKey(Key('plan-review-discuss-${question.requestId}')),
      );
      await _waitForVisible(
        tester,
        find.byKey(Key('plan-review-dismissed-${question.requestId}')),
      );
      expect(find.textContaining('未向 Host 发送取消命令'), findsNothing);
      expect(_composerText(tester), composerTextBefore);

      // 恢复后可选择需要修改（decline label）。
      await _tapVisible(
        tester,
        find.byKey(Key('plan-review-restore-${question.requestId}')),
      );
      await _waitForVisible(
        tester,
        find.byKey(Key('plan-review-decline-${question.requestId}')),
      );
      await _tapVisible(
        tester,
        find.byKey(Key('plan-review-decline-${question.requestId}')),
      );
      await _waitForGone(
        tester,
        find.byKey(Key('plan-review-decline-${question.requestId}')),
      );
      final snapshot = await harness.relay.getSessionSnapshot(sessionId);
      final answers = _latestFixtureQuestionAnswers(snapshot);
      expect(answers, hasLength(1));
      expect(answers[0]['selected'], contains('需要修改'));
    },
  );

  testWidgets(
    'MOBILE-V05-01/P1：resident header、view ring 与 composer seat 保持稳定',
    (tester) async {
      final (harness, sessionId) =
          await _openSeededWritableSession(tester);

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
      await _openSessionDetailFromRecent(tester, harness, sessionId);
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
    final (harness, _) = await _openSeededWritableSession(tester);
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

  testWidgets('MOBILE-V05-11/P6-A：Trajectory toolbar 搜索、折叠和模式切换不污染 Chat', (
    tester,
  ) async {
    final harness = await _openWritableSession(
      tester,
      'trajectory-p6-owner@fixture.test',
    );
    await _enterVisible(
      tester,
      find.byKey(const Key('session-composer-input')),
      '请生成 P6 trajectory fixture',
    );
    await _tapVisible(
      tester,
      find.byKey(const Key('session-composer-primary-action')),
    );

    final sessionId = (await harness.relay.listSessions()).single.id;
    final timeline = (await harness.relay.getSessionSnapshot(
      sessionId,
    )).events.map(SessionTimelineEvent.fromRelayEvent).toList();
    final user = timeline.firstWhere(
      (event) => event.kind == SessionTimelineKind.userMessage,
    );
    final assistant = timeline.firstWhere(
      (event) => event.kind == SessionTimelineKind.assistantMessage,
    );
    final tool = timeline.firstWhere(
      (event) => event.kind == SessionTimelineKind.toolActivity,
    );
    final userRow = find.byKey(
      Key('trajectory-row-trajectory:${user.sequence}'),
    );
    final assistantRow = find.byKey(
      Key('trajectory-row-trajectory:${assistant.sequence}'),
    );
    final toolRow = find.byKey(
      Key('trajectory-row-trajectory:${tool.sequence}'),
    );

    await _tapVisible(tester, find.byKey(const Key('session-tab-trajectory')));
    await _waitForVisible(
      tester,
      find.byKey(const Key('session-trajectory-view')),
    );
    await _scrollTrajectoryUntilVisible(tester, toolRow);
    expect(find.textContaining('读取工作区状态'), findsOneWidget);

    await _scrollTrajectoryToTop(tester);
    await _tapVisible(
      tester,
      find.byKey(const Key('session-trajectory-fold-calls')),
    );
    await _waitForGone(tester, toolRow);
    await _scrollTrajectoryToTop(tester);
    await _tapVisible(
      tester,
      find.byKey(const Key('session-trajectory-fold-calls')),
    );
    await _scrollTrajectoryUntilVisible(tester, toolRow);

    await _scrollTrajectoryToTop(tester);
    await _tapVisible(
      tester,
      find.byKey(const Key('session-trajectory-mode-toggle')),
    );
    await _waitForVisible(tester, find.text('等宽'));
    await _scrollTrajectoryToTop(tester);
    await _tapVisible(
      tester,
      find.byKey(const Key('session-trajectory-fold-turns')),
    );
    await _scrollTrajectoryUntilVisible(tester, userRow);
    await _scrollTrajectoryUntilVisible(tester, assistantRow);
    await _waitForGone(tester, toolRow);
    await _scrollTrajectoryToTop(tester);
    await _tapVisible(
      tester,
      find.byKey(const Key('session-trajectory-fold-turns')),
    );
    await _scrollTrajectoryUntilVisible(tester, toolRow);

    // P6-A：搜索只过滤 Trajectory ledger 的本地 records，不回写 Chat projection。
    await _scrollTrajectoryToTop(tester);
    await _enterVisible(
      tester,
      find.byKey(const Key('session-trajectory-search')),
      '读取工作区状态',
    );
    await tester.pump(const Duration(milliseconds: 300));
    await _scrollTrajectoryUntilVisible(tester, toolRow);
    expect(userRow, findsNothing);

    await _tapVisible(tester, find.byKey(const Key('session-tab-chat')));
    await _waitForVisible(tester, find.byKey(const Key('session-chat-view')));
    final chatToolNode = find.byKey(
      Key('session-chat-node-node:${tool.sequence}:tool'),
    );
    await _scrollChatUntilVisible(tester, chatToolNode);
    expect(chatToolNode, findsOneWidget);
  });

  testWidgets('MOBILE-07：文件浏览入口打开只读工作区文件页', (tester) async {
    await _openSeededWritableSession(tester);

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

  testWidgets('MOBILE-V05-24/P5-E1：模型设置中的 Goal 编辑、暂停和恢复走统一写入口', (tester) async {
    final harness = await _openWritableSession(
      tester,
      'goal-dock-owner@fixture.test',
    );
    await _openModelSettings(tester);
    expect(
      find.descendant(
        of: find.byKey(const Key('session-task-controls')),
        matching: find.text('保持移动端控制链路可回归'),
      ),
      findsOneWidget,
    );

    await _tapVisible(
      tester,
      find.byKey(const Key('session-goal-edit-button')),
    );
    await _enterVisible(tester, find.byKey(const Key('goal-edit-input')), '');
    await _tapVisible(tester, find.byKey(const Key('goal-edit-submit')));

    await _enterVisible(
      tester,
      find.byKey(const Key('goal-edit-input')),
      'P5-E 模型设置 Goal 回归目标',
    );
    await _tapVisible(tester, find.byKey(const Key('goal-edit-submit')));
    await _waitForVisible(
      tester,
      find.descendant(
        of: find.byKey(const Key('session-task-controls')),
        matching: find.text('P5-E 模型设置 Goal 回归目标'),
      ),
    );

    await _tapVisible(
      tester,
      find.byKey(const Key('session-goal-toggle-button')),
    );
    await _waitForVisible(
      tester,
      find.descendant(
        of: find.byKey(const Key('session-task-controls')),
        matching: find.textContaining('已暂停'),
      ),
    );
    await _tapVisible(
      tester,
      find.byKey(const Key('session-goal-toggle-button')),
    );
    await _waitForVisible(
      tester,
      find.descendant(
        of: find.byKey(const Key('session-task-controls')),
        matching: find.textContaining('进行中'),
      ),
    );
    await _tapVisible(
      tester,
      find.byKey(const Key('session-model-details-close')),
    );

    final snapshot = await harness.relay.getSessionSnapshot(
      (await harness.relay.listSessions()).single.id,
    );
    expect(
      snapshot.events.any((event) => event.eventType == 'session.goal_edited'),
      isTrue,
    );
    expect(
      snapshot.events.where((event) => event.eventType == 'goal.changed'),
      hasLength(2),
    );
  });

  testWidgets('MOBILE-V05-24/P5-E2：模型设置中的 Goal clear 清除目标且不留下常驻面板', (
    tester,
  ) async {
    final harness = await _openWritableSession(
      tester,
      'goal-dock-clear-owner@fixture.test',
    );
    await _openModelSettings(tester);
    await _tapVisible(
      tester,
      find.byKey(const Key('session-goal-clear-button')),
    );
    await _waitForGone(tester, find.text('保持移动端控制链路可回归'));
    await _tapVisible(
      tester,
      find.byKey(const Key('session-model-details-close')),
    );
    expect(find.byKey(const Key('session-goal-dock')), findsNothing);

    final snapshot = await harness.relay.getSessionSnapshot(
      (await harness.relay.listSessions()).single.id,
    );
    expect(
      snapshot.events.any((event) => event.eventType == 'goal.cleared'),
      isTrue,
    );
  });

  testWidgets('MOBILE-V05-24/P5-E3：/goal command-input 创建模型设置中的 Goal', (
    tester,
  ) async {
    final harness = await _openWritableSession(
      tester,
      'goal-command-owner@fixture.test',
    );
    await _openModelSettings(tester);
    await _tapVisible(
      tester,
      find.byKey(const Key('session-goal-clear-button')),
    );
    await _waitForGone(tester, find.text('保持移动端控制链路可回归'));
    await _tapVisible(
      tester,
      find.byKey(const Key('session-model-details-close')),
    );

    await _enterVisible(
      tester,
      find.byKey(const Key('session-composer-input')),
      '/goal 用 slash command 创建目标',
    );
    await _tapVisible(
      tester,
      find.byKey(const Key('session-composer-primary-action')),
    );
    await _openModelSettings(tester);
    await _waitForVisible(
      tester,
      find.descendant(
        of: find.byKey(const Key('session-task-controls')),
        matching: find.text('用 slash command 创建目标'),
      ),
    );
    await _tapVisible(
      tester,
      find.byKey(const Key('session-model-details-close')),
    );

    final snapshot = await harness.relay.getSessionSnapshot(
      (await harness.relay.listSessions()).single.id,
    );
    expect(
      snapshot.events.any((event) => event.eventType == 'goal.command_input'),
      isTrue,
    );
    expect(
      snapshot.events.any((event) => event.eventType == 'goal.created'),
      isTrue,
    );
    final timeline = snapshot.events
        .map(SessionTimelineEvent.fromRelayEvent)
        .toList();
    final command = timeline.firstWhere(
      (event) => event.text == '/goal 用 slash command 创建目标',
    );
    await _scrollChatUntilVisible(
      tester,
      find.byKey(Key('session-chat-node-node:${command.sequence}:command')),
    );
  });

  testWidgets('MOBILE-V05-24/P5-E4：TodoDock 只读折叠展示 Host todo 投影', (
    tester,
  ) async {
    await _openWritableSession(tester, 'todo-dock-owner@fixture.test');
    await _waitForVisible(tester, find.byKey(const Key('session-todo-dock')));
    await _waitForVisible(
      tester,
      find.byKey(const Key('session-todo-dock-progress')),
    );
    expect(find.text('冻结 v0.5 移动端回归矩阵'), findsNothing);

    await _tapVisible(
      tester,
      find.byKey(const Key('session-todo-dock-toggle')),
    );
    await _waitForVisible(
      tester,
      find.byKey(const Key('session-todo-dock-list')),
    );
    await _waitForVisible(tester, find.text('冻结 v0.5 移动端回归矩阵'));
    await _waitForVisible(tester, find.text('迁移 Goal / Todo 到 input.dock'));
    await _waitForVisible(tester, find.text('录屏前制定 headed 回归清单'));

    // TodoDock 是 Host 投影的只读列表：不暴露编辑、删除或 steer 写入口。
    expect(find.byKey(const Key('session-todo-dock-edit')), findsNothing);
    expect(find.byKey(const Key('session-todo-dock-delete')), findsNothing);
    expect(find.byKey(const Key('session-todo-dock-steer')), findsNothing);
  });

  testWidgets('MOBILE-11：goal 文本编辑提交 goal.edit 命令并乐观更新', (tester) async {
    final (harness, _) = await _openSeededWritableSession(tester);

    // 打开编辑对话框，修改目标文本并保存。
    await _openModelSettings(tester);
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
    final (harness, _) = await _openSeededWritableSession(tester);

    // codex fixture 可用且带版本：展示「已连接 · v...」。
    await _waitForVisible(
      tester,
      find.byKey(const Key('session-provider-version-chip')),
    );
    expect(find.textContaining('已连接'), findsOneWidget);

    // 探测失败路径：全部 Provider unavailable -> 状态条 fail-closed 展示。
    // force 绕过 15 秒节流（打开会话自动刷新即走 force 通道）。
    harness.relay.providersUnavailable = true;
    final container = ProviderScope.containerOf(
      tester.element(find.byKey(const Key('session-detail-screen'))),
    );
    await container
        .read(sessionControllerProvider)
        .refreshCapabilities(force: true);
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
    final (harness, sessionId) = await _openSeededWritableSession(tester);

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

List<Map<String, dynamic>> _latestFixtureQuestionAnswers(
  SessionSnapshot snapshot,
) {
  for (final event in snapshot.events.reversed) {
    final payload = event.envelope['fixture_payload'];
    if (payload is! Map || payload['answers'] is! List) continue;
    return (payload['answers'] as List)
        .whereType<Map>()
        .map((item) => Map<String, dynamic>.from(item))
        .toList(growable: false);
  }
  return const [];
}

/// v0.8.1+：预置本机 owner 与一个 fixture 会话，pump 完整 App（router
/// 自动进入已认证首页），再经「最近会话」入口打开会话详情并等待可写。
/// 返回 harness（调用方可继续用 relay 断言事件）。
Future<MobileAppHarness> _openWritableSession(
  WidgetTester tester,
  String ownerEmail,
) async {
  final harness = MobileAppHarness();
  await harness.launchAsOwner();
  final sessionId = await harness.seedSession();
  await tester.pumpWidget(harness.build());
  await _waitForVisible(tester, find.byKey(const Key('session-home-screen')));
  await _openSessionDetailFromRecent(tester, harness, sessionId);
  await _waitForVisible(tester, find.text('可操作'));
  return harness;
}

/// 从首页「最近会话」入口打开指定会话详情。
Future<void> _openSessionDetailFromRecent(
  WidgetTester tester,
  MobileAppHarness harness,
  String sessionId,
) async {
  await _tapVisible(tester, find.byKey(const Key('session-recent-button')));
  await _waitForVisible(
    tester,
    find.byKey(Key('recent-session-$sessionId')),
  );
  await _tapVisible(tester, find.byKey(Key('recent-session-$sessionId')));
  await _waitForVisible(tester, find.byKey(const Key('session-detail-screen')));
}

Future<void> _openModelSettings(WidgetTester tester) async {
  await _tapVisible(
    tester,
    find.byKey(const Key('session-model-seat-details')),
  );
  await _waitForVisible(
    tester,
    find.byKey(const Key('session-model-details-dialog')),
  );
  await _waitForVisible(tester, find.byKey(const Key('session-task-controls')));
}

/// 轮询等待 composer 文本变为期望值（会话切换后草稿恢复是异步的）。
Future<void> _waitForComposerText(WidgetTester tester, String expected) async {
  for (var frame = 0; frame < 80; frame += 1) {
    await tester.pump(const Duration(milliseconds: 50));
    final field = tester.widget<TextField>(
      find.byKey(const Key('session-composer-input')),
    );
    if (field.controller?.text == expected) return;
  }
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

/// v0.8.1+：预置 owner 并 seed 一个可写会话，pump 完整 App 后打开其详情页。
/// 返回 harness 与会话 id；调用方继续在详情页做交互断言。
Future<(MobileAppHarness, String)> _openSeededWritableSession(
  WidgetTester tester, {
  String provider = 'codex',
}) async {
  final harness = MobileAppHarness();
  await harness.launchAsOwner();
  final sessionId = await harness.seedSession(provider: provider);
  await tester.pumpWidget(harness.build());
  await _waitForVisible(tester, find.byKey(const Key('session-home-screen')));
  await _openSessionDetailFromRecent(tester, harness, sessionId);
  await _waitForVisible(tester, find.text('可操作'));
  return (harness, sessionId);
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
  final scrollable = find
      .descendant(
        of: find.byKey(const Key('session-chat-view')),
        matching: find.byType(Scrollable),
      )
      .first;
  await _waitForVisible(tester, scrollable);
  final state = tester.state<ScrollableState>(scrollable);

  // Chat 下方的 composer seat 可能把 viewport 压到很窄，测试拖拽中心点会落在
  // seat overlay 上。直接推进 ScrollPosition，先让懒加载列表项进入树，再使用
  // ensureVisible 完成最终定位，避免把命中警告误判成产品滚动失败。
  final start = state.position.pixels;
  state.position.jumpTo(0);
  await tester.pump();
  for (var attempt = 0; attempt < 24; attempt += 1) {
    if (finder.evaluate().isNotEmpty) {
      await tester.ensureVisible(finder);
      for (var frame = 0; frame < 3; frame += 1) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      if (finder.evaluate().isNotEmpty) {
        expect(finder, findsOneWidget);
        return;
      }
    }
    if (!state.position.hasContentDimensions) {
      await tester.pump(const Duration(milliseconds: 50));
      continue;
    }
    final next = (state.position.pixels + 120)
        .clamp(0, state.position.maxScrollExtent)
        .toDouble();
    if (next == state.position.pixels) break;
    state.position.jumpTo(next);
    await tester.pump(const Duration(milliseconds: 50));
  }

  // 失败时恢复调用前的阅读位置，便于失败截图和后续断言保留上下文。
  if (state.position.hasContentDimensions) {
    state.position.jumpTo(
      start.clamp(0, state.position.maxScrollExtent).toDouble(),
    );
    await tester.pump();
  }
  expect(finder, findsOneWidget);
}

Future<void> _scrollTrajectoryUntilVisible(
  WidgetTester tester,
  Finder finder, {
  double delta = 120,
}) async {
  await tester.scrollUntilVisible(
    finder,
    delta,
    // P6-B：Trajectory ledger 现在是包含 toolbar/timeline 的单一 ListView，
    // 内部 TextField 也有 Scrollable，因此必须取第一个外层 Scrollable。
    scrollable: find
        .descendant(
          of: find.byKey(const Key('session-trajectory-ledger')),
          matching: find.byType(Scrollable),
        )
        .first,
    maxScrolls: 24,
  );
  for (var frame = 0; frame < 3; frame += 1) {
    await tester.pump(const Duration(milliseconds: 50));
  }
  expect(finder, findsOneWidget);
}

/// 把 Trajectory 单一 ListView 滚回顶部，使 toolbar/timeline 重新可见可点。
Future<void> _scrollTrajectoryToTop(WidgetTester tester) async {
  final scrollable = find
      .descendant(
        of: find.byKey(const Key('session-trajectory-ledger')),
        matching: find.byType(Scrollable),
      )
      .first;
  tester.state<ScrollableState>(scrollable).position.jumpTo(0);
  await tester.pumpAndSettle();
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
