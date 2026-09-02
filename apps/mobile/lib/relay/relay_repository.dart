import '../domain/control_models.dart';
import '../domain/daemon_observation_models.dart';
import '../domain/delegation_models.dart';
import '../domain/models.dart';
import '../domain/session_models.dart';
import '../domain/session_projection_models.dart';
import '../domain/terminal_models.dart';
import '../domain/usage_models.dart';

/// Flutter 只依赖此业务契约；真实 HTTP、fixture 或未来 Daemon 命令流实现都可替换。
abstract interface class RelayRepository {
  /// Happy-style Android 首次启动：由本机设备密钥直接初始化首个 owner，不要求账号登录。
  Future<DeviceBootstrapResult> bootstrapDevice(BootstrapOwnerInput input);

  /// 首次注册由 Relay 创建初始 owner 设备，并返回已绑定的 token。
  Future<AuthTokens> register(LoginCredentials credentials);

  Future<AuthTokens> login(LoginCredentials credentials);

  Future<AuthTokens> refresh(String refreshToken);

  Future<void> logout(AuthTokens tokens);

  Future<Device> bootstrapOwner(BootstrapOwnerInput input);

  Future<List<Device>> listDevices();

  Future<void> revokeDevice(String deviceId);

  /// 仅返回账号范围的 Terminal 白名单元数据；不得携带路径、日志或命令 payload。
  Future<List<TerminalSummary>> listTerminals();

  /// 读取账号最近 1/7/30 天（UTC 日桶）的白名单用量聚合（ADR-010）。
  /// 只返回整数计数与 Provider/日桶标识，不包含 prompt、回复、费用或精确时间。
  Future<UsageSummary> getUsageSummary({int days = 30});

  Future<PairingRequest> createPairing(PairingRequestInput input);

  Future<PairingRequest> getPairing(String requestId);

  Future<Device> approvePairing(String requestId);

  Future<void> cancelPairing(String requestId);

  /// 仅 owner 可生成；明文恢复码只返回当前调用方，业务层不得持久化。
  Future<String> generateRecoveryCode();

  Future<RecoveryResult> restoreWithRecoveryCode(RecoveryCodeInput input);

  /// 会话列表只返回 Relay 白名单元数据；标题等展示字段只能来自已解密缓存或 deterministic fixture。
  Future<List<MobileSession>> listSessions();

  /// 已归档会话列表；只包含显式归档的会话，读取不触发状态对账。
  Future<List<MobileSession>> listArchivedSessions();

  /// Workspace list is metadata-only; canonical host roots are intentionally
  /// absent from the response.
  Future<List<MobileWorkspace>> listWorkspaces();

  /// 显式请求 Daemon 扫描授权根中的 DSH 工作区；响应只包含脱敏状态。
  Future<WorkspaceSyncState> syncDSHWorkspaces({String terminalId = ''});

  /// 轮询 workspace.sync_dsh 的最终状态；停止客户端等待不会取消 Daemon 命令。
  Future<WorkspaceSyncState> getDSHWorkspaceSyncState(String commandId);

  /// 按工作区导入 DSH 历史会话的安全元数据；不返回 transcript 或路径。
  Future<WorkspaceImportState> importDSHSessions({
    required String workspaceId,
    String terminalId = '',
  });

  /// 轮询 session.import_dsh 的脱敏状态。
  Future<WorkspaceImportState> getDSHImportState(String commandId);

  /// Register a directory selected by the composed host directory flow.
  Future<MobileWorkspace> createWorkspace(CreateMobileWorkspaceInput input);

  /// 仅提交名称的真实 workspace.create 编排；结果不包含 Host canonical root。
  Future<WorkspaceCreateState> createWorkspaceWithFolder(
    CreateMobileWorkspaceWithFolderInput input,
  );

  /// 轮询 workspace.create 的脱敏状态。
  Future<WorkspaceCreateState> getWorkspaceCreateState(String commandId);

  /// 新建会话仍由认证设备身份授权，HTTP body 不允许客户端伪造 device_id。
  Future<MobileSession> createSession(CreateMobileSessionInput input);

  /// 从已完成 assistant 消息创建 child session。Relay 只返回白名单 lineage 元数据，
  /// 不复制正文、不启动 Provider。
  Future<MobileSession> forkSession(String sessionId, SessionForkInput input);

  /// 归档会话：Relay 本地元数据操作，数据与事件全部保留，仅从默认列表隐藏。
  Future<MobileSession> archiveSession(String sessionId);

  /// 取消归档，将会话恢复到默认列表。
  Future<MobileSession> unarchiveSession(String sessionId);

  /// 快照保留 Relay 的原始加密 envelope，解密与展示映射由客户端安全边界负责。
  Future<SessionSnapshot> getSessionSnapshot(
    String sessionId, {
    int afterSequence = 0,
  });

  /// 获取当前会话的 fencing epoch；后续每条控制命令必须带这个正数值。
  Future<SessionLease> acquireSessionLease(String sessionId);

  /// 提交会话控制命令。device_id 只在本地输入中校验，Relay 从 bearer token 推导实际写设备。
  Future<SessionCommandReceipt> submitSessionCommand(
    String sessionId,
    SessionCommandInput input,
  );

  /// 读取命令的最终收口状态；控制面命令的乐观更新必须经此确认。
  Future<SessionCommandReceipt> getSessionCommand(String commandId);

  /// P2-F：读取真实 Relay 的 Daemon 安全观察投影。该接口只读且不返回原始密文 envelope。
  Future<DaemonSessionObservation> getSessionDaemonObservation(
    String sessionId, {
    int afterSequence = 0,
  });

  /// parent 图只返回密文摘要与 child 引用；任务书和 child 正文不会经过该接口返回。
  Future<List<SessionDelegation>> listSessionDelegations(
    String parentSessionId,
  );

  /// v0.2/P2：Android 在父会话内发起子会话派发，只提交密文任务书/摘要与目标 Provider。
  /// 返回 proposed 节点；批准前不创建 child Session、不启动 Provider。
  Future<SessionDelegation> proposeDelegation(
    String parentSessionId,
    DelegationProposalInput input,
  );

  /// Android 用 parent lease 批准、拒绝或取消 Delegation。child 的后续控制必须重新获取 child lease。
  Future<SessionDelegation> decideDelegation(
    String delegationId,
    DelegationDecisionInput input,
  );

  /// Relay capability matrix 是会话控制入口的唯一依据；未知能力由客户端按 unsupported 展示。
  Future<CapabilityMatrix> getCapabilities();

  /// v0.2/P3：会话内容密钥（DEK）可用性。fixture 表示本机已持有该会话内容密钥；
  /// 真实 Relay 尚未部署 E2EE 内容密钥通道时保持 false（附件入口 fail-closed）。
  Future<bool> sessionContentKeyAvailable(String sessionId);

  /// Plan/Goal/Skill 摘要只来自本地已解密事件或 deterministic fixture；Relay 不返回明文控制内容。
  Future<SessionControlState> getSessionControls(String sessionId);

  /// Assistant message feedback 的真实 Relay 持久化协议。
  Future<ConversationFeedbackItem?> getMessageFeedback(
    String sessionId,
    String messageId,
  );

  Future<ConversationFeedbackResult> putMessageFeedback(
    String sessionId, {
    required String messageId,
    required ConversationFeedbackRating rating,
    String? note,
    int? version,
  });

  Future<ConversationFeedbackResult> deleteMessageFeedback(
    String sessionId, {
    required String messageId,
    required int version,
  });

  /// 仅上传客户端已经加密的附件块。显示名不会进入本层的公开契约。
  Future<AttachmentReceipt> uploadAttachmentChunk(
    AttachmentChunkUploadInput input,
  );

  /// 完成操作有独立幂等键，避免上传重试造成重复完成事件。
  Future<AttachmentReceipt> completeAttachment(AttachmentCompleteInput input);
}
