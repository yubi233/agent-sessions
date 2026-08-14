import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/lifecycle_recovery_controller.dart';
import 'providers.dart';

/// 平台适配层只把 Flutter 生命周期和链路类型翻译为业务无关状态。
/// connectivity_plus 不能证明互联网或 Relay 一定可达，真正恢复仍由只读 snapshot 请求验证。
class RuntimeRecoveryBinding extends ConsumerStatefulWidget {
  const RuntimeRecoveryBinding({required this.child, super.key});

  final Widget child;

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
    final visibility = state == AppLifecycleState.resumed
        ? MobileAppVisibility.foreground
        : MobileAppVisibility.background;
    unawaited(
      ref
          .read(sessionRecoveryControllerProvider)
          .reportAppVisibility(visibility),
    );
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

  Future<void> _publishConnectivity(ConnectivityResult result) => ref
      .read(sessionRecoveryControllerProvider)
      .reportNetworkAvailability(
        result == ConnectivityResult.none
            ? MobileNetworkAvailability.offline
            : MobileNetworkAvailability.online,
      );

  @override
  Widget build(BuildContext context) => widget.child;
}
