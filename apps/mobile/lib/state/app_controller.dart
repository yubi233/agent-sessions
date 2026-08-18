import 'package:flutter/foundation.dart';

import '../relay/relay_repository.dart';
import '../domain/models.dart';
import '../storage/encrypted_cache.dart';
import '../storage/secure_token_store.dart';

enum AppAuthPhase { booting, signedOut, authenticated }

/// 单一应用状态入口：页面只调用动作，不直接触碰 token、设备私钥或 Relay 传输。
class AppController extends ChangeNotifier {
  AppController({
    required RelayRepository relay,
    required SecureTokenStore tokenStore,
    required DeviceIdentityStore identityStore,
    required EncryptedCacheStore encryptedCache,
  }) : this._(relay, tokenStore, identityStore, encryptedCache);

  AppController._(
    this._relay,
    this._tokenStore,
    this._identityStore,
    this._encryptedCache,
  );

  final RelayRepository _relay;
  final SecureTokenStore _tokenStore;
  final DeviceIdentityStore _identityStore;
  final EncryptedCacheStore _encryptedCache;

  AppAuthPhase _phase = AppAuthPhase.booting;
  AuthTokens? _tokens;
  String? _boundDeviceId;
  List<Device> _devices = const [];
  final Map<String, PairingRequest> _pairings = {};
  bool _needsOwnerBootstrap = false;
  bool _requiresRecovery = false;
  bool _busy = false;
  String? _errorMessage;
  String? _recoveryCode;
  bool _initializing = false;

  AppAuthPhase get phase => _phase;
  bool get isAuthenticated =>
      _phase == AppAuthPhase.authenticated && _tokens != null;
  bool get isBusy => _busy;
  String? get errorMessage => _errorMessage;
  List<Device> get devices => List<Device>.unmodifiable(_devices);
  List<PairingRequest> get pairings =>
      List<PairingRequest>.unmodifiable(_pairings.values);
  bool get hasOwner => _devices.any((device) => device.isOwner);
  bool get needsOwnerBootstrap => _needsOwnerBootstrap;
  bool get requiresRecovery => _requiresRecovery;
  String? get recoveryCode => _recoveryCode;
  Device? get currentDevice {
    for (final device in _devices) {
      if (device.id == _boundDeviceId) {
        return device;
      }
    }
    return null;
  }

  /// 页面不能因为“列表里存在 owner”就解锁管理入口，必须是当前认证设备本身为 active owner。
  bool get canManageDevices =>
      (currentDevice?.isOwner ?? false) &&
      !_needsOwnerBootstrap &&
      !_requiresRecovery;

  /// 启动时只恢复安全存储 token；缓存中的密文不会在此处解密或展示。
  Future<void> initialize() async {
    if (_initializing) {
      return;
    }
    _initializing = true;
    _setBusy(true);
    try {
      final stored = await _tokenStore.read();
      if (stored == null) {
        _requiresRecovery = await _identityStore.requiresRecovery();
        _phase = AppAuthPhase.signedOut;
        return;
      }
      _tokens = stored;
      if (stored.needsRefresh) {
        _tokens = await _relay.refresh(stored.refreshToken);
        await _tokenStore.write(_tokens!);
      }
      await _adoptTokenBinding(_tokens!);
      await _reloadDevices();
      await _refreshBootstrapRequirement();
      _phase = AppAuthPhase.authenticated;
    } on RelayFailure {
      // token 失效时只清理本机认证与密文缓存，不将异常详情显示到日志。
      await _clearLocalSession();
      _phase = AppAuthPhase.signedOut;
      _errorMessage = '设备连接已失效，请重新连接或使用恢复码。';
    } catch (_) {
      await _clearLocalSession();
      _phase = AppAuthPhase.signedOut;
      _errorMessage = '无法恢复本机设备连接。';
    } finally {
      _initializing = false;
      _setBusy(false);
    }
  }

  /// Happy-style Android 主路径：不要求账号登录；首台手机用本机安全密钥直接初始化 owner。
  Future<void> connectThisDevice({String displayName = '此 Android 控制端'}) async {
    await _run(() async {
      final keys = await _identityStore.createOrRead();
      final result = await _relay.bootstrapDevice(
        BootstrapOwnerInput(
          displayName: displayName.trim().isEmpty
              ? '此 Android 控制端'
              : displayName.trim(),
          platform: 'android',
          keys: keys,
        ),
      );
      _validateDeviceTokenBinding(result.device, result.tokens);
      await _bindAcceptedDevice(result.device, tokens: result.tokens);
      _devices = [result.device];
      await _identityStore.markOwnerBootstrapComplete(true);
      _needsOwnerBootstrap = false;
      _requiresRecovery = false;
      _phase = AppAuthPhase.authenticated;
      await _reloadDevices();
    });
  }

  Future<void> signIn(LoginCredentials credentials) async {
    await _run(() async {
      final tokens = await _relay.login(credentials);
      _tokens = tokens;
      await _adoptTokenBinding(tokens);
      // 密码登录没有 Android 写设备绑定，只能读取账号元数据；owner 需恢复既有 token。
      await _tokenStore.write(_tokens!);
      await _reloadDevices();
      await _refreshBootstrapRequirement();
      _phase = AppAuthPhase.authenticated;
    });
  }

  /// 首次注册是唯一可创建初始 owner 的路径，成功后立刻完成该 owner 的公钥 bootstrap。
  Future<void> registerOwner(LoginCredentials credentials) async {
    await _run(() async {
      final tokens = await _relay.register(credentials);
      if (tokens.deviceId == null || tokens.deviceId!.isEmpty) {
        throw const RelayFailure(
          RelayFailureKind.protocol,
          '注册响应缺少初始 owner 设备绑定。',
        );
      }
      _tokens = tokens;
      await _adoptTokenBinding(tokens);
      await _tokenStore.write(_tokens!);
      await _reloadDevices();
      await _identityStore.markOwnerBootstrapComplete(false);
      _needsOwnerBootstrap = true;
      await _completeOwnerBootstrap();
      _phase = AppAuthPhase.authenticated;
    });
  }

  Future<void> signOut() async {
    await _run(() async {
      final tokens = _tokens;
      if (tokens != null) {
        try {
          await _relay.logout(tokens);
        } on RelayFailure {
          // 本地注销仍要完成，避免离线设备继续保留可用 token。
        }
      }
      await _clearLocalSession();
      _devices = const [];
      _pairings.clear();
      _phase = AppAuthPhase.signedOut;
    });
  }

  Future<void> bootstrapOwner({String displayName = '此 Android 控制端'}) async {
    await _run(() async {
      await _completeOwnerBootstrap(displayName: displayName);
    });
  }

  /// 扫码得到 request id 后读取请求；服务端才决定其是否属于当前账号与 owner。
  Future<void> loadPairingRequest(String requestId) async {
    await _run(() async {
      _requireOwner();
      final parsedRequestId = PairingPayload.requestIdFromScan(requestId);
      if (parsedRequestId == null) {
        throw const RelayFailure.validation('扫描结果不是有效的配对请求。');
      }
      final request = await _relay.getPairing(parsedRequestId);
      _pairings[request.id] = request;
    });
  }

  Future<void> approvePairing(String requestId) async {
    await _run(() async {
      _requireOwner();
      await _relay.approvePairing(requestId);
      final previous = _pairings[requestId];
      if (previous != null) {
        _pairings[requestId] = PairingRequest(
          id: previous.id,
          status: PairingStatus.approved,
          role: previous.role,
          displayName: previous.displayName,
          expiresAt: previous.expiresAt,
        );
      }
      await _reloadDevices();
    });
  }

  Future<void> cancelPairing(String requestId) async {
    await _run(() async {
      _requireOwner();
      await _relay.cancelPairing(requestId);
      final previous = _pairings[requestId];
      if (previous != null) {
        _pairings[requestId] = PairingRequest(
          id: previous.id,
          status: PairingStatus.cancelled,
          role: previous.role,
          displayName: previous.displayName,
          expiresAt: previous.expiresAt,
        );
      }
    });
  }

  Future<void> revokeDevice(String deviceId) async {
    await _run(() async {
      _requireOwner();
      await _relay.revokeDevice(deviceId);
      await _reloadDevices();
    });
  }

  Future<void> restoreWithRecoveryCode(
    String code, {
    String displayName = '恢复的 Android 控制端',
    String email = '',
  }) async {
    await _run(() async {
      if (code.trim().isEmpty) {
        throw const RelayFailure.validation('请输入恢复码。');
      }
      // 恢复码永远发送新的候选公钥；失败不会覆盖旧私钥或绑定，成功才提交替换。
      final keys = await _identityStore.createRecoveryCandidate();
      try {
        final result = await _relay.restoreWithRecoveryCode(
          RecoveryCodeInput(
            email: email.trim(),
            code: code.trim(),
            displayName: displayName.trim().isEmpty
                ? '恢复的 Android 控制端'
                : displayName.trim(),
            keys: keys,
          ),
        );
        // 先校验 Relay 的设备与 token 是同一绑定，再替换本机 active identity。
        // 这样损坏或串线的恢复响应会保留原私钥，用户仍可重试恢复而不会丢失现有身份。
        _validateDeviceTokenBinding(result.device, result.tokens);
        await _identityStore.commitRecoveryCandidate();
        await _bindAcceptedDevice(result.device, tokens: result.tokens);
        _devices = [result.device];
        await _identityStore.markOwnerBootstrapComplete(true);
        _needsOwnerBootstrap = false;
        _requiresRecovery = false;
        _phase = AppAuthPhase.authenticated;
      } catch (_) {
        await _identityStore.discardRecoveryCandidate();
        rethrow;
      }
    });
  }

  /// 恢复码仅保留在内存供当前 owner 立即展示；确认后清空，绝不写安全 token/cache 之外的存储。
  Future<void> generateRecoveryCode() async {
    await _run(() async {
      _requireOwner();
      _recoveryCode = await _relay.generateRecoveryCode();
    });
  }

  void dismissRecoveryCode() {
    if (_recoveryCode == null) return;
    _recoveryCode = null;
    notifyListeners();
  }

  void clearError() {
    if (_errorMessage == null) {
      return;
    }
    _errorMessage = null;
    notifyListeners();
  }

  Future<void> _reloadDevices() async {
    _devices = await _relay.listDevices();
  }

  /// 密码登录 token 没有 device_id 时必须降级为只读，不能借用设备安全存储里的旧绑定。
  Future<void> _adoptTokenBinding(AuthTokens tokens) async {
    final storedDeviceId = await _identityStore.readBoundDeviceId();
    final relayDeviceId = tokens.deviceId;
    if (relayDeviceId == null || relayDeviceId.isEmpty) {
      _boundDeviceId = null;
      return;
    }
    if (storedDeviceId != null && storedDeviceId != relayDeviceId) {
      throw const RelayFailure(
        RelayFailureKind.forbidden,
        '此安装已绑定到另一台设备，请使用恢复码。',
      );
    }
    await _identityStore.bindDeviceId(relayDeviceId);
    _boundDeviceId = relayDeviceId;
  }

  /// bootstrap/recovery 的设备对象由 Relay 签发；token 的 device_id 必须与其相同，不能本地改写。
  Future<void> _bindAcceptedDevice(Device device, {AuthTokens? tokens}) async {
    final boundTokens = tokens ?? _tokens;
    _validateDeviceTokenBinding(device, boundTokens);
    await _identityStore.bindDeviceId(device.id);
    _boundDeviceId = device.id;
    if (boundTokens != null) {
      _tokens = boundTokens;
      await _tokenStore.write(boundTokens);
    }
  }

  /// 写设备的 token 必须明确绑定到当前 Relay 设备；密码登录传 null 时只读降级仍是合法状态。
  void _validateDeviceTokenBinding(Device device, AuthTokens? tokens) {
    if (tokens != null &&
        (tokens.deviceId == null ||
            tokens.deviceId!.isEmpty ||
            tokens.deviceId != device.id)) {
      throw const RelayFailure(
        RelayFailureKind.protocol,
        'Relay 返回的设备令牌绑定不一致。',
      );
    }
  }

  Future<void> _completeOwnerBootstrap({
    String displayName = '此 Android 控制端',
  }) async {
    if (_requiresRecovery) {
      throw const RelayFailure(
        RelayFailureKind.forbidden,
        '本机设备密钥不完整，请使用恢复码恢复控制端。',
      );
    }
    final device = currentDevice;
    if (device == null || !device.isOwner) {
      throw const RelayFailure(RelayFailureKind.forbidden, '当前认证设备不是初始 owner。');
    }
    final keys = await _identityStore.createOrRead();
    final owner = await _relay.bootstrapOwner(
      BootstrapOwnerInput(
        displayName: displayName,
        platform: 'android',
        keys: keys,
      ),
    );
    await _bindAcceptedDevice(owner);
    await _identityStore.markOwnerBootstrapComplete(true);
    _needsOwnerBootstrap = false;
    await _reloadDevices();
  }

  Future<void> _refreshBootstrapRequirement() async {
    _requiresRecovery = await _identityStore.requiresRecovery();
    _needsOwnerBootstrap =
        !_requiresRecovery &&
        (currentDevice?.isOwner ?? false) &&
        !(await _identityStore.isOwnerBootstrapComplete());
  }

  void _requireOwner() {
    if (!canManageDevices) {
      throw const RelayFailure(
        RelayFailureKind.forbidden,
        '当前认证设备不是 active owner。',
      );
    }
  }

  Future<void> _clearLocalSession() async {
    await Future.wait([_tokenStore.clear(), _encryptedCache.clear()]);
    _tokens = null;
    _boundDeviceId = null;
    _needsOwnerBootstrap = false;
    _requiresRecovery = false;
    _recoveryCode = null;
  }

  Future<void> _run(Future<void> Function() action) async {
    _errorMessage = null;
    _setBusy(true);
    try {
      await action();
    } on RelayFailure catch (failure) {
      _errorMessage = failure.message;
    } catch (_) {
      _errorMessage = '操作未完成，请稍后重试。';
    } finally {
      _setBusy(false);
    }
  }

  void _setBusy(bool value) {
    _busy = value;
    notifyListeners();
  }
}
