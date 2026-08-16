import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

import '../domain/workspace_files_models.dart';
import '../files/workspace_files_repository.dart';

/// 代码查看器的加载阶段。
enum CodeViewerPhase { loading, ready, error }

/// P3 只读代码查看器状态机。
///
/// 它只消费 WorkspaceFilesRepository 的受限文本预览（Daemon 只读 file RPC 或
/// deterministic fixture），不持有文件正文明文之外的内容，也不提供编辑、shell
/// 或 Git 写入口。二进制/超大/无权/路径越界文件由 repository fail-closed。
class CodeViewerController extends ChangeNotifier {
  CodeViewerController({required this.repository});

  final WorkspaceFilesRepository repository;

  CodeViewerPhase _phase = CodeViewerPhase.loading;
  WorkspaceFileContent? _content;
  String? _errorMessage;
  // 行号跳转目标（1-based）；-1 表示没有待跳转的行。
  int _pendingLine = -1;
  String _searchQuery = '';
  final List<int> _searchMatches = [];
  int _activeMatchIndex = -1;

  CodeViewerPhase get phase => _phase;
  WorkspaceFileContent? get content => _content;
  String? get errorMessage => _errorMessage;
  String? get text => _content?.text;
  bool get isTruncated => _content?.isTruncated == true;
  int get pendingLine => _pendingLine;
  String get searchQuery => _searchQuery;
  int get matchCount => _searchMatches.length;
  int get activeMatchIndex => _activeMatchIndex;

  /// 当前文件总行数（1-based 最大行）。
  int lineCount() => _lineCount();

  /// 全部匹配行号（1-based），供行号列高亮。
  List<int> searchMatches() => List<int>.unmodifiable(_searchMatches);

  /// 当前激活匹配所在行；无匹配时为 null。
  int? activeMatchLine() => _activeMatchIndex >= 0 &&
          _activeMatchIndex < _searchMatches.length
      ? _searchMatches[_activeMatchIndex]
      : null;

  /// 打开文件：repo-relative 路径由 repository 做路径安全校验。
  Future<void> openFile(String path) async {
    _phase = CodeViewerPhase.loading;
    _errorMessage = null;
    _pendingLine = -1;
    _searchQuery = '';
    _searchMatches.clear();
    _activeMatchIndex = -1;
    notifyListeners();
    try {
      final content = await repository.readFile(path);
      if (content.limitedKind != WorkspaceFileLimitedKind.none) {
        // 二进制/超大文件只展示受限摘要，不尝试渲染为代码。
        _content = content;
        _phase = CodeViewerPhase.ready;
        return;
      }
      _content = content;
      _phase = CodeViewerPhase.ready;
    } on WorkspaceFilesFailure catch (failure) {
      _phase = CodeViewerPhase.error;
      _errorMessage = failure.message;
    } catch (_) {
      _phase = CodeViewerPhase.error;
      _errorMessage = '代码读取失败，请稍后重试。';
    }
    notifyListeners();
  }

  /// 跳转到指定行（1-based）；越界时忽略并保留当前视图。
  void jumpToLine(int line) {
    final lines = _lineCount();
    if (line < 1 || line > lines) return;
    _pendingLine = line;
    notifyListeners();
  }

  /// 当前文件行数；限制为内存内的确定性数量。
  int _lineCount() {
    final text = _content?.text;
    if (text == null || text.isEmpty) return 0;
    return '\n'.allMatches(text).length + (text.endsWith('\n') ? 0 : 1);
  }

  /// 在文件内搜索关键字，记录匹配行号；空查询清空结果。
  /// 搜索后自动激活第一个匹配，保证行号列立即高亮。
  void search(String query) {
    _searchQuery = query;
    _searchMatches.clear();
    _activeMatchIndex = -1;
    final text = _content?.text;
    if (query.trim().isNotEmpty && text != null) {
      final lines = text.split('\n');
      for (var index = 0; index < lines.length; index += 1) {
        if (lines[index].contains(query.trim())) {
          _searchMatches.add(index + 1);
        }
      }
      if (_searchMatches.isNotEmpty) {
        _activeMatchIndex = 0;
        _pendingLine = _searchMatches.first;
      }
    }
    notifyListeners();
  }

  /// 在匹配结果中循环跳转（方向由 [forward] 决定）。
  void stepMatch({required bool forward}) {
    if (_searchMatches.isEmpty) return;
    _activeMatchIndex = forward
        ? (_activeMatchIndex + 1) % _searchMatches.length
        : (_activeMatchIndex - 1 + _searchMatches.length) %
              _searchMatches.length;
    _pendingLine = _searchMatches[_activeMatchIndex];
    notifyListeners();
  }
}

/// 轻量语法高亮：只做行级 token 上色，不引入第三方高亮依赖。
///
/// 规则刻意保守：关键字/字符串/注释/数字各一组颜色；未知语言一律按纯文本渲染，
/// 保证 fixture 与真实文件视图确定性一致，不因为高亮错误影响只读语义。
class CodeSyntaxHighlighter {
  const CodeSyntaxHighlighter();

  static const Set<String> _dartKeywords = {
    'abstract', 'as', 'assert', 'async', 'await', 'break', 'case', 'catch',
    'class', 'const', 'continue', 'default', 'do', 'else', 'enum', 'extends',
    'false', 'final', 'finally', 'for', 'if', 'implements', 'import', 'in',
    'interface', 'is', 'late', 'library', 'mixin', 'new', 'null', 'on',
    'operator', 'part', 'required', 'return', 'sealed', 'static', 'super',
    'switch', 'sync', 'this', 'throw', 'true', 'try', 'typedef', 'var',
    'void', 'while', 'with', 'yield',
  };

  /// 将单行文本转为 TextSpan 列表。行内先切字符串与注释，再对剩余片段做
  /// 关键字/数字识别；颜色跟随主题的 code 语义色，避免硬编码深浅色值。
  List<InlineSpan> highlightLine(
    String line, {
    required TextStyle style,
    required TextStyle keywordStyle,
    required TextStyle stringStyle,
    required TextStyle commentStyle,
    required TextStyle numberStyle,
  }) {
    final spans = <InlineSpan>[];
    var index = 0;
    while (index < line.length) {
      // 注释：// 开头直到行尾。
      if (line.startsWith('//', index)) {
        spans.add(TextSpan(text: line.substring(index), style: commentStyle));
        break;
      }
      // 字符串：单引号/双引号/三引号片段。
      final quote = line[index];
      if (quote == '"' || quote == "'") {
        final end = _findStringEnd(line, index);
        spans.add(
          TextSpan(text: line.substring(index, end), style: stringStyle),
        );
        index = end;
        continue;
      }
      // 标识符/数字：连续字母数字下划线；数字单独成 token（含小数点与负号）。
      if (_isIdentifierStart(line, index)) {
        var end = index;
        while (end < line.length && _isIdentifierPart(line.codeUnitAt(end))) {
          end += 1;
        }
        final token = line.substring(index, end);
        final keyword = _dartKeywords.contains(token);
        spans.add(
          TextSpan(
            text: token,
            style: keyword ? keywordStyle : style,
          ),
        );
        index = end;
        continue;
      }
      if (_isDigitStart(line.codeUnitAt(index))) {
        var end = index;
        while (end < line.length &&
            (_isDigitStart(line.codeUnitAt(end)) ||
                line[end] == '.' ||
                line[end] == '_')) {
          end += 1;
        }
        spans.add(
          TextSpan(
            text: line.substring(index, end),
            style: numberStyle,
          ),
        );
        index = end;
        continue;
      }
      spans.add(TextSpan(text: line[index], style: style));
      index += 1;
    }
    return spans;
  }

  int _findStringEnd(String line, int start) {
    var index = start + 1;
    while (index < line.length) {
      if (line[index] == '\\') {
        index += 2;
        continue;
      }
      if (line[index] == line[start]) return index + 1;
      index += 1;
    }
    return line.length;
  }

  bool _isIdentifierStart(String line, int index) {
    final code = line.codeUnitAt(index);
    return (code >= 97 && code <= 122) ||
        (code >= 65 && code <= 90) ||
        code == 95;
  }

  bool _isIdentifierPart(int code) =>
      (code >= 97 && code <= 122) ||
      (code >= 65 && code <= 90) ||
      (code >= 48 && code <= 57) ||
      code == 95;

  bool _isDigitStart(int code) => code >= 48 && code <= 57;
}
