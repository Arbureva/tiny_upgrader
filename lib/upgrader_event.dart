/// 升级流程中的事件类型，覆盖初始化 → 检测 → 下载 → 校验 → 安装全部环节。
enum UpgraderEventType {
  // ===== 初始化 =====
  init,

  // ===== 检查更新 =====
  checkStart,
  checkResponse,
  checkCurrentVersion,
  checkNoUpdate,
  checkNewVersion,
  checkError,

  // ===== 下载 =====
  downloadStart,
  downloadProgress,
  downloadResume,
  downloadConflict,
  downloadPaused,
  downloadComplete,
  downloadError,
  downloadRetry,

  // ===== 校验 =====
  validationStart,
  validationSuccess,
  validationFailed,
  validationSkipped,

  // ===== 安装 =====
  installStart,
  installComplete,
  installError,

  // ===== 清理 =====
  cleanOldFiles,

  // ===== 通用日志 =====
  log,
}

/// 升级事件，携带类型、描述信息和可选的结构化数据。
class UpgraderEvent {
  final UpgraderEventType type;
  final String message;
  final DateTime timestamp;
  final Map<String, dynamic>? data;

  UpgraderEvent({
    required this.type,
    required this.message,
    this.data,
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();

  @override
  String toString() =>
      '[${timestamp.toIso8601String()}] ${type.name}: $message${data != null ? ' | $data' : ''}';
}

/// 统一的回调签名。
///
/// 调用方通过 [TinyUpgrader.enableLog] 开关控制是否触发回调，
/// 并在回调中根据 [UpgraderEvent.type] 自行分发业务逻辑。
typedef UpgraderCallback = void Function(UpgraderEvent event);
