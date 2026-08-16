import 'package:flutter/foundation.dart';

import '../domain/models.dart';
import '../domain/session_models.dart';
import 'session_controller.dart';

/// 消息深链页的加载阶段。
enum MessageDeepLinkPhase { loading, ready, error }

/// P3 单消息深链状态机。
///
/// 它只通过 SessionController 定位授权会话中的目标消息；跨账号/已删除/
/// 过期 message ID 统一返回 null（页面展示统一 empty，不泄漏存在性）。
class MessageDeepLinkController extends ChangeNotifier {
  MessageDeepLinkController({required this.sessionController});

  final SessionController sessionController;

  MessageDeepLinkPhase _phase = MessageDeepLinkPhase.loading;
  String? _currentSessionId;
  String? _errorMessage;
  bool _initializing = false;

  MessageDeepLinkPhase get phase => _phase;
  String? get currentSessionId => _currentSessionId;
  String? get errorMessage => _errorMessage;

  /// 按会话 id 选中并加载时间线，然后定位目标消息。
  Future<void> load({required String sessionId}) async {
    if (_initializing) return;
    _initializing = true;
    _currentSessionId = sessionId;
    _phase = MessageDeepLinkPhase.loading;
    _errorMessage = null;
    notifyListeners();
    try {
      if (sessionController.selectedSessionId != sessionId) {
        await sessionController.selectSession(sessionId);
      }
      // SessionController 会把 Relay 失败吞进 errorMessage 而不 rethrow。
      // 只有「该会话确实存在但加载失败」才进入可重试错误态；无权/不存在的
      // 会话在账号会话列表中找不到，必须走统一 empty，不泄漏存在性。
      final sessionError = sessionController.errorMessage;
      final sessionListed = sessionController.sessions.any(
        (session) => session.id == sessionId,
      );
      if (sessionError != null && sessionListed) {
        _errorMessage = sessionError;
        _phase = MessageDeepLinkPhase.error;
        return;
      }
      _phase = MessageDeepLinkPhase.ready;
    } on RelayFailure catch (failure) {
      _errorMessage = failure.message;
      _phase = MessageDeepLinkPhase.error;
    } catch (_) {
      _errorMessage = '消息暂时不可用，请稍后重试。';
      _phase = MessageDeepLinkPhase.error;
    } finally {
      _initializing = false;
      notifyListeners();
    }
  }

  /// 返回目标序号的事件；无权/不存在返回 null。
  SessionTimelineEvent? eventFor(int sequence) {
    if (_phase != MessageDeepLinkPhase.ready) return null;
    for (final event in sessionController.timeline) {
      if (event.sequence == sequence) return event;
    }
    return null;
  }
}
