/// v0.5 composer 在接入 UI 前的纯输入状态。
enum SessionInputPhase { plain, claimed, adjudicating, submitting, blocked }

/// 运行中 Enter 的用户级偏好；Shift+Enter 永远由 UI 处理为换行。
enum BusyEnterMode { queue, steer }

enum SessionSubmitMode { send, queue, steer }

class SessionDraftReference {
  const SessionDraftReference({
    required this.id,
    required this.offset,
    required this.length,
    required this.label,
    required this.clipboardText,
  });

  final int id;
  final int offset;
  final int length;
  final String label;
  final String clipboardText;

  int get end => offset + length;

  SessionDraftReference shift(int delta) => SessionDraftReference(
    id: id,
    offset: offset + delta,
    length: length,
    label: label,
    clipboardText: clipboardText,
  );
}

class QueuedComposerMessage {
  const QueuedComposerMessage({required this.id, required this.text});

  final String id;
  final String text;
}

class SessionInputSnapshot {
  const SessionInputSnapshot({
    required this.draft,
    required this.draftRevision,
    required this.phase,
    required this.references,
    required this.queue,
    this.claimToken,
    this.notice,
  });

  final String draft;
  final int draftRevision;
  final SessionInputPhase phase;
  final String? claimToken;
  final List<SessionDraftReference> references;
  final List<QueuedComposerMessage> queue;
  final String? notice;
}

class _DraftTransaction {
  const _DraftTransaction({
    required this.draft,
    required this.references,
    required this.phase,
    required this.claimToken,
  });

  final String draft;
  final List<SessionDraftReference> references;
  final SessionInputPhase phase;
  final String? claimToken;
}

/// DeepSeek Harness InputMachine 在 Flutter 侧的纯 Dart 对齐层。
///
/// 业务边界：本类只管理草稿、引用、claim 和 transient queue；提交时只返回
/// [SessionSubmitMode]，真正的 Relay 写命令仍必须由 [SessionController] 发出。
class SessionComposerInputMachine {
  SessionComposerInputMachine();

  String _draft = '';
  int _draftRevision = 0;
  int _referenceSeq = 0;
  SessionInputPhase _phase = SessionInputPhase.plain;
  String? _claimToken;
  String? _notice;
  List<SessionDraftReference> _references = const [];
  List<QueuedComposerMessage> _queue = const [];
  final List<_DraftTransaction> _undo = [];
  final List<_DraftTransaction> _redo = [];

  SessionInputSnapshot get snapshot => SessionInputSnapshot(
    draft: _draft,
    draftRevision: _draftRevision,
    phase: _phase,
    references: List.unmodifiable(_references),
    queue: List.unmodifiable(_queue),
    claimToken: _claimToken,
    notice: _notice,
  );

  /// 普通草稿编辑是一个事务：文本、引用区间和 claim 释放同时完成。
  void setDraft(String draft, {int? start, int? end, int? insertedLength}) {
    if (draft == _draft) return;
    final range = _editRange(
      draft,
      start: start,
      end: end,
      insertedLength: insertedLength,
    );
    _pushUndo();
    _references = _reconcileReferences(range);
    _draft = draft;
    _draftRevision += 1;
    _redo.clear();
    _clearClaimIfBroken();
    _notice = null;
  }

  /// slash command claim 使用 draftRevision 做 CAS，避免菜单命中旧选区。
  bool beginCommand({
    required String token,
    required int start,
    required int end,
    required int draftRevision,
  }) {
    if (!_spanMatches(start, end, draftRevision)) return false;
    if (_draft.substring(0, start).trim().isNotEmpty) return false;
    _pushUndo();
    _replaceRange(start, end, token);
    _claimToken = token;
    _phase = SessionInputPhase.claimed;
    _redo.clear();
    return true;
  }

  /// 插入结构化引用时，草稿展示文本和 clipboard 投影必须同一事务落地。
  bool insertReference({
    required String label,
    required String clipboardText,
    required int start,
    required int end,
    required int draftRevision,
  }) {
    if (!_spanMatches(start, end, draftRevision)) return false;
    final display = '@$label';
    final tail = _draft.substring(end);
    final gap = tail.isEmpty || tail.startsWith(' ') ? '' : ' ';
    _pushUndo();
    _replaceRange(start, end, display + gap);
    _referenceSeq += 1;
    _references = [
      ..._references,
      SessionDraftReference(
        id: _referenceSeq,
        offset: start,
        length: display.length,
        label: label,
        clipboardText: clipboardText,
      ),
    ]..sort((left, right) => left.offset.compareTo(right.offset));
    _redo.clear();
    _clearClaimIfBroken();
    return true;
  }

  /// Backspace/Delete 贴着引用边界时删除整个 occurrence，避免只删半个 chip。
  bool deleteReferenceNearCaret({required int caret, required bool backwards}) {
    final ref = _references.where((item) {
      return backwards ? item.end == caret : item.offset == caret;
    }).firstOrNull;
    if (ref == null) return false;
    _pushUndo();
    _replaceRange(ref.offset, ref.end, '');
    _references = _references.where((item) => item.id != ref.id).toList();
    _redo.clear();
    _clearClaimIfBroken();
    return true;
  }

  String projectClipboard({int? start, int? end}) {
    final from = start ?? 0;
    final to = end ?? _draft.length;
    var output = '';
    var cursor = from;
    for (final ref in _references) {
      if (ref.end <= from || ref.offset >= to) continue;
      final plainEnd = _clampInt(ref.offset, from, to);
      output += _draft.substring(cursor, plainEnd);
      output += ref.clipboardText;
      cursor = _clampInt(ref.end, from, to);
    }
    output += _draft.substring(cursor, to);
    return output;
  }

  String cutRange(int start, int end) {
    final copied = projectClipboard(start: start, end: end);
    setDraft(
      _draft.substring(0, start) + _draft.substring(end),
      start: start,
      end: end,
      insertedLength: 0,
    );
    return copied;
  }

  /// paste-upgrade 复用 reference 插入事务；旧选区变化时 CAS 会拒绝升级。
  bool pasteUpgradeReference({
    required String label,
    required String clipboardText,
    required int start,
    required int end,
    required int draftRevision,
  }) => insertReference(
    label: label,
    clipboardText: clipboardText,
    start: start,
    end: end,
    draftRevision: draftRevision,
  );

  void addQueuedMessage(String id, String text) {
    if (text.trim().isEmpty) return;
    _queue = [..._queue, QueuedComposerMessage(id: id, text: text)];
  }

  void editQueuedMessage(String id, String text) {
    _queue = [
      for (final item in _queue)
        item.id == id ? QueuedComposerMessage(id: id, text: text) : item,
    ];
  }

  void removeQueuedMessage(String id) {
    _queue = _queue.where((item) => item.id != id).toList(growable: false);
  }

  /// 提交决策只返回模式；不会隐式 flush queue。
  SessionSubmitMode? submit({
    required bool running,
    bool accelerated = false,
    BusyEnterMode busyEnter = BusyEnterMode.queue,
  }) {
    final empty = _draft.trim().isEmpty;
    if (empty && !(accelerated && running && _queue.isNotEmpty)) return null;
    if (accelerated && running && empty && _queue.isNotEmpty) {
      return SessionSubmitMode.steer;
    }
    if (running) {
      return busyEnter == BusyEnterMode.steer
          ? SessionSubmitMode.steer
          : SessionSubmitMode.queue;
    }
    return SessionSubmitMode.send;
  }

  void enterSubmitting() {
    _phase = SessionInputPhase.submitting;
  }

  void settleSubmit({required bool success, String? error}) {
    if (success) {
      _pushUndo();
      _draft = '';
      _references = const [];
      _claimToken = null;
      _phase = SessionInputPhase.plain;
      _draftRevision += 1;
      _notice = null;
      return;
    }
    _phase = SessionInputPhase.plain;
    _notice = error ?? '提交失败，草稿已保留。';
  }

  bool undo() {
    if (_undo.isEmpty) return false;
    final current = _transaction();
    final previous = _undo.removeLast();
    _redo.add(current);
    _restore(previous);
    return true;
  }

  bool redo() {
    if (_redo.isEmpty) return false;
    final current = _transaction();
    final next = _redo.removeLast();
    _undo.add(current);
    _restore(next);
    return true;
  }

  void release() {
    _phase = SessionInputPhase.plain;
    _claimToken = null;
    _notice = null;
  }

  ({int start, int end, int insertedLength}) _editRange(
    String next, {
    int? start,
    int? end,
    int? insertedLength,
  }) {
    if (start != null && end != null && insertedLength != null) {
      return (start: start, end: end, insertedLength: insertedLength);
    }
    var prefix = 0;
    final common = _draft.length < next.length ? _draft.length : next.length;
    while (prefix < common && _draft[prefix] == next[prefix]) {
      prefix += 1;
    }
    var suffix = 0;
    while (suffix < common - prefix &&
        _draft[_draft.length - 1 - suffix] == next[next.length - 1 - suffix]) {
      suffix += 1;
    }
    return (
      start: prefix,
      end: _draft.length - suffix,
      insertedLength: next.length - suffix - prefix,
    );
  }

  List<SessionDraftReference> _reconcileReferences(
    ({int start, int end, int insertedLength}) range,
  ) {
    final delta = range.insertedLength - (range.end - range.start);
    final kept = <SessionDraftReference>[];
    for (final ref in _references) {
      if (ref.end <= range.start) {
        kept.add(ref);
      } else if (ref.offset >= range.end) {
        kept.add(delta == 0 ? ref : ref.shift(delta));
      }
    }
    return kept;
  }

  bool _spanMatches(int start, int end, int draftRevision) =>
      draftRevision == _draftRevision &&
      start >= 0 &&
      start <= end &&
      end <= _draft.length;

  void _replaceRange(int start, int end, String replacement) {
    final range = (start: start, end: end, insertedLength: replacement.length);
    _references = _reconcileReferences(range);
    _draft = _draft.substring(0, start) + replacement + _draft.substring(end);
    _draftRevision += 1;
  }

  void _clearClaimIfBroken() {
    final token = _claimToken;
    if (token == null) return;
    if (!_draft.startsWith(token)) {
      _claimToken = null;
      _phase = SessionInputPhase.plain;
    }
  }

  _DraftTransaction _transaction() => _DraftTransaction(
    draft: _draft,
    references: List.of(_references),
    phase: _phase,
    claimToken: _claimToken,
  );

  void _pushUndo() {
    _undo.add(_transaction());
    if (_undo.length > 100) _undo.removeAt(0);
  }

  void _restore(_DraftTransaction transaction) {
    _draft = transaction.draft;
    _references = List.of(transaction.references);
    _phase = transaction.phase;
    _claimToken = transaction.claimToken;
    _draftRevision += 1;
    _notice = null;
  }
}

int _clampInt(int value, int min, int max) {
  if (value < min) return min;
  if (value > max) return max;
  return value;
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull {
    final iterator = this.iterator;
    if (!iterator.moveNext()) return null;
    return iterator.current;
  }
}
