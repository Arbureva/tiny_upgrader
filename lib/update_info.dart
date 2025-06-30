// update_info.dart
// 数据模型文件

class VersionInfo {
  int? id;
  int? createdAt;
  int? updatedAt;
  int updateStatus;
  String version;
  int buildVersion;
  String modifyContent;
  String downloadUrl;
  int apkSize;
  String apkHashCode;
  String apkPath;

  VersionInfo({
    this.id,
    this.createdAt,
    this.updatedAt,
    required this.updateStatus,
    required this.version,
    required this.buildVersion,
    required this.modifyContent,
    required this.downloadUrl,
    required this.apkSize,
    required this.apkHashCode,
    required this.apkPath,
  });

  factory VersionInfo.fromMap(Map<String, dynamic> json) {
    return VersionInfo(
      id: json['id'] as int?,
      createdAt: json['created_at'] as int?,
      updatedAt: json['updated_at'] as int?,
      updateStatus: json['update_status'],
      version: json['version'],
      buildVersion: json['build_version'],
      modifyContent: json['modify_content'],
      downloadUrl: json['download_url'],
      apkSize: json['apk_size'],
      apkHashCode: json['apk_hash_code'],
      apkPath: json['apk_path'],
    );
  }
}

class UpdateInfo {
  /// 当前版本号 (来自应用本身)
  final String currentVersion;
  final VersionInfo? latestVersion;

  UpdateInfo({required this.currentVersion, this.latestVersion});
}
