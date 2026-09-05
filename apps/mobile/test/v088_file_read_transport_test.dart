import 'package:agent_sessions_mobile/domain/session_models.dart';
import 'package:agent_sessions_mobile/domain/workspace_files_models.dart';
import 'package:agent_sessions_mobile/files/relay_workspace_files_repository.dart';
import 'package:agent_sessions_mobile/git/readonly_command_gateway.dart';
import 'package:agent_sessions_mobile/relay/fixture_relay_repository.dart';
import 'package:flutter_test/flutter_test.dart';

/// v0.8.8 P3（V088-08 / 迭代计划 §5）：file_read 消费者真实传输契约回归。
/// 模拟 daemon 只读闭环（submit→receipt→tool_result 事件注入），断言
/// RelayWorkspaceFilesRepository 映射：目录列表（数组 result → entry 列表）、
/// 文本读取、二进制/超大错误码 → limitedKind 内容（fixture 同形）、越权与
/// 无 lease fail-closed。fixture UI 场景由既有 workspace files 测试保持。

final DateTime v088FilesNow = DateTime(2026, 9, 5, 14, 0, 0);

/// 模拟 daemon 只读闭环（与 git 传输测试同形；只读 submit 不走 fixture 命令面）。
class _ReadonlyFilesRelay extends FixtureRelayRepository {
  _ReadonlyFilesRelay({required super.clock});

  final List<String> submittedKinds = [];
  String? armedKind;
  Object? armedResult;
  String? failErrorCode;

  @override
  Future<SessionCommandReceipt> submitSessionCommand(
    String sessionId,
    SessionCommandInput input,
  ) async {
    submittedKinds.add(input.kind.wireValue);
    return SessionCommandReceipt(
      id: 'cmd-ro-files-${submittedKinds.length}',
      kind: input.kind.wireValue,
      status: 'accepted',
      idempotencyKey: input.idempotencyKey,
      leaseEpoch: input.leaseEpoch,
    );
  }

  @override
  Future<SessionCommandReceipt> getSessionCommand(String commandId) async {
    return SessionCommandReceipt(
      id: commandId,
      kind: '',
      status: failErrorCode == null ? 'succeeded' : 'failed',
      idempotencyKey: 'fixture-$commandId',
      errorCode: failErrorCode,
    );
  }

  @override
  Future<SessionSnapshot> getSessionSnapshot(
    String sessionId, {
    int afterSequence = 0,
  }) async {
    final events = <RelaySessionEvent>[];
    if (armedKind != null) {
      events.add(
        RelaySessionEvent(
          sequence: 700,
          eventType: 'tool.result',
          envelope: {
            'fixture_payload': {
              'kind': 'tool_result',
              'command_kind': armedKind,
              'result': armedResult,
            },
          },
          createdAt: v088FilesNow,
        ),
      );
    }
    return SessionSnapshot(session: _stubSession(sessionId), events: events);
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

RelayWorkspaceFilesRepository _buildRepository(_ReadonlyFilesRelay relay) =>
    RelayWorkspaceFilesRepository(
      filesGateway: ReadonlyCommandGateway(
        transport: relay,
        contextSource: () => const ReadonlySessionContext(
          sessionId: 'session-fixture-001',
          deviceId: 'device-1',
          leaseEpoch: 2,
        ),
        clock: () => v088FilesNow,
      ),
    );

void main() {
  test('V088-08a：file.tree 数组 result → 目录条目列表（name 取 basename）', () async {
    final relay = _ReadonlyFilesRelay(clock: () => v088FilesNow);
    relay.armedKind = 'file.tree';
    relay.armedResult = [
      {'path': 'lib', 'is_dir': true, 'size': 0},
      {'path': 'lib/main.dart', 'is_dir': false, 'size': 4096},
    ];
    final repository = _buildRepository(relay);

    final entries = await repository.listDirectory('lib');

    expect(entries, hasLength(2));
    expect(entries[0].name, 'lib');
    expect(entries[0].isDirectory, isTrue);
    expect(entries[1].name, 'main.dart');
    expect(entries[1].byteSize, 4096);
    expect(relay.submittedKinds, ['file.tree']);
  });

  test('V088-08b：file.read 文本内容 → 可预览 WorkspaceFileContent', () async {
    final relay = _ReadonlyFilesRelay(clock: () => v088FilesNow);
    relay.armedKind = 'file.read';
    relay.armedResult = {
      'path': 'lib/main.dart',
      'content': 'void main() {}\n',
    };
    final repository = _buildRepository(relay);

    final content = await repository.readFile('lib/main.dart');

    expect(content.limitedKind, WorkspaceFileLimitedKind.none);
    expect(content.isPreviewable, isTrue);
    expect(content.text, 'void main() {}\n');
    expect(relay.submittedKinds, ['file.read']);
  });

  test('V088-08c：CONTENT_UNAVAILABLE → binary limitedKind 内容（fixture 同形）', () async {
    final relay = _ReadonlyFilesRelay(clock: () => v088FilesNow);
    relay.failErrorCode = 'CONTENT_UNAVAILABLE';
    final repository = _buildRepository(relay);

    final content = await repository.readFile('build/logo.png');

    expect(content.limitedKind, WorkspaceFileLimitedKind.binary);
    expect(content.isPreviewable, isFalse);
    expect(content.text, isEmpty);
  });

  test('V088-08d：PAYLOAD_TOO_LARGE → tooLarge limitedKind + 截断标记', () async {
    final relay = _ReadonlyFilesRelay(clock: () => v088FilesNow);
    relay.failErrorCode = 'PAYLOAD_TOO_LARGE';
    final repository = _buildRepository(relay);

    final content = await repository.readFile('notes/huge.log');

    expect(content.limitedKind, WorkspaceFileLimitedKind.tooLarge);
    expect(content.isTruncated, isTrue);
  });

  test('V088-08e：WORKSPACE_PATH_DENIED → pathEscape 失败（越权负向）', () async {
    final relay = _ReadonlyFilesRelay(clock: () => v088FilesNow);
    relay.failErrorCode = 'WORKSPACE_PATH_DENIED';
    final repository = _buildRepository(relay);

    await expectLater(
      repository.readFile('/etc/passwd'),
      throwsA(
        isA<WorkspaceFilesFailure>().having(
          (f) => f.kind,
          'kind',
          WorkspaceFilesFailureKind.pathEscape,
        ),
      ),
    );
  });

  test('V088-08f：无 lease 上下文 fail-closed（不提交任何命令）', () async {
    final relay = _ReadonlyFilesRelay(clock: () => v088FilesNow);
    final repository = RelayWorkspaceFilesRepository(
      filesGateway: ReadonlyCommandGateway(
        transport: relay,
        contextSource: () => null,
        clock: () => v088FilesNow,
      ),
    );

    await expectLater(
      repository.listDirectory(''),
      throwsA(
        isA<WorkspaceFilesFailure>().having(
          (f) => f.kind,
          'kind',
          WorkspaceFilesFailureKind.unavailable,
        ),
      ),
    );
    expect(relay.submittedKinds, isEmpty, reason: 'fail-closed 不得产生命令提交');
  });
}
