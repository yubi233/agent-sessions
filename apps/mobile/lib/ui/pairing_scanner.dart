import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'app_theme.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../domain/models.dart';

/// 扫描器只把原始字符串交给配对页；页面负责按当前协议验证后再进入 Relay 链路。
typedef PairingScannerBuilder =
    Widget Function({
      required ValueChanged<String> onDetected,
      required ValueChanged<PairingScannerFailure> onUnavailable,
    });

/// 相机不可用时的稳定错误语义，供 UI 呈现与 widget 测试替身共用。
enum PairingScannerFailureKind { permissionDenied, unavailable, web, unknown }

class PairingScannerFailure {
  const PairingScannerFailure(this.kind);

  const PairingScannerFailure.permissionDenied()
    : kind = PairingScannerFailureKind.permissionDenied;

  const PairingScannerFailure.unavailable()
    : kind = PairingScannerFailureKind.unavailable;

  const PairingScannerFailure.web() : kind = PairingScannerFailureKind.web;

  final PairingScannerFailureKind kind;

  String get message => switch (kind) {
    PairingScannerFailureKind.permissionDenied => '相机权限未授权，请允许相机访问或改用手动输入。',
    PairingScannerFailureKind.unavailable => '当前设备没有可用相机，请改用手动输入。',
    PairingScannerFailureKind.web =>
      'Flutter Web 不提供 Android 配对扫码，请在 Android 控制端扫描或手动输入。',
    PairingScannerFailureKind.unknown => '相机暂时不可用，请改用手动输入。',
  };

  factory PairingScannerFailure.fromMobileScanner(
    MobileScannerException exception,
  ) => switch (exception.errorCode) {
    MobileScannerErrorCode.permissionDenied =>
      const PairingScannerFailure.permissionDenied(),
    MobileScannerErrorCode.unsupported =>
      const PairingScannerFailure.unavailable(),
    _ => const PairingScannerFailure(PairingScannerFailureKind.unknown),
  };
}

/// 默认工厂仅为 Android 原生相机建立预览；测试可覆盖为确定性的扫描器替身。
final pairingScannerBuilderProvider = Provider<PairingScannerBuilder>((ref) {
  return buildPairingScanner;
});

Widget buildPairingScanner({
  required ValueChanged<String> onDetected,
  required ValueChanged<PairingScannerFailure> onUnavailable,
}) {
  if (kIsWeb) {
    return _UnavailableScannerSurface(
      failure: const PairingScannerFailure.web(),
      onUnavailable: onUnavailable,
    );
  }
  return CameraPairingScanner(
    onDetected: onDetected,
    onUnavailable: onUnavailable,
  );
}

/// Android 相机适配器：仅识别二维码，检测到内容后由上层验证协议格式。
class CameraPairingScanner extends StatefulWidget {
  const CameraPairingScanner({
    required this.onDetected,
    required this.onUnavailable,
    super.key,
  });

  final ValueChanged<String> onDetected;
  final ValueChanged<PairingScannerFailure> onUnavailable;

  @override
  State<CameraPairingScanner> createState() => _CameraPairingScannerState();
}

class _CameraPairingScannerState extends State<CameraPairingScanner> {
  late final MobileScannerController _controller = MobileScannerController(
    formats: const [BarcodeFormat.qrCode],
    detectionSpeed: DetectionSpeed.noDuplicates,
    autoZoom: true,
  );
  bool _reportedUnavailable = false;

  @override
  void dispose() {
    // 相机释放必须随扫码页退出发生，避免后台持有预览会话。
    unawaited(_controller.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AspectRatio(
    aspectRatio: 1,
    child: ClipRRect(
      borderRadius: BorderRadius.circular(AppRadius.card),
      child: MobileScanner(
        key: const Key('pairing-camera-preview'),
        controller: _controller,
        onDetect: _onDetect,
        placeholderBuilder: (context) => ColoredBox(
          color: Theme.of(context).colorScheme.scrim,
          child: Center(child: CircularProgressIndicator()),
        ),
        errorBuilder: _buildError,
      ),
    ),
  );

  void _onDetect(BarcodeCapture capture) {
    for (final barcode in capture.barcodes) {
      final rawValue = barcode.rawValue;
      if (rawValue != null && rawValue.trim().isNotEmpty) {
        widget.onDetected(rawValue);
        return;
      }
    }
  }

  Widget _buildError(BuildContext context, MobileScannerException exception) {
    final failure = PairingScannerFailure.fromMobileScanner(exception);
    _reportUnavailable(failure);
    return _ScannerMessage(
      key: const Key('pairing-camera-error'),
      message: failure.message,
    );
  }

  void _reportUnavailable(PairingScannerFailure failure) {
    if (_reportedUnavailable) {
      return;
    }
    _reportedUnavailable = true;
    // errorBuilder 正在构建，延后通知页面以避免在 build 内触发状态更新。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        widget.onUnavailable(failure);
      }
    });
  }
}

class PairingScannerScreen extends ConsumerStatefulWidget {
  const PairingScannerScreen({super.key});

  @override
  ConsumerState<PairingScannerScreen> createState() =>
      _PairingScannerScreenState();
}

class _PairingScannerScreenState extends ConsumerState<PairingScannerScreen> {
  PairingScannerFailure? _failure;
  String? _invalidPayloadMessage;
  bool _returnedResult = false;

  @override
  Widget build(BuildContext context) {
    final scannerBuilder = ref.watch(pairingScannerBuilderProvider);
    return Scaffold(
      key: const Key('pairing-scanner-screen'),
      appBar: AppBar(
        title: const Text('扫描配对二维码'),
        leading: IconButton(
          key: const Key('pairing-scanner-close-button'),
          tooltip: '返回二维码配对',
          onPressed: () => context.pop(),
          icon: const Icon(Icons.arrow_back),
        ),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text('将终端显示的配对二维码置于取景框内。'),
              const SizedBox(height: 12),
              if (_invalidPayloadMessage != null)
                _ScannerMessage(
                  key: const Key('pairing-scanner-invalid-payload'),
                  message: _invalidPayloadMessage!,
                ),
              if (_failure != null)
                _ScannerMessage(
                  key: const Key('pairing-scanner-fallback-message'),
                  message: _failure!.message,
                )
              else
                scannerBuilder(
                  onDetected: _handleDetectedValue,
                  onUnavailable: _handleUnavailable,
                ),
              const SizedBox(height: 12),
              TextButton.icon(
                key: const Key('pairing-scanner-manual-fallback-button'),
                onPressed: () => context.pop(),
                icon: const Icon(Icons.keyboard_alt_outlined),
                label: const Text('改用手动输入'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _handleDetectedValue(String rawValue) {
    // 只有符合协议的 payload 才能返回；无关二维码不会触发 Relay 请求。
    final requestId = PairingPayload.requestIdFromScan(rawValue);
    if (requestId == null) {
      setState(() {
        _invalidPayloadMessage = '这不是 Agent Sessions 的有效配对二维码，请重新扫描。';
      });
      return;
    }
    if (_returnedResult) {
      return;
    }
    _returnedResult = true;
    context.pop(requestId);
  }

  void _handleUnavailable(PairingScannerFailure failure) {
    if (_returnedResult || _failure != null) {
      return;
    }
    setState(() {
      _failure = failure;
    });
  }
}

class _UnavailableScannerSurface extends StatefulWidget {
  const _UnavailableScannerSurface({
    required this.failure,
    required this.onUnavailable,
  });

  final PairingScannerFailure failure;
  final ValueChanged<PairingScannerFailure> onUnavailable;

  @override
  State<_UnavailableScannerSurface> createState() =>
      _UnavailableScannerSurfaceState();
}

class _UnavailableScannerSurfaceState
    extends State<_UnavailableScannerSurface> {
  @override
  void initState() {
    super.initState();
    // Web 页面不请求浏览器相机，直接落到可预期的手动输入回退。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        widget.onUnavailable(widget.failure);
      }
    });
  }

  @override
  Widget build(BuildContext context) => _ScannerMessage(
    key: const Key('pairing-scanner-web-fallback'),
    message: widget.failure.message,
  );
}

class _ScannerMessage extends StatelessWidget {
  const _ScannerMessage({super.key, required this.message});

  final String message;

  @override
  Widget build(BuildContext context) => Semantics(
    liveRegion: true,
    child: Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      color: Theme.of(context).colorScheme.errorContainer,
      child: Text(message),
    ),
  );
}
