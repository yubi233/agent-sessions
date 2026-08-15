import '../domain/workspace_files_models.dart';

/// WorkspaceFilesRepository 是只读文件浏览边界，与 GitDiffRepository 一样独立于 RelayRepository：
/// 路径校验语义对齐 Daemon workspacesafe，客户端不持有文件正文明文传输契约。
abstract interface class WorkspaceFilesRepository {
  /// 列出目录下的直接子项（repo-relative path）。绝对路径/`..`/根外符号链接必须被拒绝。
  Future<List<WorkspaceFileEntry>> listDirectory(String path);

  /// 读取文本文件预览；二进制与超大文件只返回受限摘要。
  Future<WorkspaceFileContent> readFile(String path);
}

/// 本地可见验收使用的固定文件树。只生成无敏感名称的确定性数据。
/// 覆盖：普通文本、二进制、超大文件、越权路径拒绝（绝对路径/`..`/根外符号链接）。
class FixtureWorkspaceFilesRepository implements WorkspaceFilesRepository {
  FixtureWorkspaceFilesRepository({this.scenario = WorkspaceFixtureScenario.main});

  final WorkspaceFixtureScenario scenario;

  static const _rootEntries = [
    WorkspaceFileEntry(path: 'README.md', name: 'README.md', isDirectory: false, byteSize: 1024),
    WorkspaceFileEntry(path: 'lib/main.dart', name: 'main.dart', isDirectory: false, byteSize: 4096),
    WorkspaceFileEntry(path: 'lib', name: 'lib', isDirectory: true),
    WorkspaceFileEntry(path: 'assets', name: 'assets', isDirectory: true),
    WorkspaceFileEntry(path: 'build/logo.png', name: 'logo.png', isDirectory: false, byteSize: 512 * 1024),
    WorkspaceFileEntry(path: 'build', name: 'build', isDirectory: true),
    WorkspaceFileEntry(path: 'notes/huge.log', name: 'huge.log', isDirectory: false, byteSize: 64 * 1024 * 1024),
    WorkspaceFileEntry(path: 'notes', name: 'notes', isDirectory: true),
  ];

  static const _libEntries = [
    WorkspaceFileEntry(path: 'lib/main.dart', name: 'main.dart', isDirectory: false, byteSize: 4096),
    WorkspaceFileEntry(path: 'lib/utils', name: 'utils', isDirectory: true),
  ];

  @override
  Future<List<WorkspaceFileEntry>> listDirectory(String path) async {
    _rejectUnsafePath(path);
    return switch (path) {
      '' || '/' => _rootEntries,
      'lib' => _libEntries,
      'lib/utils' => const [
        WorkspaceFileEntry(path: 'lib/utils/format.dart', name: 'format.dart', isDirectory: false, byteSize: 2048),
      ],
      'assets' => const [
        WorkspaceFileEntry(path: 'assets/icon.png', name: 'icon.png', isDirectory: false, byteSize: 64 * 1024),
      ],
      'build' => const [
        WorkspaceFileEntry(path: 'build/logo.png', name: 'logo.png', isDirectory: false, byteSize: 512 * 1024),
      ],
      'notes' => const [
        WorkspaceFileEntry(path: 'notes/huge.log', name: 'huge.log', isDirectory: false, byteSize: 64 * 1024 * 1024),
      ],
      _ => throw const WorkspaceFilesFailure(
        WorkspaceFilesFailureKind.validation,
        '找不到所选的目录。',
      ),
    };
  }

  @override
  Future<WorkspaceFileContent> readFile(String path) async {
    _rejectUnsafePath(path);
    return switch (path) {
      'README.md' => const WorkspaceFileContent(
        path: 'README.md',
        limitedKind: WorkspaceFileLimitedKind.none,
        text: 'Agent Sessions fixture 只读文件预览。',
      ),
      'lib/main.dart' => const WorkspaceFileContent(
        path: 'lib/main.dart',
        limitedKind: WorkspaceFileLimitedKind.none,
        text: 'void main() {\n  runApp(const App());\n}\n',
      ),
      'lib/utils/format.dart' => const WorkspaceFileContent(
        path: 'lib/utils/format.dart',
        limitedKind: WorkspaceFileLimitedKind.none,
        text: 'String format(int value) => value.toString();\n',
      ),
      'build/logo.png' => const WorkspaceFileContent(
        path: 'build/logo.png',
        limitedKind: WorkspaceFileLimitedKind.binary,
        byteSize: 512 * 1024,
      ),
      'notes/huge.log' => const WorkspaceFileContent(
        path: 'notes/huge.log',
        limitedKind: WorkspaceFileLimitedKind.tooLarge,
        byteSize: 64 * 1024 * 1024,
        isTruncated: true,
      ),
      _ => throw const WorkspaceFilesFailure(
        WorkspaceFilesFailureKind.validation,
        '找不到所选文件。',
      ),
    };
  }

  /// 与 Daemon workspacesafe.ResolveRepoRelative 一致：拒绝绝对路径、`..` 与根外符号链接。
  /// 空路径表示工作区根目录（等价于 `/`），是合法的初始视图。
  void _rejectUnsafePath(String path) {
    if (path.isEmpty || path == '/') {
      return;
    }
    if (path.startsWith('/') || path.contains(':')) {
      throw const WorkspaceFilesFailure(
        WorkspaceFilesFailureKind.pathEscape,
        '绝对路径已被拒绝。',
      );
    }
    final segments = path.split('/');
    if (segments.any((segment) => segment == '..')) {
      throw const WorkspaceFilesFailure(
        WorkspaceFilesFailureKind.pathEscape,
        '路径越界（..）已被拒绝。',
      );
    }
    if (segments.contains('escape.txt')) {
      throw const WorkspaceFilesFailure(
        WorkspaceFilesFailureKind.pathEscape,
        '仓库外符号链接已被拒绝。',
      );
    }
    if (scenario == WorkspaceFixtureScenario.restricted) {
      throw const WorkspaceFilesFailure(
        WorkspaceFilesFailureKind.unavailable,
        '文件浏览依赖 Daemon 加密 RPC，当前不可用。',
      );
    }
  }
}

/// fixture 场景：main 提供确定性树；restricted 模拟 Daemon RPC 未部署的不可用状态。
enum WorkspaceFixtureScenario { main, restricted }

/// 配置真实 Relay 但尚未部署加密 Daemon 文件 RPC 时的安全实现：
/// 任何读取都显式不可用，绝不把 fixture 结果伪装成真实工作区内容。
class UnavailableWorkspaceFilesRepository implements WorkspaceFilesRepository {
  const UnavailableWorkspaceFilesRepository();

  @override
  Future<List<WorkspaceFileEntry>> listDirectory(String path) async {
    throw const WorkspaceFilesFailure(
      WorkspaceFilesFailureKind.unavailable,
      '文件浏览依赖 Daemon 加密 RPC，尚未部署，当前不可用。',
    );
  }

  @override
  Future<WorkspaceFileContent> readFile(String path) async {
    throw const WorkspaceFilesFailure(
      WorkspaceFilesFailureKind.unavailable,
      '文件浏览依赖 Daemon 加密 RPC，尚未部署，当前不可用。',
    );
  }
}
