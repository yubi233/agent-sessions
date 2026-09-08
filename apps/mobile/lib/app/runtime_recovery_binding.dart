import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/lifecycle_recovery_controller.dart';
import 'providers.dart';

/// 平台适配层只把 Flutter 生命周期和链路类型翻译为业务无关状态。
/// connectivity_plus 不能证明互联网或 Relay 一定可达，真正恢复仍由只读 snapshot 请求验证。
class RuntimeRecoveryBinding extends ConsumerStatefulWidget {
  const RuntimeRecoveryBinding({
    required this.child,
    this.desktopPlatformOverride,
    super.key,
  });

  final Widget child;

  /// 测试注入覆盖；null 时按 defaultTargetPlatform 判定桌面/移动。
  /// 桌面判定见 [_RuntimeRecoveryBindingState._isDesktopPlatform]。
  final bool? desktopPlatformOverride;

  @override
  ConsumerState<RuntimeRecoveryBinding> createState() =>
      _RuntimeRecoveryBindingState();
}

class _RuntimeRecoveryBindingState extends ConsumerState<RuntimeRecoveryBinding>
    with WidgetsBindingObserver {
  final Connectivity _connectivity = Connectivity();
  StreamSubscription<ConnectivityResult>? _connectivitySubscription;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_startConnectivityObservation());
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_connectivitySubscription?.cancel());
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 桌面端（macOS/Windows/Linux）窗口失焦产生 inactive/hidden，但进程仍完整
    // 前台运行——只有 detached/paused 才算真后台；移动端保留旧语义
    // （inactive 是瞬时过渡，非 resumed 一律按后台处理）。
    // 把桌面失焦误判为后台会让本地 lease 失效，回前台重新获取 lease 触发
    // Relay epoch 翻转，长回合会被自己的续期打死（V085-25 事故根因之一）。
    final visibility = _isForeground(state)
        ? MobileAppVisibility.foreground
        : MobileAppVisibility.background;
    unawaited(
      ref
          .read(sessionRecoveryControllerProvider)
          .reportAppVisibility(visibility),
    );
    // v0.9.1 P2：同一份生命周期事实转发给终端无感同步——后台立即停止终端
    // 列表新请求，回前台由控制器触发去重首拍。
    ref
        .read(terminalStatusControllerProvider)
        .reportAppVisibility(visibility);
  }

  bool _isForeground(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      return true;
    }
    final desktop =
        widget.desktopPlatformOverride ?? _detectDesktopPlatform();
    if (!desktop) {
      return false;
    }
    // 桌面：detached 才是进程级退出；inactive/hidden 仍是可见可渲染的前台。
    return state != AppLifecycleState.detached;
  }

  bool _detectDesktopPlatform() {
    if (kIsWeb) {
      return false;
    }
    return defaultTargetPlatform == TargetPlatform.macOS ||
        defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.linux;
  }

  Future<void> _startConnectivityObservation() async {
    try {
      final current = await _connectivity.checkConnectivity();
      if (!mounted) return;
      await _publishConnectivity(current);
      _connectivitySubscription = _connectivity.onConnectivityChanged.listen(
        (result) => unawaited(_publishConnectivity(result)),
        onError: (error, stackTrace) => unawaited(
          ref
              .read(sessionRecoveryControllerProvider)
              .reportNetworkAvailability(MobileNetworkAvailability.unknown),
        ),
      );
    } catch (_) {
      // 测试 harness、插件缺失或宿主短暂不可用时保持 unknown；不把“未知”伪装成在线。
      if (!mounted) return;
      await ref
          .read(sessionRecoveryControllerProvider)
          .reportNetworkAvailability(MobileNetworkAvailability.unknown);
    }
  }

  Future<void> _publishConnectivity(ConnectivityResult result) {
    // v0.9.1 P2：网络变化同样驱动终端无感同步；offline 停止新请求，
    // offline->恢复的去重首拍在控制器内完成。
    final availability = result == ConnectivityResult.none
        ? MobileNetworkAvailability.offline
        : MobileNetworkAvailability.online;
    ref
        .read(terminalStatusControllerProvider)
        .reportNetworkAvailability(availability);
    return ref
        .read(sessionRecoveryControllerProvider)
        .reportNetworkAvailability(availability);
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
