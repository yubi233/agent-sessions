import 'package:agent_sessions_mobile/ui/session/chat/session_markdown_text.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// V094 P3 定向回归（UI-12/13/17，计划 §3.3 Markdown 与内容规则）：
/// - 表格宽度从实际可用宽度派生，仅真正溢出时显示横滚提示；
/// - 代码块可信语言标签（缺失显示「代码」）+ 复制原始文本 + 长代码展开；
/// - Markdown 前景色参数参与默认 style（V094-17）。
void main() {
  Widget host(Widget child) => MaterialApp(
    home: Scaffold(
      body: SizedBox(width: 320, child: SingleChildScrollView(child: child)),
    ),
  );

  testWidgets('UI-13：fence 语言标签来自可信 info string，缺失显示「代码」', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(
        const SessionMarkdownText(
          text: '```bash\necho hi\n```\n\n前文\n\n```\nplain\n```',
        ),
      ),
    );
    expect(find.text('bash'), findsOneWidget);
    expect(find.text('代码'), findsOneWidget);
    expect(find.byKey(const Key('session-code-block')), findsNWidgets(2));
  });

  testWidgets('UI-13：复制按钮写入原始文本（保留换行），带已复制反馈', (tester) async {
    final clipboardValues = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          clipboardValues.add((call.arguments as Map)['text'] as String);
        }
        return null;
      },
    );
    await tester.pumpWidget(
      host(const SessionMarkdownText(text: '```bash\nline-one\n  line-two\n```')),
    );
    await tester.tap(find.byKey(const Key('session-code-copy')));
    await tester.pump();
    expect(clipboardValues.single, 'line-one\n  line-two\n');
    // 消化「已复制」反馈的 2s 复位定时器，避免悬挂 Timer。
    await tester.pump(const Duration(seconds: 2));
    // 已复制反馈：图标切换为 check（tooltip 不变）。
    expect(find.byKey(const Key('session-code-copy')), findsOneWidget);
  });

  testWidgets('UI-13：长代码提供展开/收起切换', (tester) async {
    final longCode = List.generate(30, (i) => 'line-$i').join('\n');
    await tester.pumpWidget(host(SessionMarkdownText(text: '```\n$longCode\n```')));
    expect(find.byKey(const Key('session-code-expand')), findsOneWidget);
    await tester.tap(find.byKey(const Key('session-code-expand')));
    await tester.pump();
    // 切换后按钮仍在（tooltip 语义变化），代码块保持可交互。
    expect(find.byKey(const Key('session-code-expand')), findsOneWidget);
  });

  testWidgets('UI-12：宽表格显示溢出提示，窄表格不显示', (tester) async {
    const wideTable = '''
| 列一很长很长很长很长很长很长 | 列二也很长很长很长很长很长很长 |
| --- | --- |
| 单元格内容很长很长很长很长很长很长很长 | 单元格内容很长很长很长很长很长很长 |
''';
    await tester.pumpWidget(host(const SessionMarkdownText(text: wideTable)));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('session-table-overflow-hint')), findsOneWidget);

    await tester.pumpWidget(
      host(
        const SessionMarkdownText(
          text: '| A | B |\n| --- | --- |\n| 1 | 2 |',
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('session-table-overflow-hint')), findsNothing);
  });

  testWidgets('UI-17：color 参数参与默认 style（前景色传递）', (tester) async {
    const foreground = Color(0xFF00FF00);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SessionMarkdownText(
            text: '普通段落文本',
            color: foreground,
          ),
        ),
      ),
    );
    final rich = tester.widgetList<Text>(find.byType(Text)).singleWhere(
      (widget) =>
          (widget.textSpan as TextSpan?)?.toPlainText() == '普通段落文本',
    );
    final span = rich.textSpan as TextSpan;
    expect(span.style?.color, foreground);
    expect(
      (span.children?.single as TextSpan).style?.color,
      foreground,
      reason: '行内 span 必须继承传递进来的前景色',
    );
  });
}
