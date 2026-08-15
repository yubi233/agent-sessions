/// 工作区文件浏览的错误分类（MOBILE-09）。
enum WorkspaceFilesFailureKind {
  /// 客户端参数错误（空路径等）。
  validation,

  /// 路径逃逸：绝对路径、`..` 越界或仓库外符号链接；与 Daemon workspacesafe 语义一致。
  pathEscape,

  /// 加密 Daemon RPC 未部署时不可用，禁止把 fixture 伪装成真实工作区结果。
  unavailable,

  /// 协议或上游返回格式错误。
  protocol,
}

/// 文件浏览失败，UI 按 kind 给出中文原因且不提供任何写入口。
class WorkspaceFilesFailure implements Exception {
  const WorkspaceFilesFailure(this.kind, this.message);

  final WorkspaceFilesFailureKind kind;
  final String message;

  @override
  String toString() => message;
}

/// 文件树的单节点。路径始终为 repo-relative，不携带真实文件正文。
class WorkspaceFileEntry {
  const WorkspaceFileEntry({
    required this.path,
    required this.name,
    required this.isDirectory,
    this.byteSize = 0,
  });

  final String path;
  final String name;
  final bool isDirectory;
  final int byteSize;

  bool get isTextPreviewable => !isDirectory;
}

/// 受限展示摘要：二进制或超大文件不能当文本渲染（与 DiffView 安全降级一致）。
enum WorkspaceFileLimitedKind { none, binary, tooLarge }

/// 只读文件内容。真实 Daemon RPC 未部署时不会出现本对象（走 unavailable）。
class WorkspaceFileContent {
  const WorkspaceFileContent({
    required this.path,
    required this.limitedKind,
    this.text = '',
    this.isTruncated = false,
    this.byteSize = 0,
  });

  final String path;
  final WorkspaceFileLimitedKind limitedKind;
  final String text;
  final bool isTruncated;
  final int byteSize;

  bool get isPreviewable =>
      limitedKind == WorkspaceFileLimitedKind.none && text.isNotEmpty;
}
