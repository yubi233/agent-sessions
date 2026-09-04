// v0.8.6 B 组：权限目录全会话可达 controller 回归（V086-03/04/05）。
// - start/resume 回执后立即刷新 controls（目录秒级到达，不等回合结束）；
// - permissionDirectoryHint：capability 支持但目录未同步时给出禁用原因；
// - 停止会话的 mode.set 客户端预检拦截（启动会话后再切换）。
import 'package:agent_sessions_mobile/domain/control_models.dart';
import 'package:agent_sessions_mobile/domain/session_models.dart';
import 'package:agent_sessions_mobile/relay/fixture_relay_repository.dart';
import 'package:agent_sessions_mobile/state/session_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fixture_owner.dart';

/// 统计 controls 拉取次数；withCatalog=false 模拟"目录未同步"的历史会话。
class _PermissionCatalogRelay extends FixtureRelayRepository {
  _PermissionCatalogRelay({required super.clock});

  int controlsFetches = 0;
  bool withCatalog = true;

  @override
  Future<SessionCommandReceipt> getSessionCommand(String commandId) async {
    return SessionCommandReceipt(
      id: commandId,
      kind: '',
      status: 'succeeded',
      idempotencyKey: 'fixture-$commandId',
    );
  }

  @override
  Future<SessionControlState> getSessionControls(String sessionId) async {
    controlsFetches += 1;
    final controls = await super.getSessionControls(sessionId);
    if (!withCatalog) {
      return controls.copyWith(availablePermissionModes: const []);
    }
    return controls;
  }
}

void main() {
  test('V086-03：resume 回执后立即刷新 controls', () async {
    final relay = _PermissionCatalogRelay(clock: () => DateTime.now());
    final owner = await bootstrapFixtureOwner(relay);
    final controller = SessionController(relay: relay);
    await controller.initialize();
    await controller.createSession(
      workspaceId: 'fixture-workspace',
      provider: 'codex',
      deviceId: owner.deviceId,
      canWrite: true,
    );
    final baseline = relay.controlsFetches;

    await controller.resumeSelectedSession(
      deviceId: owner.deviceId,
      canWrite: true,
    );

    // 刷新是 fire-and-forget：轮询等待计数增长。
    final deadline = DateTime.now().add(const Duration(seconds: 3));
    while (relay.controlsFetches <= baseline &&
        DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(relay.controlsFetches, greaterThan(baseline));
  });

  test('V086-04：capability 支持但目录未同步时给出禁用原因提示', () async {
    final relay = _PermissionCatalogRelay(clock: () => DateTime.now());
    final owner = await bootstrapFixtureOwner(relay);
    relay.replaceWorkspaces([
      const MobileWorkspace(
        id: 'ws-v086',
        projectId: 'v086-project',
        terminalId: 'term-v086',
        origin: MobileWorkspaceOrigin.dsh,
        displayName: 'v086 工作区',
        status: 'active',
      ),
    ]);
    final controller = SessionController(relay: relay);
    await controller.initialize();
    await controller.createSession(
      workspaceId: 'ws-v086',
      provider: 'dsh',
      deviceId: owner.deviceId,
      canWrite: true,
      autoStart: true,
    );
    await controller.refreshSelectedControls();

    // 目录在位：无提示。
    expect(controller.permissionDirectoryHint, isNull);
    // 目录被剥离（历史会话形态）：给出可执行原因。
    relay.withCatalog = false;
    await controller.refreshSelectedControls();
    expect(controller.permissionDirectoryHint, contains('权限目录未同步'));
    expect(controller.permissionDirectoryHint, contains('启动会话'));
  });

  test('V086-05：停止会话的 mode.set 预检拦截并提示启动会话', () async {
    final relay = _PermissionCatalogRelay(clock: () => DateTime.now());
    final owner = await bootstrapFixtureOwner(relay);
    relay.replaceWorkspaces([
      const MobileWorkspace(
        id: 'ws-v086',
        projectId: 'v086-project',
        terminalId: 'term-v086',
        origin: MobileWorkspaceOrigin.dsh,
        displayName: 'v086 工作区',
        status: 'active',
      ),
    ]);
    final controller = SessionController(relay: relay);
    await controller.initialize();
    await controller.createSession(
      workspaceId: 'ws-v086',
      provider: 'dsh',
      deviceId: owner.deviceId,
      canWrite: true,
    );
    // kill 让会话进入 stopped（真实链路：daemon 重启/实例回收后的形态）。
    await controller.killSelectedSession(
      deviceId: owner.deviceId,
      canWrite: true,
    );
    expect(controller.selectedSession?.status, MobileSessionStatus.stopped);

    await controller.selectPermissionMode(
      mode: 'default',
      deviceId: owner.deviceId,
      canWrite: true,
    );

    expect(controller.errorMessage, '会话未运行，启动后可切换权限模式。');
  });
}
