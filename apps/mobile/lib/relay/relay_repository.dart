import '../domain/models.dart';
import '../domain/session_models.dart';

/// Flutter 只依赖此业务契约；真实 HTTP、fixture 或未来 WebSocket 实现都可替换。
abstract interface class RelayRepository {
  /// 首次注册由 Relay 创建初始 owner 设备，并返回已绑定的 token。
  Future<AuthTokens> register(LoginCredentials credentials);

  Future<AuthTokens> login(LoginCredentials credentials);

  Future<AuthTokens> refresh(String refreshToken);

  Future<void> logout(AuthTokens tokens);

  Future<Device> bootstrapOwner(BootstrapOwnerInput input);

  Future<List<Device>> listDevices();

  Future<void> revokeDevice(String deviceId);

  Future<PairingRequest> createPairing(PairingRequestInput input);

  Future<PairingRequest> getPairing(String requestId);

  Future<Device> approvePairing(String requestId);

  Future<void> cancelPairing(String requestId);

  /// 仅 owner 可生成；明文恢复码只返回当前调用方，业务层不得持久化。
  Future<String> generateRecoveryCode();

  Future<RecoveryResult> restoreWithRecoveryCode(RecoveryCodeInput input);

  /// 会话列表只返回 Relay 白名单元数据；标题等展示字段只能来自已解密缓存或 deterministic fixture。
  Future<List<MobileSession>> listSessions();

  /// 新建会话仍由认证设备身份授权，HTTP body 不允许客户端伪造 device_id。
  Future<MobileSession> createSession(CreateMobileSessionInput input);

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
}
