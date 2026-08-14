import '../domain/git_diff_models.dart';

/// GitDiffRepository 是独立的只读边界。它不能复用 RelayRepository，以免 Git 明文进入会话传输契约。
abstract interface class GitDiffRepository {
  Future<GitDiffSnapshot> loadSnapshot();

  Future<GitFileDiffPage> loadFileDiff({
    required String path,
    required String snapshotToken,
    required int offset,
    required int limit,
  });
}

/// 本轮本地可见验收使用的固定 Git 场景。它只生成无敏感的展示数据，不访问开发机仓库。
enum GitFixtureScenario { main, restricted }

/// FixtureGitDiffRepository 模拟 Daemon 只读响应的状态转移，包括 snapshot stale 后的重试。
class FixtureGitDiffRepository implements GitDiffRepository {
  FixtureGitDiffRepository({this.scenario = GitFixtureScenario.main});

  final GitFixtureScenario scenario;
  var _revision = 1;
  var _staleDelivered = false;

  @override
  Future<GitDiffSnapshot> loadSnapshot() async => _snapshotForRevision();

  @override
  Future<GitFileDiffPage> loadFileDiff({
    required String path,
    required String snapshotToken,
    required int offset,
    required int limit,
  }) async {
    if (offset < 0 || limit <= 0) {
      throw const GitDiffFailure(GitDiffFailureKind.validation, 'Diff 分页参数无效。');
    }
    final snapshot = _snapshotForRevision();
    if (snapshotToken != snapshot.snapshotToken) {
      throw const GitDiffFailure(
        GitDiffFailureKind.snapshotStale,
        'Git 工作区已变化，请刷新后再查看 Diff。',
      );
    }
    // restricted 场景先让首个读请求失效，证明 UI 不会拼接不同快照的文件树和 hunk。
    if (scenario == GitFixtureScenario.restricted && !_staleDelivered) {
      _staleDelivered = true;
      _revision = 2;
      throw const GitDiffFailure(
        GitDiffFailureKind.snapshotStale,
        'Git 快照已失效，旧内容已停止渲染。',
      );
    }
    final file = _fileAtPath(snapshot.files, path);
    if (file == null) {
      throw const GitDiffFailure(GitDiffFailureKind.validation, '找不到所选的变更文件。');
    }
    if (file.limitedKind != GitDiffLimitedKind.none) {
      return GitFileDiffPage(
        path: path,
        snapshotToken: snapshot.snapshotToken,
        offset: 0,
        nextOffset: 0,
        hasMore: false,
        hunks: const [],
        limitedKind: file.limitedKind,
        renameFrom: file.renameFrom,
      );
    }
    final hunks = _fixtureHunksFor(path);
    final start = offset.clamp(0, hunks.length).toInt();
    final end = (start + limit).clamp(0, hunks.length).toInt();
    return GitFileDiffPage(
      path: path,
      snapshotToken: snapshot.snapshotToken,
      offset: start,
      nextOffset: end,
      hasMore: end < hunks.length,
      hunks: hunks.sublist(start, end),
      renameFrom: file.renameFrom,
    );
  }

  GitDiffSnapshot _snapshotForRevision() {
    final restricted = scenario == GitFixtureScenario.restricted;
    final files = restricted ? _restrictedFiles : _mainFiles;
    return GitDiffSnapshot(
      snapshotToken: 'fixture-git-${scenario.name}-$_revision',
      repositoryLabel: restricted
          ? 'fixture-security-review'
          : 'fixture-agent-sessions',
      branch: restricted ? 'review/diff-guard' : 'feature/mobile-diff',
      summary: restricted
          ? const GitDiffSummary(
              changedFiles: 5,
              stagedFiles: 2,
              unstagedFiles: 3,
              additions: 14,
              deletions: 6,
            )
          : const GitDiffSummary(
              changedFiles: 4,
              stagedFiles: 2,
              unstagedFiles: 3,
              additions: 24,
              deletions: 11,
            ),
      files: files,
    );
  }
}

GitChangeFile? _fileAtPath(List<GitChangeFile> files, String path) {
  for (final file in files) {
    if (file.path == path) return file;
  }
  return null;
}

/// 有真实 Relay 配置但尚未部署加密 Daemon Git RPC 时，必须明确不可用，不能回退到假成功。
class UnavailableDaemonGitDiffRepository implements GitDiffRepository {
  const UnavailableDaemonGitDiffRepository();

  Never _unavailable() => throw const GitDiffFailure(
    GitDiffFailureKind.unavailable,
    '当前 Relay 尚未配置加密 Daemon Git RPC，无法读取本地工作区变更。',
  );

  @override
  Future<GitDiffSnapshot> loadSnapshot() async => _unavailable();

  @override
  Future<GitFileDiffPage> loadFileDiff({
    required String path,
    required String snapshotToken,
    required int offset,
    required int limit,
  }) async => _unavailable();
}

const _mainFiles = <GitChangeFile>[
  GitChangeFile(
    path: 'lib/state/session_controller.dart',
    type: GitChangeType.modified,
    staged: true,
    unstaged: true,
    additions: 12,
    deletions: 4,
  ),
  GitChangeFile(
    path: 'lib/ui/session_screens.dart',
    type: GitChangeType.modified,
    staged: true,
    unstaged: false,
    additions: 8,
    deletions: 3,
  ),
  GitChangeFile(
    path: 'docs/zh/迭代计划/迭代计划v0.1.md',
    type: GitChangeType.modified,
    staged: false,
    unstaged: true,
    additions: 4,
    deletions: 1,
  ),
  GitChangeFile(
    path: 'lib/ui/git_diff_view.dart',
    type: GitChangeType.renamed,
    renameFrom: 'lib/ui/legacy_diff_view.dart',
    staged: false,
    unstaged: true,
    additions: 0,
    deletions: 3,
  ),
];

const _restrictedFiles = <GitChangeFile>[
  GitChangeFile(
    path: 'assets/preview.bin',
    type: GitChangeType.modified,
    staged: false,
    unstaged: true,
    additions: 0,
    deletions: 0,
    limitedKind: GitDiffLimitedKind.binary,
  ),
  GitChangeFile(
    path: 'vendor/review-tool',
    type: GitChangeType.modified,
    staged: true,
    unstaged: false,
    additions: 0,
    deletions: 0,
    limitedKind: GitDiffLimitedKind.submodule,
  ),
  GitChangeFile(
    path: 'data/context.lfs',
    type: GitChangeType.modified,
    staged: false,
    unstaged: true,
    additions: 0,
    deletions: 0,
    limitedKind: GitDiffLimitedKind.lfs,
  ),
  GitChangeFile(
    path: 'generated/large.diff',
    type: GitChangeType.modified,
    staged: false,
    unstaged: true,
    additions: 14,
    deletions: 6,
    limitedKind: GitDiffLimitedKind.tooLarge,
  ),
  GitChangeFile(
    path: 'lib/diff/snapshot_reader.dart',
    type: GitChangeType.renamed,
    renameFrom: 'lib/diff/reader.dart',
    staged: true,
    unstaged: false,
    additions: 0,
    deletions: 0,
  ),
];

List<GitDiffHunk> _fixtureHunksFor(String path) {
  if (path == 'lib/state/session_controller.dart') {
    return const [
      GitDiffHunk(
        id: 'state-1',
        header: '@@ -42,6 +42,9 @@ class SessionController',
        lines: [
          GitDiffLine(
            kind: GitDiffLineKind.context,
            oldLine: 42,
            newLine: 42,
            text: '  Future<void> refreshSessions() async {',
          ),
          GitDiffLine(
            kind: GitDiffLineKind.deletion,
            oldLine: 43,
            text: '    _errorMessage = null;',
          ),
          GitDiffLine(
            kind: GitDiffLineKind.addition,
            newLine: 43,
            text: '    _clearTransientGitState();',
          ),
          GitDiffLine(
            kind: GitDiffLineKind.addition,
            newLine: 44,
            text: '    _errorMessage = null;',
          ),
        ],
      ),
      GitDiffHunk(
        id: 'state-2',
        header: '@@ -167,5 +170,8 @@ class SessionController',
        lines: [
          GitDiffLine(
            kind: GitDiffLineKind.context,
            oldLine: 167,
            newLine: 170,
            text: '  void clearError() {',
          ),
          GitDiffLine(
            kind: GitDiffLineKind.addition,
            newLine: 171,
            text: '    // 旧 snapshot 不能继续与刷新后的文件树混用。',
          ),
          GitDiffLine(
            kind: GitDiffLineKind.addition,
            newLine: 172,
            text: '    _clearTransientGitState();',
          ),
        ],
      ),
      GitDiffHunk(
        id: 'state-3',
        header: '@@ -219,3 +225,7 @@ class SessionController',
        lines: [
          GitDiffLine(
            kind: GitDiffLineKind.context,
            oldLine: 219,
            newLine: 225,
            text: '  void _clearSelection() {',
          ),
          GitDiffLine(
            kind: GitDiffLineKind.addition,
            newLine: 226,
            text: '    _gitSnapshot = null;',
          ),
        ],
      ),
    ];
  }
  return const [
    GitDiffHunk(
      id: 'generic-1',
      header: '@@ -1,3 +1,4 @@',
      lines: [
        GitDiffLine(
          kind: GitDiffLineKind.context,
          oldLine: 1,
          newLine: 1,
          text: 'fixture line',
        ),
        GitDiffLine(
          kind: GitDiffLineKind.deletion,
          oldLine: 2,
          text: 'legacy behavior',
        ),
        GitDiffLine(
          kind: GitDiffLineKind.addition,
          newLine: 2,
          text: 'snapshot-safe behavior',
        ),
      ],
    ),
  ];
}
