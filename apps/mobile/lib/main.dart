import 'dart:async';
import 'dart:convert' show jsonEncode;
import 'dart:io' show File;
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
import 'ui/session_screens.dart' show SessionDetailScreen;
import 'ui/code_viewer_screens.dart';

const _compileTimeLocalFixtureMode = bool.fromEnvironment('LOCAL_FIXTURE_MODE');

/// V094-20：场景落定等待（毫秒）。V094 场景的 fixture seeding（terminal/
/// workspace/session + 时间线命令）比早期场景重，默认 3s 不够；可见 runner
/// 按 dart-define 注入更长等待，生产 Android/Web 不设置该值。
const _localVisualFrameSettleMs = int.fromEnvironment(
  'LOCAL_VISUAL_FRAME_SETTLE_MS',
);
const _compileTimeLocalVisualScenarioValue = String.fromEnvironment(
  'LOCAL_VISUAL_SCENARIO',
);
const _compileTimeLocalDevTargetSessionId = String.fromEnvironment(
  'LOCAL_DEV_TARGET_SESSION_ID',
);

/// v0.9.0 B7（V090-14）：headed 可见验收注入。
/// 仅在 `flutter run --dart-define` 显式提供时生效（可见 gate 专用，
/// 生产 Android/Web 不设置这些值，主题与文本缩放完全由用户偏好驱动）。
const _v090VisualTheme = String.fromEnvironment('V090_VISUAL_THEME');
const _v090VisualTextScale = String.fromEnvironment('V090_VISUAL_TEXT_SCALE');

/// B7 注入的文本缩放；null 表示未注入（不覆盖系统/MediaQuery 行为）。
double? get v090VisualTextScaleOverride {
  if (_v090VisualTextScale.isEmpty) return null;
  return double.tryParse(_v090VisualTextScale);
}

/// B7 注入的主题模式覆盖：'light' / 'dark'；其余值不覆盖。
ThemeMode? get v090VisualThemeModeOverride => switch (_v090VisualTheme) {
  'light' => ThemeMode.light,
  'dark' => ThemeMode.dark,
  _ => null,
};

/// B7 注入的窗口视口（逻辑像素）；仅在 macOS 可见验收运行时非空。
const _v090WindowWidth = String.fromEnvironment('V090_WINDOW_W');
const _v090WindowHeight = String.fromEnvironment('V090_WINDOW_H');

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

/// v0.9.0 B7：macOS 可见验收视口注入。flutter run 不透传进程 env 到应用，
/// Swift 无法读 env；改由 Dart 读编译期 dart-define 后经 MethodChannel 调
/// MainFlutterWindow 的 setContentSize。仅 dart-define 提供时生效。
void _scheduleV090WindowResize() {
  final width = int.tryParse(_v090WindowWidth);
  final height = int.tryParse(_v090WindowHeight);
  if (width == null || height == null) return;
  if (!kIsWeb && defaultTargetPlatform == TargetPlatform.macOS) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      const channel = MethodChannel('v090/visual_gate');
      unawaited(
        channel.invokeMethod<void>('resize', {'w': width, 'h': height}),
      );
    });
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  _scheduleV090WindowResize();
  final localVisualFixture = _useLocalFixtureMode
      ? await LocalVisualFixture.create(_localVisualScenarioValue)
      : null;
  final localDevOwnerBootstrap = localVisualFixture == null && kDebugMode
      ? await readLocalDevOwnerBootstrap()
      : null;
  final localDevTokens = localDevOwnerBootstrap == null
      ? null
      : InMemorySecureTokenStore();
  // v0.8.8 P1（迭代计划 §9.2）：localdev owner X25519 私钥种子播种——与
  // restart.sh owner.bootstrap 的真实公钥配对，附件 DEK unwrap 前置；未注入时
  // 身份库维持占位公钥（附件入口 fail-closed）。生产 Android 走 Keystore 路径。
  final localDevEncryptionPrivateKeyB64 = localDevOwnerBootstrap == null
      ? null
      : readLocalDevEncryptionPrivateKeyB64();
  final localDevIdentities = localDevOwnerBootstrap == null
      ? null
      : InMemoryDeviceIdentityStore(
          seedEncryptionPrivateKeyB64: localDevEncryptionPrivateKeyB64,
        );
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
      themeMode:
          v090VisualThemeModeOverride ?? appearance.materialThemeMode,
      builder: (context, child) {
        if (child == null) return const SizedBox.shrink();
        // 生命周期观察必须在 Android、macOS 和 widget harness 都存在；MacBook 画布仅影响可见尺寸。
        Widget runtimeBoundChild = RuntimeRecoveryBinding(child: child);
        // v0.9.0 B7：视口注入激活时跳过手机画布——窗口已被 resize 到代表性
        // 视口（360x800/430x932/1280x800），内容按真实视口布局。
        final viewportOverrideActive = _v090WindowWidth.isNotEmpty;
        final coordinated = _LocalVisualScenarioCoordinator(
          scenario: localVisualScenario,
          pairingRequestId: localVisualPairingRequestId,
          sessionId: localVisualSessionId,
          localVisualOwnerDeviceId: localVisualOwnerDeviceId,
          localVisualRecovery: localVisualRecovery,
          child: runtimeBoundChild,
        );
        // CoreGraphics 失败（显示器休眠/锁屏）时，debug fixture 可从已经显示的
        // Flutter render tree 取帧；此 hook 不进入 release/Android/Web，也不会
        // 截取宿主桌面或访问真实会话内容。
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
        // v0.9.0 B7：200% 文本缩放注入（仅 dart-define 提供时生效），最外层包装。
        final textScaleOverride = v090VisualTextScaleOverride;
        Widget visualChild = captured;
        if (textScaleOverride != null) {
          visualChild = MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(textScaleOverride)),
            child: visualChild,
          );
        }
        if (viewportOverrideActive) {
          return visualChild;
        }
        if (!useMacBookPhoneCanvas ||
            kIsWeb ||
            defaultTargetPlatform != TargetPlatform.macOS) {
          return visualChild;
        }
        return MacBookPhoneCanvas(child: visualChild);
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
    // V094-20：等待时长可由 LOCAL_VISUAL_FRAME_SETTLE_MS 注入（默认 3s），
    // 重 seeding 场景（v094 三场景）在 runner 侧注入 12s，保证拍到会话页而非首屏。
    await Future<void>.delayed(
      Duration(
        milliseconds: _localVisualFrameSettleMs > 0
            ? _localVisualFrameSettleMs
            : 3000,
      ),
    );
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
  /// v0.9.2（V092 录屏）：驱动"执行侧不可用 → 恢复可用"的可见状态转换，
  /// 使一次连续录屏即可覆盖 G4（原因可见）与 G1（执行侧事实驱动可发送）两个断言面。
  /// 只操作确定性 fixture，不连接真实 Relay、不调用模型。
  ///
  /// 必须进入**会话详情页**：只有会话页的 composer/模型入口会把执行侧给出的
  /// 不可用原因渲染成可见文案；停在 DSH 工作区主页时画面不变化，录屏无法证明
  /// 任何断言（2026-09-16 首轮录屏实测：100 帧完全相同且只显示工作区列表）。
  Future<void> _runV092SendLoopScenario() async {
    final sessionId = widget.sessionId;
    final ownerDeviceId = widget.localVisualOwnerDeviceId;

    // 关键顺序（v0.9.2 R8 修正）：**先启动状态驱动，再尝试进入会话**。
    //
    // 此前实现先把"等待会话就绪 + selectSession"做完才进入状态循环；一旦
    // sessionId 为空或该会话没出现在列表里（首次进会话、fixture 与投影不同步等），
    // 函数会直接 return，状态驱动**从未开始**——采集窗口内画面因此完全静止
    // （实测 100 帧只 1 个唯一 md5）。而录屏要立的证据恰恰是"事实变化导致可见变化"，
    // 会话导航只是让画面更好看，不能成为状态驱动的前置条件。
    final relay = ref.read(relayRepositoryProvider);
    if (relay is FixtureRelayRepository) {
      // 不 await：状态驱动必须尽早跑起来并持续整个采集窗口。
      unawaited(_driveV092FactPhases(relay));
    }

    // 以下为可选增强：把会话页打开，让 composer/模型入口把执行侧给出的不可用
    // 原因渲染成可见文案。失败**不影响**上面的状态驱动。
    if (sessionId == null || ownerDeviceId == null) return;
    for (var attempt = 0; attempt < 240; attempt += 1) {
      final app = ref.read(appControllerProvider);
      final sessions = ref.read(sessionControllerProvider);
      final ready = app.isAuthenticated &&
          app.currentDevice?.id != null &&
          sessions.sessions.any((session) => session.id == sessionId);
      if (ready) break;
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    final sessions = ref.read(sessionControllerProvider);
    await sessions.initialize();
    // 先把执行侧"不可用"事实拉进能力矩阵，再进入会话页——否则会话页首帧用的是
    // 上一次（可能可用）的快照，画面不会体现不可用态。refreshCapabilities 默认
    // 有 15s 节流，这里必须 force。
    await sessions.refreshCapabilities(force: true);
    await sessions.selectSession(sessionId);
    ref.read(appRouterProvider).go('/sessions/$sessionId');
  }

  /// 状态驱动循环：周期性在「执行侧不可用」与「执行侧已恢复」之间切换能力事实，
  /// 并每次 force 刷新能力矩阵，使画面在采集窗口内必然出现可见变化。
  ///
  /// 为什么独立成方法（v0.9.2 R8）：它必须能被**无条件**调用——录屏要立的证据是
  /// 「事实变化导致可见变化」，不能因为「会话还没就绪」就整段不执行。
  /// 周期取 10 秒：采集窗口是 100 帧 × 200ms = 20 秒，窗口内必然覆盖完整转换；
  /// 同时不短于 10 秒，避免频繁重建让 render-tree 落帧的严格 200ms 节拍抖动
  /// （实测 5 秒周期会导致采集失败）。
  Future<void> _driveV092FactPhases(FixtureRelayRepository relay) async {
    const phaseStay = Duration(seconds: 10);
    // 先立即进入"执行侧不可用"阶段：composer/模型入口展示执行侧给出的真实原因。
    for (var round = 0; round < 30; round += 1) {
      if (!mounted) return;
      relay.executionSideDshUnavailable = true;
      await ref.read(sessionControllerProvider.notifier).refreshCapabilities(
        force: true,
      );
      await Future<void>.delayed(phaseStay);
      if (!mounted) return;
      // 执行侧恢复（等同修好 node 运行时 / 桥路径）→ 能力矩阵回到可用、发送
      // 入口恢复（G1：可用性事实随执行侧变化，不再是笼统的不可用）。
      relay.executionSideDshUnavailable = false;
      await ref.read(sessionControllerProvider.notifier).refreshCapabilities(
        force: true,
      );
      await Future<void>.delayed(phaseStay);
    }
  }

  @override
  void initState() {
    super.initState();
    if (widget.scenario == LocalVisualScenario.pairingPending) {
      _openPairingWhenOwnerReady();
    } else if (widget.scenario == LocalVisualScenario.dshWorkspaceHome ||
        widget.scenario == LocalVisualScenario.terminalPresenceV091 ||
        widget.scenario == LocalVisualScenario.dshV092SendLoop) {
      // v0.9.1（V091-14）/v0.9.2（V092）：presence 四态与 DSH 发送闭环场景
      // 与 DSH 主页共用入口与布局。
      _openDshWorkspaceHomeWhenReady();
      if (widget.scenario == LocalVisualScenario.dshV092SendLoop) {
        unawaited(_runV092SendLoopScenario());
      }
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
      // v0.8.7 V087-12（真实栈口径）：localdev 注入发送文本时，打开会话页后
      // 由 App 发起真实回合（采样+埋点导出与 fixture 场景共用同一采样器）。
      unawaited(_maybeRunV087LocaldevSamplingTurn());
    }
  }

  /// v0.8.7 打字机流式可见场景（V087-08/09）：打开会话页并经 session
  /// controller 触发时间释放流式回合（真实时钟 ≈16.4s），让在途轮询
  /// （250ms 收紧档）与打字机释放动画在可见窗口真实运行。
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
    await _startV087SamplingTurn(
      sessionId: sessionId,
      message: 'v087 timed',
      deviceId: ownerDeviceId,
      maxTicks: 400,
    );
  }

  /// v0.8.7 V087-12（真实栈口径）：localdev 模式下若注入 LOCAL_DEV_SEND_MESSAGE，
  /// 打开会话页后由 App 自己发送该消息——在途轮询（250ms 收紧档）只有
  /// App 自己的 sendMessage 才会驱动，API 侧发送不产生打字机渲染。
  /// 真实免费池回合常见 30-60s，采样预算放宽到 800 拍（×200ms = 160s）。
  Future<void> _maybeRunV087LocaldevSamplingTurn() async {
    final sessionId = widget.sessionId;
    final message = localDevSendMessageFromRuntime;
    if (sessionId == null || message.isEmpty) return;
    // localdev 冷启动（owner bootstrap → 认证 → 会话列表加载）可能远超
    // _openSessionWhenReady 的 4s 窗口：这里自行等待就绪（最长 60s）、选择
    // 会话并重新导航，避免停留在主页导致打字机气泡不挂载。
    for (var attempt = 0; attempt < 240; attempt += 1) {
      final app = ref.read(appControllerProvider);
      final sessions = ref.read(sessionControllerProvider);
      final ready = app.isAuthenticated &&
          app.currentDevice?.id != null &&
          sessions.sessions.any((session) => session.id == sessionId);
      if (ready) break;
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    final sessions = ref.read(sessionControllerProvider);
    final device = ref.read(appControllerProvider).currentDevice;
    final deviceId = device?.id;
    if (deviceId == null || !sessions.sessions.any((session) => session.id == sessionId)) {
      return;
    }
    // V087-12：真实免费池回合常见 1-3 分钟，超出 v0.8.6 默认轮询总窗
    // （90s）会触发 App 侧显式超时并停止轮询——真实证据采集场景放宽窗口
    // （前台 120s@250ms + 后台 120s@500ms = 240s）。仅在 harness 注入
    // LOCAL_DEV_SEND_MESSAGE 时生效，产品路径不变。字段为 v0.8.6 的
    // @visibleForTesting 注入口，此处是同一仓库内的诊断门用途。
    // ignore: invalid_use_of_visible_for_testing_member
    sessions
      // ignore: invalid_use_of_visible_for_testing_member
      ..foregroundPollAttempts = 480
      // ignore: invalid_use_of_visible_for_testing_member
      ..backgroundPollAttempts = 240;
    await sessions.selectSession(sessionId);
    // 导航落地确认：booting 阶段的 router redirect 会把过早的 go() 弹到
    // /connect（空白壳），以「会话详情页真正 build 过」为信号，未落地则
    // 重发导航（最长 30s）。v0.8.8 P3b：深链优先修复后 App 可能已在目标页
    // （_openSessionWhenReady 落地 + 再断言），此时 go() 同路由不触发重建、
    // 重建计数不增长——以「路由已在目标」为等效落地信号，不再空等超时。
    final router = ref.read(appRouterProvider);
    final baseline = SessionDetailScreen.pageBuilds;
    final alreadyOnTarget = router.routeInformationProvider.value.uri
        .toString()
        .startsWith('/sessions/$sessionId');
    if (!alreadyOnTarget) {
      var landed = false;
      for (var attempt = 0; attempt < 30 && !landed; attempt += 1) {
        router.go('/sessions/$sessionId');
        await Future<void>.delayed(const Duration(milliseconds: 1000));
        landed = SessionDetailScreen.pageBuilds > baseline;
      }
      if (!landed) {
        // ignore: avoid_print
        print('V087REAL navigate-timeout');
        return;
      }
    }
    // ignore: avoid_print
    print('V087REAL navigated /sessions/$sessionId');
    // 等待会话页首帧稳定，再启动真实回合。
    await Future<void>.delayed(const Duration(milliseconds: 1200));
    await _startV087SamplingTurn(
      sessionId: sessionId,
      message: message,
      deviceId: deviceId,
      maxTicks: 800,
    );
  }

  /// 发送消息并启动 200ms 节拍采样：记录「已释放前缀长度（动画）/ 已到达
  /// 全文长度（数据）」，回合终态且释放动画追平（对账收敛）后，把采样序列
  /// + 移动端流式埋点写入 [localVisualTelemetryExportPath]（V087-08/09 与
  /// V087-12 双门禁的机读判定源；fixture 与真实栈共用同一采样器）。
  Future<void> _startV087SamplingTurn({
    required String sessionId,
    required String message,
    required String deviceId,
    required int maxTicks,
  }) async {
    final sessions = ref.read(sessionControllerProvider);
    TypewriterRevealText.diagnostics.reset();
    final turn = sessions.sendMessage(
      message: message,
      deviceId: deviceId,
      canWrite: true,
    );
    final samples = <Map<String, Object?>>[];
    final startedAt = DateTime.now();
    // 采样定时器：self-canceling，终态追平或拍数上限后停止（无需持有句柄）。
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
      final timelineTarget = targetText?.length ?? 0;
      // 追平判定以「当前时间线的 assistant 文本长度」为基准（widget 上报的
      // diagnostics 可能滞后于最后一次 merge）；revealed 为 null 视为 UI 尚未
      // 挂载打字机（真实栈 localdev 等价于已整段显示）。
      final caughtUp =
          revealedNow == null ||
          (timelineTarget > 0 && revealedNow >= timelineTarget);
      // completed 后还要等释放动画追平（对账收敛），终态样本才允许定稿。
      if ((completed && caughtUp) || timer.tick >= maxTicks) {
        timer.cancel();
        _writeV087StreamingEvidence(
          localVisualTelemetryExportPath,
          <String, Object?>{
            'schema': 'v087-streaming-gate',
            'samples': samples,
            'telemetry': sessions.streamingTelemetry.export(),
            // 控制器真相快照：finalize 时刻的时间线形态（kind+文本长度序列），
            // 用于对账 UI 渲染与控制器状态的分叉（V087-12 真实栈诊断）。
            'final_timeline': sessions.timeline
                .map((event) => <String, Object?>{
                    'seq': event.sequence,
                    'kind': event.kind.name,
                    'text_len': event.text?.length,
                    'streaming': event.isStreaming,
                    'completed_turn': event.completedTurn,
                  })
                .toList(),
            'final_target_chars': timelineTarget,
            'final_revealed': revealedNow,
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
    // v0.8.8 P3b（V088-13）：localdev 冷启动（owner bootstrap → 认证 → 会话
    // 列表加载）可能远超旧 4s 窗口（80×50ms）——放宽到 60s，深链在窗口内
    // 持续等待就绪，而不是超时后任由恢复导航覆盖。
    for (var attempt = 0; attempt < 1200; attempt += 1) {
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
      // v0.8.8 P3b（V088-13，迭代计划 §9.4）：深链优先于恢复导航——localdev
      // 冷启动下 App 自身的最近会话恢复导航可能晚于深链落地并把目标会话页
      // 覆盖为"新对话"空态页（V087-12 帧实证）。深链在位时做有限次"再断言"：
      // 路由或选中会话被覆盖即重新落地；恢复语义本身不改。
      final targetLocation = '/sessions/$sessionId';
      for (var reassert = 0; reassert < 20; reassert += 1) {
        await Future<void>.delayed(const Duration(milliseconds: 500));
        if (!mounted) return;
        final current = router.routeInformationProvider.value.uri.toString();
        final selected = ref.read(sessionControllerProvider).selectedSessionId;
        final settled = current.startsWith(targetLocation) &&
            selected == sessionId;
        if (settled) return;
        if (ref.read(sessionControllerProvider).sessions.any(
              (session) => session.id == sessionId,
            )) {
          await ref.read(sessionControllerProvider).selectSession(sessionId);
          router.go(targetLocation);
        }
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
