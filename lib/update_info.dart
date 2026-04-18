import 'package:tiny_upgrader/upgrader.dart';

class VersionInfo {
  final int? id;
  final int? createdAt;
  final int? updatedAt;

  /// 更新策略（0=可选, 1=推荐, 2=强制）
  final UpdateStrategy updateStrategy;

  /// 语义化版本号，如 "2.2.4"
  final String version;

  /// 构建号，如 46
  final int buildVersion;

  /// 更新说明
  final String modifyContent;

  /// APK 下载地址
  String downloadUrl;

  /// APK 文件大小（字节），0 表示未知
  final int apkSize;

  /// APK 文件的 MD5 哈希值（可为空字符串，表示跳过校验）
  final String apkHashCode;

  /// 服务端 APK 存储路径（一般客户端不使用）
  final String apkPath;

  VersionInfo({
    this.id,
    this.createdAt,
    this.updatedAt,
    required this.updateStrategy,
    required this.version,
    required this.buildVersion,
    required this.modifyContent,
    required this.downloadUrl,
    this.apkSize = 0,
    this.apkHashCode = '',
    this.apkPath = '',
  });

  factory VersionInfo.fromMap(Map<String, dynamic> json) {
    return VersionInfo(
      id: json['id'] as int?,
      createdAt: json['created_at'] as int?,
      updatedAt: json['updated_at'] as int?,
      updateStrategy: UpdateStrategy.fromInt((json['update_status'] as int?) ?? 0),
      version: json['version'] as String? ?? '',
      buildVersion: json['build_version'] as int? ?? 0,
      modifyContent: json['modify_content'] as String? ?? '',
      downloadUrl: json['download_url'] as String? ?? '',
      apkSize: json['apk_size'] as int? ?? 0,
      apkHashCode: json['apk_hash_code'] as String? ?? '',
      apkPath: json['apk_path'] as String? ?? '',
    );
  }
}

class UpdateInfo {
  /// 当前应用版本号
  final String currentVersion;

  /// 当前应用构建号
  final String currentBuildNumber;

  /// 服务端最新版本信息
  final VersionInfo? latestVersion;

  UpdateInfo({required this.currentVersion, required this.currentBuildNumber, this.latestVersion});
}
