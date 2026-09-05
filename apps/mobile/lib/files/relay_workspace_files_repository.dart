import '../domain/workspace_files_models.dart';
import '../git/readonly_command_gateway.dart';
import 'workspace_files_repository.dart';

/// v0.8.8 P3（V088-08 / 迭代计划 G3）：WorkspaceFilesRepository 的真实传输实现。
///
/// 数据流（daemon ReadOnlyDispatcher 沙箱语义）：
///   listDirectory(path) → file.tree → [{path, is_dir, size}]（单层、已排序、有上限）
///   readFile(path)      → file.read/code.read → {path, content}（文本明文只经内存）
///
/// 与 fixture 的契约差异：daemon 侧二进制（CONTENT_UNAVAILABLE）与超大
/// （PAYLOAD_TOO_LARGE）读取按错误码收口，本实现转换为与 fixture 同形的
/// limitedKind 内容对象，UI 契约两侧一致（受限摘要，不当文本渲染）。
class RelayWorkspaceFilesRepository implements WorkspaceFilesRepository {
  RelayWorkspaceFilesRepository({required ReadonlyCommandGateway filesGateway})
    : _gateway = filesGateway;

  final ReadonlyCommandGateway _gateway;

  @override
  Future<List<WorkspaceFileEntry>> listDirectory(String path) async {
    // daemon List 返回 JSON 数组；经 localdev encoder 透传后 result 顶层即数组。
    final entries = await _gateway.execute(
      wireKind: 'file.tree',
      // 空路径 = 工作区根目录（等价 `/`），daemon 侧默认 "."。
      fixturePayload: {'path': path},
      failureMapper: workspaceFilesFailureMapper,
    );
    return _entriesFromRaw((entries as List?) ?? const []);
  }

  @override
  Future<WorkspaceFileContent> readFile(String path) async {
    try {
      final result = await _gateway.execute(
        wireKind: 'file.read',
        fixturePayload: {'path': path},
        // 二进制/超大不作为失败：映射为受限内容对象（fixture 同形契约）。
        failureMapper: _limitedAwareMapper,
      ) as Map;
      final content = Map<String, dynamic>.from(result);
      final text = (content['content'] as String?) ?? '';
      return WorkspaceFileContent(
        path: (content['path'] as String?) ?? path,
        limitedKind: WorkspaceFileLimitedKind.none,
        text: text,
      );
    } on _LimitedFileRead catch (limited) {
      return WorkspaceFileContent(
        path: path,
        limitedKind: limited.code == 'PAYLOAD_TOO_LARGE'
            ? WorkspaceFileLimitedKind.tooLarge
            : WorkspaceFileLimitedKind.binary,
        isTruncated: limited.code == 'PAYLOAD_TOO_LARGE',
      );
    }
  }

  List<WorkspaceFileEntry> _entriesFromRaw(List<dynamic> raw) {
    final entries = <WorkspaceFileEntry>[];
    for (final item in raw) {
      if (item is! Map) continue;
      final entry = Map<String, dynamic>.from(item);
      final path = (entry['path'] as String?) ?? '';
      final isDir = entry['is_dir'] == true;
      entries.add(
        WorkspaceFileEntry(
          path: path,
          name: path.split('/').last,
          isDirectory: isDir,
          byteSize: (entry['size'] as num?)?.toInt() ?? 0,
        ),
      );
    }
    return entries;
  }

  /// daemon 错误码 → 视图失败；受限读取码（CONTENT_UNAVAILABLE/PAYLOAD_TOO_LARGE）
  /// 先转私有哨兵，由 readFile 转换为 limitedKind 内容。
  Exception _limitedAwareMapper(String errorCode, String fallback) {
    if (errorCode == 'CONTENT_UNAVAILABLE' || errorCode == 'PAYLOAD_TOO_LARGE') {
      throw _LimitedFileRead(errorCode);
    }
    return workspaceFilesFailureMapper(errorCode, fallback);
  }
}

/// 受限读取哨兵：daemon 收口的二进制/超大错误码（只携码，不带内容）。
class _LimitedFileRead implements Exception {
  const _LimitedFileRead(this.code);

  final String code;
}
