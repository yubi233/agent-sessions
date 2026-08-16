import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:agent_sessions_mobile/state/code_viewer_controller.dart';
import 'package:agent_sessions_mobile/domain/workspace_files_models.dart';
import 'package:agent_sessions_mobile/files/workspace_files_repository.dart';

void main() {
  group('MOBILE-18 代码查看器控制器', () {
    late CodeViewerController controller;

    setUp(() {
      controller = CodeViewerController(
        repository: FixtureWorkspaceFilesRepository(),
      );
    });

    test('打开文本文件进入 ready，正文与总行数正确', () async {
      await controller.openFile('lib/main.dart');
      expect(controller.phase, CodeViewerPhase.ready);
      expect(controller.text, contains('void main()'));
      // fixture 内容为 3 行：void main() { / runApp(const App()); / }。
      expect(controller.lineCount(), 3);
      expect(controller.isTruncated, isFalse);
    });

    test('跳转行号：越界忽略、合法行写入 pendingLine', () async {
      await controller.openFile('lib/main.dart');
      controller.jumpToLine(1);
      expect(controller.pendingLine, 1);
      controller.jumpToLine(99);
      expect(controller.pendingLine, 1);
      controller.jumpToLine(0);
      expect(controller.pendingLine, 1);
    });

    test('二进制与超大文件只返回受限摘要，不渲染正文', () async {
      await controller.openFile('build/logo.png');
      expect(controller.phase, CodeViewerPhase.ready);
      expect(
        controller.content?.limitedKind,
        WorkspaceFileLimitedKind.binary,
      );
      expect(controller.text, isEmpty);

      await controller.openFile('notes/huge.log');
      expect(controller.phase, CodeViewerPhase.ready);
      expect(
        controller.content?.limitedKind,
        WorkspaceFileLimitedKind.tooLarge,
      );
      expect(controller.isTruncated, isTrue);
    });

    test('越权路径 fail-closed：绝对路径与 .. 被拒绝', () async {
      await controller.openFile('../secret.txt');
      expect(controller.phase, CodeViewerPhase.error);
      expect(controller.errorMessage, contains('越界'));

      await controller.openFile('/etc/passwd');
      expect(controller.phase, CodeViewerPhase.error);
      expect(controller.errorMessage, contains('绝对路径'));
    });

    test('搜索记录匹配行并循环跳转', () async {
      await controller.openFile('README.md');
      controller.search('Agent');
      expect(controller.matchCount, greaterThan(0));
      expect(controller.searchMatches(), isNotEmpty);
      final first = controller.activeMatchLine();
      expect(first, isNotNull);
      controller.stepMatch(forward: true);
      expect(controller.activeMatchIndex, 0);
      expect(controller.activeMatchLine(), first);
      controller.stepMatch(forward: false);
      expect(controller.activeMatchIndex, 0);
      expect(controller.activeMatchLine(), first);
      // 空查询清空匹配。
      controller.search('');
      expect(controller.matchCount, 0);
      expect(controller.searchMatches(), isEmpty);
    });

    test('unavailable repository 显示可重试错误', () async {
      final unavailable = CodeViewerController(
        repository: const UnavailableWorkspaceFilesRepository(),
      );
      await unavailable.openFile('lib/main.dart');
      expect(unavailable.phase, CodeViewerPhase.error);
      expect(unavailable.errorMessage, contains('不可用'));
    });
  });

  group('MOBILE-18 轻量语法高亮', () {
    const highlighter = CodeSyntaxHighlighter();
    const baseStyle = TextStyle(color: Color(0xFF000000));
    const keywordStyle = TextStyle(color: Color(0xFF0000FF));
    const stringStyle = TextStyle(color: Color(0xFF00AA00));
    const commentStyle = TextStyle(color: Color(0xFF888888));
    const numberStyle = TextStyle(color: Color(0xFFAA5500));

    List<InlineSpan> highlight(String line) => highlighter.highlightLine(
      line,
      style: baseStyle,
      keywordStyle: keywordStyle,
      stringStyle: stringStyle,
      commentStyle: commentStyle,
      numberStyle: numberStyle,
    );

    test('Dart 关键字使用关键字样式', () {
      final spans = highlight('void main() {');
      final keyword = spans.whereType<TextSpan>().firstWhere(
        (span) => span.text == 'void',
      );
      expect(keyword.style, keywordStyle);
    });

    test('字符串使用字符串样式', () {
      final spans = highlight("final s = 'hello';");
      final string = spans.whereType<TextSpan>().firstWhere(
        (span) => span.text == "'hello'",
      );
      expect(string.style, stringStyle);
    });

    test('行尾注释使用注释样式并截断', () {
      final spans = highlight('int x = 1; // 行尾注释');
      final comment = spans.whereType<TextSpan>().lastWhere(
        (span) => span.text?.startsWith('//') == true,
      );
      expect(comment.style, commentStyle);
      expect(comment.text, '// 行尾注释');
    });

    test('数字使用数字样式，普通标识符保持基础样式', () {
      final spans = highlight('int count = 42;');
      final number = spans.whereType<TextSpan>().firstWhere(
        (span) => span.text == '42',
      );
      expect(number.style, numberStyle);
      final identifier = spans.whereType<TextSpan>().firstWhere(
        (span) => span.text == 'count',
      );
      expect(identifier.style, baseStyle);
    });
  });
}
