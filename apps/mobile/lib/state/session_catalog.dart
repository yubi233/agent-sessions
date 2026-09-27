import '../domain/session_models.dart';

/// 会话列表 / 工作区目录的加载阶段。
enum SessionListPhase { loading, ready, error }

/// 工作区目录的加载阶段。
enum WorkspaceListPhase { loading, ready, error }

/// 会话列表与工作区目录状态（架构收口拆自 SessionController）：
/// 列表/目录数据、加载阶段、同步与导入的进行中状态、工作区命令的 pending
/// 标识都收口在本类。SessionController 保留业务流程（刷新、同步、导入、
/// 创建/接续/打开），通过字段与域操作读写；UI 经 SessionController 的既有
/// getter 消费，公开 API 不变。
class SessionCatalog {
  /// 会话列表加载阶段与数据（按最后活动时间排序的投影由流程方写入）。
  SessionListPhase phase = SessionListPhase.loading;
  List<MobileSession> sessions = const [];

  /// 工作区目录加载阶段与数据。
  WorkspaceListPhase workspacePhase = WorkspaceListPhase.loading;
  List<MobileWorkspace> workspaces = const [];
  String? workspaceErrorMessage;

  /// 工作区创建（目录/命名）的 pending 标识与结算标志。
  String? pendingWorkspaceId;
  String? pendingWorkspaceCommandId;
  bool workspaceSettling = false;

  /// DSH 工作区同步的进行中状态。
  WorkspaceSyncState? workspaceSyncState;
  bool workspaceSyncWaiting = false;

  /// DSH 历史导入的进行中状态。
  WorkspaceImportState? workspaceImportState;
  bool workspaceImportWaiting = false;
  String? workspaceImportWorkspaceId;

  /// 会话列表是否处于 ready 且为空（首页空态判定）。
  bool get isSessionListEmptyReady =>
      phase == SessionListPhase.ready && sessions.isEmpty;

  /// 以服务端一致的排序整体替换会话列表（手动刷新/合并兜底路径）。
  void replaceSessionsSorted(List<MobileSession> loaded) {
    sessions = [...loaded]..sort(MobileSession.compareByLastActivity);
  }

  /// 前置插入或更新一个会话（创建/接续/快照合并路径）。
  void upsertSession(MobileSession session) {
    sessions = [session, ...sessions.where((item) => item.id != session.id)];
  }

  /// 目录中是否存在指定工作区。
  bool hasWorkspace(String workspaceId) =>
      workspaces.any((workspace) => workspace.id == workspaceId);

  /// 认证边界重置：列表与目录回到 loading 空态，pending/同步/导入状态一并清除。
  void reset() {
    sessions = const [];
    phase = SessionListPhase.loading;
    workspaces = const [];
    workspacePhase = WorkspaceListPhase.loading;
    workspaceErrorMessage = null;
    pendingWorkspaceId = null;
    pendingWorkspaceCommandId = null;
    workspaceSettling = false;
    workspaceSyncState = null;
    workspaceSyncWaiting = false;
    workspaceImportState = null;
    workspaceImportWaiting = false;
    workspaceImportWorkspaceId = null;
  }
}
