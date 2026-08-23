import 'package:flutter/foundation.dart';

import '../domain/session_projection_models.dart';

typedef SessionFeedbackReader =
    Future<ConversationFeedbackItem?> Function(String messageId);

typedef SessionFeedbackWriter =
    Future<ConversationFeedbackResult> Function({
      required String messageId,
      required ConversationFeedbackRating? rating,
      required String? note,
      required int? version,
    });

/// Per-session feedback object layer.
///
/// This mirrors the DeepSeek Harness lifecycle: read lazily on first focus or
/// hover, serialize mutations per message, retract the same rating, and keep a
/// note editor open when a write fails. The controller never invents a remote
/// success: without a writer it returns an explicit unsupported result.
class SessionMessageFeedbackController extends ChangeNotifier {
  SessionMessageFeedbackController({this.reader, this.writer});

  final SessionFeedbackReader? reader;
  final SessionFeedbackWriter? writer;
  final Map<String, ConversationFeedbackItem?> _items = {};
  final Set<String> _loading = {};
  final Set<String> _mutating = {};
  final Map<String, String> _errors = {};

  ConversationFeedbackItem? itemFor(String messageId) => _items[messageId];

  String? errorFor(String messageId) => _errors[messageId];

  bool isLoading(String messageId) => _loading.contains(messageId);

  bool isMutating(String messageId) => _mutating.contains(messageId);

  Future<void> ensure(String messageId) async {
    if (messageId.trim().isEmpty ||
        _items.containsKey(messageId) ||
        _loading.contains(messageId)) {
      return;
    }
    final read = reader;
    if (read == null) {
      _items[messageId] = null;
      _errors[messageId] = 'unsupported';
      notifyListeners();
      return;
    }
    _loading.add(messageId);
    _errors.remove(messageId);
    notifyListeners();
    try {
      _items[messageId] = await read(messageId);
    } catch (_) {
      _errors[messageId] = 'load-failed';
    } finally {
      _loading.remove(messageId);
      notifyListeners();
    }
  }

  Future<ConversationFeedbackResult> toggle(
    String messageId,
    ConversationFeedbackRating rating,
  ) async {
    final current = _items[messageId];
    final next = current?.rating == rating ? null : rating;
    return _mutate(
      messageId: messageId,
      rating: next,
      note: current?.note,
      version: current?.version,
    );
  }

  Future<ConversationFeedbackResult> saveNote(
    String messageId,
    String note,
  ) async {
    final current = _items[messageId];
    if (current == null) return _fail(messageId, 'validation');
    return _mutate(
      messageId: messageId,
      rating: current.rating,
      note: note.trim().isEmpty ? null : note.trim(),
      version: current.version,
    );
  }

  Future<ConversationFeedbackResult> clearNote(String messageId) async {
    final current = _items[messageId];
    if (current == null) return _fail(messageId, 'validation');
    return _mutate(
      messageId: messageId,
      rating: current.rating,
      note: null,
      version: current.version,
    );
  }

  Future<ConversationFeedbackResult> _mutate({
    required String messageId,
    required ConversationFeedbackRating? rating,
    required String? note,
    required int? version,
  }) async {
    if (_mutating.contains(messageId)) return _fail(messageId, 'busy');
    final write = writer;
    if (write == null) return _fail(messageId, 'unsupported');
    _mutating.add(messageId);
    _errors.remove(messageId);
    notifyListeners();
    try {
      final result = await write(
        messageId: messageId,
        rating: rating,
        note: note,
        version: version,
      );
      if (result.ok) {
        _items[messageId] = result.item;
        _errors.remove(messageId);
      } else {
        _errors[messageId] = result.errorCode ?? 'mutation-failed';
      }
      return result;
    } catch (_) {
      _errors[messageId] = 'mutation-failed';
      return const ConversationFeedbackResult.failure('mutation-failed');
    } finally {
      _mutating.remove(messageId);
      notifyListeners();
    }
  }

  Future<ConversationFeedbackResult> _fail(
    String messageId,
    String code,
  ) async {
    _errors[messageId] = code;
    notifyListeners();
    return ConversationFeedbackResult.failure(code);
  }
}
