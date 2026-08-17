import 'package:agent_sessions_mobile/domain/control_models.dart';
import 'package:agent_sessions_mobile/domain/daemon_observation_models.dart';
import 'package:agent_sessions_mobile/domain/delegation_models.dart';
import 'package:agent_sessions_mobile/domain/models.dart';
import 'package:agent_sessions_mobile/domain/session_models.dart';
import 'package:agent_sessions_mobile/domain/terminal_models.dart';
import 'package:agent_sessions_mobile/domain/usage_models.dart';
import 'package:agent_sessions_mobile/relay/fixture_relay_repository.dart';
import 'package:agent_sessions_mobile/relay/relay_repository.dart';
import 'package:agent_sessions_mobile/state/recent_sessions_controller.dart';
import 'package:flutter_test/flutter_test.dart';

/// MOBILE-25：最近会话页只读状态机。
/// 只消费 Relay 白名单会话元数据并按 updatedAt 稳定排序；
/// 刷新失败保留最后一份可信列表，无数据时进入可重试 error。
void main() {
  final now = DateTime.utc(2026, 8, 16, 12);

  group('MOBILE-25 最近会话控制器', () {
    test('初始 loading，refresh 后 ready；会话按 updatedAt 降序稳定排序', () async {
      // 用可变时钟推进，创建三个不同时间的会话，验证最新时间在最前。
      var clock = now;
      final relay = FixtureRelayRepository(clock: () => clock);
      await relay.register(_credentials());
      await relay.createSession(
        _sessionInput('workspace-a'),
      ); // session-fixture-001
      clock = clock.add(const Duration(minutes: 2));
      await relay.createSession(
        _sessionInput('workspace-b'),
      ); // session-fixture-002
      clock = clock.add(const Duration(minutes: 5));
      await relay.createSession(
        _sessionInput('workspace-c'),
      ); // session-fixture-003

      final controller = RecentSessionsController(relay: relay);

      // 尚未读取时处于 loading，列表为空且不算 empty
      expect(controller.phase, RecentSessionsPhase.loading);
      expect(controller.sessions, isEmpty);
      expect(controller.isEmpty, isFalse);

      await controller.initialize();

      expect(controller.phase, RecentSessionsPhase.ready);
      expect(controller.isRefreshing, isFalse);
      expect(controller.errorMessage, isNull);
      expect(controller.isEmpty, isFalse);
      // updatedAt 降序：最新的 session-fixture-003 在最前
      expect(controller.sessions.map((session) => session.id).toList(), [
        'session-fixture-003',
        'session-fixture-002',
        'session-fixture-001',
      ]);
      // 排序后仍持有完整白名单元数据
      expect(controller.sessions.first.workspaceId, 'workspace-c');
      expect(controller.sessions.first.provider, 'codex');
      expect(controller.sessions.first.lastSequence, 1);
    });

    test('空列表：ready + isEmpty', () async {
      final relay = FixtureRelayRepository(clock: () => now);
      final controller = RecentSessionsController(relay: relay);

      await controller.initialize();

      expect(controller.phase, RecentSessionsPhase.ready);
      expect(controller.isEmpty, isTrue);
      expect(controller.sessions, isEmpty);
      expect(controller.errorMessage, isNull);
      expect(controller.isRefreshing, isFalse);
    });

    test('排序独立于 relay 返回顺序：乱序输入也按 updatedAt 降序', () async {
      final relay = _ListOverridingRelay(
        FixtureRelayRepository(clock: () => now),
      );
      // 故意乱序返回，验证排序发生在控制器内部而非依赖 relay 预排序。
      relay.listOverride = () => [
        _session(
          'session-c',
          lastSequence: 1,
          updatedAt: now.subtract(const Duration(minutes: 9)),
        ),
        _session('session-a', lastSequence: 1, updatedAt: now),
        _session(
          'session-b',
          lastSequence: 1,
          updatedAt: now.subtract(const Duration(minutes: 3)),
        ),
      ];

      final controller = RecentSessionsController(relay: relay);
      await controller.initialize();

      expect(controller.sessions.map((session) => session.id).toList(), [
        'session-a',
        'session-b',
        'session-c',
      ]);
    });

    test('同 updatedAt：lastSequence 降序 → id 字典序，多次刷新顺序稳定', () async {
      final relay = _ListOverridingRelay(
        FixtureRelayRepository(clock: () => now),
      );
      relay.listOverride = () => [
        // 同时间戳，靠 lastSequence 与 id 决定次序。
        _session('session-zz', lastSequence: 1, updatedAt: now),
        _session('session-aa', lastSequence: 3, updatedAt: now),
        _session('session-mm', lastSequence: 2, updatedAt: now),
      ];

      final controller = RecentSessionsController(relay: relay);
      await controller.initialize();
      // lastSequence 降序：aa(3) → mm(2) → zz(1)
      expect(controller.sessions.map((session) => session.id).toList(), [
        'session-aa',
        'session-mm',
        'session-zz',
      ]);

      // lastSequence 相同时退到 id 字典序；多次刷新结果不变，避免页面跳项。
      relay.listOverride = () => [
        _session('session-zz', lastSequence: 1, updatedAt: now),
        _session('session-aa', lastSequence: 1, updatedAt: now),
        _session('session-mm', lastSequence: 1, updatedAt: now),
      ];
      await controller.refresh();
      expect(controller.sessions.map((session) => session.id).toList(), [
        'session-aa',
        'session-mm',
        'session-zz',
      ]);
      await controller.refresh();
      expect(controller.sessions.map((session) => session.id).toList(), [
        'session-aa',
        'session-mm',
        'session-zz',
      ]);
    });

    test('updatedAt 为 null 的会话排在有时间戳的会话之后', () async {
      final relay = _ListOverridingRelay(
        FixtureRelayRepository(clock: () => now),
      );
      relay.listOverride = () => [
        _session('session-no-time', lastSequence: 9, updatedAt: null),
        _session('session-with-time', lastSequence: 1, updatedAt: now),
      ];

      final controller = RecentSessionsController(relay: relay);
      await controller.initialize();

      expect(controller.sessions.map((session) => session.id).toList(), [
        'session-with-time',
        'session-no-time',
      ]);
    });

    test('RelayFailure：有数据时保留旧数据 + errorMessage；无数据时 error 且可重试', () async {
      final relay = FixtureRelayRepository(clock: () => now);
      await relay.register(_credentials());
      await relay.createSession(_sessionInput('workspace-retained'));
      final controller = RecentSessionsController(relay: relay);
      await controller.initialize();
      expect(controller.phase, RecentSessionsPhase.ready);

      // 已有数据时刷新失败：保留最后一份可信列表，只暴露内联错误信息。
      relay.setNetworkAvailable(false);
      await controller.refresh();
      expect(controller.phase, RecentSessionsPhase.ready);
      expect(controller.sessions.single.id, 'session-fixture-001');
      expect(controller.isEmpty, isFalse);
      expect(controller.errorMessage, contains('不可用'));

      // 无数据时首屏失败：进入 error，不显示 empty。
      final offlineRelay = FixtureRelayRepository(clock: () => now)
        ..setNetworkAvailable(false);
      final firstLoad = RecentSessionsController(relay: offlineRelay);
      await firstLoad.initialize();
      expect(firstLoad.phase, RecentSessionsPhase.error);
      expect(firstLoad.sessions, isEmpty);
      expect(firstLoad.isEmpty, isFalse);
      expect(firstLoad.errorMessage, contains('不可用'));

      // 恢复网络后重试成功进入 ready。
      offlineRelay.setNetworkAvailable(true);
      await firstLoad.refresh();
      expect(firstLoad.phase, RecentSessionsPhase.ready);
      expect(firstLoad.errorMessage, isNull);
      expect(firstLoad.isEmpty, isTrue);
    });
  });
}

MobileSession _session(
  String id, {
  required int lastSequence,
  DateTime? updatedAt,
}) => MobileSession(
  id: id,
  workspaceId: 'workspace-$id',
  status: MobileSessionStatus.idle,
  provider: 'codex',
  lastSequence: lastSequence,
  updatedAt: updatedAt,
);

CreateMobileSessionInput _sessionInput(String workspaceId) =>
    CreateMobileSessionInput(
      workspaceId: workspaceId,
      provider: 'codex',
      deviceId: 'android-owner-fixture',
    );

LoginCredentials _credentials() => const LoginCredentials(
  email: 'recent-controller@fixture.test',
  password: 'fixture-password',
);

/// 包装 fixture 并注入自定义 listSessions 返回顺序（原样返回、不预排序），
/// 用于验证 RecentSessionsController 自身的稳定排序逻辑。
class _ListOverridingRelay implements RelayRepository {
  _ListOverridingRelay(this._delegate);

  final FixtureRelayRepository _delegate;

  /// 设置后 listSessions 返回该列表；为 null 时走 fixture 默认实现。
  List<MobileSession> Function()? listOverride;

  @override
  Future<UsageSummary> getUsageSummary({int days = 30}) =>
      _delegate.getUsageSummary(days: days);

  @override
  Future<List<MobileSession>> listSessions() async {
    final override = listOverride;
    return List<MobileSession>.unmodifiable(
      override?.call() ?? await _delegate.listSessions(),
    );
  }

  @override
  Future<AuthTokens> register(LoginCredentials credentials) =>
      _delegate.register(credentials);

  @override
  Future<AuthTokens> login(LoginCredentials credentials) =>
      _delegate.login(credentials);

  @override
  Future<AuthTokens> refresh(String refreshToken) =>
      _delegate.refresh(refreshToken);

  @override
  Future<void> logout(AuthTokens tokens) => _delegate.logout(tokens);

  @override
  Future<Device> bootstrapOwner(BootstrapOwnerInput input) =>
      _delegate.bootstrapOwner(input);

  @override
  Future<List<Device>> listDevices() => _delegate.listDevices();

  @override
  Future<void> revokeDevice(String deviceId) =>
      _delegate.revokeDevice(deviceId);

  @override
  Future<List<TerminalSummary>> listTerminals() => _delegate.listTerminals();

  @override
  Future<PairingRequest> createPairing(PairingRequestInput input) =>
      _delegate.createPairing(input);

  @override
  Future<PairingRequest> getPairing(String requestId) =>
      _delegate.getPairing(requestId);

  @override
  Future<Device> approvePairing(String requestId) =>
      _delegate.approvePairing(requestId);

  @override
  Future<void> cancelPairing(String requestId) =>
      _delegate.cancelPairing(requestId);

  @override
  Future<String> generateRecoveryCode() => _delegate.generateRecoveryCode();

  @override
  Future<RecoveryResult> restoreWithRecoveryCode(RecoveryCodeInput input) =>
      _delegate.restoreWithRecoveryCode(input);

  @override
  Future<MobileSession> createSession(CreateMobileSessionInput input) =>
      _delegate.createSession(input);

  @override
  Future<SessionSnapshot> getSessionSnapshot(
    String sessionId, {
    int afterSequence = 0,
  }) => _delegate.getSessionSnapshot(sessionId, afterSequence: afterSequence);

  @override
  Future<DaemonSessionObservation> getSessionDaemonObservation(
    String sessionId, {
    int afterSequence = 0,
  }) => _delegate.getSessionDaemonObservation(
    sessionId,
    afterSequence: afterSequence,
  );

  @override
  Future<SessionLease> acquireSessionLease(String sessionId) =>
      _delegate.acquireSessionLease(sessionId);

  @override
  Future<SessionCommandReceipt> submitSessionCommand(
    String sessionId,
    SessionCommandInput input,
  ) => _delegate.submitSessionCommand(sessionId, input);

  @override
  Future<List<SessionDelegation>> listSessionDelegations(
    String parentSessionId,
  ) => _delegate.listSessionDelegations(parentSessionId);

  @override
  Future<SessionDelegation> proposeDelegation(
    String parentSessionId,
    DelegationProposalInput input,
  ) => _delegate.proposeDelegation(parentSessionId, input);

  @override
  Future<SessionDelegation> decideDelegation(
    String delegationId,
    DelegationDecisionInput input,
  ) => _delegate.decideDelegation(delegationId, input);

  @override
  Future<CapabilityMatrix> getCapabilities() => _delegate.getCapabilities();

  @override
  Future<bool> sessionContentKeyAvailable(String sessionId) =>
      _delegate.sessionContentKeyAvailable(sessionId);

  @override
  Future<SessionControlState> getSessionControls(String sessionId) =>
      _delegate.getSessionControls(sessionId);

  @override
  Future<AttachmentReceipt> uploadAttachmentChunk(
    AttachmentChunkUploadInput input,
  ) => _delegate.uploadAttachmentChunk(input);

  @override
  Future<AttachmentReceipt> completeAttachment(AttachmentCompleteInput input) =>
      _delegate.completeAttachment(input);
}
