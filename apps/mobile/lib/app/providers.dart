import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
// P1 仍由 ChangeNotifier 承载单一应用状态；Riverpod 3 将该 provider 移到显式 legacy 入口。
import 'package:flutter_riverpod/legacy.dart';

import '../attachments/attachment_picker.dart';
import '../crypto/box.dart';
import '../domain/models.dart';
import '../relay/fixture_relay_repository.dart';
import '../relay/relay_repository.dart';
import '../relay/acceptance_tls.dart';
import '../relay/http_relay_repository.dart';
import '../git/git_diff_repository.dart';
import '../git/readonly_command_gateway.dart';
import '../files/relay_workspace_files_repository.dart';
import '../git/relay_git_diff_repository.dart';
import '../files/workspace_files_repository.dart';
import '../state/app_controller.dart';
import '../state/code_viewer_controller.dart';
import '../state/command_palette_controller.dart';
import '../state/daemon_observation_controller.dart';
import '../state/delegation_controller.dart';
import '../state/git_diff_controller.dart';
import '../state/lifecycle_recovery_controller.dart';
import '../state/message_deep_link_controller.dart';
import '../state/recent_sessions_controller.dart';
import '../state/session_controller.dart';
import '../state/session_info_controller.dart';
import '../state/session_view_controller.dart';
import '../state/composer_preference_controller.dart';
import '../state/settings_controller.dart';
import '../state/terminal_status_controller.dart';
import '../state/usage_controller.dart';
import '../state/workspace_files_controller.dart';
import '../storage/composer_preference_store.dart';
import '../storage/encrypted_cache.dart';
import '../storage/model_effort_preference_store.dart';
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
final composerPreferenceStoreProvider = Provider<ComposerPreferenceStore>(
  (ref) => InMemoryComposerPreferenceStore(),
);

/// 「模型 → 上次选中推理等级」本地记忆（v0.8.6）：选模型自动带回上次使用的
/// 推理等级，模型列表在模型名后展示该值。与认证、Relay 和会话控制分离。
final modelEffortPreferenceStoreProvider = Provider<ModelEffortPreferenceStore>(
  (ref) => InMemoryModelEffortPreferenceStore(),
);

/// Composer 用户级偏好（Enter Queue/Steer）与认证、Relay 和会话控制分离。
final composerPreferenceControllerProvider =
    ChangeNotifierProvider<ComposerPreferenceController>((ref) {
      final controller = ComposerPreferenceController(
        ref.read(composerPreferenceStoreProvider),
      );
      unawaited(controller.initialize());
      return controller;
    });

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
    // 验收环境自签证书指纹放行（计划 §1/§4.4）：未构建期注入 ACC_TLS_FINGERPRINT 时
    // 是空操作，默认构建走系统信任链不受影响。
    dio: applyAcceptanceTls(
      Dio(
        BaseOptions(
          baseUrl: relayBaseUrl,
          connectTimeout: const Duration(seconds: 10),
          receiveTimeout: const Duration(seconds: 12),
          sendTimeout: const Duration(seconds: 12),
        ),
      ),
    ),
    readTokens: () => ref.read(secureTokenStoreProvider).read(),
    // 401 自动刷新会把旋转后的 refresh token 写回安全存储，防止 reuse 撤销整族令牌。
    writeTokens: (tokens) => ref.read(secureTokenStoreProvider).write(tokens),
  );
});

/// Git 读取独立于 Relay 会话 repository（明文不进会话时间线契约）：
/// 本地 fixture 验收 UI；已配置 Relay 时走 v0.8.8 P2 真实传输——只读命令
/// （git.status/git.diff）经同一 lease/幂等/鉴权链路提交，结果从 tool_result
/// 事件回读（localdev 明文投影；生产 E2EE 下为密文占位，视图保持不可用）。
final gitDiffRepositoryProvider = Provider<GitDiffRepository>((ref) {
  const relayBaseUrl = String.fromEnvironment('RELAY_BASE_URL');
  if (relayBaseUrl.isEmpty) {
    return FixtureGitDiffRepository();
  }
  return RelayGitDiffRepository(
    gateway: ReadonlyCommandGateway(
      transport: ref.read(relayRepositoryProvider),
      contextSource: () => _readonlySessionContext(ref),
    ),
  );
});

/// 只读命令的会话上下文：当前选中会话 + 本机持有 lease 的 epoch。
/// 无会话/无 lease/无设备绑定时返回 null——网关 fail-closed 提示不可用。
ReadonlySessionContext? _readonlySessionContext(Ref ref) {
  final sessions = ref.read(sessionControllerProvider);
  final sessionId = sessions.selectedSessionId;
  final lease = sessions.selectedLease;
  final deviceId = ref.read(appControllerProvider).boundDeviceId;
  if (sessionId == null || deviceId == null || deviceId.isEmpty) {
    return null;
  }
  if (lease == null || lease.sessionId != sessionId || lease.epoch <= 0) {
    return null;
  }
  return ReadonlySessionContext(
    sessionId: sessionId,
    deviceId: deviceId,
    leaseEpoch: lease.epoch,
  );
}

/// 只读文件浏览与 Git 一样独立于会话传输：fixture 验收 UI；已配置 Relay 时走
/// v0.8.8 P3 真实传输——file.tree/file.read 经同一 lease/幂等/鉴权链路提交，
/// 结果从 tool_result 事件回读（生产 E2EE 下为密文占位，视图保持不可用）。
final workspaceFilesRepositoryProvider = Provider<WorkspaceFilesRepository>((
  ref,
) {
  const relayBaseUrl = String.fromEnvironment('RELAY_BASE_URL');
  if (relayBaseUrl.isEmpty) {
    return FixtureWorkspaceFilesRepository();
  }
  return RelayWorkspaceFilesRepository(
    filesGateway: ReadonlyCommandGateway(
      transport: ref.read(relayRepositoryProvider),
      contextSource: () => _readonlySessionContext(ref),
    ),
  );
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

/// 会话流、lease 和 composer 与设备连接状态独立管理，避免首屏 rebuild 影响已打开的时间线。
final sessionControllerProvider = ChangeNotifierProvider<SessionController>((
  ref,
) {
  final relay = ref.read(relayRepositoryProvider);
  final identity = ref.read(deviceIdentityStoreProvider);
  final controller = SessionController(
    relay: relay,
    // 真实运行使用系统文件选择器；content key 提供方在此闭包接线：
    // Relay content-dek 读取 + 本机 X25519 私钥 unwrap（无 DEK/非本设备 wrap
    // 时返回 null，选文件入口 fail-closed 提示等待密钥）。
    picker: SystemAttachmentPicker(
      contentKeyProvider: (sessionId) =>
          _sessionContentKeyFromStore(relay, identity, sessionId),
    ),
    modelEffortMemory: ref.read(modelEffortPreferenceStoreProvider),
    // v0.9.0 C6：session SSE 传输（仅真实 Relay 存在；fixture 模式无传输，
    // 仍由 L1/L3/手动刷新完整承载）。poll_only 构建开关在 controller 内消费。
    sessionEventSourceFactory:
        relay is HttpRelayRepository ? relay.sessionEventStreamSource : null,
    sessionAuthRefresh:
        relay is HttpRelayRepository ? relay.refreshTokenOnce : null,
  );
  unawaited(controller.initialize());
  // v0.9.0 C7：App 认证状态与会话运行期的显式协调。注销/设备失效/账号切换
  // （认证相位回到 signedOut）时先 resetForAuthBoundary——递增认证代际丢弃
  // 旧代际回包并清空运行期状态——再由 AppController 清 token/cache；重新认证
  // （回到 authenticated）后重建会话运行期（重新拉列表/能力矩阵）。
  // 2026-09-16 P1 修正：不得用 previousPhase == nextPhase 早退——riverpod 3
  // 的首帧/合并通知会把 booting→authenticated 折叠为同值对，早退会把真实
  // 跃迁丢弃导致 SessionController 永不初始化（恢复码接管路径实测）。
  ref.listen(appControllerProvider, (previous, next) {
    switch (next.phase) {
      case AppAuthPhase.signedOut:
        controller.resetForAuthBoundary();
      case AppAuthPhase.authenticated:
        unawaited(controller.initialize());
      case AppAuthPhase.booting:
        break;
    }
  });
  return controller;
});

/// 会话内容密钥提供方（v0.8.5 §3.2 / ADR-016）：真实链路从 Relay 读取本设备
/// 可解的 wrapped DEK，用本机 X25519 加密私钥 unwrap 后返回会话 DEK（只在本进程
/// 内存使用，不写日志/上行）。fetch 返回 null（无 DEK/非本设备 wrap/私钥缺失）
/// 时同样返回 null——选文件入口保持 fail-closed 的"等待密钥"提示。
/// fixture 模式（FixtureRelayRepository.fetch 恒 null）不经此路径密封预密封草稿。
Future<Uint8List?> _sessionContentKeyFromStore(
  RelayRepository relay,
  DeviceIdentityStore identity,
  String sessionId,
) async {
  try {
    final wrapped = await relay.fetchSessionContentDEK(sessionId);
    if (wrapped == null) {
      return null;
    }
    final privateB64 = await identity.readEncryptionPrivateKeyB64();
    if (privateB64 == null || privateB64.isEmpty) {
      return null;
    }
    final privateBytes = base64Url.decode(base64Url.normalize(privateB64));
    return await CryptoBox.unwrapSessionDEK(
      wrappedPayload: wrapped.wrappedBytes,
      encryptionPrivateKeyBytes: Uint8List.fromList(privateBytes),
    );
  } on RelayFailure {
    // Relay 不可达/无权限：fail-closed，选文件入口继续提示等待密钥。
    return null;
  } on Object {
    // unwrap 失败（载荷损坏/密钥不符）同样 fail-closed；不向 picker 暴露异常细节。
    return null;
  }
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

/// v0.5 resident shell 的本地 UI 状态：只保存 active view 等展示选择，不写 Relay。
final sessionViewControllerProvider =
    ChangeNotifierProvider<SessionViewController>(
      (ref) => SessionViewController(),
    );

/// P2-F Daemon 观察按会话隔离，只消费 Relay 的裁剪只读投影；不与 composer、lease 或写命令共享状态。
final daemonObservationControllerProvider =
    ChangeNotifierProvider.family<DaemonObservationController, String>((
      ref,
      sessionId,
    ) {
      final controller = DaemonObservationController(
        relay: ref.read(relayRepositoryProvider),
        sessionId: sessionId,
      );
      unawaited(controller.initialize());
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

/// P3 代码查看器：复用文件只读 repository 的受限文本预览，行号与高亮纯本地渲染。
final codeViewerControllerProvider =
    ChangeNotifierProvider<CodeViewerController>((ref) {
      return CodeViewerController(
        repository: ref.read(workspaceFilesRepositoryProvider),
      );
    });

/// P3 最近会话页只读状态机：复用 Relay 白名单会话列表并稳定排序。
final recentSessionsControllerProvider =
    ChangeNotifierProvider<RecentSessionsController>((ref) {
      return RecentSessionsController(relay: ref.read(relayRepositoryProvider));
    });

/// P3 用量统计页只读状态机：消费 Relay 白名单整数聚合（ADR-010）。
final usageControllerProvider = ChangeNotifierProvider<UsageController>((ref) {
  return UsageController(relay: ref.read(relayRepositoryProvider));
});

/// P3 命令面板索引：只引用 SessionController 的快照与 capability 门控。
final commandPaletteControllerProvider =
    ChangeNotifierProvider<CommandPaletteController>((ref) {
      return CommandPaletteController(
        sessionController: ref.read(sessionControllerProvider),
      );
    });

/// P3 单消息深链：只通过 SessionController 定位授权会话中的目标消息。
final messageDeepLinkControllerProvider =
    ChangeNotifierProvider<MessageDeepLinkController>((ref) {
      return MessageDeepLinkController(
        sessionController: ref.read(sessionControllerProvider),
      );
    });

/// P3 机器状态只消费 Relay 白名单字段；v0.9.1 P2 升级为生命周期感知同步：
/// 认证边界（注销/重认证/换账号）由 AppController 相位变化转发（递增认证代际），
/// 前后台/网络由 RuntimeRecoveryBinding 转发，页面挂载由各 surface 显式 attach。
/// controller 自身承担 single-flight、quiet refresh 与 45-60s jitter safety reconcile。
final terminalStatusControllerProvider =
    ChangeNotifierProvider<TerminalStatusController>((ref) {
      final relay = ref.read(relayRepositoryProvider);
      final controller = TerminalStatusController(
        relay: relay,
        clock: relay is FixtureRelayRepository ? relay.fixtureNow : null,
      );
      // v0.9.1 事故回归修正：ref.listen 只在「相位变化」时触发。若本 provider
      // 创建时 App 已处于 authenticated（本地 fixture 启动、恢复已登录会话等
      // 启动顺序），监听器永远不会为初值触发，终端同步资格会一直为 false，
      // 终端列表一次都不拉、所有工作区落进「未归属终端」灰态组。因此创建时
      // 必须先读一次当前相位作为初值，再监听后续变化。
      controller.reportAuthBoundary(
        authenticated:
            ref.read(appControllerProvider).phase ==
            AppAuthPhase.authenticated,
      );

      // 2026-09-15 P1 回归修正：恢复码接管序列下（provider 创建于未认证，
      // 接管完成后才切 authenticated），依赖 ref.listen 的相位变化通知在真机
      // 上不触发终端拉取（中继日志无 GET /v1/terminals）。修复 = 相位变化时
      // 显式协调：这里改为在 appController 相位变化时由 SessionController 同款
      // 监听语义保证——具体以 listenManual/初始化后补拍实现（见回归测试）。
      // 认证相位与同步资格的显式协调：signedOut 递增认证代际并清空旧账号
      // 投影；authenticated 重建资格并触发去重首拍（与 SessionController 同口径）。
      // 注意：不得用 previousPhase == nextPhase 早退——riverpod 3 的首帧/合并
      // 通知会把 booting→authenticated 折叠成同值对（2026-09-15 P1 实测：
      // LISTEN FIRED authenticated->authenticated），早退会把真实跃迁丢弃；
      // 同值幂等由 reportAuthBoundary 内部去重兜底。
      ref.listen(appControllerProvider, (previous, next) {
        controller.reportAuthBoundary(
          authenticated: next.phase == AppAuthPhase.authenticated,
        );
      });
      return controller;
    });

/// P3 设置中心只读聚合：设备/能力矩阵/终端状态均来自 Relay 白名单投影，
/// 与认证、会话控制隔离，避免设置页刷新影响已打开的时间线。
final settingsControllerProvider = ChangeNotifierProvider<SettingsController>((
  ref,
) {
  final controller = SettingsController(
    relay: ref.read(relayRepositoryProvider),
  );
  unawaited(controller.initialize());
  return controller;
});

/// P3 会话 info 页投影：按会话 id 聚合 SessionController 与终端白名单状态。
/// 不在此处调用 selectSession —— provider 初始化期间修改其他 provider 会违反
/// Riverpod 初始化规则，深链/通知跳转时会在 debug 构建直接崩溃；
/// 会话选中由 SessionInfoScreen 的 initState 显式发起。
final sessionInfoControllerProvider =
    Provider.family<SessionInfoController, String>((ref, sessionId) {
      return SessionInfoController(
        sessionController: ref.read(sessionControllerProvider),
        terminalStatusController: ref.read(terminalStatusControllerProvider),
      );
    });
