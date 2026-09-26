import 'package:agent_sessions_mobile/domain/session_models.dart';
import 'package:agent_sessions_mobile/relay/fixture_relay_repository.dart';
import 'package:agent_sessions_mobile/relay/relay_repository.dart';
import 'package:agent_sessions_mobile/state/session_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fixture_owner.dart';

MobileSession _session({
  String id = 'sess_hist_1',
  MobileSessionVisibility visibility = MobileSessionVisibility.history,
  String? displayName,
}) => MobileSession(
  id: id,
  workspaceId: 'ws-dsh',
  status: MobileSessionStatus.idle,
  provider: 'dsh',
  lastSequence: 0,
  displayName: displayName,
  origin: MobileSessionOrigin.dshImport,
  visibility: visibility,
);

/// v0.9.6 展示边界回归：外部历史默认不可见；显式发现才出现候选；
/// 逐条接续后才进入日常列表；无标题命名不再误称历史。
void main() {
  test('MOBILE-HIST-1 无标题 DSH 会话显示未命名标签，不再误称历史', () {
    expect(_session(displayName: '').title, '未命名 DSH 会话');
    expect(_session(displayName: '真实验证标题').title, '真实验证标题');
  });

  test('MOBILE-HIST-2 历史/副本默认不可见', () {
    expect(_session().isVisible, isFalse);
    expect(_session().isHistoryCandidate, isTrue);
    expect(
      _session(visibility: MobileSessionVisibility.duplicate).isVisible,
      isFalse,
    );
    expect(
      _session(visibility: MobileSessionVisibility.duplicate)
          .isHistoryCandidate,
      isFalse,
    );
  });

  test('MOBILE-HIST-3 历史候选需显式发现并逐条接续后进入日常列表', () async {
    final relay = FixtureRelayRepository(clock: () => DateTime.now());
    final owner = await bootstrapFixtureOwner(relay);
    relay.replaceWorkspaces(const [
      MobileWorkspace(
        id: 'ws-dsh',
        projectId: 'dsh-project',
        terminalId: 'term-dsh',
        origin: MobileWorkspaceOrigin.dsh,
        displayName: 'history-project',
        status: 'active',
      ),
    ]);
    relay.seedDSHHistoryCandidate(_session());

    // 未发现前：历史候选不在任何列表（默认/候选均不可见）。
    expect(await relay.listSessions(), isEmpty);
    expect(await (relay as SessionHistoryRepository).listHistorySessions(), isEmpty);

    final controller = SessionController(relay: relay);
    await controller.initialize();

    // 显式发现后成为候选；日常列表仍看不到。
    final importState = await controller.importDSHSessions(
      workspaceId: 'ws-dsh',
      deviceId: owner.deviceId,
      canWrite: true,
    );
    expect(importState?.isSucceeded, isTrue);
    expect(
      controller.sessions.where((item) => item.id == 'sess_hist_1'),
      isEmpty,
    );
    final candidates = await (relay as SessionHistoryRepository)
        .listHistorySessions();
    expect(candidates.map((item) => item.id), ['sess_hist_1']);

    // 逐条接续后才可见，来源保持 dsh_import。
    final managed = await controller.manageHistorySession(
      candidate: _session(),
      deviceId: owner.deviceId,
      canWrite: true,
    );
    expect(managed?.id, 'sess_hist_1');
    expect(managed?.visibility, MobileSessionVisibility.defaultList);
    expect(managed?.origin, MobileSessionOrigin.dshImport);
    expect(
      controller.sessions.where((item) => item.id == 'sess_hist_1'),
      isNotEmpty,
    );
    expect(
      await (relay as SessionHistoryRepository).listHistorySessions(),
      isEmpty,
    );

    // 副本永远不可接续。
    final rejected = await controller.manageHistorySession(
      candidate: _session(
        id: 'sess_dup_1',
        visibility: MobileSessionVisibility.duplicate,
      ),
      deviceId: owner.deviceId,
      canWrite: true,
    );
    expect(rejected, isNull);
  });
}
