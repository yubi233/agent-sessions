import 'package:flutter/foundation.dart';

import '../domain/workspace_files_models.dart';
import '../files/workspace_files_repository.dart';

/// 文件浏览页面的加载阶段。
enum WorkspaceFilesPhase { loading, ready, error }

/// 文件浏览的只读状态机：目录树、选中文件预览与越权拒绝都只存在于内存。
/// 控制器不持有文件正文明文，也不提供 shell 或 Git 写入口。
class WorkspaceFilesController extends ChangeNotifier {
  WorkspaceFilesController({required this.repository});

  // 与 GitDiffController 相同：公开注入 repository，保持只读边界可替换。
  final WorkspaceFilesRepository repository;

  WorkspaceFilesPhase _phase = WorkspaceFilesPhase.loading;
  String _currentPath = '';
  List<WorkspaceFileEntry> _entries = const [];
  WorkspaceFileContent? _preview;  String? _errorMessage;
  String? _rejectionMessage;
  final List<WorkspaceFileEntry> _searchResults = [];
  String _searchQuery = '';

  WorkspaceFilesPhase get phase => _phase;
  String get currentPath => _currentPath;
  List<WorkspaceFileEntry> get entries =>
      List<WorkspaceFileEntry>.unmodifiable(_entries);
  WorkspaceFileContent? get preview => _preview;
  String? get errorMessage => _errorMessage;
  String? get rejectionMessage => _rejectionMessage;
  List<WorkspaceFileEntry> get searchResults =>
      List<WorkspaceFileEntry>.unmodifiable(_searchResults);
  bool get isSearching => _searchQuery.trim().isNotEmpty;

  /// 进入页面时加载根目录。
  Future<void> initialize() async {
    await openDirectory('');
  }

  /// 打开目录（repo-relative）。越权路径显示拒绝原因且保持当前内容不变。
  Future<void> openDirectory(String path) async {
    _errorMessage = null;
    _rejectionMessage = null;
    _phase = WorkspaceFilesPhase.loading;
    _preview = null;
    notifyListeners();
    try {
      final entries = await repository.listDirectory(path);
      _currentPath = path;
      _entries = entries;
      _phase = WorkspaceFilesPhase.ready;
    } on WorkspaceFilesFailure catch (failure) {
      _phase = WorkspaceFilesPhase.error;
      _errorMessage = failure.message;
      if (failure.kind == WorkspaceFilesFailureKind.pathEscape) {
        _rejectionMessage = failure.message;
      }
    } catch (_) {
      _phase = WorkspaceFilesPhase.error;
      _errorMessage = '文件列表暂时不可用，请稍后重试。';
    }
    notifyListeners();
  }

  /// 打开文本文件只读预览；二进制/超大文件显示安全摘要。
  Future<void> openFile(String path) async {
    _errorMessage = null;
    _rejectionMessage = null;
    _preview = null;
    notifyListeners();
    try {
      final content = await repository.readFile(path);
      _preview = content;
    } on WorkspaceFilesFailure catch (failure) {
      _errorMessage = failure.message;
      if (failure.kind == WorkspaceFilesFailureKind.pathEscape) {
        _rejectionMessage = failure.message;
      }
    } catch (_) {
      _errorMessage = '文件内容暂时不可用，请稍后重试。';
    }
    notifyListeners();
  }

  /// 目录内文件名搜索（仅对已加载条目；Daemon 搜索 RPC 未部署时不伪造结果）。
  void search(String query) {
    _searchQuery = query.trim().toLowerCase();
    if (_searchQuery.isNotEmpty) {
      _searchResults
        ..clear()
        ..addAll(
          _entries.where(
            (entry) => entry.name.toLowerCase().contains(_searchQuery),
          ),
        );
    } else {
      _searchResults.clear();
    }
    notifyListeners();
  }

  /// 刷新当前目录。
  Future<void> refresh() => openDirectory(_currentPath);

  /// 关闭预览（只清内存内容，不触碰文件系统）。
  void clearPreview() {
    if (_preview == null) return;
    _preview = null;
    notifyListeners();
  }

  void clearRejection() {
    if (_rejectionMessage == null) return;
    _rejectionMessage = null;
    notifyListeners();
  }
}
