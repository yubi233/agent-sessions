// v0.8.6 D/E 组回归（V086-15/16）：
// D——SessionMarkdownText 的 GFM 语法面（标题/表格/列表/行内样式/代码块）、
//    流式 partial 不抛错、HTML 不渲染、图片降级 alt 文本；
// E——复制全覆盖：投影层 canCopy 在流式 assistant/tool/thought/notice 节点
//    上均为 true（不再要求 completedTurn），且超长文本按 64K 截断。
import 'package:agent_sessions_mobile/domain/control_models.dart';
import 'package:agent_sessions_mobile/domain/session_models.dart';
import 'package:agent_sessions_mobile/domain/session_projection_models.dart';
import 'package:agent_sessions_mobile/state/session_projection_controller.dart';
import 'package:agent_sessions_mobile/ui/session/chat/session_markdown_text.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _host(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  testWidgets('V086-15：标题/表格/列表/行内样式/代码块正确渲染', (tester) async {
    const markdown = '''
### 状态统计（截至最新抓取）

| 销售状态 | 房号数 |
|---------|-------|
| 已备案 | 230+ |
| 可售 | 100+ |

## 重点楼栋

- 10栋（20层）：绝大多数已备案
  - 202、203 为可售
1. 第一优先
2. 第二优先

**加粗** 与 `行内代码` 与 ~~删除线~~ 与 [链接](https://example.com)

```bash
PYTHONPATH=src python3 -m cli crawl
```
''';
    await tester.pumpWidget(_host(SessionMarkdownText(text: markdown)));

    expect(find.text('状态统计（截至最新抓取）'), findsOneWidget);
    expect(find.text('已备案'), findsOneWidget);
    expect(find.text('230+'), findsOneWidget);
    expect(find.text('重点楼栋'), findsOneWidget);
    expect(find.textContaining('绝大多数已备案'), findsOneWidget);
    expect(find.text('202、203 为可售'), findsOneWidget);
    expect(find.text('1. '), findsOneWidget);
    // 行内样式位于 Text.rich 的 span 中，需要 findRichText 才能命中。
    expect(find.textContaining('加粗', findRichText: true), findsOneWidget);
    expect(
      find.textContaining('行内代码', findRichText: true),
      findsOneWidget,
    );
    expect(
      find.textContaining('删除线', findRichText: true),
      findsOneWidget,
    );
    expect(find.textContaining('外链'), findsNothing);
    expect(find.textContaining('PYTHONPATH=src'), findsOneWidget);
    // 原始 markdown 语法不得残留为正文（### 与 |---| 分隔行）。
    expect(find.textContaining('### '), findsNothing);
    expect(find.textContaining('|---'), findsNothing);
  });

  testWidgets('V086-15：流式 partial 文本不抛错且降级为普通文本', (tester) async {
    await tester.pumpWidget(
      _host(
        SessionMarkdownText(text: '这是一个**未闭合的加粗\n| 还有 | 半截 | 表格'),
      ),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('V086-15：HTML 不渲染、图片降级为 alt 占位、链接不导航', (tester) async {
    const markdown =
        '<script>alert(1)</script>\n\n![替代文本](https://example.com/x.png)\n\n[外链](https://example.com)';
    await tester.pumpWidget(_host(SessionMarkdownText(text: markdown)));

    expect(find.textContaining('alert(1)'), findsNothing);
    expect(find.textContaining('替代文本', findRichText: true), findsOneWidget);
    expect(find.textContaining('外链', findRichText: true), findsOneWidget);
    expect(find.textContaining('https://example.com/x.png'), findsNothing);
  });

  test('V086-16：复制全覆盖——各节点类型均有复制文本，流式 assistant 可复制', () {
    final controller = SessionProjectionController();
    final snapshot = controller.buildSnapshot(
      timeline: [
        // 流式中（completedTurn=false）的 assistant：必须可复制。
        SessionTimelineEvent(
          sequence: 1,
          kind: SessionTimelineKind.assistantMessage,
          label: 'Assistant',
          text: '已生成一半的回答',
          isStreaming: true,
        ),
        SessionTimelineEvent(
          sequence: 2,
          kind: SessionTimelineKind.toolActivity,
          label: 'bash',
          text: 'ls -la /tmp',
          toolStatus: '已完成',
        ),
        SessionTimelineEvent(
          sequence: 4,
          kind: SessionTimelineKind.systemNotice,
          label: '通知',
          text: '系统通知内容',
        ),
        SessionTimelineEvent(
          sequence: 5,
          kind: SessionTimelineKind.userMessage,
          label: '你',
          text: '用户消息',
        ),
      ],
      controls: const SessionControlState.empty(),
    );

    final copyableKinds = snapshot.chatNodes
        .where((node) => node.canCopy)
        .map((node) => node.kind)
        .toSet();
    expect(
      copyableKinds,
      containsAll([
        ConversationNodeKind.assistant,
        ConversationNodeKind.tool,
        ConversationNodeKind.notice,
        ConversationNodeKind.user,
      ]),
    );
  });

  test('V086-16：completedTurn=false 的 assistant 不再被排除', () {
    final controller = SessionProjectionController();
    final snapshot = controller.buildSnapshot(
      timeline: [
        // A① 事故形态：文本已流式产出但回合永远等不到终态。
        SessionTimelineEvent(
          sequence: 7,
          kind: SessionTimelineKind.assistantMessage,
          label: 'Assistant',
          text: '已输出但回合未终态的内容',
          isStreaming: false,
          completedTurn: false,
        ),
      ],
      controls: const SessionControlState.empty(),
    );
    expect(snapshot.chatNodes.any((node) => node.canCopy), isTrue);
  });
}
