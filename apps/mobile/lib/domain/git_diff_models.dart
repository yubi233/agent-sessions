/// Git DiffView 的状态筛选只影响本地展示，不会触发任何 Git 写操作。
enum GitChangeFilter {
  all('全部'),
  staged('已暂存'),
  unstaged('未暂存');

  const GitChangeFilter(this.label);

  final String label;
}

/// Git 变更类型由 Daemon 的 porcelain v2 结果映射而来。
enum GitChangeType {
  added('新增'),
  modified('修改'),
  deleted('删除'),
  renamed('重命名'),
  typeChanged('类型变更'),
  untracked('未跟踪');

  const GitChangeType(this.label);

  final String label;
}

/// 窄屏默认 unified；split 仅改变渲染方式，不修改底层 diff 或 snapshot。
enum GitDiffViewMode { unified, split }

/// 每一行的类型决定 unified/split 中的颜色和左右行号。
enum GitDiffLineKind { context, addition, deletion }

/// 受限文件必须明确说明原因，不能将二进制或超大内容伪装成普通文本 diff。
enum GitDiffLimitedKind {
  none,
  binary,
  submodule,
  lfs,
  tooLarge;

  String get label => switch (this) {
    GitDiffLimitedKind.none => '',
    GitDiffLimitedKind.binary => '二进制文件',
    GitDiffLimitedKind.submodule => '子模块变更',
    GitDiffLimitedKind.lfs => 'Git LFS 指针',
    GitDiffLimitedKind.tooLarge => 'Diff 超出安全上限',
  };

  String get detail => switch (this) {
    GitDiffLimitedKind.none => '',
    GitDiffLimitedKind.binary => '为避免把二进制内容渲染为文本，此文件只显示元数据。',
    GitDiffLimitedKind.submodule => '子模块仅展示提交引用变化，不展开子仓库内容。',
    GitDiffLimitedKind.lfs => '此文件由 Git LFS 管理，只展示受控指针状态。',
    GitDiffLimitedKind.tooLarge => '内容超过单次读取上限，请在本机缩小范围后重试。',
  };
}

/// GitDiffSummary 是同一个 snapshot 下的变更统计，避免文件树与统计混用快照。
class GitDiffSummary {
  const GitDiffSummary({
    required this.changedFiles,
    required this.stagedFiles,
    required this.unstagedFiles,
    required this.additions,
    required this.deletions,
  });

  final int changedFiles;
  final int stagedFiles;
  final int unstagedFiles;
  final int additions;
  final int deletions;
}

/// GitChangeFile 只保留 DiffView 所需的白名单元数据；真实路径和 diff 正文不会进入日志。
class GitChangeFile {
  const GitChangeFile({
    required this.path,
    required this.type,
    required this.staged,
    required this.unstaged,
    required this.additions,
    required this.deletions,
    this.renameFrom,
    this.limitedKind = GitDiffLimitedKind.none,
  });

  final String path;
  final GitChangeType type;
  final bool staged;
  final bool unstaged;
  final int additions;
  final int deletions;
  final String? renameFrom;
  final GitDiffLimitedKind limitedKind;

  bool matchesFilter(GitChangeFilter filter) => switch (filter) {
    GitChangeFilter.all => true,
    GitChangeFilter.staged => staged,
    GitChangeFilter.unstaged => unstaged,
  };

  bool matchesQuery(String query) {
    final normalized = query.trim().toLowerCase();
    if (normalized.isEmpty) return true;
    return path.toLowerCase().contains(normalized) ||
        (renameFrom?.toLowerCase().contains(normalized) ?? false);
  }
}

/// GitDiffSnapshot 是一次不可混用的文件树快照；token 来自 Daemon，客户端仅透传回后续读取。
class GitDiffSnapshot {
  const GitDiffSnapshot({
    required this.snapshotToken,
    required this.repositoryLabel,
    required this.branch,
    required this.summary,
    required this.files,
  });

  final String snapshotToken;
  final String repositoryLabel;
  final String branch;
  final GitDiffSummary summary;
  final List<GitChangeFile> files;
}

/// GitDiffLine 保留稳定左右行号，使 unified/split 切换不会改变 hunk 的原始顺序。
class GitDiffLine {
  const GitDiffLine({
    required this.kind,
    required this.text,
    this.oldLine,
    this.newLine,
  });

  final GitDiffLineKind kind;
  final String text;
  final int? oldLine;
  final int? newLine;
}

/// GitDiffHunk 是可单独折叠的稳定片段；hunk id 只在当前 snapshot 内使用。
class GitDiffHunk {
  const GitDiffHunk({
    required this.id,
    required this.header,
    required this.lines,
  });

  final String id;
  final String header;
  final List<GitDiffLine> lines;
}

/// GitFileDiffPage 用于 hunk 分页。受限文件会带 limitedKind 且没有可渲染文本行。
class GitFileDiffPage {
  const GitFileDiffPage({
    required this.path,
    required this.snapshotToken,
    required this.offset,
    required this.nextOffset,
    required this.hasMore,
    required this.hunks,
    this.limitedKind = GitDiffLimitedKind.none,
    this.renameFrom,
  });

  final String path;
  final String snapshotToken;
  final int offset;
  final int nextOffset;
  final bool hasMore;
  final List<GitDiffHunk> hunks;
  final GitDiffLimitedKind limitedKind;
  final String? renameFrom;
}

/// Git 读取失败类型与 Relay 会话失败分离，避免客户端误把本地 Git 读取当成会话写控制。
enum GitDiffFailureKind { unavailable, snapshotStale, validation, transport }

class GitDiffFailure implements Exception {
  const GitDiffFailure(this.kind, this.message);

  final GitDiffFailureKind kind;
  final String message;

  @override
  String toString() => message;
}
