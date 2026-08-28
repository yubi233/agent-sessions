import 'package:agent_sessions_mobile/domain/session_models.dart';
import 'package:agent_sessions_mobile/relay/fixture_relay_repository.dart';
import 'package:agent_sessions_mobile/state/session_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/session_harness.dart';

/// V07-03/V07-04 的 Flutter 根因回归：名称创建只走共享名称契约，成功后
/// 只把 Relay 白名单 workspace 投影回填到会话页，不让 Host canonical root 进入 UI。
void main() {
  testWidgets('MOBILE-V07-03：合法名称创建工作区并自动填入 workspace ID', (tester) async {
    final harness = MobileAppHarness();
    await tester.pumpWidget(harness.build());
    await waitForVisible(
      tester,
      find.byKey(const Key('device-connect-submit')),
    );
    await registerOwner(tester, 'v07-workspace-widget-owner@fixture.test');

    await tapVisible(tester, find.byKey(const Key('session-new-button')));
    await waitForVisible(
      tester,
      find.byKey(const Key('new-session-workspace-name-input')),
    );
    await enterVisible(
      tester,
      find.byKey(const Key('new-session-workspace-name-input')),
      'v07-widget-project',
    );
    await tapVisible(
      tester,
      find.byKey(const Key('new-session-create-workspace-button')),
    );

    await waitForVisible(
      tester,
      find.byKey(const Key('new-session-workspace-input')),
    );
    final workspaceID = tester
        .widget<TextFormField>(
          find.byKey(const Key('new-session-workspace-input')),
        )
        .controller!
        .text;
    expect(workspaceID, isNot('fixture-workspace'));
    expect(workspaceID, startsWith('ws_'));
    expect(
      (await harness.relay.listWorkspaces()).any(
        (workspace) => workspace.id == workspaceID,
      ),
      isTrue,
    );
    // Fixture 的 Workspace 投影不携带 canonical root；客户端也不能从状态对象取得它。
    expect(
      (await harness.relay.createWorkspaceWithFolder(
        const CreateMobileWorkspaceWithFolderInput(
          name: 'v07-widget-project',
          deviceId: 'android-owner-fixture',
        ),
      )).workspace,
      isNotNull,
    );
  });

  testWidgets('MOBILE-V07-04：非法名称在页面校验并且不会创建工作区', (tester) async {
    final harness = MobileAppHarness();
    await tester.pumpWidget(harness.build());
    await waitForVisible(
      tester,
      find.byKey(const Key('device-connect-submit')),
    );
    await registerOwner(tester, 'v07-workspace-widget-invalid@fixture.test');

    await tapVisible(tester, find.byKey(const Key('session-new-button')));
    await waitForVisible(
      tester,
      find.byKey(const Key('new-session-workspace-name-input')),
    );
    await enterVisible(
      tester,
      find.byKey(const Key('new-session-workspace-name-input')),
      '../escape',
    );
    await tapVisible(
      tester,
      find.byKey(const Key('new-session-create-workspace-button')),
    );
    await waitForVisible(tester, find.text('请输入合法工作区名称。'));
    expect(await harness.relay.listWorkspaces(), isEmpty);
  });

  testWidgets('MOBILE-V07-03：创建 pending 时按钮单飞并在结果收口后填入 ID', (tester) async {
    final relay = _PendingWorkspaceRelay();
    final harness = MobileAppHarness(relay: relay);
    await tester.pumpWidget(harness.build());
    await waitForVisible(
      tester,
      find.byKey(const Key('device-connect-submit')),
    );
    await registerOwner(tester, 'v07-workspace-widget-pending@fixture.test');

    await tapVisible(tester, find.byKey(const Key('session-new-button')));
    await waitForVisible(
      tester,
      find.byKey(const Key('new-session-workspace-name-input')),
    );
    await enterVisible(
      tester,
      find.byKey(const Key('new-session-workspace-name-input')),
      'v07-pending-project',
    );
    await tapVisible(
      tester,
      find.byKey(const Key('new-session-create-workspace-button')),
    );
    // 轮询首次返回前，UI 必须进入忙态，重复 tap 不得发起第二条命令。
    await tester.pump(const Duration(milliseconds: 20));
    expect(find.text('正在创建工作区…'), findsOneWidget);
    final button = tester.widget<OutlinedButton>(
      find.byKey(const Key('new-session-create-workspace-button')),
    );
    expect(button.onPressed, isNull);

    await pumpUntil(tester, () => relay.pollCount >= 2);
    expect(relay.createCount, 1);
    await waitForGone(tester, find.text('正在创建工作区…'));
    final workspaceID = tester
        .widget<TextFormField>(
          find.byKey(const Key('new-session-workspace-input')),
        )
        .controller!
        .text;
    expect(workspaceID, startsWith('ws_'));
  });
}

/// 可控 pending fixture：保留真实 controller 的轮询/单飞语义，不依赖网络或时钟。
class _PendingWorkspaceRelay extends FixtureRelayRepository {
  int createCount = 0;
  int pollCount = 0;
  CreateMobileWorkspaceWithFolderInput? _input;

  @override
  Future<WorkspaceCreateState> createWorkspaceWithFolder(
    CreateMobileWorkspaceWithFolderInput input,
  ) async {
    input.validate();
    createCount += 1;
    _input = input;
    return const WorkspaceCreateState(
      status: 'pending',
      commandId: 'fixture-pending-command',
      workspaceId: 'ws_v07_pending',
    );
  }

  @override
  Future<WorkspaceCreateState> getWorkspaceCreateState(String commandId) async {
    pollCount += 1;
    if (pollCount < 2) {
      return const WorkspaceCreateState(
        status: 'pending',
        commandId: 'fixture-pending-command',
        workspaceId: 'ws_v07_pending',
      );
    }
    final input = _input!;
    final workspace = await super.createWorkspaceWithFolder(input);
    return workspace;
  }
}

Future<void> pumpUntil(WidgetTester tester, bool Function() predicate) async {
  for (var i = 0; i < 80 && !predicate(); i += 1) {
    await tester.pump(const Duration(milliseconds: 50));
  }
  expect(predicate(), isTrue);
}
