// app_upgrader.dart
// 核心逻辑文件

import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:tiny_upgrader/dialog.dart';
import 'package:tiny_upgrader/upgrader_platform_interface.dart';
import 'package:tiny_upgrader/update_info.dart';

/// 下载状态枚举
enum DownloadStatus {
  none, // 未开始
  downloading, // 下载中
  paused, // 已暂停
  finished, // 已完成
  error, // 发生错误
}

enum UpdateStatus {
  // 0. 无更新
  none,

  // 1. 有更新
  update,

  /// 2. 有更新，且强制更新
  mustUpToDate,
}

// ========== 回调定义 (Typedefs) ==========

/// 自定义更新API响应解析器
/// [response] dio请求后的响应体
typedef UpdateApiParser = Future<VersionInfo> Function(dynamic response);

/// 错误处理器
typedef ErrorHandler = void Function(dynamic error);

/// 当检测到有新版本时的回调（如果未提供 `dialogBuilder`）
/// 用户可以利用此回调实现页面内更新提示等自定义逻辑
typedef UpdateAvailableCallback = void Function(BuildContext context, UpdateInfo updateInfo);

/// 自定义更新对话框构建器
/// [context] - BuildContext
/// [updateInfo] - 更新信息
/// [statusNotifier] - 下载状态监听器
/// [progressNotifier] - 下载进度监听器 (0.0 ~ 1.0)
typedef UpdateDialogBuilder =
    Widget Function(
      BuildContext context,
      UpdateInfo updateInfo,
      ValueNotifier<DownloadStatus> statusNotifier,
      ValueNotifier<double> progressNotifier,
    );

/// Flutter 应用内更新核心类 (采用单例模式)
class TinyUpgrader {
  // ========== 单例实现 ==========
  static final TinyUpgrader _instance = TinyUpgrader._internal();
  factory TinyUpgrader() => _instance;

  TinyUpgrader._internal();

  static TinyUpgrader get instance => _instance;

  // ========== 私有变量 ==========
  static late Dio _dio;
  CancelToken? _cancelToken; // 用于取消/暂停下载
  bool _isDebugging = false;

  // 更新信息与状态
  UpdateInfo? _updateInfo;
  String? _savePath; // 安装包保存路径
  bool _hasUpdate = false;

  // 使用 ValueNotifier 来驱动UI更新，更加灵活
  final ValueNotifier<DownloadStatus> statusNotifier = ValueNotifier(DownloadStatus.none);
  final ValueNotifier<double> progressNotifier = ValueNotifier(0.0);

  // ========== 可配置的回调函数 ==========
  static UpdateApiParser _parser = _defaultParser;
  static ErrorHandler? _errorHandler;
  static UpdateDialogBuilder? _dialogBuilder;

  /// 初始化配置
  /// 可以在 App 启动时调用此方法进行全局配置
  static void init({
    bool isDebug = false,
    String? baseUrl,
    Dio? dio,
    UpdateApiParser? parser,
    ErrorHandler? errorHandler,
    UpdateAvailableCallback? onUpdateAvailable,
    UpdateDialogBuilder? dialogBuilder,
  }) {
    if (!Platform.isAndroid) assert(false, 'Only Android is supported');

    instance._isDebugging = isDebug;
    if (parser != null) _parser = parser;
    if (errorHandler != null) _errorHandler = errorHandler;
    if (dialogBuilder != null) {
      _dialogBuilder = dialogBuilder;
    } else {
      // 空则使用默认弹出框
      _dialogBuilder = (context, updateInfo, statusNotifier, progressNotifier) => MyUpdateDialog(
        updateInfo: updateInfo,
        statusNotifier: statusNotifier,
        progressNotifier: progressNotifier,
      );
    }

    if (dio != null) {
      _dio = dio;
    } else {
      _dio = Dio(
        BaseOptions(
          baseUrl: baseUrl ?? '',
          connectTimeout: const Duration(seconds: 15),
          receiveTimeout: const Duration(seconds: 60 * 30), // 30分钟超时
        ),
      );

      _dio.interceptors.add(
        InterceptorsWrapper(
          onResponse: (response, handler) {
            if (isDebug) {
              print('响应数据: ${response.data.runtimeType}');
              print('响应头 ${response.headers}');
            }

            return handler.next(response);
          },
          onError: (error, handler) => debugPrint('错误信息: ${error.message}'),
        ),
      );
    }
  }

  Future<String?> getPlatformVersion() async {
    if (!Platform.isAndroid) assert(false, 'Only Android is supported');

    return TinyUpgraderPlatform.instance.getPlatformVersion();
  }

  /// 检查更新
  ///
  /// [context] - BuildContext，用于显示对话框
  /// [url] - 检查更新的API地址
  /// [params] - API请求参数
  Future<void> check(
    BuildContext context, {
    required String url,
    UpdateAvailableCallback? onUpdateAvailable,
    bool Function(VersionInfo, PackageInfo)? shouldUpdate,
    Map<String, dynamic>? params,
  }) async {
    if (!Platform.isAndroid) assert(false, 'Only Android is supported');

    _log('开始检查更新...');
    try {
      final response = await _dio.get(url, queryParameters: params);
      if (response.statusCode != 200) {
        throw "网络请求失败，状态码: ${response.statusCode}";
      }

      _log('检查更新成功，开始解析数据: ${response.data}');
      final newVersionInfo = await _parser(response.data);
      final packageInfo = await PackageInfo.fromPlatform();
      final currentVersion = packageInfo.version;
      _log('获得旧版本信息 ${currentVersion}+${packageInfo.buildNumber}');
      _updateInfo = UpdateInfo(currentVersion: currentVersion, latestVersion: newVersionInfo);

      if (shouldUpdate != null) {
        _hasUpdate = shouldUpdate(newVersionInfo, packageInfo);
      } else {
        if (newVersionInfo.version != currentVersion) {
          _hasUpdate = true;
          _log('版本号不一致，触发更新');
        } else {
          if (newVersionInfo.buildVersion.toString() != packageInfo.buildNumber) {
            _hasUpdate = true;
            _log('构建号不一致，触发更新');
          }
        }
      }

      // 简单比较版本号，可根据需要替换为更复杂的比较逻辑
      if (_hasUpdate) {
        _log('发现新版本: ${newVersionInfo.version}+${newVersionInfo.buildVersion}');
        statusNotifier.value = DownloadStatus.none; // 重置状态
        progressNotifier.value = 0.0; // 重置进度

        // 优先使用回调
        if (onUpdateAvailable != null) {
          onUpdateAvailable(context, _updateInfo!);
        }
        // 若回调为空，则使用弹出框
        else if (_dialogBuilder != null) {
          showDialog(
            context: context,
            barrierDismissible: newVersionInfo.updateStatus == 2,
            builder: (ctx) => _dialogBuilder!(ctx, _updateInfo!, statusNotifier, progressNotifier),
          );
        } else {
          _log('警告: 未设置 dialogBuilder 和 onUpdateAvailable 回调，将不会有任何更新提示。');
        }
      } else {
        _log('当前已是最新版本。');
      }
    } catch (e) {
      _log('检查更新时出错: $e');
      _errorHandler?.call(e);
    }
  }

  /// 开始或继续下载
  Future<void> startDownload() async {
    if (!Platform.isAndroid) assert(false, 'Only Android is supported');

    if (_updateInfo == null || _updateInfo!.latestVersion == null) {
      _log('错误: 更新信息或下载链接为空。');
      statusNotifier.value = DownloadStatus.error;
      return;
    }

    if (statusNotifier.value == DownloadStatus.downloading) {
      _log('下载已在进行中。');
      return;
    }

    statusNotifier.value = DownloadStatus.downloading;
    _cancelToken = CancelToken();

    final latestVersion = _updateInfo!.latestVersion!;

    try {
      final tempDir = await getTemporaryDirectory();
      _savePath = '${tempDir.path}/app-v${latestVersion.version}.apk';

      _log('本地路径: $_savePath');
      _log('下载链接: ${latestVersion.downloadUrl}');

      int existingLength = 0;
      final file = File(_savePath!);
      if (await file.exists()) {
        existingLength = await file.length();
        _log('文件已存在，大小: $existingLength bytes. 尝试断点续传。');
      }

      // 检查已下载部分是否等于总大小
      if (latestVersion.apkSize == existingLength) {
        _log('文件已完整下载，直接进入完成状态。');
        await _onDownloadCompleted();
        return;
      }

      await _dio.download(
        latestVersion.downloadUrl,
        _savePath,
        cancelToken: _cancelToken,
        onReceiveProgress: (received, total) {
          // total 可能为-1，如果服务器未返回Content-Length
          final int totalSize = total > 0 ? total : (latestVersion.apkSize);
          if (totalSize > 0) {
            progressNotifier.value = (existingLength + received) / (existingLength + totalSize);
          }
          _log('下载进度: ${progressNotifier.value.toStringAsFixed(2)}');
        },
        // 设置 Range 请求头以实现断点续传
        options: Options(headers: {'range': 'bytes=$existingLength-'}),
        deleteOnError: true,
      );

      await _onDownloadCompleted();
    } on DioException catch (e) {
      if (CancelToken.isCancel(e)) {
        statusNotifier.value = DownloadStatus.paused;
        _log('下载已暂停。');
      } else {
        statusNotifier.value = DownloadStatus.error;
        _log('下载出错: $e');
        _errorHandler?.call(e);
      }
    } catch (e) {
      statusNotifier.value = DownloadStatus.error;
      _log('下载时发生未知错误: $e');
      _errorHandler?.call(e);
    }
  }

  /// 暂停下载
  void pauseDownload() {
    if (!Platform.isAndroid) assert(false, 'Only Android is supported');

    if (statusNotifier.value == DownloadStatus.downloading) {
      _cancelToken?.cancel();
    }
  }

  /// 调用平台接口安装APK (仅限Android)
  Future<void> install() async {
    if (!Platform.isAndroid) assert(false, 'Only Android is supported');

    if (statusNotifier.value != DownloadStatus.finished || _savePath == null) {
      _log('错误: 文件未下载完成，无法安装。');
      return;
    }
    _log('准备安装APK: $_savePath');
    try {
      await TinyUpgraderPlatform.instance.installApk(_savePath!);
    } catch (e) {
      _log('安装失败: $e');
      _errorHandler?.call(e);
    }
  }

  // ========== 私有辅助方法 ==========

  /// 下载完成后的处理
  Future<void> _onDownloadCompleted() async {
    if (!Platform.isAndroid) assert(false, 'Only Android is supported');

    _log('下载完成，路径: $_savePath');

    final latestVersion = _updateInfo?.latestVersion;
    if (latestVersion == null) {
      _log('没有新版本');
      return;
    }

    // 如果提供了MD5，则进行校验
    if (latestVersion.apkHashCode.isNotEmpty) {
      _log('正在校验文件 MD5...');
      final file = File(_savePath!);
      final fileMd5 = md5.convert(await file.readAsBytes()).toString();
      _log('文件MD5: $fileMd5, 期望MD5: ${latestVersion.apkHashCode.toLowerCase()}');
      if (fileMd5 == latestVersion.apkHashCode.toLowerCase()) {
        _log('MD5 校验成功!');
        statusNotifier.value = DownloadStatus.finished;
        progressNotifier.value = 1.0;
      } else {
        _log('MD5 校验失败! 文件可能已损坏。');
        await file.delete(); // 删除损坏的文件
        statusNotifier.value = DownloadStatus.error;
        progressNotifier.value = 0.0;
        _errorHandler?.call('MD5_VALIDATION_FAILED');
      }
    } else {
      _log('未提供 MD5，跳过校验。');
      statusNotifier.value = DownloadStatus.finished;
      progressNotifier.value = 1.0;
    }
  }

  /// _defaultParser
  /// 这是一个默认实现，假设API返回一个标准的Map
  /// 你也可以通过 init 方法提供一个符合你API结构的解析器
  static Future<VersionInfo> _defaultParser(dynamic data) async {
    return VersionInfo.fromMap((data as Map<String, dynamic>)['data']);
  }

  /// 内部日志打印
  void _log(String message) {
    if (_isDebugging) {
      debugPrint('[AppUpgrader] $message');
    }
  }
}
