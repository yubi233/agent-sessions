import 'dart:math';

import 'package:agent_sessions_mobile/domain/control_models.dart';
import 'package:agent_sessions_mobile/domain/model_effort_preferences.dart';
import 'package:agent_sessions_mobile/domain/session_models.dart';
import 'package:agent_sessions_mobile/relay/fixture_relay_repository.dart';
import 'package:agent_sessions_mobile/state/session_controller.dart';
import 'package:agent_sessions_mobile/storage/model_effort_preference_store.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fixture_owner.dart';

void main() {
  test('MOBILE-V06-REAL-SESSION：autoStart 在创建后自动获取 lease 并提交 start', () async {
    final relay = FixtureRelayRepository(clock: () => _now);
    await _prepareOwner(relay);
    final controller = SessionController(
      relay: relay,
      clock: () => _now,
      random: _DeterministicRandom(),
    );
    await controller.initialize();

    final created = await controller.createSession(
      workspaceId: 'fixture-workspace',
      provider: 'codex',
      deviceId: _ownerDeviceId,
      canWrite: true,
      autoStart: true,
    );

    expect(created, isNotNull);
    expect(controller.hasSelectedLease, isTrue);
    expect(controller.timeline.any((event) => event.label == '会话已启动'), isTrue);
  });

  group('V081 DSH 工作区同步与历史元数据导入', () {
    test('客户端拒绝在非 DSH 工作区直接创建 DSH 会话', () async {
      final relay = FixtureRelayRepository(clock: () => _now);
      await _prepareOwner(relay);
      relay.replaceWorkspaces(const [
        MobileWorkspace(
          id: 'ws-managed',
          projectId: 'fixture-managed',
          terminalId: 'term-managed',
          origin: MobileWorkspaceOrigin.managed,
          status: 'active',
        ),
      ]);
      final controller = SessionController(relay: relay, clock: () => _now);
      await controller.initialize();

      final created = await controller.createSession(
        workspaceId: 'ws-managed',
        provider: 'dsh',
        deviceId: _ownerDeviceId,
        canWrite: true,
      );

      expect(created, isNull);
      expect(controller.sessions, isEmpty);
      expect(controller.workspaceErrorMessage, 'DSH 会话必须在已同步的 DSH 工作区内创建。');
    });

    test('同步完成后刷新安全工作区和会话投影', () async {
      final relay = _CompletingDSHWorkspaceSyncRelay(clock: () => _now);
      await _prepareOwner(relay);
      relay.replaceWorkspaces(const [
        MobileWorkspace(
          id: 'ws-dsh',
          projectId: 'fixture-dsh',
          terminalId: 'term-dsh',
          origin: MobileWorkspaceOrigin.dsh,
          displayName: 'fixture-dsh',
          status: 'active',
        ),
      ]);
      final controller = SessionController(relay: relay, clock: () => _now);
      await controller.initialize();

      final state = await controller.syncDSHWorkspaces(terminalId: 'term-dsh');

      expect(state?.isSucceeded, isTrue);
      expect(controller.workspaceSyncState?.workspaceIds, ['ws-dsh']);
      expect(controller.workspaceSyncWaiting, isFalse);
      expect(relay.pollCount, 1);
      expect(controller.workspaces.single.isDsh, isTrue);
    });

    test('同步失败保留终态且不会刷新为伪造工作区', () async {
      final relay = _FailedDSHWorkspaceSyncRelay(clock: () => _now);
      await _prepareOwner(relay);
      final controller = SessionController(relay: relay, clock: () => _now);
      await controller.initialize();

      final state = await controller.syncDSHWorkspaces(terminalId: 'term-dsh');

      expect(state?.status, 'failed');
      expect(controller.workspaceSyncState?.status, 'failed');
      expect(controller.workspaceSyncWaiting, isFalse);
      expect(
        controller.workspaces.where((workspace) => workspace.isDsh),
        isEmpty,
      );
    });

    test('停止等待只终止客户端同步轮询，不撤销已提交命令', () async {
      final relay = _PendingDSHWorkspaceSyncRelay(clock: () => _now);
      await _prepareOwner(relay);
      final controller = SessionController(relay: relay, clock: () => _now);
      await controller.initialize();

      final pending = controller.syncDSHWorkspaces(terminalId: 'term-dsh');
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(controller.workspaceSyncWaiting, isTrue);
      controller.stopWaitingForDSHWorkspaceSync();
      final state = await pending;

      expect(state?.isPending, isTrue);
      expect(controller.workspaceSyncWaiting, isFalse);
      expect(relay.pollCount, 0);
    });

    test('DSH 历史会话在持有 lease 后按声明能力恢复', () async {
      final relay = FixtureRelayRepository(clock: () => _now);
      await _prepareOwner(relay);
      relay.replaceWorkspaces(const [
        MobileWorkspace(
          id: 'ws-dsh',
          projectId: 'fixture-dsh',
          terminalId: 'term-dsh',
          origin: MobileWorkspaceOrigin.dsh,
          displayName: 'fixture-dsh',
          status: 'active',
        ),
      ]);
      final imported = await relay.createSession(
        const CreateMobileSessionInput(
          workspaceId: 'ws-dsh',
          provider: 'dsh',
          deviceId: _ownerDeviceId,
        ),
      );
      final controller = SessionController(relay: relay, clock: () => _now);
      await controller.initialize();
      await controller.selectSession(imported.id);

      await controller.acquireSelectedLease(
        deviceId: _ownerDeviceId,
        canWrite: true,
      );
      expect(controller.resumeBlockedReason(canWrite: true), isNull);
      await controller.resumeSelectedSession(
        deviceId: _ownerDeviceId,
        canWrite: true,
      );
      expect(relay.submittedCommandCount, 1);
      expect(controller.errorMessage, isNull);
    });

    test('导入成功后只刷新会话元数据，并保留 DSH workspace 边界', () async {
      final relay = FixtureRelayRepository(clock: () => _now);
      await _prepareOwner(relay);
      relay.replaceWorkspaces(const [
        MobileWorkspace(
          id: 'ws-dsh',
          projectId: 'fixture-dsh',
          terminalId: 'term-dsh',
          origin: MobileWorkspaceOrigin.dsh,
          displayName: 'fixture-dsh',
          status: 'active',
        ),
      ]);
      await relay.createSession(
        const CreateMobileSessionInput(
          workspaceId: 'ws-dsh',
          provider: 'dsh',
          deviceId: _ownerDeviceId,
        ),
      );
      final controller = SessionController(relay: relay, clock: () => _now);
      await controller.initialize();

      final state = await controller.importDSHSessions(
        workspaceId: 'ws-dsh',
        terminalId: 'term-dsh',
        deviceId: _ownerDeviceId,
        canWrite: true,
      );

      expect(state?.isSucceeded, isTrue);
      expect(state?.sessionIds, hasLength(1));
      expect(controller.workspaceImportState?.isSucceeded, isTrue);
      expect(
        controller.sessions.every(
          (session) =>
              session.workspaceId != 'ws-dsh' || session.provider == 'dsh',
        ),
        isTrue,
      );
    });

    test('停止等待只终止客户端轮询，不撤销已提交的导入命令', () async {
      final relay = _PendingDSHImportRelay(clock: () => _now);
      await _prepareOwner(relay);
      relay.replaceWorkspaces(const [
        MobileWorkspace(
          id: 'ws-dsh',
          projectId: 'fixture-dsh',
          terminalId: 'term-dsh',
          origin: MobileWorkspaceOrigin.dsh,
          displayName: 'fixture-dsh',
          status: 'active',
        ),
      ]);
      final controller = SessionController(relay: relay, clock: () => _now);
      await controller.initialize();

      final pending = controller.importDSHSessions(
        workspaceId: 'ws-dsh',
        terminalId: 'term-dsh',
        deviceId: _ownerDeviceId,
        canWrite: true,
      );
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(controller.workspaceImportWaiting, isTrue);
      controller.stopWaitingForDSHImport();
      final state = await pending;

      expect(state?.isPending, isTrue);
      expect(controller.workspaceImportWaiting, isFalse);
      expect(relay.pollCount, 0);
    });
  });

  test('MOBILE-V07 发送密文携带当前生效模型，避免服务端回退到配置默认', () async {
    final relay = _CapturingControlsRelay(clock: () => _now);
    await _prepareOwner(relay);
    final controller = SessionController(
      relay: relay,
      clock: () => _now,
      random: _DeterministicRandom(),
    );
    await controller.initialize();
    await controller.createSession(
      workspaceId: 'fixture-workspace',
      provider: 'opencode',
      deviceId: _ownerDeviceId,
      canWrite: true,
      autoStart: true,
    );

    await controller.sendMessage(
      message: '你好',
      deviceId: _ownerDeviceId,
      canWrite: true,
    );

    final send = relay.submitted.lastWhere(
      (command) => command.kind == SessionCommandKind.send,
    );
    final payload = send.ciphertext?['fixture_payload'] as Map<String, dynamic>;
    expect(payload['message'], '你好');
    expect(payload['model'], 'opencode/big-pickle');
  });

  test('MOBILE-V081 send 命令执行端 failed 时浮出错误并清掉乐观回显', () async {
    // 真实链路的 local_state_missing 场景：Daemon 以 failed 终态收口 send 命令。
    // 客户端不能把受理当成功，否则乐观气泡与“生成中”指示会无限停留。
    final relay = _FailingCommandRelay(clock: () => _now);
    await _prepareOwner(relay);
    final controller = SessionController(
      relay: relay,
      clock: () => _now,
      random: _DeterministicRandom(),
    );
    await controller.initialize();
    // autoStart 的 start 命令同样以 failed 收口，但 lease 已先行获取；
    // 这里只依赖 lease 覆盖 sendMessage 的前置校验。
    await controller.createSession(
      workspaceId: 'fixture-workspace',
      provider: 'codex',
      deviceId: _ownerDeviceId,
      canWrite: true,
      autoStart: true,
    );

    await controller.sendMessage(
      message: '你好',
      deviceId: _ownerDeviceId,
      canWrite: true,
    );

    expect(controller.errorMessage, '消息发送失败（命令 failed），请查看时间线中的失败提示。');
    expect(controller.pendingOutgoingMessage, isNull);
    expect(controller.isStreaming, isFalse);
  });
  group('MOBILE-V07 命令终态确认与乐观更新收口', () {
    test('selectModel 命令执行端 failed 时浮出错误且不更新 controls', () async {
      final relay = _FailingCommandRelay(clock: () => _now);
      await _prepareOwner(relay);
      final controller = SessionController(
        relay: relay,
        clock: () => _now,
        random: _DeterministicRandom(),
      );
      await controller.initialize();
      // codex 在 fixture 能力矩阵中声明 model_select；opencode 未声明会被
      // controlBlockedReason 先行拦截，覆盖不到终态确认链路。
      await controller.createSession(
        workspaceId: 'fixture-workspace',
        provider: 'codex',
        deviceId: _ownerDeviceId,
        canWrite: true,
        autoStart: true,
      );
      // 让 _controls 携带本测试声明的模型目录后再校验 selectModel。
      expect(await controller.refreshSelectedControls(), isNull);

      await controller.selectModel(
        model: 'fixture-model-b',
        deviceId: _ownerDeviceId,
        canWrite: true,
      );

      // 受理（202）不算成功：执行端终态 failed 必须浮出错误且不应用乐观更新。
      expect(controller.errorMessage, '操作未被会话执行端接受，请重试。');
      expect(controller.controls.model, isNull);
    });

    test('selectModel 命令 succeeded 才应用乐观更新', () async {
      final relay = _FailingCommandRelay(
        clock: () => _now,
        terminalStatus: 'succeeded',
      );
      await _prepareOwner(relay);
      final controller = SessionController(
        relay: relay,
        clock: () => _now,
        random: _DeterministicRandom(),
      );
      await controller.initialize();
      await controller.createSession(
        workspaceId: 'fixture-workspace',
        provider: 'codex',
        deviceId: _ownerDeviceId,
        canWrite: true,
        autoStart: true,
      );
      // 让 _controls 携带本测试声明的模型目录后再校验 selectModel。
      final refreshError = await controller.refreshSelectedControls();
      expect(refreshError, isNull);

      await controller.selectModel(
        model: 'fixture-model-b',
        deviceId: _ownerDeviceId,
        canWrite: true,
      );

      expect(controller.errorMessage, isNull);
      expect(controller.controls.model, 'fixture-model-b');
    });
  });

  group('V086 模型推理等级本地记忆', () {
    Future<(SessionController, InMemoryModelEffortPreferenceStore)>
    readyController(
      _ModelEffortControlsRelay relay, {
      ModelEffortPreferences preload = ModelEffortPreferences.defaults,
    }) async {
      await _prepareOwner(relay);
      final store = InMemoryModelEffortPreferenceStore();
      if (preload.effortsByModel.isNotEmpty) {
        await store.write(preload);
      }
      final controller = SessionController(
        relay: relay,
        clock: () => _now,
        random: _DeterministicRandom(),
        modelEffortMemory: store,
      );
      await controller.initialize();
      await controller.createSession(
        workspaceId: 'fixture-workspace',
        provider: 'codex',
        deviceId: _ownerDeviceId,
        canWrite: true,
        autoStart: true,
      );
      expect(await controller.refreshSelectedControls(), isNull);
      return (controller, store);
    }

    test('selectEffort 成功后把等级记到当前模型名下并持久化', () async {
      final relay = _ModelEffortControlsRelay(clock: () => _now);
      final (controller, store) = await readyController(relay);

      await controller.selectEffort(
        effort: '高',
        deviceId: _ownerDeviceId,
        canWrite: true,
      );

      expect(controller.errorMessage, isNull);
      expect(controller.controls.effort, '高');
      expect(controller.cachedEffortFor('fixture-model-a'), '高');
      expect((await store.read()).effortFor('fixture-model-a'), '高');
      expect(controller.modelEffortsMemory['fixture-model-a'], '高');
    });

    test('selectModel 自动带回该模型上次使用的推理等级', () async {
      final relay = _ModelEffortControlsRelay(clock: () => _now);
      final (controller, _) = await readyController(
        relay,
        preload: const ModelEffortPreferences(
          effortsByModel: {'fixture-model-b': '低'},
        ),
      );

      await controller.selectModel(
        model: 'fixture-model-b',
        deviceId: _ownerDeviceId,
        canWrite: true,
      );

      expect(controller.errorMessage, isNull);
      expect(controller.controls.model, 'fixture-model-b');
      final effortCommands = relay.submitted
          .where((command) => command.kind == SessionCommandKind.effortSelect)
          .toList();
      expect(effortCommands, hasLength(1));
      final payload =
          effortCommands.single.ciphertext?['fixture_payload']
              as Map<String, dynamic>;
      expect(payload['effort'], '低');
      expect(controller.controls.effort, '低');
    });

    test('记忆等级不在目录中时跳过自动带回，不发必败命令', () async {
      final relay = _ModelEffortControlsRelay(clock: () => _now);
      final (controller, _) = await readyController(
        relay,
        preload: const ModelEffortPreferences(
          effortsByModel: {'fixture-model-b': '极速'},
        ),
      );

      await controller.selectModel(
        model: 'fixture-model-b',
        deviceId: _ownerDeviceId,
        canWrite: true,
      );

      expect(controller.errorMessage, isNull);
      expect(controller.controls.model, 'fixture-model-b');
      expect(
        relay.submitted
            .where((command) => command.kind == SessionCommandKind.effortSelect),
        isEmpty,
      );
      // fixture 种子的当前 effort 为「高」，模型切换不改变它。
      expect(controller.controls.effort, '高');
    });
  });

  test('V085-07 mode.set：wire kind/payload 与 Daemon 权威契约对齐', () async {
    // v0.8.5 §3.5：移动端 permissionModeSelect 的 wire 必须为 mode.set + mode_id
    //（旧 session.permission_mode/permission_mode 会被 Daemon 拒为 unsupported）。
    final relay = _CapturingControlsRelay(clock: () => _now);
    await _prepareOwner(relay);
    final controller = SessionController(
      relay: relay,
      clock: () => _now,
      random: _DeterministicRandom(),
    );
    await controller.initialize();
    await controller.createSession(
      workspaceId: 'fixture-workspace',
      provider: 'codex',
      deviceId: _ownerDeviceId,
      canWrite: true,
      autoStart: true,
    );
    expect(await controller.refreshSelectedControls(), isNull);
    // fixture 目录预置 default/plan/acceptEdits/danger-full-access。
    expect(
      controller.controls.availablePermissionModes,
      contains('acceptEdits'),
    );

    await controller.selectPermissionMode(
      mode: 'acceptEdits',
      deviceId: _ownerDeviceId,
      canWrite: true,
    );
    expect(controller.errorMessage, isNull);
    expect(controller.controls.permissionMode, 'acceptEdits');

    final submitted = relay.submitted.lastWhere(
      (command) => command.kind == SessionCommandKind.permissionModeSelect,
    );
    // 权威契约：kind=mode.set、payload key=mode_id。
    expect(submitted.kind.wireValue, 'mode.set');
    final payload =
        submitted.ciphertext?['fixture_payload'] as Map<String, dynamic>;
    expect(payload['mode_id'], 'acceptEdits');
  });

  test('MOBILE-V07 会话切换时乐观回显不跨会话泄漏', () async {
    final relay = _DelayedEchoRelay(clock: () => _now);
    await _prepareOwner(relay);
    final controller = SessionController(
      relay: relay,
      clock: () => _now,
      random: _DeterministicRandom(),
    );
    await controller.initialize();
    // codex 在 fixture 能力矩阵声明完整能力；本测试聚焦回显的会话隔离而非
    // provider 能力差异。
    final sessionA = await controller.createSession(
      workspaceId: 'fixture-workspace',
      provider: 'codex',
      deviceId: _ownerDeviceId,
      canWrite: true,
      autoStart: true,
    );
    final sessionB = await controller.createSession(
      workspaceId: 'fixture-workspace',
      provider: 'codex',
      deviceId: _ownerDeviceId,
      canWrite: true,
      autoStart: true,
    );
    await controller.selectSession(sessionA!.id);
    // 切换会话后写权需重新确认：先取回 lease 再发送。
    await controller.acquireSelectedLease(
      deviceId: _ownerDeviceId,
      canWrite: true,
    );

    const echoText = '跨会话回显文本';
    relay.echoAfterCalls = 99;
    relay.echoText = echoText;
    final sending = controller.sendMessage(
      message: echoText,
      deviceId: _ownerDeviceId,
      canWrite: true,
    );
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(controller.pendingOutgoingMessage, echoText);

    // 切到 B：A 的待确认回显不得泄漏到 B 的视图。
    await controller.selectSession(sessionB!.id);
    expect(controller.pendingOutgoingMessage, isNull);

    // 切回 A：回显仍在，canonical 事件到达后清账。
    await controller.selectSession(sessionA.id);
    expect(controller.pendingOutgoingMessage, echoText);
    relay.echoAfterCalls = 0;
    await sending;
    expect(controller.pendingOutgoingMessage, isNull);
  });

  test('MOBILE-V07 流式增量坍缩为单一生长气泡，completed 全文替换', () async {
    final relay = _StreamingTurnRelay(clock: () => _now);
    await _prepareOwner(relay);
    final controller = SessionController(
      relay: relay,
      clock: () => _now,
      random: _DeterministicRandom(),
    );
    await controller.initialize();
    await controller.createSession(
      workspaceId: 'fixture-workspace',
      provider: 'opencode',
      deviceId: _ownerDeviceId,
      canWrite: true,
      autoStart: true,
    );

    await controller.sendMessage(
      message: '讲个笑话',
      deviceId: _ownerDeviceId,
      canWrite: true,
    );

    // completed_turn 空标记也属 assistantMessage，但投影层不渲染；只统计真实气泡。
    final assistantNodes = controller.timeline
        .where(
          (event) =>
              event.kind == SessionTimelineKind.assistantMessage &&
              !event.completedTurn,
        )
        .toList();
    // 三条流式增量被全文 completed 替换，最终只剩单一完整节点。
    expect(assistantNodes.length, 1);
    expect(assistantNodes.single.text, '完整回复文本');
    expect(assistantNodes.single.isStreaming, isFalse);
  });

  test('MOBILE-V07 快照合并去重且按 sequence 排序', () async {
    final relay = _OutOfOrderSnapshotRelay(clock: () => _now);
    await _prepareOwner(relay);
    final controller = SessionController(
      relay: relay,
      clock: () => _now,
      random: _DeterministicRandom(),
    );
    await controller.initialize();
    await controller.createSession(
      workspaceId: 'fixture-workspace',
      provider: 'opencode',
      deviceId: _ownerDeviceId,
      canWrite: true,
      autoStart: true,
    );

    final sequences = controller.timeline
        .map((event) => event.sequence)
        .toList();
    expect(sequences, isNotEmpty);
    final sorted = [...sequences]..sort();
    expect(sequences, sorted);
    expect(sequences.toSet().length, sequences.length);
  });

  test('MOBILE-V07 发送后乐观回显用户气泡，canonical 事件到达后清账', () async {
    final relay = _DelayedEchoRelay(clock: () => _now);
    await _prepareOwner(relay);
    final controller = SessionController(
      relay: relay,
      clock: () => _now,
      random: _DeterministicRandom(),
    );
    await controller.initialize();
    await controller.createSession(
      workspaceId: 'fixture-workspace',
      provider: 'opencode',
      deviceId: _ownerDeviceId,
      canWrite: true,
      autoStart: true,
    );

    // 先让用户事件迟迟不回传：发送后立即应挂出本地乐观回显气泡。
    // 文本不能与 fixture 预置演示对话（「你好」）相同，否则清账判定会撞车。
    const echoText = '测试乐观回显文本';
    relay.echoAfterCalls = 99;
    relay.echoText = echoText;
    final sending = controller.sendMessage(
      message: echoText,
      deviceId: _ownerDeviceId,
      canWrite: true,
    );
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(controller.pendingOutgoingMessage, echoText);

    // canonical user.message 回传后，乐观条目清账，不留双气泡。
    relay.echoAfterCalls = 0;
    await sending;
    expect(controller.pendingOutgoingMessage, isNull);
  });

  group('MOBILE-02 SESS-01..02 CTRL-01..02 会话控制状态机', () {
    test('空列表、新会话、流式时间线、权限问题和停止共享同一 lease 链路', () async {
      final relay = FixtureRelayRepository(clock: () => _now);
      await _prepareOwner(relay);
      final controller = SessionController(
        relay: relay,
        clock: () => _now,
        random: _DeterministicRandom(),
      );

      await controller.initialize();
      expect(controller.isEmpty, isTrue);

      final created = await controller.createSession(
        workspaceId: 'fixture-workspace',
        provider: 'codex',
        deviceId: _ownerDeviceId,
        canWrite: true,
      );
      expect(created, isNotNull);
      expect(controller.selectedSession?.id, created!.id);
      expect(controller.timeline.single.kind, SessionTimelineKind.systemNotice);
      // v0.9：lease 不再是 composer 前置阻断；写命令提交时自动静默获取。
      expect(controller.composerBlockedReason(canWrite: true), isNull);

      // 未显式 acquire 时 start 也会自动获取 lease 并成功执行。
      await controller.startSelectedSession(
        deviceId: _ownerDeviceId,
        canWrite: true,
      );
      expect(controller.selectedLease?.epoch, 1);
      expect(
        controller.timeline.any((event) => event.label == '会话已启动'),
        isTrue,
      );

      await controller.sendMessage(
        message: '请检查 fixture 会话',
        deviceId: _ownerDeviceId,
        canWrite: true,
      );
      expect(controller.isStreaming, isTrue);
      expect(
        controller.timeline.any(
          (event) =>
              event.kind == SessionTimelineKind.assistantMessage &&
              event.isStreaming,
        ),
        isTrue,
      );
      final permission = controller.timeline
          .firstWhere((event) => event.permission != null)
          .permission!;
      final question = controller.timeline
          .firstWhere((event) => event.question != null)
          .question!;

      await controller.resolvePermission(
        requestId: permission.requestId,
        approved: true,
        deviceId: _ownerDeviceId,
        canWrite: true,
      );
      await controller.answerQuestion(
        requestId: question.requestId,
        answer: question.options.first,
        deviceId: _ownerDeviceId,
        canWrite: true,
      );
      expect(
        controller.isRequestResolved('permission', permission.requestId),
        isTrue,
      );
      expect(
        controller.isRequestResolved('question', question.requestId),
        isTrue,
      );

      await controller.stopStreaming(deviceId: _ownerDeviceId, canWrite: true);
      expect(controller.selectedSession?.status, MobileSessionStatus.stopped);
      expect(controller.timeline.any((event) => event.label == '已中止'), isTrue);
      final aborted = controller.timeline.firstWhere(
        (event) => event.label == '已中止',
      );
      expect(aborted.createdAt, _now);
      expect(controller.errorMessage, isNull);
    });

    test('V085-22 stopStreaming 在 abort 命令 failed 时浮出失败且不伪装中止', () async {
      // 真实链路中 Abort 命令回执与 canonical 投影分开到达；若执行端以 failed
      // 收口（如 Provider 中止失败），客户端必须浮出可见错误，不能把受理当成功。
      final relay = _FailingCommandRelay(clock: () => _now);
      await _prepareOwner(relay);
      final controller = SessionController(
        relay: relay,
        clock: () => _now,
        random: _DeterministicRandom(),
      );
      await controller.initialize();
      // codex 声明 abort capability；建立会话并获取 lease 后直接提交 abort，
      // 让 abort 命令走完整的回执确认链路（父类 fixture 命令即时 succeeded，
      // 本 relay 把终态固定为 failed 以覆盖失败分支）。
      final created = await controller.createSession(
        workspaceId: 'fixture-workspace',
        provider: 'codex',
        deviceId: _ownerDeviceId,
        canWrite: true,
      );
      expect(created, isNotNull);
      await controller.acquireSelectedLease(
        deviceId: _ownerDeviceId,
        canWrite: true,
      );

      await controller.stopStreaming(deviceId: _ownerDeviceId, canWrite: true);

      // failed 终态必须浮出且不产生“已中止”伪证轨迹。
      expect(controller.errorMessage, contains('中止命令未成功'));
      expect(controller.timeline.any((event) => event.label == '已中止'), isFalse);
    });

    test('start 后可通过 kill 结束 fixture 进程并进入 stopped', () async {
      final relay = FixtureRelayRepository(clock: () => _now);
      await _prepareOwner(relay);
      final controller = SessionController(relay: relay, clock: () => _now);
      await controller.initialize();
      final created = await controller.createSession(
        workspaceId: 'fixture-workspace',
        provider: 'codex',
        deviceId: _ownerDeviceId,
        canWrite: true,
      );
      await controller.acquireSelectedLease(
        deviceId: _ownerDeviceId,
        canWrite: true,
      );
      await controller.startSelectedSession(
        deviceId: _ownerDeviceId,
        canWrite: true,
      );
      await controller.killSelectedSession(
        deviceId: _ownerDeviceId,
        canWrite: true,
      );

      expect(controller.selectedSession?.id, created!.id);
      expect(controller.selectedSession?.status, MobileSessionStatus.stopped);
      expect(
        controller.timeline.any((event) => event.label == '已结束本机进程'),
        isTrue,
      );
      expect(controller.errorMessage, isNull);
    });

    test('未声明 kill capability 时保持 fail-closed', () async {
      final relay = FixtureRelayRepository(clock: () => _now);
      await _prepareOwner(relay);
      final controller = SessionController(relay: relay, clock: () => _now);
      await controller.initialize();
      await controller.createSession(
        workspaceId: 'fixture-workspace',
        provider: 'claude',
        deviceId: _ownerDeviceId,
        canWrite: true,
      );
      await controller.acquireSelectedLease(
        deviceId: _ownerDeviceId,
        canWrite: true,
      );

      await controller.killSelectedSession(
        deviceId: _ownerDeviceId,
        canWrite: true,
      );

      expect(controller.errorMessage, 'fixture Provider 未声明此能力。');
    });

    test('只读状态不会创建会话或调用 fixture 写路径', () async {
      final relay = FixtureRelayRepository(clock: () => _now);
      final controller = SessionController(relay: relay, clock: () => _now);
      await controller.initialize();

      final created = await controller.createSession(
        workspaceId: 'fixture-workspace',
        provider: 'codex',
        deviceId: null,
        canWrite: false,
      );

      expect(created, isNull);
      expect(controller.sessions, isEmpty);
      expect(controller.errorMessage, contains('只读'));
    });

    test('旧 epoch 被 fixture 拒绝，控制器保留可见错误而不伪造发送成功', () async {
      final relay = FixtureRelayRepository(clock: () => _now);
      await _prepareOwner(relay);
      final controller = SessionController(relay: relay, clock: () => _now);
      final created = await controller.createSession(
        workspaceId: 'fixture-workspace',
        provider: 'codex',
        deviceId: _ownerDeviceId,
        canWrite: true,
      );
      await controller.acquireSelectedLease(
        deviceId: _ownerDeviceId,
        canWrite: true,
      );
      // 另一个显式 lease 获取会推进 epoch，模拟旧 UI 在 fencing 后继续发送。
      await relay.acquireSessionLease(created!.id);

      await controller.sendMessage(
        message: '这条旧 epoch 命令不能被接受',
        deviceId: _ownerDeviceId,
        canWrite: true,
      );

      expect(controller.errorMessage, '会话可操作状态已更新，请重试。');
      expect(controller.timeline.length, 1);
    });

    test('forkFromMessage 使用当前 lease 创建 child，并刷新 parent lineage 事件', () async {
      final relay = FixtureRelayRepository(clock: () => _now);
      await _prepareOwner(relay);
      final controller = SessionController(
        relay: relay,
        clock: () => _now,
        random: _DeterministicRandom(),
      );
      final parent = await controller.createSession(
        workspaceId: 'fixture-workspace',
        provider: 'codex',
        deviceId: _ownerDeviceId,
        canWrite: true,
      );
      await controller.acquireSelectedLease(
        deviceId: _ownerDeviceId,
        canWrite: true,
      );

      final child = await controller.forkFromMessage(
        messageId: 'assistant-message-1',
        deviceId: _ownerDeviceId,
        canWrite: true,
      );
      final retried = await controller.forkFromMessage(
        messageId: 'assistant-message-1',
        deviceId: _ownerDeviceId,
        canWrite: true,
      );

      expect(child, isNotNull);
      expect(retried?.id, child!.id);
      expect(child.parentSessionId, parent!.id);
      expect(child.forkedFromMessageId, 'assistant-message-1');
      expect(
        controller.sessions.where((session) => session.id == child.id),
        hasLength(1),
      );
      expect(
        controller.sessions.any((session) => session.id == parent.id),
        isTrue,
      );
      expect(controller.selectedSession?.id, parent.id);
      expect(
        controller.timeline.any((event) => event.label == '已创建分支'),
        isTrue,
      );
      expect(controller.errorMessage, isNull);
    });
  });

  test(
    'MOBILE-V06-TURN-COMPLETED：completed_turn 事件把 streaming 会话收敛为 idle 并刷新 controls',
    () async {
      final relay = _TurnCompletedRelay(clock: () => _now);
      await _prepareOwner(relay);
      final controller = SessionController(
        relay: relay,
        clock: () => _now,
        random: _DeterministicRandom(),
      );
      await controller.initialize();

      final created = await controller.createSession(
        workspaceId: 'fixture-workspace',
        provider: 'codex',
        deviceId: _ownerDeviceId,
        canWrite: true,
      );
      await controller.acquireSelectedLease(
        deviceId: _ownerDeviceId,
        canWrite: true,
      );
      await controller.startSelectedSession(
        deviceId: _ownerDeviceId,
        canWrite: true,
      );

      // 下一次 snapshot 注入：session 仍为 streaming，但携带 completed_turn。
      relay.armNextSnapshot = true;
      await controller.sendMessage(
        message: '结束这一轮',
        deviceId: _ownerDeviceId,
        canWrite: true,
      );

      expect(controller.selectedSession?.status, MobileSessionStatus.idle);
      expect(controller.isStreaming, isFalse);
      expect(controller.timeline.any((event) => event.completedTurn), isTrue);
      // 回合结束后 controls 被主动刷新；fixture 控制项带确定性 usage。
      expect(controller.controls.usage, isNotNull);
      expect(created, isNotNull);
    },
  );

  test('MOBILE-V06-TURN-IDLE-SNAPSHOT：空增量快照仍把 streaming 会话收敛为 idle', () async {
    final relay = _EmptyDeltaIdleRelay(clock: () => _now);
    await _prepareOwner(relay);
    final controller = SessionController(
      relay: relay,
      clock: () => _now,
      random: _DeterministicRandom(),
    );
    await controller.initialize();
    await controller.createSession(
      workspaceId: 'fixture-workspace',
      provider: 'codex',
      deviceId: _ownerDeviceId,
      canWrite: true,
    );
    await controller.acquireSelectedLease(
      deviceId: _ownerDeviceId,
      canWrite: true,
    );
    await controller.startSelectedSession(
      deviceId: _ownerDeviceId,
      canWrite: true,
    );

    await controller.sendMessage(
      message: '空增量也要结束这一轮',
      deviceId: _ownerDeviceId,
      canWrite: true,
    );

    expect(relay.streamingSnapshots, greaterThanOrEqualTo(2));
    expect(controller.selectedSession?.status, MobileSessionStatus.idle);
    expect(controller.isStreaming, isFalse);
  });

  test('归档会话从列表隐藏且保留数据，取消归档可恢复', () async {
    final relay = FixtureRelayRepository(clock: () => _now);
    await _prepareOwner(relay);
    final controller = SessionController(
      relay: relay,
      clock: () => _now,
      random: _DeterministicRandom(),
    );
    await controller.initialize();

    final created = await controller.createSession(
      workspaceId: 'fixture-workspace',
      provider: 'codex',
      deviceId: _ownerDeviceId,
      canWrite: true,
    );
    expect(created, isNotNull);
    expect(controller.sessions, hasLength(1));

    final archived = await controller.archiveSelectedSession(
      deviceId: _ownerDeviceId,
      canWrite: true,
    );
    expect(archived, isTrue);
    expect(controller.sessions, isEmpty);
    expect(controller.selectedSessionId, isNull);

    // 直接通过 fixture 快照仍能读取原会话（数据未删除）。
    final snapshot = await relay.getSessionSnapshot(created!.id);
    expect(snapshot.session.id, created.id);
    expect(snapshot.session.archivedAt, isNotNull);

    // 已归档会话不能从当前首页恢复（没有选择入口），但 Relay 恢复接口可将其取消归档。
    final restored = await relay.unarchiveSession(created.id);
    expect(restored.archivedAt, isNull);
    await controller.refreshSessions();
    expect(controller.sessions, hasLength(1));
  });
}

/// 在 sendMessage 后的首次快照中注入 completed_turn 事件，
/// 验证真实后端 turn.completed 终止路径在控制器里的状态收敛。
/// 前 `echoAfterCalls` 次 snapshot 不回传用户事件且保持 streaming，
/// 用于验证乐观回显的挂出与清账时序。
class _DelayedEchoRelay extends FixtureRelayRepository {
  _DelayedEchoRelay({required super.clock});

  int snapshotCalls = 0;
  int echoAfterCalls = 2;
  String echoText = '你好';

  @override
  Future<SessionSnapshot> getSessionSnapshot(
    String sessionId, {
    int afterSequence = 0,
  }) async {
    snapshotCalls += 1;
    final snapshot = await super.getSessionSnapshot(
      sessionId,
      afterSequence: afterSequence,
    );
    // fixture 预置时间线带未解决的 permission/question 事件；按 _snapshotCompletesTurn
    // 的设计它们会让轮询立即收敛，这里过滤掉以便演练乐观回显的完整时序。
    final events = snapshot.events
        .where(
          (event) =>
              !(event.envelope['fixture_payload'] is Map &&
                  const ['permission_request', 'question_request'].contains(
                    (event.envelope['fixture_payload'] as Map)['kind'],
                  )),
        )
        .toList();
    if (snapshotCalls <= echoAfterCalls) {
      return SessionSnapshot(
        session: snapshot.session.copyWith(
          status: MobileSessionStatus.streaming,
        ),
        events: events,
      );
    }
    // canonical 阶段：用户事件回传 + completed_turn 标记，控制器应清账乐观回显
    // 并按真实轮次收敛。
    final userEvent = RelaySessionEvent(
      sequence: snapshot.session.lastSequence + 1,
      eventType: 'user.message',
      envelope: {
        'fixture_payload': {
          'kind': 'user_message',
          'label': '你',
          'text': echoText,
          'streaming': false,
          'copy_text': echoText,
        },
      },
    );
    final completedEvent = RelaySessionEvent(
      sequence: snapshot.session.lastSequence + 2,
      eventType: 'turn.completed',
      envelope: const {
        'fixture_payload': {
          'kind': 'assistant_message',
          'label': 'Assistant',
          'text': '回合已结束。',
          'completed_turn': true,
        },
      },
    );
    return SessionSnapshot(
      session: snapshot.session.copyWith(
        status: MobileSessionStatus.streaming,
        lastSequence: completedEvent.sequence,
      ),
      events: [...events, userEvent, completedEvent],
    );
  }
}

/// 回合内注入三条流式增量与一条全文 completed：验证流式合并契约。
class _StreamingTurnRelay extends FixtureRelayRepository {
  _StreamingTurnRelay({required super.clock});

  @override
  Future<SessionSnapshot> getSessionSnapshot(
    String sessionId, {
    int afterSequence = 0,
  }) async {
    final snapshot = await super.getSessionSnapshot(
      sessionId,
      afterSequence: afterSequence,
    );
    RelaySessionEvent delta(int seq, String text) => RelaySessionEvent(
      sequence: seq,
      eventType: 'message.delta',
      envelope: {
        'fixture_payload': {
          'kind': 'assistant_message',
          'label': 'Assistant',
          'text': text,
          'streaming': true,
        },
      },
    );
    final base = snapshot.session.lastSequence;
    final events = [
      delta(base + 1, '完整'),
      delta(base + 2, '完整回复'),
      delta(base + 3, '完整回复文本'),
      RelaySessionEvent(
        sequence: base + 4,
        eventType: 'message.completed',
        envelope: {
          'fixture_payload': {
            'kind': 'assistant_message',
            'label': 'Assistant',
            'text': '完整回复文本',
            'streaming': false,
            'copy_text': '完整回复文本',
          },
        },
      ),
      RelaySessionEvent(
        sequence: base + 5,
        eventType: 'turn.completed',
        envelope: const {
          'fixture_payload': {
            'kind': 'assistant_message',
            'label': 'Assistant',
            'completed_turn': true,
          },
        },
      ),
    ];
    return SessionSnapshot(
      session: snapshot.session.copyWith(
        status: MobileSessionStatus.idle,
        lastSequence: base + 5,
      ),
      events: events,
    );
  }
}

/// 返回含重复与乱序 sequence 的快照：验证合并层以 sequence 为唯一序。
class _OutOfOrderSnapshotRelay extends FixtureRelayRepository {
  _OutOfOrderSnapshotRelay({required super.clock});

  @override
  Future<SessionSnapshot> getSessionSnapshot(
    String sessionId, {
    int afterSequence = 0,
  }) async {
    final snapshot = await super.getSessionSnapshot(
      sessionId,
      afterSequence: afterSequence,
    );
    RelaySessionEvent event(int seq) => RelaySessionEvent(
      sequence: seq,
      eventType: 'user.message',
      envelope: const {
        'fixture_payload': {
          'kind': 'user_message',
          'label': '你',
          'text': '乱序事件 \$seq',
          'streaming': false,
        },
      },
    );
    final base = snapshot.session.lastSequence;
    return SessionSnapshot(
      session: snapshot.session.copyWith(lastSequence: base + 2),
      events: [event(base + 2), event(base + 1), event(base + 2)],
    );
  }
}

/// 命令终态可编程的 relay：验证控制面命令必须等执行端收口，失败要浮出错误。
class _FailingCommandRelay extends FixtureRelayRepository {
  _FailingCommandRelay({required super.clock, this.terminalStatus = 'failed'});

  final String terminalStatus;

  @override
  Future<SessionSnapshot> getSessionSnapshot(
    String sessionId, {
    int afterSequence = 0,
  }) async {
    final snapshot = await super.getSessionSnapshot(
      sessionId,
      afterSequence: afterSequence,
    );
    // A failed send is terminal from the client's perspective. Simulate the
    // daemon's status projection arriving as idle during the compensating read.
    if (snapshot.session.status != MobileSessionStatus.streaming) {
      return snapshot;
    }
    return SessionSnapshot(
      session: snapshot.session.copyWith(status: MobileSessionStatus.idle),
      events: snapshot.events,
    );
  }

  @override
  Future<SessionCommandReceipt> getSessionCommand(String commandId) async {
    return SessionCommandReceipt(
      id: commandId,
      kind: '',
      status: terminalStatus,
      idempotencyKey: 'fixture-$commandId',
    );
  }

  @override
  Future<SessionControlState> getSessionControls(String sessionId) async {
    // 与 fixture 会话目录对齐，让命令通过受理、拒绝集中到终态链路。
    return SessionControlState.empty().copyWith(
      models: const ['fixture-model-a', 'fixture-model-b'],
    );
  }
}

/// 捕获提交的命令并固定 controls 的模型与 effort 目录（V086 记忆测试）：
/// 模型/effort 命令统一以 succeeded 收口，断言自动回带与记忆写入行为。
class _ModelEffortControlsRelay extends FixtureRelayRepository {
  _ModelEffortControlsRelay({required super.clock});

  final List<SessionCommandInput> submitted = [];

  @override
  Future<SessionCommandReceipt> submitSessionCommand(
    String sessionId,
    SessionCommandInput input,
  ) {
    submitted.add(input);
    return super.submitSessionCommand(sessionId, input);
  }

  @override
  Future<SessionCommandReceipt> getSessionCommand(String commandId) async {
    return SessionCommandReceipt(
      id: commandId,
      kind: '',
      status: 'succeeded',
      idempotencyKey: 'fixture-$commandId',
    );
  }

  // 注意：不覆写 getSessionControls——fixture 种子已带
  // models=[fixture-model-a, fixture-model-b] / efforts=[低,中,高]，
  // 且 fixture 的 submitSessionCommand 会按同一份内部目录校验 effort 命令，
  // 测试必须使用种子值（低/中/高），否则命令会被 fixture 以
  // "目标 effort 不在目录中。" 拒绝。
}

/// 捕获提交的命令并固定 controls 的生效模型：验证发送密文把模型带给 daemon
/// （空模型会让 opencode 服务端回退到它的配置默认，可能命中付费条目）。
class _CapturingControlsRelay extends FixtureRelayRepository {
  _CapturingControlsRelay({required super.clock});

  final List<SessionCommandInput> submitted = [];

  @override
  Future<SessionCommandReceipt> submitSessionCommand(
    String sessionId,
    SessionCommandInput input,
  ) {
    submitted.add(input);
    return super.submitSessionCommand(sessionId, input);
  }

  @override
  Future<SessionControlState> getSessionControls(String sessionId) async {
    final controls = await super.getSessionControls(sessionId);
    return controls.copyWith(model: 'opencode/big-pickle');
  }
}

/// 在 sendMessage 后的首次快照中注入 completed_turn 事件，
/// 验证真实后端 turn.completed 终止路径在控制器里的状态收敛。
class _TurnCompletedRelay extends FixtureRelayRepository {
  _TurnCompletedRelay({required super.clock});

  bool armNextSnapshot = false;

  @override
  Future<SessionSnapshot> getSessionSnapshot(
    String sessionId, {
    int afterSequence = 0,
  }) async {
    final snapshot = await super.getSessionSnapshot(
      sessionId,
      afterSequence: afterSequence,
    );
    if (!armNextSnapshot) return snapshot;
    armNextSnapshot = false;
    final event = RelaySessionEvent(
      sequence: snapshot.session.lastSequence + 1,
      eventType: 'turn.completed',
      envelope: const {
        'fixture_payload': {
          'kind': 'assistant_message',
          'label': 'Assistant',
          'text': '回合已结束。',
          'completed_turn': true,
        },
      },
    );
    return SessionSnapshot(
      session: snapshot.session.copyWith(
        status: MobileSessionStatus.streaming,
        lastSequence: event.sequence,
      ),
      events: [...snapshot.events, event],
    );
  }
}

/// 首个 streaming 快照带事件，下一次仅返回 idle 状态和空增量，模拟事件已被
/// 消费但 session 投影稍后才收口的真实执行端时序。
class _EmptyDeltaIdleRelay extends FixtureRelayRepository {
  _EmptyDeltaIdleRelay({required super.clock});

  int streamingSnapshots = 0;

  @override
  Future<SessionSnapshot> getSessionSnapshot(
    String sessionId, {
    int afterSequence = 0,
  }) async {
    final snapshot = await super.getSessionSnapshot(
      sessionId,
      afterSequence: afterSequence,
    );
    if (snapshot.session.status != MobileSessionStatus.streaming) {
      return snapshot;
    }
    streamingSnapshots += 1;
    if (streamingSnapshots >= 2) {
      return SessionSnapshot(
        session: snapshot.session.copyWith(status: MobileSessionStatus.idle),
        events: const [],
      );
    }
    // Hide the fixture's permission/question waits so the first snapshot really
    // represents an in-progress turn and the second poll is exercised.
    return SessionSnapshot(
      session: snapshot.session,
      events: snapshot.events
          .where(
            (event) =>
                event.eventType != 'permission.requested' &&
                event.eventType != 'question.requested',
          )
          .toList(growable: false),
    );
  }
}

class _PendingDSHImportRelay extends FixtureRelayRepository {
  _PendingDSHImportRelay({required super.clock});

  var pollCount = 0;

  @override
  Future<WorkspaceImportState> importDSHSessions({
    required String workspaceId,
    String terminalId = '',
  }) async => const WorkspaceImportState(
    status: 'pending',
    commandId: 'cmd-import-pending',
  );

  @override
  Future<WorkspaceImportState> getDSHImportState(String commandId) async {
    pollCount += 1;
    return const WorkspaceImportState(
      status: 'pending',
      commandId: 'cmd-import-pending',
    );
  }
}

class _CompletingDSHWorkspaceSyncRelay extends FixtureRelayRepository {
  _CompletingDSHWorkspaceSyncRelay({required super.clock});

  var pollCount = 0;

  @override
  Future<WorkspaceSyncState> syncDSHWorkspaces({
    String terminalId = '',
  }) async => const WorkspaceSyncState(
    status: 'pending',
    commandId: 'cmd-sync-pending',
  );

  @override
  Future<WorkspaceSyncState> getDSHWorkspaceSyncState(String commandId) async {
    pollCount += 1;
    return const WorkspaceSyncState(
      status: 'succeeded',
      commandId: 'cmd-sync-pending',
      workspaceIds: ['ws-dsh'],
    );
  }
}

class _FailedDSHWorkspaceSyncRelay extends FixtureRelayRepository {
  _FailedDSHWorkspaceSyncRelay({required super.clock});

  @override
  Future<WorkspaceSyncState> syncDSHWorkspaces({
    String terminalId = '',
  }) async =>
      const WorkspaceSyncState(status: 'failed', errorCode: 'fixture_failed');
}

class _PendingDSHWorkspaceSyncRelay extends FixtureRelayRepository {
  _PendingDSHWorkspaceSyncRelay({required super.clock});

  var pollCount = 0;

  @override
  Future<WorkspaceSyncState> syncDSHWorkspaces({
    String terminalId = '',
  }) async => const WorkspaceSyncState(
    status: 'pending',
    commandId: 'cmd-sync-pending',
  );

  @override
  Future<WorkspaceSyncState> getDSHWorkspaceSyncState(String commandId) async {
    pollCount += 1;
    return const WorkspaceSyncState(
      status: 'pending',
      commandId: 'cmd-sync-pending',
    );
  }
}

const _ownerDeviceId = 'android-owner-fixture';
final _now = DateTime.utc(2026, 8, 14, 9, 30);

Future<void> _prepareOwner(FixtureRelayRepository relay) async {
  await bootstrapFixtureOwner(relay);
}

/// 稳定随机数让幂等键的测试环境可重复，但产品默认使用 Random.secure。
class _DeterministicRandom implements Random {
  var _value = 0;

  @override
  bool nextBool() => nextInt(2) == 1;

  @override
  double nextDouble() => nextInt(1 << 20) / (1 << 20);

  @override
  int nextInt(int max) {
    _value += 1;
    return _value % max;
  }
}
