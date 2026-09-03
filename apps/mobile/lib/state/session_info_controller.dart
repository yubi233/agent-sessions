import 'package:flutter/foundation.dart';

import '../domain/session_models.dart';
import '../domain/terminal_models.dart';
import 'session_controller.dart';
import 'terminal_status_controller.dart';

/// P3 会话 info 页的只读聚合投影。
///
/// 它只从 SessionController 与 TerminalStatusController 读取白名单元数据，
/// 不持有会话正文、token、完整路径或任何写命令；复制与分享能力按 capability
/// 三态展示，独立安全 ADR 未通过前分享恒为 unavailable。
class SessionInfoController extends ChangeNotifier {
  SessionInfoController({
    required this.sessionController,
    required this.terminalStatusController,
  }) {
    // 订阅数据源，保证页面打开期间会话状态/终端白名单变化能实时刷新。
    sessionController.addListener(_onSourceChanged);
    terminalStatusController.addListener(_onSourceChanged);
  }

  final SessionController sessionController;
  final TerminalStatusController terminalStatusController;

  void _onSourceChanged() => notifyListeners();

  @override
  void dispose() {
    sessionController.removeListener(_onSourceChanged);
    terminalStatusController.removeListener(_onSourceChanged);
    super.dispose();
  }

  /// 当前选中会话的元数据投影；未选择会话时为 null。
  MobileSession? get session => sessionController.selectedSession;

  /// 会话状态文案使用 Relay 白名单状态，不解读密文正文。
  String get statusLabel {
    final status = session?.status;
    if (status == null) return '未知';
    return switch (status) {
      MobileSessionStatus.idle => '空闲',
      MobileSessionStatus.streaming => '运行中',
      MobileSessionStatus.waitingPermission => '等待权限',
      MobileSessionStatus.waitingQuestion => '等待提问',
      MobileSessionStatus.stopped => '已停止',
      MobileSessionStatus.errored => '出错',
      MobileSessionStatus.offline => '离线',
      MobileSessionStatus.unknown => '未确认',
    };
  }

  /// 关联机器只做白名单展示：当前没有终端绑定到会话的契约，机器列只显示
  /// 账户可见的终端状态摘要；不展示终端 ID、路径或日志。
  List<TerminalSummary> get visibleTerminals =>
      terminalStatusController.terminals;

  /// 终止（abort）能力的只读三态；不可写时明确不可执行。
  String? get stopBlockedReason {
    final declared = sessionController.selectedProviderCapabilities.capability(
      'abort',
    );
    if (!declared.isSupported) {
      return declared.reason ?? '当前 Provider 不支持终止会话。';
    }
    return null;
  }

  String? get killBlockedReason =>
      sessionController.killBlockedReason(canWrite: false);

  /// 恢复能力的只读三态；复用 SessionController 的阻断原因，不伪造能力。
  String? get resumeBlockedReason =>
      sessionController.resumeBlockedReason(canWrite: false);

  /// 分享能力：独立安全 ADR 未通过前恒为 unavailable，不展示假入口。
  bool get shareUnavailable => true;
}
