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

/// 更新策略枚举（与服务端 update_status 字段映射）
enum UpdateStrategy {
  /// 0 - 普通更新，可跳过
  optional(0),

  /// 1 - 推荐更新
  recommended(1),

  /// 2 - 强制更新，不可跳过
  forced(2);

  final int value;
  const UpdateStrategy(this.value);

  static UpdateStrategy fromInt(int v) {
    return UpdateStrategy.values.firstWhere(
      (e) => e.value == v,
      orElse: () => UpdateStrategy.optional,
    );
  }
}

// ========== 回调定义 ==========

/// 自定义更新API响应解析器
typedef UpdateApiParser = Future<VersionInfo> Function(dynamic response);

/// 错误处理器
typedef ErrorHandler = void Function(dynamic error);

/// 当检测到有新版本时的回调
typedef UpdateAvailableCallback = void Function(BuildContext context, UpdateInfo updateInfo);

/// 自定义更新对话框构建器
typedef UpdateDialogBuilder =
    Widget Function(
      BuildContext context,
      UpdateInfo updateInfo,
      ValueNotifier<DownloadStatus> statusNotifier,
      ValueNotifier<double> progressNotifier,
    );

/// Flutter 应用内更新核心类（单例模式）
class TinyUpgrader {
  // ========== 单例 ==========
  static final TinyUpgrader _instance = TinyUpgrader._internal();
  factory TinyUpgrader() => _instance;
  TinyUpgrader._internal();
  static TinyUpgrader get instance => _instance;

  // ========== 配置（通过 init 设置） ==========
  late Dio _dio;
  bool _initialized = false;
  bool _isDebugging = false;
  UpdateApiParser _parser = _defaultParser;
  ErrorHandler? _errorHandler;
  UpdateDialogBuilder? _dialogBuilder;

  // ========== 运行时状态 ==========
  CancelToken? _cancelToken;
  UpdateInfo? _updateInfo;
  String? _savePath;

  final ValueNotifier<DownloadStatus> statusNotifier = ValueNotifier(DownloadStatus.none);
  final ValueNotifier<double> progressNotifier = ValueNotifier(0.0);

  // ========== 初始化 ==========

  /// 初始化配置，应在 App 启动时调用一次
  static void init({
    bool isDebug = false,
    String? baseUrl,
    Dio? dio,
    UpdateApiParser? parser,
    ErrorHandler? errorHandler,
    UpdateDialogBuilder? dialogBuilder,
  }) {
    final inst = instance;
    inst._isDebugging = isDebug;
    if (parser != null) inst._parser = parser;
    inst._errorHandler = errorHandler;

    inst._dialogBuilder =
        dialogBuilder ??
        (context, updateInfo, statusNotifier, progressNotifier) => MyUpdateDialog(
          updateInfo: updateInfo,
          statusNotifier: statusNotifier,
          progressNotifier: progressNotifier,
        );

    if (dio != null) {
      inst._dio = dio;
    } else {
      inst._dio = Dio(
        BaseOptions(
          baseUrl: baseUrl ?? '',
          connectTimeout: const Duration(seconds: 15),
          receiveTimeout: const Duration(minutes: 30),
        ),
      );

      if (isDebug) {
        inst._dio.interceptors.add(
          InterceptorsWrapper(
            onResponse: (response, handler) {
              debugPrint('[TinyUpgrader] 响应: ${response.statusCode}');
              return handler.next(response);
            },
            onError: (error, handler) {
              debugPrint('[TinyUpgrader] 请求错误: ${error.message}');
              return handler.next(error);
            },
          ),
        );
      }
    }

    inst._initialized = true;
  }

  // ========== 公开方法 ==========

  Future<String?> getPlatformVersion() async {
    _assertAndroid();
    return TinyUpgraderPlatform.instance.getPlatformVersion();
  }

  /// 检查更新
  ///
  /// 流程：请求API → 解析版本 → 判断是否需要更新 → 触发回调或弹窗
  Future<void> check(
    BuildContext context, {
    required String url,
    UpdateAvailableCallback? onUpdateAvailable,
    bool Function(VersionInfo newVersion, PackageInfo currentPackage)? shouldUpdate,
    Map<String, dynamic>? params,
  }) async {
    _assertAndroid();
    _assertInitialized();

    _log('开始检查更新...');
    try {
      final response = await _dio.get(url, queryParameters: params);
      if (response.statusCode != 200) {
        throw '网络请求失败，状态码: ${response.statusCode}';
      }

      _log('检查更新响应: ${response.data}');
      final newVersionInfo = await _parser(response.data);
      final packageInfo = await PackageInfo.fromPlatform();
      _log('当前版本: ${packageInfo.version}+${packageInfo.buildNumber}');

      _updateInfo = UpdateInfo(
        currentVersion: packageInfo.version,
        currentBuildNumber: packageInfo.buildNumber,
        latestVersion: newVersionInfo,
      );

      // 判断是否需要更新
      final hasUpdate = shouldUpdate != null
          ? shouldUpdate(newVersionInfo, packageInfo)
          : _defaultShouldUpdate(newVersionInfo, packageInfo);

      if (!hasUpdate) {
        _log('当前已是最新版本。');
        return;
      }

      _log('发现新版本: ${newVersionInfo.version}+${newVersionInfo.buildVersion}');

      // 重置下载状态
      statusNotifier.value = DownloadStatus.none;
      progressNotifier.value = 0.0;

      // 优先使用回调
      if (onUpdateAvailable != null) {
        if (!context.mounted) return;
        onUpdateAvailable(context, _updateInfo!);
        return;
      }

      // 使用弹窗
      if (_dialogBuilder != null) {
        if (!context.mounted) return;
        final strategy = newVersionInfo.updateStrategy;
        showDialog(
          context: context,
          // 强制更新时不允许点外部关闭
          barrierDismissible: strategy != UpdateStrategy.forced,
          builder: (ctx) => PopScope(
            // 强制更新时禁用返回键
            canPop: strategy != UpdateStrategy.forced,
            child: _dialogBuilder!(ctx, _updateInfo!, statusNotifier, progressNotifier),
          ),
        );
      } else {
        _log('警告: 未设置 dialogBuilder 和 onUpdateAvailable');
      }
    } catch (e) {
      _log('检查更新出错: $e');
      _errorHandler?.call(e);
    }
  }

  /// 开始或恢复下载
  ///
  /// 断点续传策略：
  /// 1. 文件名包含 version+buildVersion，版本变化自动重新下载
  /// 2. 检测本地文件大小，若超出预期则删除重来
  /// 3. 服务端不支持 Range（返回200而非206）时，自动清理本地文件从头写入
  Future<void> startDownload() async {
    _assertAndroid();

    if (_updateInfo?.latestVersion == null) {
      _log('错误: 更新信息为空');
      statusNotifier.value = DownloadStatus.error;
      return;
    }

    if (statusNotifier.value == DownloadStatus.downloading) {
      _log('下载已在进行中');
      return;
    }

    statusNotifier.value = DownloadStatus.downloading;
    _cancelToken = CancelToken();

    final latest = _updateInfo!.latestVersion!;

    try {
      final tempDir = await getTemporaryDirectory();
      // 文件名包含 version + buildVersion，避免版本切换时复用旧文件
      _savePath = '${tempDir.path}/app-v${latest.version}-${latest.buildVersion}.apk';

      _log('保存路径: $_savePath');
      _log('下载链接: ${latest.downloadUrl}');

      // 清理其他版本的残留文件
      await _cleanOldApkFiles(tempDir, _savePath!);

      final file = File(_savePath!);
      int existingLength = 0;

      if (await file.exists()) {
        existingLength = await file.length();
        _log('本地已有文件: $existingLength bytes');

        // 本地文件大小超出或等于预期大小
        if (latest.apkSize > 0 && existingLength >= latest.apkSize) {
          if (existingLength == latest.apkSize) {
            _log('文件大小匹配，直接校验');
            await _onDownloadCompleted();
            return;
          }
          // 大小超出，说明文件损坏，删除重来
          _log('本地文件大小异常 ($existingLength > ${latest.apkSize})，删除重下');
          await file.delete();
          existingLength = 0;
        }
      }

      // 执行下载
      final useRange = existingLength > 0;

      await _dio.download(
        latest.downloadUrl,
        _savePath,
        cancelToken: _cancelToken,
        // 有续传偏移时用 append 模式，否则用 write（覆盖）
        fileAccessMode: useRange ? FileAccessMode.append : FileAccessMode.write,
        onReceiveProgress: (received, total) {
          final currentTotal = existingLength + received;
          final totalSize = latest.apkSize > 0 ? latest.apkSize : (total + existingLength);

          if (totalSize > 0) {
            progressNotifier.value = (currentTotal / totalSize).clamp(0.0, 1.0);
          }
        },
        options: useRange
            ? Options(
                headers: {'Range': 'bytes=$existingLength-'},
                // 断点续传：服务端应返回 206；如果返回 200 说明不支持 Range
                validateStatus: (status) => status == 200 || status == 206,
              )
            : null,
        deleteOnError: false,
      );

      // 下载请求完成后，检查文件一致性
      // 如果我们请求了 Range 但服务端返回了完整文件（200），
      // dio.download 在 append 模式下会把完整文件追加到已有内容后面
      // 这里通过大小检测来兜底
      if (latest.apkSize > 0) {
        final actualSize = await file.length();
        if (actualSize != latest.apkSize) {
          _log('下载后文件大小不匹配 (实际: $actualSize, 预期: ${latest.apkSize})，可能是续传冲突，重新下载');
          await file.delete();
          // 递归重试一次（此时本地文件已删除，不会再走续传）
          statusNotifier.value = DownloadStatus.none;
          await startDownload();
          return;
        }
      }

      await _onDownloadCompleted();
    } on DioException catch (e) {
      if (CancelToken.isCancel(e)) {
        statusNotifier.value = DownloadStatus.paused;
        _log('下载已暂停');
      } else if (e.response?.statusCode == 416) {
        // 416 Range Not Satisfiable：本地文件 offset 无效
        _log('收到 416，清理本地文件后重试');
        if (_savePath != null) {
          final file = File(_savePath!);
          if (await file.exists()) await file.delete();
        }
        statusNotifier.value = DownloadStatus.none;
        await startDownload(); // 重试
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
    _assertAndroid();
    if (statusNotifier.value == DownloadStatus.downloading) {
      _cancelToken?.cancel();
    }
  }

  /// 安装APK（仅 Android）
  Future<void> install() async {
    _assertAndroid();

    if (statusNotifier.value != DownloadStatus.finished || _savePath == null) {
      _log('错误: 文件未下载完成，无法安装');
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

  /// 重置所有状态（用于需要重新开始的场景）
  void reset() {
    _cancelToken?.cancel();
    _cancelToken = null;
    _updateInfo = null;
    _savePath = null;
    statusNotifier.value = DownloadStatus.none;
    progressNotifier.value = 0.0;
  }

  // ========== 私有方法 ==========

  /// 默认的更新判断逻辑
  bool _defaultShouldUpdate(VersionInfo newVersion, PackageInfo packageInfo) {
    if (newVersion.version != packageInfo.version) {
      _log('版本号不一致: ${packageInfo.version} → ${newVersion.version}');
      return true;
    }
    if (newVersion.buildVersion.toString() != packageInfo.buildNumber) {
      _log('构建号不一致: ${packageInfo.buildNumber} → ${newVersion.buildVersion}');
      return true;
    }
    return false;
  }

  /// 下载完成后的校验处理
  Future<void> _onDownloadCompleted() async {
    _log('下载完成，路径: $_savePath');

    final latestVersion = _updateInfo?.latestVersion;
    if (latestVersion == null) {
      _log('没有版本信息，无法校验');
      statusNotifier.value = DownloadStatus.error;
      return;
    }

    final file = File(_savePath!);
    if (!await file.exists()) {
      _log('文件不存在');
      statusNotifier.value = DownloadStatus.error;
      return;
    }

    // MD5 校验（如果提供了 hash）
    if (latestVersion.apkHashCode.isNotEmpty) {
      _log('正在校验 MD5...');
      final bytes = await file.readAsBytes();
      final fileMd5 = md5.convert(bytes).toString();
      final expectedMd5 = latestVersion.apkHashCode.toLowerCase();
      _log('文件MD5: $fileMd5, 期望: $expectedMd5');

      if (fileMd5 != expectedMd5) {
        _log('MD5 校验失败，文件已损坏');
        await file.delete();
        statusNotifier.value = DownloadStatus.error;
        progressNotifier.value = 0.0;
        _errorHandler?.call('MD5_VALIDATION_FAILED');
        return;
      }
      _log('MD5 校验通过');
    } else {
      // 未提供 MD5 时不删文件，而是放行（跳过校验）
      _log('未提供 MD5 校验值，跳过校验');
    }

    statusNotifier.value = DownloadStatus.finished;
    progressNotifier.value = 1.0;
  }

  /// 清理临时目录中其他版本的 APK 残留文件
  Future<void> _cleanOldApkFiles(Directory tempDir, String currentPath) async {
    try {
      final entities = tempDir.listSync();
      for (final entity in entities) {
        if (entity is File && entity.path.endsWith('.apk') && entity.path != currentPath) {
          _log('清理旧版 APK: ${entity.path}');
          await entity.delete();
        }
      }
    } catch (e) {
      _log('清理旧文件时出错: $e');
    }
  }

  /// 默认的 API 响应解析器
  static Future<VersionInfo> _defaultParser(dynamic data) async {
    return VersionInfo.fromMap((data as Map<String, dynamic>)['data']);
  }

  void _assertAndroid() {
    assert(Platform.isAndroid, 'TinyUpgrader only supports Android');
  }

  void _assertInitialized() {
    assert(_initialized, 'TinyUpgrader.init() must be called before use');
  }

  void _log(String message) {
    if (_isDebugging) {
      debugPrint('[TinyUpgrader] $message');
    }
  }
}
