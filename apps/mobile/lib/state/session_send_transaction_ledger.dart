import 'session_send_transaction.dart';

/// 发送事务账本（V094 §2.2/§2.4）：每会话最新一次显式发送对应一个逻辑事务。
/// 失败/待确认事务保留在槽内作为"消息待处理项"（失败内容不回填草稿、不删除
/// 记录），新一次显式发送或"编辑后重试"会将其取代。
/// 从 SessionController 拆出的独立职责（架构收口）：账本只管事务槽位、幂等
/// 序号与草稿版本快照，不持有 Relay/回合业务；选中会话的展示口径（活动事务、
/// 可重试事务）仍由 SessionController 面向 UI 提供。
class SessionSendTransactionLedger {
  /// 每会话最新事务槽（key = sessionId）。
  final Map<String, SessionSendTransaction> _txBySession =
      <String, SessionSendTransaction>{};

  /// 幂等序号源：submissionId / clientMessageId / retry 尾号共用单调递增。
  int _counter = 0;

  /// 草稿 revision 计数：提交时刻的草稿版本快照（§2.4 结算身份之一）。
  final Map<String, int> _draftRevisions = <String, int>{};

  /// 读取指定会话的当前事务；null 表示该会话无活动事务。
  SessionSendTransaction? forSession(String? sessionId) =>
      sessionId == null ? null : _txBySession[sessionId];

  /// 记录会话的最新事务（新一次显式发送/重试取代旧槽）。
  void put(String sessionId, SessionSendTransaction tx) {
    _txBySession[sessionId] = tx;
  }

  /// 仅当槽内仍是 [expected] 时移除（防止后台观察器误删更新后的事务）。
  void removeIf(String sessionId, SessionSendTransaction expected) {
    if (_txBySession[sessionId] == expected) {
      _txBySession.remove(sessionId);
    }
  }

  /// 无条件移除会话事务槽（编辑接管失败事务等入口）。
  void remove(String sessionId) {
    _txBySession.remove(sessionId);
  }

  /// 取下一个幂等序号（递增并返回，与原 `_sendTxCounter += 1` 等价）。
  int nextId() => _counter += 1;

  /// 读取当前序号（不递增；retry 的 clientMessageId 后缀沿用该值）。
  int currentId() => _counter;

  /// 预览下一个序号（不递增；send 的 clientMessageId 使用 counter+1 但不消费，
  /// 保留与既有实现逐字节一致的幂等键形状）。
  int peekNextId() => _counter + 1;

  /// 会话提交时刻的草稿版本（未跟踪的会话按 0）。
  int draftRevisionOf(String sessionId) => _draftRevisions[sessionId] ?? 0;
}
