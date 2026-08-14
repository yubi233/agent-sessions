import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../domain/models.dart';

abstract interface class SecureTokenStore {
  Future<AuthTokens?> read();

  Future<void> write(AuthTokens tokens);

  Future<void> clear();
}

/// Android 由 Keystore 包装存储密钥；Web 使用 flutter_secure_storage 的 WebCrypto 实现。
class FlutterSecureTokenStore implements SecureTokenStore {
  FlutterSecureTokenStore({FlutterSecureStorage? storage})
    : _storage =
          storage ??
          const FlutterSecureStorage(
            aOptions: AndroidOptions(
              storageNamespace: 'agent_sessions.tokens.v1',
            ),
          );

  static const _storageKey = 'auth_tokens';
  final FlutterSecureStorage _storage;

  @override
  Future<AuthTokens?> read() async {
    final encoded = await _storage.read(key: _storageKey);
    if (encoded == null) {
      return null;
    }
    try {
      return AuthTokens.fromSecureJson(
        Map<String, dynamic>.from(jsonDecode(encoded) as Map),
      );
    } on FormatException {
      await clear();
      return null;
    }
  }

  @override
  Future<void> write(AuthTokens tokens) =>
      _storage.write(key: _storageKey, value: tokens.encodeForSecureStorage());

  @override
  Future<void> clear() => _storage.delete(key: _storageKey);
}

/// 测试和 fixture 使用的短生命周期实现；应用运行时会在 ProviderScope 中替换成安全存储。
class InMemorySecureTokenStore implements SecureTokenStore {
  AuthTokens? _tokens;

  @override
  Future<AuthTokens?> read() async => _tokens;

  @override
  Future<void> write(AuthTokens tokens) async {
    _tokens = tokens;
  }

  @override
  Future<void> clear() async {
    _tokens = null;
  }
}

abstract interface class DeviceIdentityStore {
  Future<DeviceRegistrationMaterial> createOrRead();

  /// 恢复码必须使用新候选密钥，绝不复用已撤销设备的身份公钥。
  Future<DeviceRegistrationMaterial> createRecoveryCandidate();

  /// 仅当 Relay 已接受候选公钥后，才把候选私钥切换为本机正式身份。
  Future<void> commitRecoveryCandidate();

  /// 恢复失败时删除候选私钥，保留原本机身份以便用户重试或查看现有只读状态。
  Future<void> discardRecoveryCandidate();

  /// 本机绑定 id 由 Relay 成功 bootstrap/login/recovery 后写入，不能来自可编辑 UI。
  Future<String?> readBoundDeviceId();

  Future<void> bindDeviceId(String deviceId);

  Future<bool> isOwnerBootstrapComplete();

  /// 检测到损坏的 active identity 后只能走恢复码，不能静默生成另一把未登记公钥。
  Future<bool> requiresRecovery();

  Future<void> markOwnerBootstrapComplete(bool complete);

  Future<void> clear();
}

/// 设备私钥只保存在安全存储；Relay 仅接收本方法返回的两个公钥。
class SecureDeviceIdentityStore implements DeviceIdentityStore {
  SecureDeviceIdentityStore({FlutterSecureStorage? storage})
    : _storage =
          storage ??
          const FlutterSecureStorage(
            aOptions: AndroidOptions(
              storageNamespace: 'agent_sessions.device-identity.v1',
            ),
          );

  static const _identityPublicKey = 'identity_public_key';
  static const _identityPrivateKey = 'identity_private_key';
  static const _encryptionPublicKey = 'encryption_public_key';
  static const _encryptionPrivateKey = 'encryption_private_key';
  static const _boundDeviceId = 'bound_device_id';
  static const _ownerBootstrapComplete = 'owner_bootstrap_complete';
  static const _identityCorrupted = 'identity_corrupted';
  static const _pendingIdentityPublicKey =
      'recovery_pending_identity_public_key';
  static const _pendingIdentityPrivateKey =
      'recovery_pending_identity_private_key';
  static const _pendingEncryptionPublicKey =
      'recovery_pending_encryption_public_key';
  static const _pendingEncryptionPrivateKey =
      'recovery_pending_encryption_private_key';
  final FlutterSecureStorage _storage;

  @override
  Future<DeviceRegistrationMaterial> createOrRead() async {
    if (await requiresRecovery()) {
      throw const RelayFailure(
        RelayFailureKind.forbidden,
        '本机设备密钥不完整，请使用恢复码恢复控制端。',
      );
    }
    final active = await _readKeySet(_activeKeyNames);
    if (_isComplete(active)) return _materialFrom(active);
    if (_hasAny(active)) {
      // 部分 key 不可能安全证明为已登记设备，清理绑定并持久标记为恢复状态。
      await _markActiveIdentityCorrupted();
      throw const RelayFailure(
        RelayFailureKind.forbidden,
        '本机设备密钥不完整，请使用恢复码恢复控制端。',
      );
    }

    final generated = await _generateKeySet();
    await _writeKeySet(_activeKeyNames, generated);
    return _materialFrom(generated);
  }

  @override
  Future<DeviceRegistrationMaterial> createRecoveryCandidate() async {
    final pending = await _readKeySet(_pendingKeyNames);
    if (_isComplete(pending)) return _materialFrom(pending);
    if (_hasAny(pending)) await discardRecoveryCandidate();

    final generated = await _generateKeySet();
    await _writeKeySet(_pendingKeyNames, generated);
    return _materialFrom(generated);
  }

  @override
  Future<void> commitRecoveryCandidate() async {
    final pending = await _readKeySet(_pendingKeyNames);
    if (!_isComplete(pending)) {
      throw const RelayFailure(
        RelayFailureKind.protocol,
        '恢复候选密钥不完整，无法绑定恢复后的设备。',
      );
    }
    // 先完整写入 active key，再删除候选；任何写入错误都会保留候选以供下次诊断。
    await _writeKeySet(_activeKeyNames, pending);
    await _storage.delete(key: _identityCorrupted);
    await discardRecoveryCandidate();
  }

  @override
  Future<void> discardRecoveryCandidate() => _deleteKeys(_pendingKeyNames);

  static const _activeKeyNames = <String>[
    _identityPublicKey,
    _identityPrivateKey,
    _encryptionPublicKey,
    _encryptionPrivateKey,
  ];
  static const _pendingKeyNames = <String>[
    _pendingIdentityPublicKey,
    _pendingIdentityPrivateKey,
    _pendingEncryptionPublicKey,
    _pendingEncryptionPrivateKey,
  ];

  Future<Map<String, String?>> _readKeySet(List<String> keys) async {
    final values = await Future.wait(
      keys.map((key) async => MapEntry(key, await _storage.read(key: key))),
    );
    return Map<String, String?>.fromEntries(values);
  }

  bool _isComplete(Map<String, String?> keys) =>
      keys.values.every((value) => value != null && value.isNotEmpty);

  bool _hasAny(Map<String, String?> keys) =>
      keys.values.any((value) => value != null && value.isNotEmpty);

  DeviceRegistrationMaterial _materialFrom(Map<String, String?> keys) =>
      DeviceRegistrationMaterial(
        identityPublicKey:
            keys[_identityPublicKey] ?? keys[_pendingIdentityPublicKey] ?? '',
        encryptionPublicKey:
            keys[_encryptionPublicKey] ??
            keys[_pendingEncryptionPublicKey] ??
            '',
      );

  Future<Map<String, String>> _generateKeySet() async {
    final identity = await Ed25519().newKeyPair();
    final encryption = await X25519().newKeyPair();
    final generatedIdentityPrivate = await identity.extractPrivateKeyBytes();
    final generatedEncryptionPrivate = await encryption
        .extractPrivateKeyBytes();
    final identityPublicBytes = (await identity.extractPublicKey()).bytes;
    final encryptionPublicBytes = (await encryption.extractPublicKey()).bytes;
    return <String, String>{
      _identityPublicKey: base64UrlEncode(identityPublicBytes),
      _identityPrivateKey: base64UrlEncode(generatedIdentityPrivate),
      _encryptionPublicKey: base64UrlEncode(encryptionPublicBytes),
      _encryptionPrivateKey: base64UrlEncode(generatedEncryptionPrivate),
    };
  }

  Future<void> _writeKeySet(
    List<String> destinations,
    Map<String, String?> source,
  ) async {
    final values = <String>[
      source[_identityPublicKey] ?? source[_pendingIdentityPublicKey]!,
      source[_identityPrivateKey] ?? source[_pendingIdentityPrivateKey]!,
      source[_encryptionPublicKey] ?? source[_pendingEncryptionPublicKey]!,
      source[_encryptionPrivateKey] ?? source[_pendingEncryptionPrivateKey]!,
    ];
    // 四项都先在内存完成后再写入，防止只持久化公钥造成后续身份无法恢复。
    await Future.wait([
      for (var index = 0; index < destinations.length; index += 1)
        _storage.write(key: destinations[index], value: values[index]),
    ]);
  }

  @override
  Future<String?> readBoundDeviceId() => _storage.read(key: _boundDeviceId);

  @override
  Future<void> bindDeviceId(String deviceId) {
    if (deviceId.isEmpty) {
      throw const RelayFailure.validation('Relay 未返回有效设备绑定。');
    }
    return _storage.write(key: _boundDeviceId, value: deviceId);
  }

  @override
  Future<bool> isOwnerBootstrapComplete() async {
    final values = await Future.wait([
      _storage.read(key: _ownerBootstrapComplete),
      _storage.read(key: _identityPrivateKey),
      _storage.read(key: _identityPublicKey),
      _storage.read(key: _encryptionPrivateKey),
      _storage.read(key: _encryptionPublicKey),
    ]);
    // 标记与四份密钥材料必须同时存在，且不能处于损坏恢复状态。
    return values.every((value) => value != null) &&
        values.first == 'true' &&
        !(await requiresRecovery());
  }

  @override
  Future<bool> requiresRecovery() async {
    if (await _storage.read(key: _identityCorrupted) == 'true') return true;
    final active = await _readKeySet(_activeKeyNames);
    if (_hasAny(active) && !_isComplete(active)) {
      // 启动恢复时也要识别部分写入，不能等用户点击 bootstrap 才暴露安全状态。
      await _markActiveIdentityCorrupted();
      return true;
    }
    return false;
  }

  @override
  Future<void> markOwnerBootstrapComplete(bool complete) => _storage.write(
    key: _ownerBootstrapComplete,
    value: complete ? 'true' : 'false',
  );

  Future<void> _markActiveIdentityCorrupted() async {
    await Future.wait([
      _deleteKeys(_activeKeyNames),
      _storage.delete(key: _boundDeviceId),
      _storage.delete(key: _ownerBootstrapComplete),
      _storage.write(key: _identityCorrupted, value: 'true'),
    ]);
  }

  Future<void> _deleteKeys(List<String> keys) =>
      Future.wait(keys.map((key) => _storage.delete(key: key)));

  @override
  Future<void> clear() => Future.wait([
    _deleteKeys(_activeKeyNames),
    _deleteKeys(_pendingKeyNames),
    _storage.delete(key: _boundDeviceId),
    _storage.delete(key: _ownerBootstrapComplete),
    _storage.delete(key: _identityCorrupted),
  ]);
}

class InMemoryDeviceIdentityStore implements DeviceIdentityStore {
  DeviceRegistrationMaterial? _material;
  DeviceRegistrationMaterial? _recoveryCandidate;
  String? _boundDeviceId;
  var _ownerBootstrapComplete = false;
  var _requiresRecovery = false;

  @override
  Future<DeviceRegistrationMaterial> createOrRead() async => _requiresRecovery
      ? throw const RelayFailure(
          RelayFailureKind.forbidden,
          '本机设备密钥不完整，请使用恢复码恢复控制端。',
        )
      : _material ??= const DeviceRegistrationMaterial(
          identityPublicKey: 'fixture-ed25519-public-key',
          encryptionPublicKey: 'fixture-x25519-public-key',
        );

  @override
  Future<DeviceRegistrationMaterial> createRecoveryCandidate() async =>
      _recoveryCandidate ??= const DeviceRegistrationMaterial(
        identityPublicKey: 'fixture-recovery-ed25519-public-key',
        encryptionPublicKey: 'fixture-recovery-x25519-public-key',
      );

  @override
  Future<void> commitRecoveryCandidate() async {
    final candidate = _recoveryCandidate;
    if (candidate == null) {
      throw const RelayFailure(RelayFailureKind.protocol, '恢复候选密钥不完整。');
    }
    _material = candidate;
    _recoveryCandidate = null;
    _requiresRecovery = false;
  }

  @override
  Future<void> discardRecoveryCandidate() async {
    _recoveryCandidate = null;
  }

  @override
  Future<String?> readBoundDeviceId() async => _boundDeviceId;

  @override
  Future<void> bindDeviceId(String deviceId) async {
    _boundDeviceId = deviceId;
  }

  @override
  Future<bool> isOwnerBootstrapComplete() async => _ownerBootstrapComplete;

  @override
  Future<bool> requiresRecovery() async => _requiresRecovery;

  @override
  Future<void> markOwnerBootstrapComplete(bool complete) async {
    _ownerBootstrapComplete = complete;
  }

  @override
  Future<void> clear() async {
    _material = null;
    _recoveryCandidate = null;
    _boundDeviceId = null;
    _ownerBootstrapComplete = false;
    _requiresRecovery = false;
  }
}

Uint8List decodeStoredKey(String encoded) =>
    Uint8List.fromList(base64Url.decode(base64Url.normalize(encoded)));
