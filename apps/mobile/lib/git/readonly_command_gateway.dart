import '../domain/git_diff_models.dart';
import '../domain/session_models.dart';
import '../domain/workspace_files_models.dart';
import '../relay/relay_repository.dart';

/// v0.8.8 P2/P3（迭代计划 §3 表）：应用层只读命令通道的移动端网关。
///
/// 链路（与 daemon `ReadOnlyDispatcher` 沙箱一一对应）：
///   submit（POST /v1/sessions/:id/commands，kind=git.status 等）
///     → receipt 轮询（GET /v1/commands/:id，succeeded/failed + 稳定错误码）
///     → tool_result 事件扫描（GET /v1/sessions/:id/snapshot?after_seq，
///       localdev encoder 投影 kind="tool_result"，result 为 daemon 结构化结果）。
///
/// 红线（对齐 ADR-014 §9 与计划 §1.4）：Git/文件明文只经本网关内存返回给
/// 只读视图，不进会话时间线正文（timeline 解析层丢弃 tool_result），
/// 不写日志、不进报告；命令经同一 lease/幂等/鉴权链路，不绕过写端授权。
/// 生产 E2EE 部署下事件为密文占位，只读视图维持不可用（fail-closed，§1.4）。
///
/// transport 直接取 [RelayRepository]：submit/receipt/snapshot 三个方法已在其
/// 接口内（同一 Dio/鉴权/401 刷新面），测试用 FixtureRelayRepository 子类覆写。

/// 只读命令的会话上下文：session-scoped 命令必须绑定当前 lease（fencing）
/// 与运行实例；上下文缺失（未选中会话/未持有 lease）时网关 fail-closed。
class ReadonlySessionContext {
  const ReadonlySessionContext({
    required this.sessionId,
    required this.deviceId,
    required this.leaseEpoch,
    this.targetInstanceId,
  });

  final String sessionId;
  final String deviceId;
  final int leaseEpoch;
  final String? targetInstanceId;
}

/// 稳定错误码 → 调用方视图失败的映射函数签名（入参：错误码、兜底文案）。
typedef ReadonlyFailureMapper = Exception Function(
  String errorCode,
  String fallbackMessage,
);

/// 真实网关：把「submit → receipt 轮询 → tool_result 扫描」封装为一次 execute。
/// 命令按 kind + 单调游标关联结果；单仓库内由 UI 顺序消费，不做并发去重。
class ReadonlyCommandGateway {
  ReadonlyCommandGateway({
    required this.transport,
    required this.contextSource,
    this.clock = DateTime.now,
    this.receiptPollAttempts = 60,
    this.receiptPollInterval = const Duration(milliseconds: 250),
    this.resultScanAttempts = 10,
  });

  final RelayRepository transport;
  final ReadonlySessionContext? Function() contextSource;
  final DateTime Function() clock;
  final int receiptPollAttempts;
  final Duration receiptPollInterval;
  final int resultScanAttempts;

  /// 结果扫描游标：只向前推进，保证同 kind 的先后命令不会错配旧结果。
  int _consumedThrough = 0;

  String? _activeSessionId;

  /// 执行一条只读命令并返回 daemon 结构化 `result` 对象。
  /// [failureMapper] 把稳定错误码翻译为调用方视图的失败类型
  /// （Git/Files 各自保留文案）；任何失败都不携带明文细节。
  Future<Map<String, dynamic>> execute({
    required String wireKind,
    required Map<String, dynamic> fixturePayload,
    required ReadonlyFailureMapper failureMapper,
  }) async {
    final context = _requireContext(failureMapper);
    _activeSessionId = context.sessionId;
    // 1. 提交：kind 与 fixture_payload 形状对齐 daemon parseEnvelope 契约
    //    （path/snapshot_token/offset/limit 白名单字段）；lease epoch 显式 fencing。
    var receipt = await transport.submitSessionCommand(
      context.sessionId,
      SessionCommandInput(
        kind: _kindForWire(wireKind),
        idempotencyKey:
            'ro-$wireKind-${context.sessionId}-${clock().microsecondsSinceEpoch}',
        leaseEpoch: context.leaseEpoch,
        deviceId: context.deviceId,
        targetInstanceId: context.targetInstanceId,
        ciphertext: {'fixture_payload': fixturePayload},
      ),
    );
    // 2. receipt 轮询到终态；超时按 transport 失败处理，不伪装成功/失败。
    for (var attempt = 0;
        attempt < receiptPollAttempts &&
            receipt.status != 'succeeded' &&
            receipt.status != 'failed';
        attempt += 1) {
      await Future<void>.delayed(receiptPollInterval);
      receipt = await transport.getSessionCommand(receipt.id);
    }
    if (receipt.status == 'failed') {
      throw failureMapper(
        receipt.errorCode ?? 'DAEMON_EXECUTION_FAILED',
        receipt.errorCode ?? '只读命令执行失败。',
      );
    }
    if (receipt.status != 'succeeded') {
      throw failureMapper('TRANSPORT_TIMEOUT', '只读命令超时，请稍后重试。');
    }
    // 3. 结果扫描：tool_result 事件按 kind + 游标向前匹配（迟到事件有限重扫）。
    return _scanToolResult(wireKind, failureMapper);
  }

  ReadonlySessionContext _requireContext(ReadonlyFailureMapper failureMapper) {
    final context = contextSource();
    if (context == null ||
        context.sessionId.isEmpty ||
        context.deviceId.isEmpty ||
        context.leaseEpoch <= 0) {
      throw failureMapper(
        'CAPABILITY_UNSUPPORTED',
        '只读视图需要选中会话并持有写控制权。',
      );
    }
    return context;
  }

  /// 在快照原始事件里查找本命令的 tool_result（kind 匹配 + 游标单调）。
  Future<Map<String, dynamic>> _scanToolResult(
    String wireKind,
    ReadonlyFailureMapper failureMapper,
  ) async {
    for (var attempt = 0; attempt < resultScanAttempts; attempt += 1) {
      final snapshot = await transport.getSessionSnapshot(
        _activeSessionId!,
        afterSequence: _consumedThrough,
      );
      for (final event in snapshot.events) {
        if (event.sequence <= _consumedThrough) continue;
        if (event.eventType != 'tool.result') continue;
        final fixture = event.envelope['fixture_payload'];
        if (fixture is! Map) continue;
        final payload = Map<String, dynamic>.from(fixture);
        if (payload['kind'] != 'tool_result') continue;
        if (payload['command_kind'] != wireKind) continue;
        final result = Map<String, dynamic>.from(
          (payload['result'] as Map?) ?? const {},
        );
        _consumedThrough = event.sequence;
        return result;
      }
      // 本轮未见结果：推进游标到当前快照末端，稍后重扫（事件可能迟到）。
      if (snapshot.events.isNotEmpty) {
        _consumedThrough = snapshot.events.last.sequence;
      }
      if (attempt + 1 < resultScanAttempts) {
        await Future<void>.delayed(receiptPollInterval);
      }
    }
    throw failureMapper(
      'DAEMON_EXECUTION_FAILED',
      '只读命令结果未到达，请刷新重试。',
    );
  }
}

/// SessionCommandKind 只覆盖会话写命令；只读 kind 由 wire 值直发（同一提交面）。
SessionCommandKind _kindForWire(String wireKind) => switch (wireKind) {
      'git.status' => SessionCommandKind.gitStatus,
      'git.changes' => SessionCommandKind.gitChanges,
      'git.diff' => SessionCommandKind.gitDiff,
      'file.tree' => SessionCommandKind.fileTree,
      'file.read' => SessionCommandKind.fileRead,
      'code.read' => SessionCommandKind.codeRead,
      _ => throw ArgumentError('未知只读命令 kind: $wireKind'),
    };

/// Git 视图的失败映射（稳定错误码 → GitDiffFailure，文案对齐 fixture 语义）。
GitDiffFailure gitDiffFailureMapper(String errorCode, String fallback) =>
    switch (errorCode) {
      'SNAPSHOT_STALE' => const GitDiffFailure(
          GitDiffFailureKind.snapshotStale,
          'Git 工作区已变化，请刷新后再查看 Diff。',
        ),
      'CAPABILITY_UNSUPPORTED' => GitDiffFailure(
          GitDiffFailureKind.unavailable,
          fallback,
        ),
      'LOCAL_STATE_MISSING' => const GitDiffFailure(
          GitDiffFailureKind.unavailable,
          '本机会话实例丢失，请重新打开会话后重试。',
        ),
      'WORKSPACE_PATH_DENIED' => const GitDiffFailure(
          GitDiffFailureKind.validation,
          '路径超出工作区安全边界，已拒绝读取。',
        ),
      'PAYLOAD_TOO_LARGE' => const GitDiffFailure(
          GitDiffFailureKind.validation,
          '内容超过单次读取上限，请在本机缩小范围后重试。',
        ),
      'INVALID_REQUEST' => GitDiffFailure(
          GitDiffFailureKind.validation,
          fallback,
        ),
      _ => GitDiffFailure(GitDiffFailureKind.transport, fallback),
    };

/// 文件视图的失败映射（稳定错误码 → WorkspaceFilesFailure）。
WorkspaceFilesFailure workspaceFilesFailureMapper(
  String errorCode,
  String fallback,
) =>
    switch (errorCode) {
      'SNAPSHOT_STALE' => const WorkspaceFilesFailure(
          WorkspaceFilesFailureKind.protocol,
          '工作区已变化，请刷新后再浏览。',
        ),
      'CAPABILITY_UNSUPPORTED' => WorkspaceFilesFailure(
          WorkspaceFilesFailureKind.unavailable,
          fallback,
        ),
      'LOCAL_STATE_MISSING' => const WorkspaceFilesFailure(
          WorkspaceFilesFailureKind.unavailable,
          '本机会话实例丢失，请重新打开会话后重试。',
        ),
      'WORKSPACE_PATH_DENIED' => const WorkspaceFilesFailure(
          WorkspaceFilesFailureKind.pathEscape,
          '路径超出工作区安全边界，已拒绝读取。',
        ),
      'PAYLOAD_TOO_LARGE' => const WorkspaceFilesFailure(
          WorkspaceFilesFailureKind.validation,
          '文件超出预览上限，只读视图不支持完整读取。',
        ),
      'INVALID_REQUEST' => WorkspaceFilesFailure(
          WorkspaceFilesFailureKind.validation,
          fallback,
        ),
      _ => WorkspaceFilesFailure(WorkspaceFilesFailureKind.protocol, fallback),
    };
