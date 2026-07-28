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
  installIntentLaunched,
  @Deprecated('Use installIntentLaunched')
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
      '[${timestamp.toIso8601String()}] ${type.name}: '
      '$message${data != null ? ' | $data' : ''}';
}

/// 统一的回调签名。
///
/// 业务事件始终触发；[TinyUpgrader.enableLog] 只控制通用日志事件。
typedef UpgraderCallback = void Function(UpgraderEvent event);
