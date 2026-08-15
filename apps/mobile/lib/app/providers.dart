import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
// P1 仍由 ChangeNotifier 承载单一应用状态；Riverpod 3 将该 provider 移到显式 legacy 入口。
import 'package:flutter_riverpod/legacy.dart';

import '../attachments/attachment_picker.dart';
import '../relay/fixture_relay_repository.dart';
import '../relay/http_relay_repository.dart';
import '../relay/relay_repository.dart';
import '../git/git_diff_repository.dart';
import '../files/workspace_files_repository.dart';
import '../state/app_controller.dart';
import '../state/delegation_controller.dart';
import '../state/git_diff_controller.dart';
import '../state/lifecycle_recovery_controller.dart';
import '../state/session_controller.dart';
import '../state/workspace_files_controller.dart';
import '../storage/encrypted_cache.dart';
import '../storage/secure_token_store.dart';
import '../storage/theme_preference_store.dart';
import 'theme_controller.dart';

/// 未配置 RELAY_BASE_URL 时使用固定 fixture，保证 Android/Web 本地测试无需真实上游。
final secureTokenStoreProvider = Provider<SecureTokenStore>(
  (ref) => InMemorySecureTokenStore(),
);
final deviceIdentityStoreProvider = Provider<DeviceIdentityStore>(
  (ref) => InMemoryDeviceIdentityStore(),
);
final encryptedCacheStoreProvider = Provider<EncryptedCacheStore>(
  (ref) => InMemoryEncryptedCacheStore(),
);
final themePreferenceStoreProvider = Provider<ThemePreferenceStore>(
  (ref) => InMemoryThemePreferenceStore(),
);

/// 外观状态与认证、Relay 和会话控制分离，主题切换不会触发远端读取或写入。
final themeControllerProvider = ChangeNotifierProvider<ThemeController>((ref) {
  final controller = ThemeController(ref.read(themePreferenceStoreProvider));
  unawaited(controller.initialize());
  return controller;
});

final relayRepositoryProvider = Provider<RelayRepository>((ref) {
  const relayBaseUrl = String.fromEnvironment('RELAY_BASE_URL');
  if (relayBaseUrl.isEmpty) {
    return FixtureRelayRepository();
  }
  return HttpRelayRepository(
    dio: Dio(
      BaseOptions(
        baseUrl: relayBaseUrl,
        connectTimeout: const Duration(seconds: 10),
      ),
    ),
    readTokens: () => ref.read(secureTokenStoreProvider).read(),
  );
});

/// Git 读取独立于 Relay 会话 repository：本地 fixture 可验收 UI，而已配置 Relay 时必须等待加密 Daemon RPC。
final gitDiffRepositoryProvider = Provider<GitDiffRepository>((ref) {
  const relayBaseUrl = String.fromEnvironment('RELAY_BASE_URL');
  if (relayBaseUrl.isEmpty) {
    return FixtureGitDiffRepository();
  }
  return const UnavailableDaemonGitDiffRepository();
});

/// 只读文件浏览与 Git 一样独立于会话传输：fixture 验收 UI；真实 Relay 未部署加密 Daemon RPC 时不可用。
final workspaceFilesRepositoryProvider = Provider<WorkspaceFilesRepository>((
  ref,
) {
  const relayBaseUrl = String.fromEnvironment('RELAY_BASE_URL');
  if (relayBaseUrl.isEmpty) {
    return FixtureWorkspaceFilesRepository();
  }
  return const UnavailableWorkspaceFilesRepository();
});

final appControllerProvider = ChangeNotifierProvider<AppController>((ref) {
  final controller = AppController(
    relay: ref.read(relayRepositoryProvider),
    tokenStore: ref.read(secureTokenStoreProvider),
    identityStore: ref.read(deviceIdentityStoreProvider),
    encryptedCache: ref.read(encryptedCacheStoreProvider),
  );
  unawaited(controller.initialize());
  return controller;
});

/// 会话流、lease 和 composer 与认证状态独立管理，避免登录页面 rebuild 影响已打开的时间线。
final sessionControllerProvider = ChangeNotifierProvider<SessionController>((
  ref,
) {
  final controller = SessionController(
    relay: ref.read(relayRepositoryProvider),
    // 真实运行使用系统文件选择器；会话 DEK 通道未部署时内部 fail-closed。
    picker: const SystemAttachmentPicker(
      contentKeyProvider: _sessionContentKeyFromStore,
    ),
  );
  unawaited(controller.initialize());
  return controller;
});

/// 会话内容密钥提供方：当前无 Keystore 内容密钥通道，固定返回 null（fail-closed）。
/// fixture 模式由 FixtureRelayRepository.sessionContentKeyAvailable 放行入口，
/// 但真实密封只会发生在真实 DEK 通道部署之后。
Future<Uint8List?> _sessionContentKeyFromStore(String sessionId) async {
  return null;
}

/// 生命周期适配层只消费该 controller；它通过 SessionController 的只读 cursor 恢复接口补齐事件，
/// 不拥有 token、lease 或任何待发送命令，避免前后台恢复意外重放写入。
final sessionRecoveryControllerProvider =
    ChangeNotifierProvider<SessionRecoveryController>((ref) {
      final controller = SessionRecoveryController(
        sessions: ref.read(sessionControllerProvider),
      );
      return controller;
    });

/// Delegation 图与会话正文独立拉取，父会话切换时不会把上一页的 child 节点短暂画到当前页面。
final delegationControllerProvider =
    ChangeNotifierProvider<DelegationController>(
      (ref) => DelegationController(relay: ref.read(relayRepositoryProvider)),
    );

/// DiffView 采用独立状态机，避免会话刷新、lease 或 composer rebuild 影响只读 Git 快照。
final gitDiffControllerProvider = ChangeNotifierProvider<GitDiffController>((
  ref,
) {
  final controller = GitDiffController(
    repository: ref.read(gitDiffRepositoryProvider),
  );
  unawaited(controller.initialize());
  return controller;
});

/// 文件浏览控制器只读取只读 repository；与 DiffView 一样独立于会话状态机。
final workspaceFilesControllerProvider =
    ChangeNotifierProvider<WorkspaceFilesController>((ref) {
      return WorkspaceFilesController(
        repository: ref.read(workspaceFilesRepositoryProvider),
      );
    });
