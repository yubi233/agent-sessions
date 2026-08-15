import 'package:agent_sessions_mobile/domain/workspace_files_models.dart';
import 'package:agent_sessions_mobile/files/workspace_files_repository.dart';
import 'package:agent_sessions_mobile/state/workspace_files_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('MOBILE-09 文件浏览控制器', () {
    test('根目录加载、进入目录、打开文本预览、二进制与超大文件安全摘要', () async {
      final controller = WorkspaceFilesController(
        repository: FixtureWorkspaceFilesRepository(),
      );
      final log = <String>[];
      controller.addListener(() => log.add('${controller.phase}:${controller.entries.length}:${controller.preview?.path ?? ''}:${controller.rejectionMessage ?? ''}'));

      await controller.initialize();
      expect(controller.currentPath, '');
      expect(controller.entries.length, 8);

      await controller.openDirectory('lib');
      expect(controller.currentPath, 'lib');
      expect(controller.entries.map((entry) => entry.name), contains('main.dart'));

      await controller.openFile('lib/main.dart');
      expect(controller.preview?.isPreviewable, isTrue);
      expect(controller.preview?.text, contains('void main()'));

      await controller.openFile('build/logo.png');
      expect(controller.preview?.limitedKind, WorkspaceFileLimitedKind.binary);
      expect(controller.preview?.text, isEmpty);

      await controller.openFile('notes/huge.log');
      expect(controller.preview?.limitedKind, WorkspaceFileLimitedKind.tooLarge);
      expect(controller.preview?.isTruncated, isTrue);
    });

    test('越权路径被拒绝且保持内容不变：绝对路径、..、根外符号链接', () async {
      final controller = WorkspaceFilesController(
        repository: FixtureWorkspaceFilesRepository(),
      );
      await controller.initialize();
      final before = controller.entries.map((entry) => entry.path).toList();

      await controller.openDirectory('/etc');
      expect(controller.rejectionMessage, contains('绝对路径'));
      expect(
        controller.entries.map((entry) => entry.path).toList(),
        before,
        reason: '越权目录被拒后根视图条目保持不变',
      );

      await controller.openFile('../secret.txt');
      expect(controller.rejectionMessage, contains('路径越界'));

      await controller.openFile('lib/escape.txt');
      expect(controller.rejectionMessage, contains('符号链接'));

      // 拒绝只展示原因，条目与根视图不被替换成越权内容。
      expect(controller.entries.length, before.length);
    });

    test('搜索只作用于当前目录条目', () async {
      final controller = WorkspaceFilesController(
        repository: FixtureWorkspaceFilesRepository(),
      );
      await controller.initialize();
      controller.search('main');
      expect(controller.searchResults.map((entry) => entry.path), contains('lib/main.dart'));
      controller.search('');
      expect(controller.searchResults, isEmpty);
    });

    test('Daemon RPC 未部署时显示不可用，不回退到 fixture 成功', () async {
      final controller = WorkspaceFilesController(
        repository: const UnavailableWorkspaceFilesRepository(),
      );
      await controller.initialize();
      expect(controller.phase, WorkspaceFilesPhase.error);
      expect(controller.errorMessage, contains('不可用'));
      expect(controller.entries, isEmpty);
    });

    test('restricted fixture 模拟未部署状态', () async {
      final controller = WorkspaceFilesController(
        repository: FixtureWorkspaceFilesRepository(
          scenario: WorkspaceFixtureScenario.restricted,
        ),
      );
      await controller.initialize();
      // 根目录可列（路径合法）；进入子目录时按未部署 Daemon RPC 返回不可用。
      expect(controller.phase, WorkspaceFilesPhase.ready);
      await controller.openDirectory('lib');
      expect(controller.phase, WorkspaceFilesPhase.error);
      expect(controller.errorMessage, contains('不可用'));
    });
  });

  group('MOBILE-09 文件浏览 UI', () {
    testWidgets('目录树可进入子目录并打开只读预览', (tester) async {
      final controller = WorkspaceFilesController(
        repository: FixtureWorkspaceFilesRepository(),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: _WorkspaceFilesTestHarness(controller: controller),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('workspace-files-list')), findsOneWidget);
      await tester.tap(find.byKey(const Key('workspace-file-lib')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('workspace-file-lib/main.dart')), findsOneWidget);

      await tester.tap(find.byKey(const Key('workspace-file-lib/main.dart')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('workspace-files-preview-panel')), findsOneWidget);
      expect(find.textContaining('void main()'), findsOneWidget);
    });

    testWidgets('二进制文件只显示受限摘要，不渲染正文', (tester) async {
      final controller = WorkspaceFilesController(
        repository: FixtureWorkspaceFilesRepository(),
      );
      await tester.pumpWidget(
        MaterialApp(home: _WorkspaceFilesTestHarness(controller: controller)),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('workspace-file-build')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('workspace-file-build/logo.png')));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('workspace-files-limited-preview')),
        findsOneWidget,
      );
      expect(find.textContaining('二进制文件'), findsOneWidget);
    });

    testWidgets('搜索过滤当前目录并可直接打开结果', (tester) async {
      final controller = WorkspaceFilesController(
        repository: FixtureWorkspaceFilesRepository(),
      );
      await tester.pumpWidget(
        MaterialApp(home: _WorkspaceFilesTestHarness(controller: controller)),
      );
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const Key('workspace-files-search-input')),
        'readme',
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('workspace-search-README.md')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('workspace-search-README.md')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('workspace-files-preview-panel')),
        findsOneWidget,
      );
    });
  });
}

/// 只挂载文件页 body 的轻量 harness（不依赖完整 App 路由）。
class _WorkspaceFilesTestHarness extends StatefulWidget {
  const _WorkspaceFilesTestHarness({required this.controller});

  final WorkspaceFilesController controller;

  @override
  State<_WorkspaceFilesTestHarness> createState() =>
      _WorkspaceFilesTestHarnessState();
}

class _WorkspaceFilesTestHarnessState
    extends State<_WorkspaceFilesTestHarness> {
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onChange);
    Future<void>.microtask(widget.controller.initialize);
  }

  @override
  void didUpdateWidget(covariant _WorkspaceFilesTestHarness oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onChange);
      widget.controller.addListener(_onChange);
    }
  }

  void _onChange() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onChange);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final entries = widget.controller.entries;
    final searchResults = widget.controller.searchResults;
    final isSearching = widget.controller.isSearching;
    final show = isSearching ? searchResults : entries;
    return Scaffold(
      body: Column(
        children: [
          TextField(
            key: const Key('workspace-files-search-input'),
            onChanged: widget.controller.search,
          ),
          Expanded(
            child: ListView(
              key: const Key('workspace-files-list'),
              children: [
                for (final entry in show)
                  ListTile(
                    key: Key('${isSearching ? 'workspace-search-' : 'workspace-file-'}${entry.path}'),
                    title: Text(entry.name),
                    onTap: () => entry.isDirectory
                        ? widget.controller.openDirectory(entry.path)
                        : widget.controller.openFile(entry.path),
                  ),
                if (widget.controller.rejectionMessage != null)
                  Text(
                    widget.controller.rejectionMessage!,
                    key: const Key('workspace-files-rejection-banner'),
                  ),
                if (widget.controller.preview != null)
                  Column(
                    key: const Key('workspace-files-preview-panel'),
                    children: [
                      if (widget.controller.preview!.isPreviewable)
                        Text(
                          widget.controller.preview!.text,
                          key: const Key('workspace-files-preview-text'),
                        )
                      else
                        Text(
                          widget.controller.preview!.limitedKind ==
                                  WorkspaceFileLimitedKind.binary
                              ? '二进制文件，不提供文本预览。'
                              : '文件过大，仅显示受限摘要。',
                          key: const Key('workspace-files-limited-preview'),
                        ),
                    ],
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
