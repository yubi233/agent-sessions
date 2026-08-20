/// v0.5/P5：Input Trigger 纯语法核心（无 Flutter 依赖）。
///
/// 对照 deepseek-harness：
/// - `packages/client/ui-input-trigger/src/core/detect.ts`（/ 触发 + 词边界与 URL carve-out）
/// - `packages/context/file-reference/src/grammar.ts`（@ 引用 token，含 `@"quoted path"`）
///
/// 强制契约（《迭代计划v0.5.md》第 3 节）：
/// - `/` 要避开 URL/路径中非触发位置（`https:/…`、`//`、词中）；
/// - `@` 要避开 `user@host`，支持 `@"..."` 引用路径；
/// - 候选按 caret（selection）+ draftRev CAS 定位，禁止继续按最后一个空格截 token。
library;

/// 触发字符类型。
enum InputTriggerChar { at, slash }

/// 触发命中：trigger 到 caret 的查询片段与可替换的 span。
class InputTriggerHit {
  const InputTriggerHit({
    required this.trigger,
    required this.query,
    required this.quoted,
    required this.leading,
    required this.start,
    required this.end,
  });

  final InputTriggerChar trigger;
  final String query;

  /// 是否 `@"..."` 引号引用 token。
  final bool quoted;

  /// token 是否位于整段草稿开头（leading）。
  final bool leading;

  /// 可替换 span 起点（trigger 字符位置）。
  final int start;

  /// 可替换 span 终点（caret 位置）。
  final int end;

  bool get isAt => trigger == InputTriggerChar.at;
  bool get isSlash => trigger == InputTriggerChar.slash;
}

/// 词边界：trigger 字符只在「草稿开头 / 空白后 / 标点后」开启。
/// `/` 额外避开 URL 的 `scheme:/…` 与 `//`。
bool _boundaryOk(String draft, int index, InputTriggerChar char) {
  if (index == 0) return true;
  final prev = draft.codeUnitAt(index - 1);
  final prevChar = String.fromCharCode(prev);
  if (_isWhitespaceVar(prevChar)) return true;
  if (_isWordChar(prevChar)) return false;
  if (char == InputTriggerChar.slash) {
    if (prevChar == '/') return false;
    // `:` 前面是非空白字符 → 视为 scheme 分隔（`https:/…`），不触发。
    if (prevChar == ':' &&
        index >= 2 &&
        !_isWhitespaceVar(draft.substring(index - 2, index - 1))) {
      return false;
    }
  }
  return true;
}

bool _isWhitespaceVar(String ch) => RegExp(r'\s').hasMatch(ch);

bool _isWordChar(String ch) =>
    RegExp(r'[\p{L}\p{N}_]', unicode: true).hasMatch(ch);

/// 复刻 `activeAtToken`：提取 caret 处的 `@` 或 `@"..."` 引用 token。
/// `@` 出现在词中（如 email）不作为 trigger。
InputTriggerHit? _activeAtToken(String draft, int caret) {
  final before = draft.substring(0, caret);
  final quoted = RegExp(
    r'(?:^|\s)(@"([^"]*))$',
    unicode: true,
  ).firstMatch(before);
  if (quoted != null && quoted.group(2) != null) {
    final prefix = quoted.group(1)!;
    return InputTriggerHit(
      trigger: InputTriggerChar.at,
      query: quoted.group(2)!,
      quoted: true,
      leading: _leadingAt(draft, caret - prefix.length),
      start: caret - prefix.length,
      end: caret,
    );
  }
  final plain = RegExp(
    r'(?:^|\s)(@([^\s]*))$',
    unicode: true,
  ).firstMatch(before);
  if (plain == null || plain.group(1) == null || plain.group(2) == null) {
    return null;
  }
  final prefix = plain.group(1)!;
  return InputTriggerHit(
    trigger: InputTriggerChar.at,
    query: plain.group(2)!,
    quoted: false,
    leading: _leadingAt(draft, caret - prefix.length),
    start: caret - prefix.length,
    end: caret,
  );
}

bool _leadingAt(String draft, int index) {
  for (var i = 0; i < index; i += 1) {
    if (!_isWhitespaceVar(draft.substring(i, i + 1))) return false;
  }
  return true;
}

/// 探测 caret 处的活跃 trigger。
///
/// [claimed] 对应「已 claim command」guard tier：claimed 时 `/` 被抑制，`@` 仍活跃；
/// frozen 时返回 null。实现侧当前由 composer 根据 machine phase 传入。
InputTriggerHit? detectInputTrigger(
  String draft,
  int caret, {
  bool claimed = false,
  bool frozen = false,
}) {
  if (frozen) return null;
  // `@` 优先使用引用 grammar（含 `@"..."` 跨空白 token）。
  final at = _activeAtToken(draft, caret);
  if (at != null) return at;
  // `/` 从 caret 向左扫描到首个空白；未过词边界的 `/` 视为普通字符继续退。
  for (var i = caret - 1; i >= 0; i -= 1) {
    final ch = draft.substring(i, i + 1);
    if (_isWhitespaceVar(ch)) return null;
    if (ch != '/') continue;
    if (claimed) continue;
    if (!_boundaryOk(draft, i, InputTriggerChar.slash)) continue;
    return InputTriggerHit(
      trigger: InputTriggerChar.slash,
      query: draft.substring(i + 1, caret),
      quoted: false,
      leading: _leadingAtPunct(draft, i),
      start: i,
      end: caret,
    );
  }
  return null;
}

/// leading 判定：trigger 之前整段仅空白/制表/换行。
bool _leadingAtPunct(String draft, int index) {
  for (var i = 0; i < index; i += 1) {
    if (!_isWhitespaceVar(draft.substring(i, i + 1))) return false;
  }
  return true;
}
