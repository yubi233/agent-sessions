import 'package:agent_sessions_mobile/ui/pairing_scanner.dart';
import 'package:flutter/material.dart';

/// 扫描器 fixture 让路由和配对状态测试不依赖本机相机、权限或平台通道。
Widget buildPairingScannerFixture({
  required ValueChanged<String> onDetected,
  required ValueChanged<PairingScannerFailure> onUnavailable,
}) => _PairingScannerFixture(
  onDetected: onDetected,
  onUnavailable: onUnavailable,
);

class _PairingScannerFixture extends StatefulWidget {
  const _PairingScannerFixture({
    required this.onDetected,
    required this.onUnavailable,
  });

  final ValueChanged<String> onDetected;
  final ValueChanged<PairingScannerFailure> onUnavailable;

  @override
  State<_PairingScannerFixture> createState() => _PairingScannerFixtureState();
}

class _PairingScannerFixtureState extends State<_PairingScannerFixture> {
  final _payloadController = TextEditingController();

  @override
  void dispose() {
    _payloadController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      TextField(
        key: const Key('fixture-scanner-payload'),
        controller: _payloadController,
        decoration: const InputDecoration(labelText: 'Fixture 扫描内容'),
      ),
      FilledButton(
        key: const Key('fixture-scanner-detect-button'),
        onPressed: () => widget.onDetected(_payloadController.text),
        child: const Text('提交 fixture 扫描内容'),
      ),
      TextButton(
        key: const Key('fixture-scanner-unavailable-button'),
        onPressed: () => widget.onUnavailable(
          const PairingScannerFailure.permissionDenied(),
        ),
        child: const Text('模拟相机权限拒绝'),
      ),
    ],
  );
}
