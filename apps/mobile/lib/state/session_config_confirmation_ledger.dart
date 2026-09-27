import 'session_send_transaction.dart';

/// 控制域确认账本（V094 §2.3/§2.4/§2.5）：model / effort / permission 三个控制域
/// 的显式选择确认状态、同域串行锁与操作幂等序号。
/// 从 SessionController 拆出的独立职责（架构收口）：账本只持有状态与串行化，
/// 不接触 Relay 或会话业务；投影核验仍由 SessionController 完成（需要
/// controls 权威读取），记录与通知经本账本收口。
class SessionConfigConfirmationLedger {
  /// [onChanged] 在确认状态变化时回调（SessionController 转发为 notifyListeners）。
  // 私有字段不能用 this._onChanged 初始化形式（与 SessionController 同一口径）。
  // ignore: prefer_initializing_formals
  SessionConfigConfirmationLedger({void Function()? onChanged}) : _onChanged = onChanged;

  final void Function()? _onChanged;

  /// 每控制域（model/effort/permission）当前确认记录。
  final Map<String, ControlDomainConfirmation> _confirmations =
      <String, ControlDomainConfirmation>{};

  /// 每控制域的串行锁：确认期间后续显式选择排队串行（§2.5）。
  final Map<String, Future<void>> _domainLocks = <String, Future<void>>{};

  int _actionCounter = 0;

  /// 生成控制域操作的幂等序号尾号（递增并返回）。
  int nextActionId() => _actionCounter += 1;

  /// 读取控制域确认状态（UI 摘要行显示"切换中/待确认/失败"的事实来源）。
  ControlDomainConfirmation? confirmationFor(String domain) =>
      _confirmations[domain];

  /// 在指定控制域串行执行 [action]：前序确认未结束时等待其完成。
  Future<T> serialized<T>(String domain, Future<T> Function() action) {
    final previous = _domainLocks[domain];
    Future<T> run() async {
      if (previous != null) {
        try {
          await previous;
        } catch (_) {
          // 前序失败不阻塞本次显式选择（失败已有独立错误面）。
        }
      }
      return action();
    }
    final future = run();
    _domainLocks[domain] = future.then(
      (_) {},
      onError: (_) {},
    );
    return future;
  }

  /// 记录确认状态并通知。
  void record(ControlDomainConfirmation confirmation) {
    _confirmations[confirmation.domain] = confirmation;
    _onChanged?.call();
  }
}
