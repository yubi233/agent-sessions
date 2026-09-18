import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/app_harness.dart';

void main() {
  testWidgets('MOBILE-V05-22 textarea 软换行、caret reveal 与按钮保焦', (tester) async {
    await tester.binding.setSurfaceSize(const Size(430, 820));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await _openComposer(tester);
    final input = find.byKey(const Key('session-composer-input'));
    const multiline = '第一行很长但保持软换行内容。\n第二行。\n第三行。\n第四行。\n第五行。\n第六行末尾';
    await tester.enterText(input, multiline);
    await tester.pump();

    final field = tester.widget<TextField>(input);
    expect(field.minLines, 1);
    expect(field.maxLines, 5);
    expect(field.controller!.text, multiline);
    final editable = tester
        .state<EditableTextState>(
          find.descendant(of: input, matching: find.byType(EditableText)),
        )
        .renderEditable;
    final caret = editable.getLocalRectForCaret(
      const TextPosition(offset: multiline.length),
    );
    expect(caret.bottom, lessThanOrEqualTo(editable.size.height + 1));

    await tester.ensureVisible(
      find.byKey(const Key('session-command-launcher')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('session-command-launcher')));
    await tester.pump();
    expect(
      tester
          .widget<EditableText>(
            find.descendant(of: input, matching: find.byType(EditableText)),
          )
          .focusNode
          .hasFocus,
      isTrue,
    );
    expect(
      find.byKey(const Key('session-command-launcher-menu')),
      findsOneWidget,
    );

    await tester.ensureVisible(find.byKey(const Key('session-chat-view')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('session-chat-view')));
    await tester.pump();
    expect(
      find.byKey(const Key('session-command-launcher-menu')),
      findsNothing,
    );
  });

  testWidgets('MOBILE-V05-23 reference copy/cut/paste-upgrade 与 undo', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(430, 820));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await _openComposer(tester);
    final input = find.byKey(const Key('session-composer-input'));
    final clipboard = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          clipboard.add((call.arguments as Map)['text'] as String);
        }
        if (call.method == 'Clipboard.getData') {
          return {'text': clipboard.last};
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );

    await tester.enterText(input, '@read');
    await _waitFor(
      tester,
      find.byKey(const Key('completion-suggestion-文件 · README.md')),
    );
    await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(_text(tester), startsWith('@README.md'));

    _select(tester, 0, '@README.md'.length);
    await _shortcut(tester, LogicalKeyboardKey.keyC);
    expect(clipboard.last, '@file:README.md');

    await _shortcut(tester, LogicalKeyboardKey.keyX);
    await tester.pump();
    expect(_text(tester).trim(), isEmpty);
    await _shortcut(tester, LogicalKeyboardKey.keyZ);
    await tester.pump();
    expect(_text(tester), startsWith('@README.md'));

    _select(tester, 0, '@README.md'.length);
    await _shortcut(tester, LogicalKeyboardKey.keyX);
    await tester.pump();
    await _shortcut(tester, LogicalKeyboardKey.keyV);
    await tester.pump();
    expect(_text(tester), startsWith('@README.md'));

    _select(tester, '@README.md'.length, '@README.md'.length);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.backspace);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.backspace);
    await tester.pump();
    expect(_text(tester), isNot(contains('@README.md')));
  });
}

Future<void> _openComposer(WidgetTester tester) async {
  final harness = MobileAppHarness();
  await harness.bootstrapLocalOwner();
  final sessionId = await harness.seedSession();
  await tester.pumpWidget(harness.build());
  await _waitFor(tester, find.byKey(const Key('session-home-screen')));
  // v0.8.1+：经「最近会话」入口打开预置会话详情（首页已无旧式新建按钮）。
  await tester.tap(find.byKey(const Key('session-recent-button')));
  await _waitFor(tester, find.byKey(Key('recent-session-$sessionId')));
  await tester.tap(find.byKey(Key('recent-session-$sessionId')));
  await _waitFor(tester, find.byKey(const Key('session-detail-screen')));
  await _waitFor(tester, find.text('可控制'));
  await tester.ensureVisible(find.byKey(const Key('session-composer-input')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('session-composer-input')));
  await tester.pump();
}

Future<void> _shortcut(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
  await tester.sendKeyDownEvent(key);
  await tester.sendKeyUpEvent(key);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
  await tester.pump();
}

void _select(WidgetTester tester, int start, int end) {
  final text = _text(tester);
  tester.testTextInput.updateEditingValue(
    TextEditingValue(
      text: text,
      selection: TextSelection(baseOffset: start, extentOffset: end),
    ),
  );
}

String _text(WidgetTester tester) => tester
    .widget<TextField>(find.byKey(const Key('session-composer-input')))
    .controller!
    .text;

Future<void> _waitFor(WidgetTester tester, Finder finder) async {
  for (var index = 0; index < 120; index++) {
    if (finder.evaluate().isNotEmpty) return;
    await tester.pump(const Duration(milliseconds: 25));
  }
  expect(finder, findsWidgets);
}
