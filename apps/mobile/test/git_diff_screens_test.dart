import 'package:agent_sessions_mobile/app/providers.dart';
import 'package:agent_sessions_mobile/git/git_diff_repository.dart';
import 'package:agent_sessions_mobile/ui/git_diff_screens.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('MOBILE-04：480x960 上展示文件树、split、hunk 折叠和分页', (tester) async {
    await tester.binding.setSurfaceSize(const Size(480, 960));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(_screen(FixtureGitDiffRepository()));
    await _waitFor(
      tester,
      find.byKey(const Key('git-diff-file-lib-state-session-controller-dart')),
    );
    await _waitFor(tester, find.byKey(const Key('git-hunk-state-1')));

    expect(find.byKey(const Key('git-view-unified')), findsOneWidget);
    await _tapVisible(tester, find.byKey(const Key('git-view-split')));
    await _waitFor(tester, find.byKey(const Key('git-split-lines')));
    await _tapVisible(tester, find.byKey(const Key('git-view-unified')));
    await _waitFor(tester, find.byKey(const Key('git-unified-line-42')));

    await _tapVisible(tester, find.byKey(const Key('git-hunk-toggle-state-1')));
    expect(find.byKey(const Key('git-unified-line-42')), findsNothing);
    await _tapVisible(tester, find.byKey(const Key('git-load-more-button')));
    await _waitFor(tester, find.byKey(const Key('git-hunk-state-3')));

    await _tapVisible(tester, find.byKey(const Key('git-filter-staged')));
    await tester.enterText(
      find.byKey(const Key('git-diff-search-input')),
      'session_controller',
    );
    await tester.pump();
    expect(find.byKey(const Key('git-file-tree-empty')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('MOBILE-04：snapshot stale 后只显示重试，刷新后展示受限文件摘要', (tester) async {
    await tester.pumpWidget(
      _screen(
        FixtureGitDiffRepository(scenario: GitFixtureScenario.restricted),
      ),
    );
    await _waitFor(tester, find.byKey(const Key('git-snapshot-stale')));

    expect(find.byKey(const Key('git-diff-scroll')), findsNothing);
    await _tapVisible(tester, find.byKey(const Key('git-stale-retry-button')));
    await _waitFor(tester, find.byKey(const Key('git-diff-limited-state')));
    expect(find.text('二进制文件'), findsWidgets);
    expect(tester.takeException(), isNull);
  });
}

Widget _screen(GitDiffRepository repository) => ProviderScope(
  overrides: [gitDiffRepositoryProvider.overrideWithValue(repository)],
  child: MaterialApp(
    theme: ThemeData.dark(useMaterial3: true),
    home: const GitDiffScreen(sessionId: 'session_fixture'),
  ),
);

Future<void> _waitFor(
  WidgetTester tester,
  Finder finder, {
  int maxFrames = 80,
}) async {
  for (var frame = 0; frame < maxFrames; frame += 1) {
    await tester.pump(const Duration(milliseconds: 50));
    if (finder.evaluate().isNotEmpty) return;
  }
  expect(finder, findsOneWidget);
}

Future<void> _tapVisible(WidgetTester tester, Finder finder) async {
  await _waitFor(tester, finder);
  await tester.ensureVisible(finder);
  await tester.pump();
  await tester.tap(finder);
  await tester.pump();
}
