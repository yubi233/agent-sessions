import '../domain/git_diff_models.dart';
import 'git_diff_repository.dart';
import 'readonly_command_gateway.dart';

/// v0.8.8 P2（V088-07 / 迭代计划 G2）：GitDiffRepository 的真实传输实现。
///
/// 数据流（daemon ReadOnlyDispatcher 沙箱语义）：
///   loadSnapshot()      → git.status   → {head, branch, snapshot_token, files[]}
///   loadFileDiff(...)   → git.diff     → {path, hunks[], has_more, ...}（分页期间
///     透传调用方给定的 snapshot_token，daemon 侧 SNAPSHOT_STALE 时映射 stale 失败）
///
/// 与 fixture 的契约差异：本实现不做本地 stale 预检（daemon 的 snapshot_token
/// 校验是唯一事实源）；行号由 unified diff 头 `@@ -a,b +c,d @@` 解析。
/// 明文红线：diff 正文只在返回值内存中，不写日志。
class RelayGitDiffRepository implements GitDiffRepository {
  RelayGitDiffRepository({required this.gateway});

  /// 只读命令网关（submit → receipt → tool_result 关联）。
  final ReadonlyCommandGateway gateway;

  @override
  Future<GitDiffSnapshot> loadSnapshot() async {
    final status = await gateway.execute(
      wireKind: 'git.status',
      fixturePayload: const <String, dynamic>{},
      failureMapper: gitDiffFailureMapper,
    );
    return _snapshotFromStatus(status);
  }

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
    final page = await gateway.execute(
      wireKind: 'git.diff',
      fixturePayload: <String, dynamic>{
        'path': path,
        'snapshot_token': snapshotToken,
        'offset': offset,
        'limit': limit,
      },
      failureMapper: gitDiffFailureMapper,
    );
    return _pageFromDaemon(page);
  }

  /// git.status 结果 → GitDiffSnapshot（白名单元数据映射，见 gitread.Status）。
  GitDiffSnapshot _snapshotFromStatus(Map<String, dynamic> status) {
    final filesRaw = (status['files'] as List?) ?? const [];
    final files = <GitChangeFile>[];
    var additions = 0;
    var deletions = 0;
    var staged = 0;
    var unstaged = 0;
    for (final item in filesRaw) {
      if (item is! Map) continue;
      final file = Map<String, dynamic>.from(item);
      final fileAdditions = (file['additions'] as num?)?.toInt() ?? 0;
      final fileDeletions = (file['deletions'] as num?)?.toInt() ?? 0;
      final isStaged = file['staged'] == true;
      final isUnstaged = file['unstaged'] == true;
      additions += fileAdditions;
      deletions += fileDeletions;
      if (isStaged) staged += 1;
      if (isUnstaged) unstaged += 1;
      files.add(
        GitChangeFile(
          path: (file['path'] as String?) ?? '',
          type: _changeTypeFromWire((file['type'] as String?) ?? ''),
          staged: isStaged,
          unstaged: isUnstaged,
          additions: fileAdditions,
          deletions: fileDeletions,
          renameFrom: (file['rename'] as Map?)?['from'] as String?,
          limitedKind: _limitedKindFromFlags(
            binary: file['binary'] == true,
            lfs: file['lfs'] == true,
            submodule: file['submodule'] == true,
          ),
        ),
      );
    }
    return GitDiffSnapshot(
      snapshotToken: (status['snapshot_token'] as String?) ?? '',
      // repositoryLabel 用 HEAD 短哈希：仓库显示名属于工作区投影，不属于 git 结果。
      repositoryLabel: ((status['head'] as String?) ?? '').substring(
        0,
        ((status['head'] as String?) ?? '').length.clamp(0, 7),
      ),
      branch: (status['branch'] as String?) ?? '',
      summary: GitDiffSummary(
        changedFiles: files.length,
        stagedFiles: staged,
        unstagedFiles: unstaged,
        additions: additions,
        deletions: deletions,
      ),
      files: files,
    );
  }

  /// git.diff 结果 → GitFileDiffPage（受限文件只带 limitedKind，无可渲染行）。
  GitFileDiffPage _pageFromDaemon(Map<String, dynamic> page) {
    final limitedKind = _limitedKindFromFlags(
      binary: page['binary'] == true,
      lfs: page['lfs'] == true,
      submodule: page['submodule'] == true,
    );
    final hunksRaw = (page['hunks'] as List?) ?? const [];
    final hunks = <GitDiffHunk>[];
    var index = 0;
    for (final item in hunksRaw) {
      if (item is! Map) continue;
      final hunk = Map<String, dynamic>.from(item);
      index += 1;
      final header = (hunk['header'] as String?) ?? '';
      hunks.add(
        GitDiffHunk(
          id: 'hunk-$index',
          header: header,
          // daemon DiffHunk 把 @@ 头与行体分离：行号状态机从 header 初始化。
          lines: _linesFromRaw(
            (hunk['lines'] as List?) ?? const [],
            startHeader: header,
          ),
        ),
      );
    }
    return GitFileDiffPage(
      path: (page['path'] as String?) ?? '',
      snapshotToken: (page['snapshot_token'] as String?) ?? '',
      offset: (page['offset'] as num?)?.toInt() ?? 0,
      nextOffset: (page['next_offset'] as num?)?.toInt() ?? 0,
      hasMore: page['has_more'] == true,
      hunks: hunks,
      limitedKind: limitedKind,
      renameFrom: (page['rename'] as Map?)?['from'] as String?,
    );
  }
}

GitChangeType _changeTypeFromWire(String wire) => switch (wire) {
      'added' => GitChangeType.added,
      'deleted' => GitChangeType.deleted,
      'renamed' => GitChangeType.renamed,
      'type_changed' => GitChangeType.typeChanged,
      'untracked' => GitChangeType.untracked,
      _ => GitChangeType.modified,
    };

GitDiffLimitedKind _limitedKindFromFlags({
  required bool binary,
  required bool lfs,
  required bool submodule,
}) {
  if (binary) return GitDiffLimitedKind.binary;
  if (submodule) return GitDiffLimitedKind.submodule;
  if (lfs) return GitDiffLimitedKind.lfs;
  return GitDiffLimitedKind.none;
}

/// unified diff 原始行 → 带稳定行号的 GitDiffLine。
/// 行号状态机：context 双侧递增，deletion 递增旧行号，addition 递增新行号；
/// 初始行号来自 hunk 头 `@@ -o,n +p,q @@`（daemon 把头放在 header 字段；
/// 行体内偶见的 @@ 头同样被识别，无头时行号保持 null）。
List<GitDiffLine> _linesFromRaw(
  List<dynamic> rawLines, {
  String startHeader = '',
}) {
  final lines = <GitDiffLine>[];
  var oldLine = 0;
  var newLine = 0;
  var lineNumbersKnown = false;
  void applyHeader(String raw) {
    final header = RegExp(r'@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@')
        .firstMatch(raw);
    if (header != null) {
      oldLine = int.parse(header.group(1)!);
      newLine = int.parse(header.group(2)!);
      lineNumbersKnown = true;
    }
  }

  if (startHeader.isNotEmpty) {
    applyHeader(startHeader);
  }
  for (final raw in rawLines) {
    if (raw is! String) continue;
    if (raw.startsWith('@@')) {
      applyHeader(raw);
      continue;
    }
    if (raw.startsWith('\\')) continue; // "\ No newline at end of file"
    final kind = switch (raw.isEmpty ? ' ' : raw[0]) {
      '+' => GitDiffLineKind.addition,
      '-' => GitDiffLineKind.deletion,
      _ => GitDiffLineKind.context,
    };
    final text = raw.isEmpty ? '' : raw.substring(1);
    switch (kind) {
      case GitDiffLineKind.addition:
        lines.add(
          GitDiffLine(
            kind: kind,
            text: text,
            newLine: lineNumbersKnown ? newLine : null,
          ),
        );
        if (lineNumbersKnown) newLine += 1;
      case GitDiffLineKind.deletion:
        lines.add(
          GitDiffLine(
            kind: kind,
            text: text,
            oldLine: lineNumbersKnown ? oldLine : null,
          ),
        );
        if (lineNumbersKnown) oldLine += 1;
      case GitDiffLineKind.context:
        lines.add(
          GitDiffLine(
            kind: kind,
            text: text,
            oldLine: lineNumbersKnown ? oldLine : null,
            newLine: lineNumbersKnown ? newLine : null,
          ),
        );
        if (lineNumbersKnown) {
          oldLine += 1;
          newLine += 1;
        }
    }
  }
  return lines;
}
