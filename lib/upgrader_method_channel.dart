import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'upgrader_platform_interface.dart';

/// 使用方法通道实现的 [TinyUpgraderPlatform]
///
/// 通过MethodChannel与原生Android代码通信
class MethodChannelTinyUpgrader extends TinyUpgraderPlatform {
  /// 用于与原生平台交互的方法通道
  @visibleForTesting
  final methodChannel = const MethodChannel('tiny_upgrader');

  @override
  Future<String?> getPlatformVersion() async {
    // 调用原生方法获取平台版本
    final version = await methodChannel.invokeMethod<String>('getPlatformVersion');
    return version;
  }

  @override
  Future<bool> installApk(String filePath) async {
    try {
      // 直接安装APK文件
      final result = await methodChannel.invokeMethod<bool>('installApk', {'filePath': filePath});
      return result ?? false;
    } on PlatformException catch (e) {
      debugPrint('安装APK失败: ${e.message}');
      return false;
    }
  }
}
