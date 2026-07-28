import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'foreground_download.dart';
import 'upgrader_platform_interface.dart';
import 'install_result.dart';

/// 使用方法通道实现的 [TinyUpgraderPlatform]
///
/// 通过MethodChannel与原生Android代码通信
class MethodChannelTinyUpgrader extends TinyUpgraderPlatform {
  /// 用于与原生平台交互的方法通道
  @visibleForTesting
  final methodChannel = const MethodChannel('tiny_upgrader');
  final StreamController<ForegroundDownloadEvent> _downloadEvents =
      StreamController<ForegroundDownloadEvent>.broadcast();
  bool _nativeHandlerInstalled = false;

  @override
  Future<String?> getPlatformVersion() async {
    // 调用原生方法获取平台版本
    final version = await methodChannel.invokeMethod<String>(
      'getPlatformVersion',
    );
    return version;
  }

  @override
  Future<InstallResult> installApk(String filePath) async {
    try {
      final result = await methodChannel.invokeMethod<String>('installApk', {
        'filePath': filePath,
      });
      return InstallResult(_parseInstallStatus(result));
    } on PlatformException catch (e) {
      debugPrint('安装APK失败: ${e.message}');
      return InstallResult(InstallStatus.failed, message: e.message);
    }
  }

  @override
  Future<bool> canRequestPackageInstalls() async {
    return await methodChannel.invokeMethod<bool>(
          'canRequestPackageInstalls',
        ) ??
        false;
  }

  @override
  Future<void> openInstallPermissionSettings() {
    return methodChannel.invokeMethod<void>('openInstallPermissionSettings');
  }

  @override
  Future<int> getAvailableStorageBytes(String directoryPath) async {
    return await methodChannel.invokeMethod<int>('getAvailableStorageBytes', {
          'directoryPath': directoryPath,
        }) ??
        0;
  }

  @override
  Stream<ForegroundDownloadEvent> get foregroundDownloadEvents {
    _ensureNativeHandler();
    return _downloadEvents.stream;
  }

  @override
  Future<void> startForegroundDownload(ForegroundDownloadRequest request) {
    _ensureNativeHandler();
    return methodChannel.invokeMethod<void>(
      'startForegroundDownload',
      request.toMap(),
    );
  }

  @override
  Future<void> pauseForegroundDownload() {
    return methodChannel.invokeMethod<void>('pauseForegroundDownload');
  }

  @override
  Future<void> cancelForegroundDownload({bool deleteFile = true}) {
    return methodChannel.invokeMethod<void>('cancelForegroundDownload', {
      'deleteFile': deleteFile,
    });
  }

  @override
  Future<ForegroundDownloadEvent> getForegroundDownloadState() async {
    _ensureNativeHandler();
    final result = await methodChannel.invokeMapMethod<Object?, Object?>(
      'getForegroundDownloadState',
    );
    return ForegroundDownloadEvent.fromMap(result ?? const {});
  }

  Future<void> _handleNativeCall(MethodCall call) async {
    if (call.method != 'foregroundDownloadEvent') return;
    final arguments = call.arguments;
    if (arguments is Map) {
      _downloadEvents.add(
        ForegroundDownloadEvent.fromMap(Map<Object?, Object?>.from(arguments)),
      );
    }
  }

  void _ensureNativeHandler() {
    if (_nativeHandlerInstalled) return;
    methodChannel.setMethodCallHandler(_handleNativeCall);
    _nativeHandlerInstalled = true;
  }

  InstallStatus _parseInstallStatus(String? value) {
    return InstallStatus.values.firstWhere(
      (status) => status.name == value,
      orElse: () => InstallStatus.failed,
    );
  }
}
