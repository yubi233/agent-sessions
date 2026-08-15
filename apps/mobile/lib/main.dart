import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app/local_visual_fixture.dart';
import 'app/local_runtime_environment.dart';
import 'app/providers.dart';
import 'app/router.dart';
import 'app/runtime_recovery_binding.dart';
import 'domain/control_models.dart';
import 'relay/fixture_relay_repository.dart';
import 'state/lifecycle_recovery_controller.dart';
import 'storage/encrypted_cache.dart';
import 'storage/runtime_encrypted_cache.dart';
import 'storage/secure_token_store.dart';

const _compileTimeLocalFixtureMode = bool.fromEnvironment('LOCAL_FIXTURE_MODE');
const _compileTimeLocalVisualScenarioValue = String.fromEnvironment(
  'LOCAL_VISUAL_SCENARIO',
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

/// Android 目标手机画布，macOS 本地验收也使用同一逻辑尺寸，避免桌面屏幕高度改变移动布局。
const macBookPhoneLogicalSize = Size(480, 960);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final localVisualFixture = _useLocalFixtureMode
      ? await LocalVisualFixture.create(_localVisualScenarioValue)
      : null;
  runApp(
    ProviderScope(
      // LOCAL_FIXTURE_MODE 只供 MacBook 可见 smoke 使用，避免未签名的 macOS 调试壳触碰 Keychain；正常 Android/Web 运行仍使用安全存储。
      overrides: [
        secureTokenStoreProvider.overrideWithValue(
          localVisualFixture?.tokens ??
              (_useLocalFixtureMode
                  ? InMemorySecureTokenStore()
                  : FlutterSecureTokenStore()),
        ),
        deviceIdentityStoreProvider.overrideWithValue(
          localVisualFixture?.identities ??
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
        localVisualSessionId: localVisualFixture?.sessionId,
        localVisualRecovery: localVisualFixture?.stageLifecycleRecovery,
        localVisualFrameDirectory: _useLocalFixtureMode && kDebugMode
            ? localVisualFrameDirectoryFromRuntime
            : '',
        localVisualFrameCount: _useLocalFixtureMode && kDebugMode
            ? localVisualFrameCountFromRuntime
            : 0,
        localVisualFrameIntervalMs: _useLocalFixtureMode && kDebugMode
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
  final Future<void> Function(SessionRecoveryController)? localVisualRecovery;
  final String localVisualFrameDirectory;
  final int localVisualFrameCount;
  final int localVisualFrameIntervalMs;

  @override
  Widget build(BuildContext context, WidgetRef ref) => MaterialApp.router(
    routerConfig: ref.watch(appRouterProvider),
    title: 'Agent Sessions',
    debugShowCheckedModeBanner: false,
    theme: _mobileTheme(),
    darkTheme: _mobileTheme(),
    // 本地和 Android 均固定深色移动控制面，保证会话状态颜色不会随宿主系统切换而歧义化。
    themeMode: ThemeMode.dark,
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
    // Coordinator 需要完成认证、选会话和 lease；固定等待只存在于 deterministic visual fixture。
    await Future<void>.delayed(const Duration(milliseconds: 1400));
    for (var index = 0; index < widget.frameCount; index += 1) {
      if (!mounted) return;
      final boundary = _boundaryKey.currentContext?.findRenderObject();
      if (boundary is! RenderRepaintBoundary) return;
      final image = await boundary.toImage(pixelRatio: 1);
      try {
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        if (bytes == null) return;
        await writeLocalVisualFrame(
          '${widget.directory}/frame-${(index + 1).toString().padLeft(4, '0')}.png',
          bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
        );
      } finally {
        image.dispose();
      }
      if (index + 1 < widget.frameCount) {
        await Future<void>.delayed(
          Duration(milliseconds: widget.frameIntervalMs),
        );
      }
    }
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
    required this.child,
  });

  final LocalVisualScenario scenario;
  final String? pairingRequestId;
  final String? sessionId;
  final Future<void> Function(SessionRecoveryController)? localVisualRecovery;
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
    } else if (widget.sessionId != null) {
      _openSessionWhenReady();
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
        LocalVisualScenario.sessionComposerControls => true,
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
      } else if (widget.scenario == LocalVisualScenario.sessionGitMain ||
          widget.scenario == LocalVisualScenario.sessionGitRestricted) {
        router.go('/sessions/$sessionId/git');
      } else if (widget.scenario == LocalVisualScenario.sessionFilesBrowse) {
        // 文件浏览是独立只读页面，与 Git 一样不需要 lease。
        router.go('/sessions/$sessionId/files');
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
      color: const Color(0xff111113),
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

/// 参考 Happy 移动端的深色中性层级：重点状态和主操作使用高对比，其余信息保持低噪声。
ThemeData _mobileTheme() {
  const canvas = Color(0xff111113);
  const surface = Color(0xff1a1a1e);
  const surfaceRaised = Color(0xff232329);
  const border = Color(0xff35353d);
  const primaryText = Color(0xfff4f4f6);
  const secondaryText = Color(0xffa4a4af);
  const primaryAction = Color(0xfff4f4f6);
  const shape = RoundedRectangleBorder(
    borderRadius: BorderRadius.all(Radius.circular(8)),
  );
  final colorScheme = const ColorScheme.dark(
    primary: primaryAction,
    onPrimary: canvas,
    secondary: Color(0xff86e0bf),
    onSecondary: canvas,
    surface: surface,
    onSurface: primaryText,
    error: Color(0xffffb4ab),
    onError: Color(0xff690005),
  );

  return ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    colorScheme: colorScheme,
    scaffoldBackgroundColor: canvas,
    dividerColor: border,
    textTheme: const TextTheme(
      headlineSmall: TextStyle(
        color: primaryText,
        fontSize: 26,
        fontWeight: FontWeight.w600,
        letterSpacing: 0,
      ),
      titleLarge: TextStyle(
        color: primaryText,
        fontSize: 20,
        fontWeight: FontWeight.w600,
        letterSpacing: 0,
      ),
      titleMedium: TextStyle(
        color: primaryText,
        fontSize: 17,
        fontWeight: FontWeight.w600,
        letterSpacing: 0,
      ),
      bodyLarge: TextStyle(color: primaryText, fontSize: 17, letterSpacing: 0),
      bodyMedium: TextStyle(
        color: secondaryText,
        fontSize: 14,
        letterSpacing: 0,
      ),
      labelLarge: TextStyle(
        color: primaryText,
        fontSize: 15,
        fontWeight: FontWeight.w600,
        letterSpacing: 0,
      ),
      labelMedium: TextStyle(
        color: secondaryText,
        fontSize: 12,
        fontWeight: FontWeight.w600,
        letterSpacing: 0,
      ),
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: canvas,
      foregroundColor: primaryText,
      elevation: 0,
      scrolledUnderElevation: 0,
      surfaceTintColor: Colors.transparent,
      centerTitle: true,
      toolbarHeight: 68,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: surface,
      labelStyle: const TextStyle(color: secondaryText),
      hintStyle: const TextStyle(color: secondaryText),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      border: OutlineInputBorder(
        borderRadius: const BorderRadius.all(Radius.circular(8)),
        borderSide: const BorderSide(color: border),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: const BorderRadius.all(Radius.circular(8)),
        borderSide: const BorderSide(color: border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: const BorderRadius.all(Radius.circular(8)),
        borderSide: const BorderSide(color: primaryAction, width: 1.5),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: const BorderRadius.all(Radius.circular(8)),
        borderSide: const BorderSide(color: Color(0xffffb4ab)),
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderRadius: const BorderRadius.all(Radius.circular(8)),
        borderSide: const BorderSide(color: Color(0xffffb4ab), width: 1.5),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: ButtonStyle(
        minimumSize: const WidgetStatePropertyAll(Size.fromHeight(52)),
        backgroundColor: const WidgetStatePropertyAll(primaryAction),
        foregroundColor: const WidgetStatePropertyAll(canvas),
        shape: const WidgetStatePropertyAll(shape),
        textStyle: const WidgetStatePropertyAll(
          TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
            letterSpacing: 0,
          ),
        ),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: ButtonStyle(
        minimumSize: const WidgetStatePropertyAll(Size.fromHeight(48)),
        foregroundColor: const WidgetStatePropertyAll(primaryText),
        side: const WidgetStatePropertyAll(BorderSide(color: border)),
        shape: const WidgetStatePropertyAll(shape),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: ButtonStyle(
        foregroundColor: const WidgetStatePropertyAll(secondaryText),
        textStyle: const WidgetStatePropertyAll(
          TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w600,
            letterSpacing: 0,
          ),
        ),
      ),
    ),
    listTileTheme: const ListTileThemeData(
      iconColor: secondaryText,
      textColor: primaryText,
      contentPadding: EdgeInsets.symmetric(horizontal: 0, vertical: 4),
      minVerticalPadding: 10,
      minLeadingWidth: 32,
      horizontalTitleGap: 12,
    ),
    iconButtonTheme: const IconButtonThemeData(
      style: ButtonStyle(foregroundColor: WidgetStatePropertyAll(primaryText)),
    ),
    snackBarTheme: const SnackBarThemeData(
      backgroundColor: surfaceRaised,
      contentTextStyle: TextStyle(color: primaryText),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(8)),
      ),
    ),
  );
}
