import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'foreground_download.dart';
import 'upgrader_method_channel.dart';
import 'install_result.dart';

/// TinyUpgrader 平台接口
///
/// 定义了所有平台需要实现的方法
abstract class TinyUpgraderPlatform extends PlatformInterface {
  /// 构造函数
  TinyUpgraderPlatform() : super(token: _token);

  static final Object _token = Object();

  static TinyUpgraderPlatform _instance = MethodChannelTinyUpgrader();

  /// 默认的平台实例
  ///
  /// 默认使用 [MethodChannelTinyUpgrader] 实现
  static TinyUpgraderPlatform get instance => _instance;

  /// 设置平台实例
  ///
  /// 平台特定的实现应该在注册时设置这个实例
  static set instance(TinyUpgraderPlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  /// 获得平台版本
  Future<String?> getPlatformVersion() async {
    throw UnimplementedError('platformVersion() has not been implemented.');
  }

  /// 直接安装APK文件
  ///
  /// [filePath] APK文件的完整路径
  Future<InstallResult> installApk(String filePath) {
    throw UnimplementedError('installApk() has not been implemented.');
  }

  Future<bool> canRequestPackageInstalls() {
    throw UnimplementedError(
      'canRequestPackageInstalls() has not been implemented.',
    );
  }

  Future<void> openInstallPermissionSettings() {
    throw UnimplementedError(
      'openInstallPermissionSettings() has not been implemented.',
    );
  }

  Future<int> getAvailableStorageBytes(String directoryPath) {
    throw UnimplementedError(
      'getAvailableStorageBytes() has not been implemented.',
    );
  }

  Stream<ForegroundDownloadEvent> get foregroundDownloadEvents {
    throw UnimplementedError(
      'foregroundDownloadEvents has not been implemented.',
    );
  }

  Future<void> startForegroundDownload(ForegroundDownloadRequest request) {
    throw UnimplementedError(
      'startForegroundDownload() has not been implemented.',
    );
  }

  Future<void> pauseForegroundDownload() {
    throw UnimplementedError(
      'pauseForegroundDownload() has not been implemented.',
    );
  }

  Future<void> cancelForegroundDownload({bool deleteFile = true}) {
    throw UnimplementedError(
      'cancelForegroundDownload() has not been implemented.',
    );
  }

  Future<ForegroundDownloadEvent> getForegroundDownloadState() {
    throw UnimplementedError(
      'getForegroundDownloadState() has not been implemented.',
    );
  }
}
