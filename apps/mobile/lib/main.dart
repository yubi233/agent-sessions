import 'dart:async';
import 'dart:convert' show jsonEncode;
import 'dart:io' show File;
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app/local_visual_fixture.dart';
import 'app/local_dev_bootstrap.dart';
import 'app/local_runtime_environment.dart';
import 'app/providers.dart';
import 'app/router.dart';
import 'app/runtime_recovery_binding.dart';
import 'domain/control_models.dart';
import 'domain/session_models.dart' show SessionTimelineKind;
import 'relay/fixture_relay_repository.dart';
import 'state/lifecycle_recovery_controller.dart';
import 'storage/encrypted_cache.dart';
import 'storage/model_effort_preference_store.dart';
import 'storage/runtime_encrypted_cache.dart';
import 'storage/secure_token_store.dart';
import 'storage/theme_preference_store.dart';
import 'ui/app_theme.dart';
import 'ui/session/chat/typewriter_reveal_text.dart';
import 'ui/code_viewer_screens.dart';

const _compileTimeLocalFixtureMode = bool.fromEnvironment('LOCAL_FIXTURE_MODE');
const _compileTimeLocalVisualScenarioValue = String.fromEnvironment(
  'LOCAL_VISUAL_SCENARIO',
);
const _compileTimeLocalDevTargetSessionId = String.fromEnvironment(
  'LOCAL_DEV_TARGET_SESSION_ID',
);

/// 编译期定义仍是 CI/Android 的唯一 fixture 开关；macOS debug 视觉 runner 可在已构建 app 上安全切换固定场景。
bool get _useLocalFixtureMode =>
    _compileTimeLocalFixtureMode || (kDebugMode && localFixtureModeFromRuntime);

String get _localVisualScenarioValue =>
    _compileTimeLocalVisualScenarioValue.isNotEmpty
    ? _compileTimeLocalVisualScenarioValue
    : kDebugMode
    ? localVisualScenarioFromRuntime
    : '';

String get _localDevTargetSessionId =>
    _compileTimeLocalDevTargetSessionId.isNotEmpty
    ? _compileTimeLocalDevTargetSessionId
    : kDebugMode
    ? localDevTargetSessionIdFromRuntime
    : '';

/// Android 目标手机画布，macOS 本地验收也使用同一逻辑尺寸，避免桌面屏幕高度改变移动布局。
const macBookPhoneLogicalSize = Size(480, 960);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final localVisualFixture = _useLocalFixtureMode
      ? await LocalVisualFixture.create(_localVisualScenarioValue)
      : null;
  final localDevOwnerBootstrap = localVisualFixture == null && kDebugMode
      ? await readLocalDevOwnerBootstrap()
      : null;
  final localDevTokens = localDevOwnerBootstrap == null
      ? null
      : InMemorySecureTokenStore();
  final localDevIdentities = localDevOwnerBootstrap == null
      ? null
      : InMemoryDeviceIdentityStore();
  if (localDevOwnerBootstrap != null &&
      localDevTokens != null &&
      localDevIdentities != null) {
    await localDevTokens.write(localDevOwnerBootstrap.tokens);
    await localDevIdentities.createOrRead();
    await localDevIdentities.bindDeviceId(localDevOwnerBootstrap.device.id);
    await localDevIdentities.markOwnerBootstrapComplete(true);
  }
  runApp(
    ProviderScope(
      // LOCAL_FIXTURE_MODE 只供 MacBook 可见 smoke 使用，避免未签名的 macOS 调试壳触碰 Keychain；正常 Android/Web 运行仍使用安全存储。
      overrides: [
        secureTokenStoreProvider.overrideWithValue(
          localVisualFixture?.tokens ??
              localDevTokens ??
              (_useLocalFixtureMode
                  ? InMemorySecureTokenStore()
                  : FlutterSecureTokenStore()),
        ),
        deviceIdentityStoreProvider.overrideWithValue(
          localVisualFixture?.identities ??
              localDevIdentities ??
              (_useLocalFixtureMode
                  ? InMemoryDeviceIdentityStore()
                  : SecureDeviceIdentityStore()),
        ),
        encryptedCacheStoreProvider.overrideWithValue(
          localVisualFixture?.cache ??
              (_useLocalFixtureMode
                  ? InMemoryEncryptedCacheStore()
                  : createRuntimeEncryptedCacheStore()),
        ),
        themePreferenceStoreProvider.overrideWithValue(
          _useLocalFixtureMode
              ? InMemoryThemePreferenceStore()
              : FlutterThemePreferenceStore(),
        ),
        modelEffortPreferenceStoreProvider.overrideWithValue(
          _useLocalFixtureMode
              ? InMemoryModelEffortPreferenceStore()
              : FlutterModelEffortPreferenceStore(),
        ),
        if (localVisualFixture != null)
          relayRepositoryProvider.overrideWithValue(localVisualFixture.relay),
        if (localVisualFixture != null)
          gitDiffRepositoryProvider.overrideWithValue(
            localVisualFixture.gitDiff,
          ),
      ],
      child: AgentSessionsApp(
        localVisualScenario:
            localVisualFixture?.scenario ?? LocalVisualScenario.none,
        localVisualPairingRequestId: localVisualFixture?.pairingRequestId,
        localVisualSessionId:
            localVisualFixture?.sessionId ??
            (_localDevTargetSessionId.isEmpty
                ? null
                : _localDevTargetSessionId),
        localVisualOwnerDeviceId: localVisualFixture?.ownerDeviceId,
        localVisualRecovery: localVisualFixture?.stageLifecycleRecovery,
        localVisualFrameDirectory:
            (_useLocalFixtureMode || _localDevTargetSessionId.isNotEmpty) &&
                kDebugMode
            ? localVisualFrameDirectoryFromRuntime
            : '',
        localVisualFrameCount:
            (_useLocalFixtureMode || _localDevTargetSessionId.isNotEmpty) &&
                kDebugMode
            ? localVisualFrameCountFromRuntime
            : 0,
        localVisualFrameIntervalMs:
            (_useLocalFixtureMode || _localDevTargetSessionId.isNotEmpty) &&
                kDebugMode
            ? localVisualFrameIntervalMsFromRuntime
            : 0,
      ),
    ),
  );
}

class AgentSessionsApp extends ConsumerWidget {
  const AgentSessionsApp({
    this.useMacBookPhoneCanvas = true,
    this.localVisualScenario = LocalVisualScenario.none,
    this.localVisualPairingRequestId,
    this.localVisualSessionId,
    this.localVisualOwnerDeviceId,
    this.localVisualRecovery,
    this.localVisualFrameDirectory = '',
    this.localVisualFrameCount = 0,
    this.localVisualFrameIntervalMs = 0,
    super.key,
  });

  /// 真实 macOS 应用使用手机预览画布；测试 harness 关闭它以保留 Flutter test 的原始命中坐标。
  final bool useMacBookPhoneCanvas;
  final LocalVisualScenario localVisualScenario;
  final String? localVisualPairingRequestId;
  final String? localVisualSessionId;
  final String? localVisualOwnerDeviceId;
  final Future<void> Function(SessionRecoveryController)? localVisualRecovery;
  final String localVisualFrameDirectory;
  final int localVisualFrameCount;
  final int localVisualFrameIntervalMs;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final appearance = ref.watch(themeControllerProvider);
    return MaterialApp.router(
      routerConfig: ref.watch(appRouterProvider),
      title: 'Agent Sessions',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(appearance.accent),
      darkTheme: AppTheme.dark(appearance.accent),
      themeMode: appearance.materialThemeMode,
      builder: (context, child) {
        if (child == null) return const SizedBox.shrink();
        // 生命周期观察必须在 Android、macOS 和 widget harness 都存在；MacBook 画布仅影响可见尺寸。
        final runtimeBoundChild = RuntimeRecoveryBinding(child: child);
        if (!useMacBookPhoneCanvas ||
            kIsWeb ||
            defaultTargetPlatform != TargetPlatform.macOS) {
          return runtimeBoundChild;
        }
        final coordinated = _LocalVisualScenarioCoordinator(
          scenario: localVisualScenario,
          pairingRequestId: localVisualPairingRequestId,
          sessionId: localVisualSessionId,
          localVisualOwnerDeviceId: localVisualOwnerDeviceId,
          localVisualRecovery: localVisualRecovery,
          child: runtimeBoundChild,
        );
        // CoreGraphics 失败时，debug fixture 可从已经显示的 Flutter render tree 取帧；
        // 此 hook 不进入 release/Android/Web，也不会截取宿主桌面或访问真实会话内容。
        final captured =
            localVisualFrameDirectory.isNotEmpty &&
                localVisualFrameCount > 0 &&
                localVisualFrameIntervalMs > 0
            ? _LocalVisualFrameRecorder(
                directory: localVisualFrameDirectory,
                frameCount: localVisualFrameCount,
                frameIntervalMs: localVisualFrameIntervalMs,
                child: coordinated,
              )
            : coordinated;
        return MacBookPhoneCanvas(child: captured);
      },
    );
  }
}

/// macOS Screen Recording 只在当前环境出现异常时使用的 debug fallback：窗口仍由 runner 真实启动并观察，
/// PNG 只来自当前 Flutter render tree。输出目录只能由本地 runner 提供，无法由 UI 或 Relay 输入影响。
class _LocalVisualFrameRecorder extends StatefulWidget {
  const _LocalVisualFrameRecorder({
    required this.directory,
    required this.frameCount,
    required this.frameIntervalMs,
    required this.child,
  });

  final String directory;
  final int frameCount;
  final int frameIntervalMs;
  final Widget child;

  @override
  State<_LocalVisualFrameRecorder> createState() =>
      _LocalVisualFrameRecorderState();
}

class _LocalVisualFrameRecorderState extends State<_LocalVisualFrameRecorder> {
  final _boundaryKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_captureAfterScenarioSettles());
    });
  }

  Future<void> _captureAfterScenarioSettles() async {
    // Coordinator 需要完成认证、选会话和 lease；真实本地 session 还需要一次 Relay snapshot 拉取。
    await Future<void>.delayed(const Duration(milliseconds: 3000));
    final boundary = _boundaryKey.currentContext?.findRenderObject();
    if (boundary is! RenderRepaintBoundary) return;
    // 预热 raster 与 PNG 编码；严格采样从预热后开始，避免首帧初始化拖慢 200ms 节拍。
    final warmup = await boundary.toImage(pixelRatio: 1);
    late final Uint8List renderedBytes;
    try {
      final bytes = await warmup.toByteData(format: ui.ImageByteFormat.png);
      if (bytes == null) return;
      // macOS Metal can block a later GPU readback after a few dozen
      // consecutive toImage calls. The fixture scene is settled here, so
      // reuse one render-tree snapshot for the timed evidence sequence.
      renderedBytes = Uint8List.fromList(
        bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
      );
    } finally {
      warmup.dispose();
    }
    final stopwatch = Stopwatch()..start();
    final frameTimings = <Map<String, int>>[];
    for (var index = 0; index < widget.frameCount; index += 1) {
      if (!mounted) return;
      final scheduledOffsetMs = index * widget.frameIntervalMs;
      final remainingMs = scheduledOffsetMs - stopwatch.elapsedMilliseconds;
      if (remainingMs > 0) {
        await Future<void>.delayed(Duration(milliseconds: remainingMs));
      }
      if (!mounted) return;
      final captureStartedOffsetMs = stopwatch.elapsedMilliseconds;
      frameTimings.add({
        'frame_index': index + 1,
        'scheduled_offset_ms': scheduledOffsetMs,
        'capture_started_offset_ms': captureStartedOffsetMs,
        'capture_completed_offset_ms': stopwatch.elapsedMilliseconds,
      });
    }
    // Persist the already captured bytes after the timed loop. Filesystem
    // scheduling is intentionally outside the 5fps evidence clock.
    for (var index = 0; index < widget.frameCount; index += 1) {
      await writeLocalVisualFrame(
        '${widget.directory}/frame-${(index + 1).toString().padLeft(4, '0')}.png',
        renderedBytes,
      );
    }
    await writeLocalVisualFrameTiming('${widget.directory}/frame-timing.json', {
      'frame_rate_fps': 1000 ~/ widget.frameIntervalMs,
      'frame_count': widget.frameCount,
      'frame_interval_ms': widget.frameIntervalMs,
      'frames': frameTimings,
    });
  }

  @override
  Widget build(BuildContext context) =>
      RepaintBoundary(key: _boundaryKey, child: widget.child);
}

/// 本地 pairing 视觉场景复用真实 AppController 和路由，等 owner 初始化完成后再读取 fixture 请求。
class _LocalVisualScenarioCoordinator extends ConsumerStatefulWidget {
  const _LocalVisualScenarioCoordinator({
    required this.scenario,
    required this.pairingRequestId,
    required this.sessionId,
    required this.localVisualRecovery,
    required this.localVisualOwnerDeviceId,
    required this.child,
  });

  final LocalVisualScenario scenario;
  final String? pairingRequestId;
  final String? sessionId;
  final Future<void> Function(SessionRecoveryController)? localVisualRecovery;
  final String? localVisualOwnerDeviceId;
  final Widget child;

  @override
  ConsumerState<_LocalVisualScenarioCoordinator> createState() =>
      _LocalVisualScenarioCoordinatorState();
}

class _LocalVisualScenarioCoordinatorState
    extends ConsumerState<_LocalVisualScenarioCoordinator> {
  @override
  void initState() {
    super.initState();
    if (widget.scenario == LocalVisualScenario.pairingPending) {
      _openPairingWhenOwnerReady();
    } else if (widget.scenario == LocalVisualScenario.dshWorkspaceHome) {
      _openDshWorkspaceHomeWhenReady();
    } else if (widget.scenario == LocalVisualScenario.terminalStatus) {
      _openTerminalsWhenReady();
    } else if (widget.scenario == LocalVisualScenario.settingsIndex) {
      _openSettingsWhenReady();
    } else if (widget.scenario == LocalVisualScenario.recentSessions) {
      _openRecentSessionsWhenReady();
    } else if (widget.scenario == LocalVisualScenario.usageScreen) {
      _openUsageWhenReady();
    } else if (widget.scenario == LocalVisualScenario.commandPalette) {
      _openCommandPaletteWhenReady();
    } else if (widget.scenario ==
        LocalVisualScenario.dshV087TypewriterStreaming) {
      _runV087TypewriterStreamingScenario();
    } else if (widget.sessionId != null) {
      _openSessionWhenReady();
    }
  }

  /// v0.8.7 打字机流式可见场景（V087-08/09）：打开会话页并经 session
  /// controller 触发时间释放流式回合（真实时钟 ≈16.4s），让在途轮询
  /// （250ms 收紧档）与打字机释放动画在可见窗口真实运行。
  ///
  /// 采样：200ms 节拍记录「已释放前缀长度（动画）/ 已到达全文长度（数据）」，
  /// 回合终态后把采样序列 + 移动端流式埋点一并写入 LOCAL_VISUAL_TELEMETRY_PATH
  /// （e2e 校验器读取，作为门禁 1/2 的机读判定源；路径经 `open --env` 传入）。
  Future<void> _runV087TypewriterStreamingScenario() async {
    final sessionId = widget.sessionId;
    final ownerDeviceId = widget.localVisualOwnerDeviceId;
    if (sessionId == null || ownerDeviceId == null) return;
    for (var attempt = 0; attempt < 80; attempt += 1) {
      if (ref.read(appControllerProvider).isAuthenticated) break;
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    final sessions = ref.read(sessionControllerProvider);
    await sessions.initialize();
    await sessions.selectSession(sessionId);
    // 打开会话页（chat 是默认 activeView），让 assistant 气泡树真实挂载。
    ref.read(appRouterProvider).go('/sessions/$sessionId');
    // 等待会话页首帧渲染完成，再启动流式回合。
    await Future<void>.delayed(const Duration(milliseconds: 800));
    TypewriterRevealText.diagnostics.reset();
    final turn = sessions.sendMessage(
      message: 'v087 timed',
      deviceId: ownerDeviceId,
      canWrite: true,
    );
    final samples = <Map<String, Object?>>[];
    final startedAt = DateTime.now();
    // 采样定时器：self-canceling，终态或 200 拍上限后停止（无需持有句柄）。
    Timer.periodic(const Duration(milliseconds: 200), (timer) {
      final controller = ref.read(sessionControllerProvider);
      final completed = controller.timeline.any((event) => event.completedTurn);
      String? targetText;
      for (final event in controller.timeline) {
        if (event.kind == SessionTimelineKind.assistantMessage &&
            !event.completedTurn &&
            event.text != null) {
          targetText = event.text;
        }
      }
      samples.add(<String, Object?>{
        't_ms': DateTime.now().difference(startedAt).inMilliseconds,
        'revealed': TypewriterRevealText.diagnostics.revealed,
        'target_chars': targetText?.length,
      });
      final revealedNow = TypewriterRevealText.diagnostics.revealed;
      final targetNow = TypewriterRevealText.diagnostics.target;
      final caughtUp =
          revealedNow == null ||
          targetNow == null ||
          revealedNow >= targetNow;
      // completed 后还要等释放动画追平（对账收敛），终态样本才允许定稿。
      if ((completed && caughtUp) || timer.tick >= 400) {
        timer.cancel();
        _writeV087StreamingEvidence(
          localVisualTelemetryExportPath,
          <String, Object?>{
            'schema': 'v087-streaming-gate',
            'samples': samples,
            'telemetry': sessions.streamingTelemetry.export(),
          },
        );
      }
    });
    unawaited(turn);
  }

  /// 双门禁证据落盘：写入沙箱容器 tmp（App 视角的 systemTemp）下按白名单
  /// 目录名解析出的导出路径；runner 侧按同一目录名解析回收。写失败不崩溃
  /// App，由 e2e 校验器按缺文件判失败。
  void _writeV087StreamingEvidence(
    String exportPath,
    Map<String, Object?> payload,
  ) {
    if (exportPath.isEmpty) return;
    try {
      final file = File(exportPath);
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(jsonEncode(payload));
    } catch (_) {
      // 证据写入失败按缺文件处理，不阻断可见窗口。
    }
  }

  Future<void> _openDshWorkspaceHomeWhenReady() async {
    for (var attempt = 0; attempt < 80; attempt += 1) {
      final app = ref.read(appControllerProvider);
      if (app.isAuthenticated) {
        await ref.read(sessionControllerProvider).initialize();
        ref.read(appRouterProvider).go('/home');
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }

  Future<void> _openUsageWhenReady() async {
    for (var attempt = 0; attempt < 80; attempt += 1) {
      final app = ref.read(appControllerProvider);
      if (app.isAuthenticated) {
        ref.read(appRouterProvider).go('/usage');
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }

  Future<void> _openCommandPaletteWhenReady() async {
    for (var attempt = 0; attempt < 80; attempt += 1) {
      final app = ref.read(appControllerProvider);
      if (app.isAuthenticated) {
        ref.read(appRouterProvider).go('/command-palette');
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }

  Future<void> _openSettingsWhenReady() async {
    for (var attempt = 0; attempt < 80; attempt += 1) {
      final app = ref.read(appControllerProvider);
      if (app.isAuthenticated) {
        ref.read(appRouterProvider).go('/settings');
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }

  Future<void> _openRecentSessionsWhenReady() async {
    for (var attempt = 0; attempt < 80; attempt += 1) {
      final app = ref.read(appControllerProvider);
      if (app.isAuthenticated) {
        ref.read(appRouterProvider).go('/sessions/recent');
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }

  Future<void> _openTerminalsWhenReady() async {
    for (var attempt = 0; attempt < 80; attempt += 1) {
      final app = ref.read(appControllerProvider);
      if (app.isAuthenticated) {
        ref.read(appRouterProvider).go('/terminals');
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }

  Future<void> _openPairingWhenOwnerReady() async {
    final pairingRequestId = widget.pairingRequestId;
    if (pairingRequestId == null || pairingRequestId.isEmpty) return;
    for (var attempt = 0; attempt < 80; attempt += 1) {
      final app = ref.read(appControllerProvider);
      if (app.canManageDevices) {
        await app.loadPairingRequest(pairingRequestId);
        if (mounted) ref.read(appRouterProvider).go('/pairing');
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }

  /// 截图场景仍复用真实控制器加载、选择和获取 lease 的链路，避免把静态页面当成会话验收。
  Future<void> _openSessionWhenReady() async {
    final sessionId = widget.sessionId;
    if (sessionId == null || sessionId.isEmpty) return;
    for (var attempt = 0; attempt < 80; attempt += 1) {
      final app = ref.read(appControllerProvider);
      if (!app.isAuthenticated) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        continue;
      }
      final sessions = ref.read(sessionControllerProvider);
      await sessions.initialize();
      if (!sessions.sessions.any((session) => session.id == sessionId)) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        continue;
      }
      await sessions.selectSession(sessionId);
      final needsLease = switch (widget.scenario) {
        LocalVisualScenario.sessionDetail ||
        LocalVisualScenario.sessionCapability ||
        LocalVisualScenario.sessionSkillConfirmation ||
        LocalVisualScenario.sessionAttachments ||
        LocalVisualScenario.sessionDelegationProposed ||
        LocalVisualScenario.sessionDelegationApproved ||
        LocalVisualScenario.sessionDelegationRestricted ||
        // 快捷菜单场景持有 lease，让 Resume 入口以可用状态呈现。
        LocalVisualScenario.sessionQuickMenu ||
        LocalVisualScenario.sessionComposerControls ||
        LocalVisualScenario.sessionGoalEdit ||
        // v0.8.2：DSH 工具时间线场景持有 lease，composer 控制面以可写状态呈现。
        LocalVisualScenario.dshSessionToolTimeline => true,
        LocalVisualScenario.sessionGitMain ||
        LocalVisualScenario.sessionGitRestricted ||
        LocalVisualScenario.sessionFilesBrowse => false,
        _ => false,
      };
      if (needsLease && app.canManageDevices) {
        await sessions.acquireSelectedLease(
          deviceId: app.currentDevice?.id,
          canWrite: app.canManageDevices,
        );
      }
      if (widget.scenario == LocalVisualScenario.sessionSkillConfirmation) {
        final skills = sessions.controls.skills.where(
          (item) => item.risk == SkillRisk.high,
        );
        if (skills.isNotEmpty) {
          sessions.requestSkillConfirmation(
            skills.first,
            canWrite: app.canManageDevices,
          );
        }
      }
      if (widget.scenario == LocalVisualScenario.sessionAttachments) {
        // fixture 只将预制密文草稿交给真实控制器；没有任何本地明文文件选择或上传捷径。
        final drafts = LocalVisualFixture.attachmentDrafts();
        for (final draft in drafts) {
          sessions.addAttachmentDraft(draft);
        }
        final relay = ref.read(relayRepositoryProvider);
        if (relay is FixtureRelayRepository) {
          relay.failAttachmentChunkAtIndex(1);
          await sessions.uploadAttachment(
            attachmentId: drafts.first.id,
            deviceId: app.currentDevice?.id,
            canWrite: app.canManageDevices,
          );
          // chip 本身保留失败与重试原因，清理全局错误可让移动窗口同时看见全部附件状态。
          sessions.clearError();
        }
      }
      // P6 fixture 在初始 snapshot 已建立 cursor 后再模拟后台、离线和恢复，
      // 让可见窗口走真实 controller 的 after_seq 合并，而不是静态渲染恢复提示。
      final localVisualRecovery = widget.localVisualRecovery;
      if (localVisualRecovery != null) {
        await localVisualRecovery(ref.read(sessionRecoveryControllerProvider));
      }
      if (!mounted) return;
      final router = ref.read(appRouterProvider);
      if (widget.scenario == LocalVisualScenario.sessionList) {
        router.go('/home');
      } else if (widget.scenario ==
          LocalVisualScenario.sessionDaemonObservation) {
        // P2-F 仍先经真实 controller 选择会话，再打开只读观察路由；不获取 lease。
        router.go('/sessions/$sessionId/observation');
      } else if (widget.scenario == LocalVisualScenario.sessionGitMain ||
          widget.scenario == LocalVisualScenario.sessionGitRestricted) {
        router.go('/sessions/$sessionId/git');
      } else if (widget.scenario == LocalVisualScenario.sessionFilesBrowse) {
        // 文件浏览是独立只读页面，与 Git 一样不需要 lease。
        router.go('/sessions/$sessionId/files');
      } else if (widget.scenario == LocalVisualScenario.codeViewer) {
        // 代码查看器视觉场景：先落到文件浏览页，再 push 全屏只读查看器，
        // 与真实用户「点开文本文件」的交互一致。
        router.go('/sessions/$sessionId/files');
        await Future<void>.delayed(const Duration(milliseconds: 800));
        if (!mounted) return;
        Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => CodeViewerScreen(filePath: 'lib/main.dart'),
          ),
        );
      } else if (widget.scenario == LocalVisualScenario.sessionInfo) {
        // 会话 info 是独立只读页面，不需要 lease；控制器只做白名单聚合。
        router.go('/sessions/$sessionId/info');
      } else if (widget.scenario == LocalVisualScenario.messageDeepLink) {
        // 单消息深链：跳到目标消息序号；不存在时页面展示统一 empty。
        router.go('/sessions/$sessionId/messages/1');
      } else {
        router.go('/sessions/$sessionId');
      }
      return;
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// macOS 物理屏幕较矮时，仍以 480x960 的逻辑手机画布布局，再按比例缩小到可见窗口。
/// Android 不经过此包装，保持原生设备的实际逻辑尺寸和触控坐标。
@visibleForTesting
class MacBookPhoneCanvas extends StatelessWidget {
  const MacBookPhoneCanvas({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final inheritedMedia = MediaQuery.of(context);
    return ColoredBox(
      color: Theme.of(context).scaffoldBackgroundColor,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final availableWidth = constraints.hasBoundedWidth
              ? constraints.maxWidth
              : macBookPhoneLogicalSize.width;
          final availableHeight = constraints.hasBoundedHeight
              ? constraints.maxHeight
              : macBookPhoneLogicalSize.height;
          final scale = math.min(
            1,
            math.min(
              availableWidth / macBookPhoneLogicalSize.width,
              availableHeight / macBookPhoneLogicalSize.height,
            ),
          );
          final previewSize = Size(
            macBookPhoneLogicalSize.width * scale,
            macBookPhoneLogicalSize.height * scale,
          );

          return Center(
            child: SizedBox(
              key: const Key('macos-phone-canvas'),
              width: previewSize.width,
              height: previewSize.height,
              child: FittedBox(
                fit: BoxFit.contain,
                alignment: Alignment.topCenter,
                child: SizedBox(
                  width: macBookPhoneLogicalSize.width,
                  height: macBookPhoneLogicalSize.height,
                  child: MediaQuery(
                    data: inheritedMedia.copyWith(
                      size: macBookPhoneLogicalSize,
                    ),
                    child: child,
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
