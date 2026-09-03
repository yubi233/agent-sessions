
import 'package:agent_sessions_mobile/domain/control_models.dart';
import 'package:agent_sessions_mobile/domain/models.dart';
import 'package:agent_sessions_mobile/relay/fixture_relay_repository.dart';
import 'package:agent_sessions_mobile/state/session_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'support/fixture_owner.dart';

/// 回归：空闲会话状态行误显示"未连接"。
///
/// 根因：能力快照只在 App 启动时拉取一次；启动瞬间早于 daemon 完成 Provider
/// 探测（或拉取失败）时，"未连接"结果会缓存到 App 生命周期结束——即使服务端
/// 早已恢复 available。修复后打开会话强制刷新，失败时保留最近成功快照。
void main() {
  final baseNow = DateTime.utc(2026, 9, 4, 10, 0);
  var now = baseNow;

  test('启动竞态（探测未就绪）后打开会话刷新为已连接', () async {
    now = baseNow;
    final relay = _CountingCapsRelay(clock: () => now);
    // 模拟启动瞬间 daemon 尚未完成 DSH 探测。
    relay.providersUnavailable = true;
    final owner = await bootstrapFixtureOwner(relay);
    final controller = SessionController(relay: relay, clock: () => now);
    await controller.initialize();
    expect(
      controller.capabilityMatrix.provider('dsh').available,
      isFalse,
      reason: '探测未就绪时初始快照应不可用',
    );

    // daemon 探测完成后，打开会话必须以服务端当前事实重渲染状态行。
    relay.providersUnavailable = false;
    // 用 codex 会话驱动"打开会话"路径（避免 DSH 工作区前置）；被刷新的是
    // 整份能力快照，断言仍针对用户报告的 dsh 条目恢复。
    final created = await controller.createSession(
      workspaceId: 'fixture-workspace',
      provider: 'codex',
      deviceId: owner.deviceId,
      canWrite: true,
      autoStart: true,
    );
    expect(created, isNotNull);
    expect(
      controller.capabilityMatrix.provider('dsh').available,
      isTrue,
      reason: '打开会话应强制刷新能力快照，空闲会话状态行不再停留在"未连接"',
    );
    // 创建 + 启动 + 打开：能力端点至少被 initialize 与会话打开各调用一次。
    expect(relay.capabilitiesCalls, greaterThanOrEqualTo(2));
  });

  test('拉取失败时保留最近一次成功快照，不把好数据清成空矩阵', () async {
    now = baseNow;
    final relay = _CountingCapsRelay(clock: () => now);
    await bootstrapFixtureOwner(relay);
    final controller = SessionController(relay: relay, clock: () => now);
    await controller.initialize();
    final goodMatrix = controller.capabilityMatrix;
    expect(goodMatrix.provider('dsh').available, isTrue);

    // 越过节流窗口后发生一次失败：快照必须保持最近成功结果。
    relay.failCapabilities = true;
    now = baseNow.add(const Duration(seconds: 16));
    await controller.refreshCapabilities();
    expect(
      controller.capabilityMatrix.provider('dsh').available,
      isTrue,
      reason: '瞬时失败不得清空已成功的能力快照',
    );
  });

  test('非强制刷新走 15 秒节流窗口', () async {
    now = baseNow;
    final relay = _CountingCapsRelay(clock: () => now);
    await bootstrapFixtureOwner(relay);
    final controller = SessionController(relay: relay, clock: () => now);
    await controller.initialize();
    final callsAfterInitialize = relay.capabilitiesCalls;

    // 固定时钟下时间未推进：非强制调用应被节流跳过。
    await controller.refreshCapabilities();
    expect(relay.capabilitiesCalls, callsAfterInitialize);

    // 越过节流窗口后恢复拉取。
    now = baseNow.add(const Duration(seconds: 16));
    await controller.refreshCapabilities();
    expect(relay.capabilitiesCalls, callsAfterInitialize + 1);
  });
}

class _CountingCapsRelay extends FixtureRelayRepository {
  _CountingCapsRelay({required super.clock});

  int capabilitiesCalls = 0;
  bool failCapabilities = false;

  @override
  Future<CapabilityMatrix> getCapabilities() async {
    capabilitiesCalls += 1;
    if (failCapabilities) {
      throw const RelayFailure(
        RelayFailureKind.unavailable,
        'daemon Provider 探测尚未完成（测试注入）。',
      );
    }
    return super.getCapabilities();
  }
}
