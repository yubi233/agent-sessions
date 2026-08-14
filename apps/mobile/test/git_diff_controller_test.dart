import 'dart:async';

import 'package:agent_sessions_mobile/domain/git_diff_models.dart';
import 'package:agent_sessions_mobile/git/git_diff_repository.dart';
import 'package:agent_sessions_mobile/state/git_diff_controller.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('MOBILE-04 Git DiffView snapshot 状态机', () {
    test('文件树筛选、unified/split、hunk 折叠和分页都复用同一 snapshot', () async {
      final controller = GitDiffController(
        repository: FixtureGitDiffRepository(),
      );

      await controller.initialize();

      expect(controller.phase, GitDiffPhase.ready);
      expect(controller.snapshot?.snapshotToken, 'fixture-git-main-1');
      expect(controller.selectedPath, 'lib/state/session_controller.dart');
      expect(controller.hunks, hasLength(2));
      expect(controller.hasMore, isTrue);

      controller.setFilter(GitChangeFilter.staged);
      expect(controller.visibleFiles.every((file) => file.staged), isTrue);
      controller.setQuery('session_controller');
      expect(controller.visibleFiles, hasLength(1));
      controller.setViewMode(GitDiffViewMode.split);
      expect(controller.viewMode, GitDiffViewMode.split);
      controller.toggleHunk('state-1');
      expect(controller.isHunkCollapsed('state-1'), isTrue);

      await controller.loadNextPage();

      expect(controller.phase, GitDiffPhase.ready);
      expect(controller.hunks, hasLength(3));
      expect(controller.hasMore, isFalse);
      expect(controller.snapshot?.snapshotToken, 'fixture-git-main-1');
    });

    test('snapshot stale 会清空旧 hunk，只能刷新后重试', () async {
      final controller = GitDiffController(
        repository: FixtureGitDiffRepository(
          scenario: GitFixtureScenario.restricted,
        ),
      );

      await controller.initialize();

      expect(controller.phase, GitDiffPhase.stale);
      expect(controller.hunks, isEmpty);
      expect(controller.snapshot?.snapshotToken, 'fixture-git-restricted-1');

      await controller.retryAfterStale();

      expect(controller.phase, GitDiffPhase.ready);
      expect(controller.snapshot?.snapshotToken, 'fixture-git-restricted-2');
      expect(controller.selectedFile?.limitedKind, GitDiffLimitedKind.binary);
      expect(controller.hunks, isEmpty);
    });

    test('未部署加密 Daemon RPC 时显示不可用，不回退到 fixture 成功', () async {
      final controller = GitDiffController(
        repository: const UnavailableDaemonGitDiffRepository(),
      );

      await controller.initialize();

      expect(controller.phase, GitDiffPhase.unavailable);
      expect(controller.snapshot, isNull);
      expect(controller.message, contains('Daemon Git RPC'));
    });

    test('首个文件读取期间切换文件后，刷新不会被旧请求永久阻塞', () async {
      final repository = _DeferredFirstDiffRepository();
      final controller = GitDiffController(repository: repository);

      final initialLoad = controller.initialize();
      await repository.firstDiffStarted.future;
      await controller.selectFile('lib/ui/session_screens.dart');
      repository.releaseFirstDiff();
      await initialLoad;

      await controller.initialize(force: true);

      expect(repository.snapshotLoads, 2);
      expect(controller.phase, GitDiffPhase.ready);
      expect(controller.selectedPath, 'lib/ui/session_screens.dart');
    });
  });
}

/// 让第一次 diff 请求停在网络边界，复现用户在初始加载期间切换文件的竞态。
class _DeferredFirstDiffRepository implements GitDiffRepository {
  final FixtureGitDiffRepository _delegate = FixtureGitDiffRepository();
  final Completer<void> firstDiffStarted = Completer<void>();
  final Completer<void> _releaseFirstDiff = Completer<void>();
  var _diffLoads = 0;
  var snapshotLoads = 0;

  void releaseFirstDiff() {
    if (!_releaseFirstDiff.isCompleted) _releaseFirstDiff.complete();
  }

  @override
  Future<GitDiffSnapshot> loadSnapshot() async {
    snapshotLoads += 1;
    return _delegate.loadSnapshot();
  }

  @override
  Future<GitFileDiffPage> loadFileDiff({
    required String path,
    required String snapshotToken,
    required int offset,
    required int limit,
  }) async {
    _diffLoads += 1;
    if (_diffLoads == 1) {
      firstDiffStarted.complete();
      await _releaseFirstDiff.future;
    }
    return _delegate.loadFileDiff(
      path: path,
      snapshotToken: snapshotToken,
      offset: offset,
      limit: limit,
    );
  }
}
