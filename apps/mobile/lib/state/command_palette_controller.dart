import 'package:flutter/material.dart';

import '../domain/session_models.dart';
import 'session_controller.dart';

/// 命令面板中命令的类别。
enum PaletteCommandKind { navigate, session, control }

/// 面板可执行的控制动作；只索引现有已授权动作，不创造隐藏写能力。
enum PaletteControlAction { resume, stop, openFiles, openGit }

/// 一条命令面板结果。blockedReason 非空时该条不可执行，并显示明确原因。
class PaletteCommand {
  const PaletteCommand({
    required this.kind,
    required this.title,
    required this.subtitle,
    required this.icon,
    this.route,
    this.sessionId,
    this.action,
    this.blockedReason,
  });

  final PaletteCommandKind kind;
  final String title;
  final String subtitle;
  final IconData icon;
  final String? route;
  final String? sessionId;
  final PaletteControlAction? action;
  final String? blockedReason;
}

/// P3 命令面板的只读索引状态机。
///
/// 导航条目只索引已注册路由；控制条目按 capability 三态与 lease 门控，
/// unsupported/无 lease 时标记 blocked 原因，绝不绕过服务端授权。
class CommandPaletteController extends ChangeNotifier {
  CommandPaletteController({required SessionController sessionController})
    : this._(sessionController);

  // 公开注入参数名保持 sessionController；私有字段只供本类内部使用。
  CommandPaletteController._(this._sessionController) {
    // 订阅会话变化，面板打开期间会话列表/选中状态变化时自动重建索引。
    _sessionController.addListener(_onSessionChanged);
  }

  final SessionController _sessionController;

  String _query = '';
  List<PaletteCommand> _results = const [];
  List<PaletteCommand> _all = const [];

  String get query => _query;
  List<PaletteCommand> get results =>
      List<PaletteCommand>.unmodifiable(_results);

  @override
  void dispose() {
    _sessionController.removeListener(_onSessionChanged);
    super.dispose();
  }

  void _onSessionChanged() => filter(_query);

  /// 按关键字过滤；空查询显示全部已登记命令。
  void filter(String query) {
    _query = query.trim();
    _rebuildIndex();
    final normalized = _query.toLowerCase();
    if (normalized.isEmpty) {
      _results = _all;
    } else {
      _results = _all
          .where(
            (command) =>
                command.title.toLowerCase().contains(normalized) ||
                command.subtitle.toLowerCase().contains(normalized),
          )
          .toList(growable: false);
    }
    notifyListeners();
  }

  void _rebuildIndex() {
    final commands = <PaletteCommand>[
      // 导航：只索引已注册路由，不索引未实现的页面。
      const PaletteCommand(
        kind: PaletteCommandKind.navigate,
        title: 'DSH 工作区',
        subtitle: '/home',
        icon: Icons.folder_open_outlined,
        route: '/home',
      ),
      const PaletteCommand(
        kind: PaletteCommandKind.navigate,
        title: '设置',
        subtitle: '/settings',
        icon: Icons.settings_outlined,
        route: '/settings',
      ),
      const PaletteCommand(
        kind: PaletteCommandKind.navigate,
        title: '终端状态',
        subtitle: '/terminals',
        icon: Icons.terminal_outlined,
        route: '/terminals',
      ),
      const PaletteCommand(
        kind: PaletteCommandKind.navigate,
        title: '最近会话',
        subtitle: '/sessions/recent',
        icon: Icons.history,
        route: '/sessions/recent',
      ),
      const PaletteCommand(
        kind: PaletteCommandKind.navigate,
        title: '设备',
        subtitle: '/devices',
        icon: Icons.devices_other_outlined,
        route: '/devices',
      ),
      const PaletteCommand(
        kind: PaletteCommandKind.navigate,
        title: '配对',
        subtitle: '/pairing',
        icon: Icons.qr_code_scanner_outlined,
        route: '/pairing',
      ),
      // 控制：capability 门控（fail-closed）。
      PaletteCommand(
        kind: PaletteCommandKind.control,
        title: '恢复当前会话',
        subtitle: _resumeSubtitle(),
        icon: Icons.play_circle_outline,
        action: PaletteControlAction.resume,
        blockedReason: _resumeBlockedReason(),
      ),
      PaletteCommand(
        kind: PaletteCommandKind.control,
        title: '停止当前会话',
        subtitle: '需要 abort 能力且会话可操作',
        icon: Icons.stop_circle_outlined,
        action: PaletteControlAction.stop,
        blockedReason: _stopBlockedReason(),
      ),
      PaletteCommand(
        kind: PaletteCommandKind.control,
        title: '浏览当前会话文件',
        subtitle: '只读文件树',
        icon: Icons.folder_open_outlined,
        action: PaletteControlAction.openFiles,
        blockedReason: _sessionController.selectedSessionId == null
            ? '当前没有选中会话。'
            : null,
      ),
      PaletteCommand(
        kind: PaletteCommandKind.control,
        title: '查看当前会话 Git',
        subtitle: '只读 Git Diff',
        icon: Icons.merge_type_outlined,
        action: PaletteControlAction.openGit,
        blockedReason: _sessionController.selectedSessionId == null
            ? '当前没有选中会话。'
            : null,
      ),
      // 会话：只索引当前账号可见会话。
      for (final session in _sessionController.sessions)
        PaletteCommand(
          kind: PaletteCommandKind.session,
          title: session.title,
          subtitle: _sessionSubtitle(session),
          icon: Icons.chat_bubble_outline,
          sessionId: session.id,
        ),
    ];
    _all = commands;
  }

  String _resumeSubtitle() {
    final session = _sessionController.selectedSession;
    return session == null ? '未选中会话' : 'Provider ${session.provider}';
  }

  String? _resumeBlockedReason() {
    if (_sessionController.selectedSessionId == null) return '当前没有选中会话。';
    // 面板是入口索引，门控只按 capability 声明；真实写权限仍由 SessionController
    // 在提交命令时与服务端最终裁决，避免与 stop 门控口径不一致。
    final declared = _sessionController.selectedProviderCapabilities.capability(
      'resume',
    );
    if (!declared.isSupported) {
      return declared.reason ?? '当前 Provider 不支持恢复会话。';
    }
    return null;
  }

  String? _stopBlockedReason() {
    if (_sessionController.selectedSessionId == null) return '当前没有选中会话。';
    if (_sessionController.hasSelectedLease == false) return '当前会话暂不可操作。';
    final declared = _sessionController.selectedProviderCapabilities.capability(
      'abort',
    );
    if (!declared.isSupported) {
      return declared.reason ?? '当前 Provider 不支持终止会话。';
    }
    return null;
  }

  String _sessionSubtitle(MobileSession session) =>
      '${session.provider} · ${_statusLabel(session.status)}';

  String _statusLabel(MobileSessionStatus status) => switch (status) {
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
