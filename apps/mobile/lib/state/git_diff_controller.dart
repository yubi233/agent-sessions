import 'package:flutter/foundation.dart';

import '../domain/git_diff_models.dart';
import '../git/git_diff_repository.dart';

/// GitDiffPhase 区分正常空态、可重试 stale 和未部署 Daemon RPC，避免 UI 把三者都画成“没有变更”。
enum GitDiffPhase { loading, ready, stale, unavailable, error }

/// GitDiffController 只管理只读 Git 视图状态，不持有 Relay 会话正文或任何写控制权。
class GitDiffController extends ChangeNotifier {
  GitDiffController({required this.repository});

  final GitDiffRepository repository;

  GitDiffPhase _phase = GitDiffPhase.loading;
  GitDiffSnapshot? _snapshot;
  String? _selectedPath;
  GitChangeFilter _filter = GitChangeFilter.all;
  GitDiffViewMode _viewMode = GitDiffViewMode.unified;
  String _query = '';
  List<GitDiffHunk> _hunks = const [];
  bool _hasMore = false;
  int _nextOffset = 0;
  bool _isFileLoading = false;
  bool _isLoadingMore = false;
  bool _isInitializing = false;
  final Set<String> _collapsedHunks = {};
  String? _message;
  int _requestSerial = 0;

  GitDiffPhase get phase => _phase;
  GitDiffSnapshot? get snapshot => _snapshot;
  String? get selectedPath => _selectedPath;
  GitChangeFilter get filter => _filter;
  GitDiffViewMode get viewMode => _viewMode;
  String get query => _query;
  List<GitDiffHunk> get hunks => List<GitDiffHunk>.unmodifiable(_hunks);
  bool get hasMore => _hasMore;
  bool get isFileLoading => _isFileLoading;
  bool get isLoadingMore => _isLoadingMore;
  String? get message => _message;
  bool get isStale => _phase == GitDiffPhase.stale;

  List<GitChangeFile> get visibleFiles {
    final files = _snapshot?.files ?? const <GitChangeFile>[];
    return files
        .where(
          (file) => file.matchesFilter(_filter) && file.matchesQuery(_query),
        )
        .toList(growable: false);
  }

  GitChangeFile? get selectedFile {
    final path = _selectedPath;
    if (path == null) return null;
    for (final file in _snapshot?.files ?? const <GitChangeFile>[]) {
      if (file.path == path) return file;
    }
    return null;
  }

  bool isHunkCollapsed(String hunkId) => _collapsedHunks.contains(hunkId);

  /// 初始化和刷新都从新 snapshot 开始；旧 hunk 会先清空，防止 UI 混用两个工作区状态。
  Future<void> initialize({bool force = false}) async {
    if (!force && _snapshot != null && _phase == GitDiffPhase.ready) return;
    if (_isInitializing) return;
    _isInitializing = true;
    final preferredPath = _selectedPath;
    final serial = ++_requestSerial;
    _phase = GitDiffPhase.loading;
    _message = null;
    _hunks = const [];
    _hasMore = false;
    _nextOffset = 0;
    _isFileLoading = false;
    _isLoadingMore = false;
    notifyListeners();
    try {
      final next = await repository.loadSnapshot();
      if (serial != _requestSerial) return;
      _snapshot = next;
      _selectedPath = _preferredPath(next, preferredPath);
      _phase = GitDiffPhase.ready;
      notifyListeners();
      if (_selectedPath != null) {
        await _loadSelectedFile(reset: true, serial: serial);
      }
    } on GitDiffFailure catch (failure) {
      if (serial != _requestSerial) return;
      _applyFailure(failure);
    } catch (_) {
      if (serial != _requestSerial) return;
      _phase = GitDiffPhase.error;
      _message = 'Git 变更暂时不可用，请稍后重试。';
      notifyListeners();
    } finally {
      // 文件切换会使旧读取 serial 失效，但不能把初始化互斥锁永久留在 true；
      // 否则用户在首个 Diff 尚未返回时切换文件，后续刷新会被错误忽略。
      _isInitializing = false;
    }
  }

  /// 筛选只改变文件树，不重新请求或改写当前 snapshot。
  void setFilter(GitChangeFilter value) {
    if (_filter == value) return;
    _filter = value;
    notifyListeners();
  }

  /// 搜索在已获取的文件树内执行，避免用户每输入一个字符就创建新的 Git 读取请求。
  void setQuery(String value) {
    if (_query == value) return;
    _query = value;
    notifyListeners();
  }

  Future<void> selectFile(String path) async {
    if (_snapshot == null || _selectedPath == path) return;
    if (!_snapshot!.files.any((file) => file.path == path)) return;
    _selectedPath = path;
    _hunks = const [];
    _hasMore = false;
    _nextOffset = 0;
    _collapsedHunks.clear();
    _message = null;
    _phase = GitDiffPhase.ready;
    notifyListeners();
    await _loadSelectedFile(reset: true, serial: ++_requestSerial);
  }

  void setViewMode(GitDiffViewMode value) {
    if (_viewMode == value) return;
    _viewMode = value;
    notifyListeners();
  }

  void toggleHunk(String hunkId) {
    if (_collapsedHunks.remove(hunkId)) {
      notifyListeners();
      return;
    }
    _collapsedHunks.add(hunkId);
    notifyListeners();
  }

  Future<void> loadNextPage() async {
    final snapshot = _snapshot;
    final path = _selectedPath;
    if (snapshot == null || path == null || !_hasMore || _isLoadingMore) return;
    final serial = ++_requestSerial;
    _isLoadingMore = true;
    notifyListeners();
    try {
      final page = await repository.loadFileDiff(
        path: path,
        snapshotToken: snapshot.snapshotToken,
        offset: _nextOffset,
        limit: 2,
      );
      if (serial != _requestSerial) return;
      if (page.snapshotToken != snapshot.snapshotToken || page.path != path) {
        _isLoadingMore = false;
        _applyFailure(
          const GitDiffFailure(
            GitDiffFailureKind.snapshotStale,
            'Git 返回了另一快照的数据，请刷新后重试。',
          ),
        );
        return;
      }
      _hunks = [..._hunks, ...page.hunks];
      _nextOffset = page.nextOffset;
      _hasMore = page.hasMore;
      _isLoadingMore = false;
      notifyListeners();
    } on GitDiffFailure catch (failure) {
      if (serial != _requestSerial) return;
      _isLoadingMore = false;
      _applyFailure(failure);
    } catch (_) {
      if (serial != _requestSerial) return;
      _isLoadingMore = false;
      _phase = GitDiffPhase.error;
      _message = '无法继续加载 Diff，请刷新后重试。';
      notifyListeners();
    }
  }

  /// stale 只能通过重新读取 snapshot 恢复，不能在旧 token 上重发分页请求。
  Future<void> retryAfterStale() => initialize(force: true);

  Future<void> _loadSelectedFile({
    required bool reset,
    required int serial,
  }) async {
    final snapshot = _snapshot;
    final path = _selectedPath;
    if (snapshot == null || path == null) return;
    _isFileLoading = true;
    notifyListeners();
    try {
      final page = await repository.loadFileDiff(
        path: path,
        snapshotToken: snapshot.snapshotToken,
        offset: reset ? 0 : _nextOffset,
        limit: 2,
      );
      if (serial != _requestSerial) return;
      if (page.snapshotToken != snapshot.snapshotToken || page.path != path) {
        _isFileLoading = false;
        _applyFailure(
          const GitDiffFailure(
            GitDiffFailureKind.snapshotStale,
            'Git 返回了另一快照的数据，请刷新后重试。',
          ),
        );
        return;
      }
      _hunks = reset ? page.hunks : [..._hunks, ...page.hunks];
      _nextOffset = page.nextOffset;
      _hasMore = page.hasMore;
      _isFileLoading = false;
      _phase = GitDiffPhase.ready;
      _message = null;
      notifyListeners();
    } on GitDiffFailure catch (failure) {
      if (serial != _requestSerial) return;
      _isFileLoading = false;
      _applyFailure(failure);
    } catch (_) {
      if (serial != _requestSerial) return;
      _isFileLoading = false;
      _phase = GitDiffPhase.error;
      _message = '无法读取此文件的 Diff，请刷新后重试。';
      notifyListeners();
    }
  }

  String? _preferredPath(GitDiffSnapshot snapshot, String? previous) {
    if (previous != null &&
        snapshot.files.any((file) => file.path == previous)) {
      return previous;
    }
    return snapshot.files.isEmpty ? null : snapshot.files.first.path;
  }

  void _applyFailure(GitDiffFailure failure) {
    _hunks = const [];
    _hasMore = false;
    _nextOffset = 0;
    _phase = switch (failure.kind) {
      GitDiffFailureKind.snapshotStale => GitDiffPhase.stale,
      GitDiffFailureKind.unavailable => GitDiffPhase.unavailable,
      _ => GitDiffPhase.error,
    };
    _message = failure.message;
    notifyListeners();
  }
}
