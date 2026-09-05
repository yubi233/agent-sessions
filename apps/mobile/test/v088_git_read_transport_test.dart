
import 'package:agent_sessions_mobile/domain/git_diff_models.dart';
import 'package:agent_sessions_mobile/domain/models.dart';
import 'package:agent_sessions_mobile/domain/session_models.dart';
import 'package:agent_sessions_mobile/git/readonly_command_gateway.dart';
import 'package:agent_sessions_mobile/git/relay_git_diff_repository.dart';
import 'package:agent_sessions_mobile/relay/fixture_relay_repository.dart';
import 'package:flutter_test/flutter_test.dart';

/// v0.8.8 P2（V088-07 / 迭代计划 §5）：git_read 真实传输契约回归。
/// 用 FixtureRelayRepository 子类模拟 daemon 只读执行闭环（submit→receipt→
/// tool_result 事件），断言 ReadonlyCommandGateway 关联 + RelayGitDiffRepository
/// 映射：快照字段、diff 分页/行号解析、stale/越权失败映射、无 lease fail-closed。
/// fixture 场景（main/restricted）回归由既有 git_diff_controller_test 保持。
/// 模拟 daemon 只读闭环：只读 submit 受理后，快照注入 tool_result 事件，
/// receipt 二次轮询返回终态（可注入失败码）。
class _ReadonlyLoopRelay extends FixtureRelayRepository {
  _ReadonlyLoopRelay({required super.clock});

  final List<String> submittedKinds = [];
  final List<Map<String, dynamic>> submittedPayloads = [];
  String? armedKind;
  Map<String, dynamic>? armedResult;
  String? failErrorCode;
  int receiptPolls = 0;

  @override
  Future<SessionCommandReceipt> submitSessionCommand(
    String sessionId,
    SessionCommandInput input,
  ) async {
    submittedKinds.add(input.kind.wireValue);
    submittedPayloads.add(
      Map<String, dynamic>.from(
        (input.ciphertext?['fixture_payload'] as Map?) ?? const {},
      ),
    );
    return SessionCommandReceipt(
      id: 'cmd-ro-${submittedKinds.length}',
      kind: input.kind.wireValue,
      status: 'accepted',
      idempotencyKey: input.idempotencyKey,
      leaseEpoch: input.leaseEpoch,
    );
  }

  @override
  Future<SessionCommandReceipt> getSessionCommand(String commandId) async {
    receiptPolls += 1;
    // 首次轮询仍受理（证明网关会等终态），之后按注入返回终态。
    if (receiptPolls > 1) {
      return SessionCommandReceipt(
        id: commandId,
        kind: '',
        status: failErrorCode == null ? 'succeeded' : 'failed',
        idempotencyKey: 'fixture-$commandId',
        errorCode: failErrorCode,
      );
    }
    return SessionCommandReceipt(
      id: commandId,
      kind: '',
      status: 'accepted',
      idempotencyKey: 'fixture-$commandId',
    );
  }

  @override
  Future<SessionSnapshot> getSessionSnapshot(
    String sessionId, {
    int afterSequence = 0,
  }) async {
    // 本测试只关注 tool_result 注入；fixture 会话不存在时回退空事件快照。
    SessionSnapshot snapshot;
    try {
      snapshot = await super.getSessionSnapshot(
        sessionId,
        afterSequence: afterSequence,
      );
    } on RelayFailure {
      snapshot = SessionSnapshot(
        session: _stubSession(sessionId),
        events: const [],
      );
    }
    if (armedKind == null) {
      return snapshot;
    }
    final resultEvent = RelaySessionEvent(
      sequence: 900,
      eventType: 'tool.result',
      envelope: {
        'fixture_payload': {
          'kind': 'tool_result',
          'command_kind': armedKind,
          'result': armedResult ?? const {},
        },
      },
      createdAt: v088Now,
    );
    return SessionSnapshot(
      session: snapshot.session,
      events: [...snapshot.events, resultEvent],
    );
  }
}

/// fixture 会话缺失时的最小会话投影（网关只消费 events，不读会话字段）。
MobileSession _stubSession(String sessionId) => MobileSession(
      id: sessionId,
      workspaceId: 'ws-fixture',
      status: MobileSessionStatus.idle,
      provider: 'codex',
      lastSequence: 0,
    );


/// 固定上下文（有/无 lease 两种形态）。
class _ContextRelay extends _ReadonlyLoopRelay {
  _ContextRelay({required super.clock, this.context});

  final ReadonlySessionContext? context;
}


final DateTime v088Now = DateTime(2026, 9, 5, 12, 0, 0);

void main() {
  final now = v088Now;

  test('V088-07a：git.status 全链 → GitDiffSnapshot 白名单字段映射', () async {
    final relay = _ReadonlyLoopRelay(clock: () => now);
    relay.armedKind = 'git.status';
    relay.armedResult = {
      'head': '9f83decafe00ba4212345678',
      'branch': 'feature/v088',
      'snapshot_token': 'snap-1',
      'files': [
        {
          'path': 'lib/main.dart',
          'type': 'modified',
          'staged': true,
          'unstaged': true,
          'additions': 12,
          'deletions': 4,
        },
        {
          'path': 'lib/old.dart',
          'type': 'renamed',
          'staged': true,
          'unstaged': false,
          'additions': 0,
          'deletions': 0,
          'rename': {'from': 'lib/legacy.dart', 'to': 'lib/old.dart'},
        },
      ],
      'truncated': false,
    };
    final repository = RelayGitDiffRepository(
      gateway: ReadonlyCommandGateway(
        transport: relay,
        contextSource: () => const ReadonlySessionContext(
          sessionId: 'session-fixture-001',
          deviceId: 'device-1',
          leaseEpoch: 3,
        ),
        clock: () => now,
      ),
    );

    final snapshot = await repository.loadSnapshot();

    expect(snapshot.snapshotToken, 'snap-1');
    expect(snapshot.branch, 'feature/v088');
    expect(snapshot.files, hasLength(2));
    expect(snapshot.summary.changedFiles, 2);
    expect(snapshot.summary.additions, 12);
    expect(snapshot.summary.deletions, 4);
    expect(snapshot.summary.stagedFiles, 2);
    expect(snapshot.files[1].type, GitChangeType.renamed);
    expect(snapshot.files[1].renameFrom, 'lib/legacy.dart');
    // 提交形状：kind=git.status + fixture_payload 透传（daemon parseEnvelope 契约）。
    expect(relay.submittedKinds, ['git.status']);
    expect(relay.submittedPayloads.single, isEmpty);
  });

  test('V088-07b：git.diff 分页与 unified 行号解析', () async {
    final relay = _ReadonlyLoopRelay(clock: () => now);
    relay.armedKind = 'git.diff';
    relay.armedResult = {
      'path': 'lib/main.dart',
      'snapshot_token': 'snap-1',
      'offset': 0,
      'next_offset': 2,
      'has_more': true,
      'hunks': [
        {
          'header': '@@ -42,6 +42,9 @@ class Session',
          'lines': [
            '  void clear() {',
            '-    _x = null;',
            '+    _y = null;',
            '+    _z = null;',
            '  }',
          ],
        },
      ],
      'binary': false,
      'truncated': false,
    };
    final repository = RelayGitDiffRepository(
      gateway: ReadonlyCommandGateway(
        transport: relay,
        contextSource: () => const ReadonlySessionContext(
          sessionId: 'session-fixture-001',
          deviceId: 'device-1',
          leaseEpoch: 3,
        ),
        clock: () => now,
      ),
    );

    final page = await repository.loadFileDiff(
      path: 'lib/main.dart',
      snapshotToken: 'snap-1',
      offset: 0,
      limit: 2,
    );

    expect(page.hasMore, isTrue);
    expect(page.nextOffset, 2);
    expect(page.hunks, hasLength(1));
    final lines = page.hunks.single.lines;
    expect(lines[0].kind, GitDiffLineKind.context);
    expect(lines[0].oldLine, 42);
    expect(lines[0].newLine, 42);
    expect(lines[1].kind, GitDiffLineKind.deletion);
    expect(lines[1].oldLine, 43);
    expect(lines[2].kind, GitDiffLineKind.addition);
    expect(lines[2].newLine, 43);
    expect(lines[3].newLine, 44);
    // 提交形状：path/snapshot_token/offset/limit 白名单字段（daemon 契约）。
    expect(relay.submittedKinds, ['git.diff']);
    expect(relay.submittedPayloads.single, {
      'path': 'lib/main.dart',
      'snapshot_token': 'snap-1',
      'offset': 0,
      'limit': 2,
    });
  });

  test('V088-07c：SNAPSHOT_STALE 收口映射为 stale 失败（UI 可重试刷新）', () async {
    final relay = _ReadonlyLoopRelay(clock: () => now);
    relay.failErrorCode = 'SNAPSHOT_STALE';
    final repository = RelayGitDiffRepository(
      gateway: ReadonlyCommandGateway(
        transport: relay,
        contextSource: () => const ReadonlySessionContext(
          sessionId: 'session-fixture-001',
          deviceId: 'device-1',
          leaseEpoch: 3,
        ),
        clock: () => now,
        receiptPollAttempts: 3,
      ),
    );

    await expectLater(
      repository.loadFileDiff(
        path: 'lib/main.dart',
        snapshotToken: 'stale-token',
        offset: 0,
        limit: 2,
      ),
      throwsA(
        isA<GitDiffFailure>()
            .having((f) => f.kind, 'kind', GitDiffFailureKind.snapshotStale),
      ),
    );
  });

  test('V088-07d：无 lease 上下文 fail-closed（不提交任何命令）', () async {
    final relay = _ContextRelay(clock: () => now, context: null);
    final repository = RelayGitDiffRepository(
      gateway: ReadonlyCommandGateway(
        transport: relay,
        contextSource: () => relay.context,
        clock: () => now,
      ),
    );

    await expectLater(
      repository.loadSnapshot(),
      throwsA(
        isA<GitDiffFailure>()
            .having((f) => f.kind, 'kind', GitDiffFailureKind.unavailable),
      ),
    );
    expect(relay.submittedKinds, isEmpty, reason: 'fail-closed 不得产生命令提交');
  });

  test('V088-07e：CAPABILITY_UNSUPPORTED 收口映射为 unavailable（矩阵降级面）', () async {
    final relay = _ReadonlyLoopRelay(clock: () => now);
    relay.failErrorCode = 'CAPABILITY_UNSUPPORTED';
    final repository = RelayGitDiffRepository(
      gateway: ReadonlyCommandGateway(
        transport: relay,
        contextSource: () => const ReadonlySessionContext(
          sessionId: 'session-fixture-001',
          deviceId: 'device-1',
          leaseEpoch: 3,
        ),
        clock: () => now,
        receiptPollAttempts: 3,
      ),
    );

    await expectLater(
      repository.loadSnapshot(),
      throwsA(
        isA<GitDiffFailure>()
            .having((f) => f.kind, 'kind', GitDiffFailureKind.unavailable),
      ),
    );
  });
}
