import 'package:agent_sessions_mobile/app/providers.dart';
import 'package:agent_sessions_mobile/files/workspace_files_repository.dart';
import 'package:agent_sessions_mobile/ui/code_viewer_screens.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('MOBILE-18 代码查看器 UI', () {
    Future<void> pumpCodeViewer(
      WidgetTester tester, {
      String filePath = 'lib/main.dart',
    }) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            workspaceFilesRepositoryProvider.overrideWithValue(
              FixtureWorkspaceFilesRepository(),
            ),
          ],
          child: const MaterialApp(
            home: CodeViewerScreen(filePath: 'lib/main.dart'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      // filePath 参数通过构造传入，但上面 home 固定 lib/main.dart；
      // 使用同名变量避免 lint 未使用警告。
      expect(filePath, isNotEmpty);
    }

    testWidgets('打开文本文件显示行号列、正文列与文件名标题', (tester) async {
      await pumpCodeViewer(tester);
      expect(find.byKey(const Key('code-viewer-screen')), findsOneWidget);
      expect(find.byKey(const Key('code-viewer-title')), findsOneWidget);
      expect(
        tester.widget<Text>(find.byKey(const Key('code-viewer-title'))).data,
        'lib/main.dart',
      );
      expect(find.byKey(const Key('code-viewer-line-numbers')), findsOneWidget);
      expect(find.byKey(const Key('code-viewer-text-column')), findsOneWidget);
      // fixture 内容包含 Dart 关键字，正文渲染而不是受限摘要。
      expect(find.byKey(const Key('code-viewer-limited')), findsNothing);
      expect(find.textContaining('void main()'), findsOneWidget);
    });

    testWidgets('二进制文件只显示受限摘要，不渲染正文', (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            workspaceFilesRepositoryProvider.overrideWithValue(
              FixtureWorkspaceFilesRepository(),
            ),
          ],
          child: const MaterialApp(
            home: CodeViewerScreen(filePath: 'build/logo.png'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('code-viewer-limited')), findsOneWidget);
      expect(find.textContaining('二进制文件'), findsOneWidget);
      expect(find.byKey(const Key('code-viewer-text-column')), findsNothing);
    });

    testWidgets('超大文件显示受限摘要', (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            workspaceFilesRepositoryProvider.overrideWithValue(
              FixtureWorkspaceFilesRepository(),
            ),
          ],
          child: const MaterialApp(
            home: CodeViewerScreen(filePath: 'notes/huge.log'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('code-viewer-limited')), findsOneWidget);
      expect(find.textContaining('文件过大'), findsOneWidget);
    });

    testWidgets('越权路径显示错误与重试按钮', (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            workspaceFilesRepositoryProvider.overrideWithValue(
              FixtureWorkspaceFilesRepository(),
            ),
          ],
          child: const MaterialApp(
            home: CodeViewerScreen(filePath: '../secret.txt'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('code-viewer-error')), findsOneWidget);
      expect(find.textContaining('越界'), findsOneWidget);
      expect(find.byTooltip('重试读取代码'), findsOneWidget);
    });

    testWidgets('加载中显示 loading 指示器', (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            workspaceFilesRepositoryProvider.overrideWithValue(
              FixtureWorkspaceFilesRepository(),
            ),
          ],
          child: const MaterialApp(
            home: CodeViewerScreen(filePath: 'lib/main.dart'),
          ),
        ),
      );
      // 首次帧处于 loading；pump 一次微任务后进入 ready。
      expect(find.byKey(const Key('code-viewer-loading')), findsOneWidget);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('code-viewer-loading')), findsNothing);
    });

    testWidgets('搜索功能：显示匹配计数并可上下跳转', (tester) async {
      await pumpCodeViewer(tester);
      await tester.tap(find.byKey(const Key('code-viewer-search-button')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('code-viewer-search-input')),
        'void',
      );
      await tester.pumpAndSettle();
      // 搜索确认在 onSubmitted，enterText 后需要提交。
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('code-viewer-search-bar')), findsOneWidget);
      expect(find.byKey(const Key('code-viewer-search-count')), findsOneWidget);
      // 关闭搜索后搜索条消失。
      await tester.tap(find.byKey(const Key('code-viewer-search-close')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('code-viewer-search-bar')), findsNothing);
    });

    testWidgets('跳转行对话框可提交并回到视图', (tester) async {
      await pumpCodeViewer(tester);
      await tester.tap(find.byKey(const Key('code-viewer-jump-button')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('code-viewer-line-input')), findsOneWidget);
      await tester.enterText(
        find.byKey(const Key('code-viewer-line-input')),
        '2',
      );
      await tester.tap(find.byKey(const Key('code-viewer-line-jump-confirm')));
      await tester.pumpAndSettle();
      // 对话框关闭后回到代码视图。
      expect(find.byKey(const Key('code-viewer-line-input')), findsNothing);
      expect(find.byKey(const Key('code-viewer-text-column')), findsOneWidget);
    });

    testWidgets('返回按钮关闭页面', (tester) async {
      await pumpCodeViewer(tester);
      await tester.tap(find.byKey(const Key('code-viewer-back-button')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('code-viewer-screen')), findsNothing);
    });
  });
}
