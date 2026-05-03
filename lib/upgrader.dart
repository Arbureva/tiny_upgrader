import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:tiny_upgrader/dialog.dart';
import 'package:tiny_upgrader/forced_update_page.dart';
import 'package:tiny_upgrader/oss_config.dart';
import 'package:tiny_upgrader/oss_signer.dart';
import 'package:tiny_upgrader/upgrader_event.dart';
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

/// 自定义更新对话框构建器（可选 / 推荐更新时展示）
typedef UpdateDialogBuilder =
    Widget Function(
      BuildContext context,
      UpdateInfo updateInfo,
      ValueNotifier<DownloadStatus> statusNotifier,
      ValueNotifier<double> progressNotifier,
    );

/// 强制更新拦截页构建器
///
/// 当 [UpdateStrategy.forced] 时，会 push 一个全屏路由来阻止用户使用 App。
/// 页面不可通过返回键或手势关闭，直到 APK 下载并安装完成。
///
/// 默认使用 [DefaultForcedUpdatePage]（Material Design 风格）。
typedef ForcedUpdatePageBuilder =
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
  ForcedUpdatePageBuilder? _forcedUpdatePageBuilder;
  OssConfig? _ossConfig;

  /// 日志/事件回调，所有升级流程事件通过此回调统一输出。
  UpgraderCallback? _onEvent;

  /// 是否启用日志回调。
  ///
  /// 设置为 `true` 后，每个升级事件都会触发 [onEvent] 回调。
  /// 可在运行时动态切换，方便调试或在特定页面开启。
  bool _enableLog = false;

  // ========== 运行时状态 ==========
  CancelToken? _cancelToken;
  UpdateInfo? _updateInfo;
  String? _savePath;

  final ValueNotifier<DownloadStatus> statusNotifier = ValueNotifier(DownloadStatus.none);
  final ValueNotifier<double> progressNotifier = ValueNotifier(0.0);

  // ========== 公开属性 ==========

  /// 获取当前是否启用日志回调。
  bool get enableLog => _enableLog;

  /// 运行时切换日志回调开关。
  set enableLog(bool value) {
    _enableLog = value;
    _emit(UpgraderEventType.log, '日志回调已${value ? "开启" : "关闭"}');
  }

  /// 获取当前设置的事件回调（可能为 null）。
  UpgraderCallback? get onEvent => _onEvent;

  // ========== 初始化 ==========

  /// 初始化配置，应在 App 启动时调用一次。
  ///
  /// [onEvent]：统一的升级事件回调，所有流程事件（检测、下载、校验、
  /// 安装、清理）均通过此回调输出。调用方可根据 [UpgraderEvent.type]
  /// 自行分发业务逻辑。
  ///
  /// [enableLog]：是否在初始化后立即启用日志回调，默认为 `false`。
  /// 也可以在运行时通过 [enableLog] 属性动态切换。
  static void init({
    bool isDebug = false,
    String? baseUrl,
    Dio? dio,
    UpdateApiParser? parser,
    ErrorHandler? errorHandler,
    UpdateDialogBuilder? dialogBuilder,
    ForcedUpdatePageBuilder? forcedUpdatePageBuilder,
    OssConfig? ossConfig,
    UpgraderCallback? onEvent,
    bool enableLog = false,
  }) {
    final inst = instance;
    inst._isDebugging = isDebug;
    if (parser != null) inst._parser = parser;
    inst._errorHandler = errorHandler;
    inst._forcedUpdatePageBuilder = forcedUpdatePageBuilder;
    inst._ossConfig = ossConfig;
    inst._onEvent = onEvent;
    inst._enableLog = enableLog;

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
    inst._emit(UpgraderEventType.init, 'TinyUpgrader 初始化完成', {
      'isDebug': isDebug,
      'enableLog': enableLog,
      'hasOssConfig': ossConfig != null,
      'hasCustomParser': parser != null,
      'hasCustomDialog': dialogBuilder != null,
      'hasForcedPage': forcedUpdatePageBuilder != null,
    });
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

    _emit(UpgraderEventType.checkStart, '开始检查更新', {'url': url});

    try {
      final response = await _dio.get(url, queryParameters: params);
      if (response.statusCode != 200) {
        final errMsg = '网络请求失败，状态码: ${response.statusCode}';
        _emit(UpgraderEventType.checkError, errMsg, {
          'statusCode': response.statusCode,
        });
        throw errMsg;
      }

      _emit(UpgraderEventType.checkResponse, '检查更新响应', {
        'statusCode': response.statusCode,
        'data': response.data,
      });

      final newVersionInfo = await _parser(response.data);
      final packageInfo = await PackageInfo.fromPlatform();

      _emit(UpgraderEventType.checkCurrentVersion, '当前版本信息', {
        'version': packageInfo.version,
        'buildNumber': packageInfo.buildNumber,
        'appName': packageInfo.appName,
        'packageName': packageInfo.packageName,
      });

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
        _emit(UpgraderEventType.checkNoUpdate, '当前已是最新版本', {
          'currentVersion': packageInfo.version,
          'currentBuildNumber': packageInfo.buildNumber,
        });
        return;
      }

      _emit(UpgraderEventType.checkNewVersion, '发现新版本', {
        'currentVersion': packageInfo.version,
        'currentBuildNumber': packageInfo.buildNumber,
        'latestVersion': newVersionInfo.version,
        'latestBuildVersion': newVersionInfo.buildVersion,
        'updateStrategy': newVersionInfo.updateStrategy.name,
        'apkSize': newVersionInfo.apkSize,
        'hasMd5': newVersionInfo.apkHashCode.isNotEmpty,
        'modifyContent': newVersionInfo.modifyContent,
      });

      // 重置下载状态
      statusNotifier.value = DownloadStatus.none;
      progressNotifier.value = 0.0;

      // 优先使用回调
      if (onUpdateAvailable != null) {
        if (!context.mounted) return;
        onUpdateAvailable(context, _updateInfo!);
        return;
      }

      // 强制更新 → 全屏拦截页；可选/推荐 → Dialog
      if (!context.mounted) return;
      final strategy = newVersionInfo.updateStrategy;

      if (strategy == UpdateStrategy.forced) {
        _emit(UpgraderEventType.log, '触发强制更新页面');

        final pageBuilder = _forcedUpdatePageBuilder ??
            (ctx, info, st, pr) => DefaultForcedUpdatePage(
                  updateInfo: info,
                  statusNotifier: st,
                  progressNotifier: pr,
                );

        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (ctx) => PopScope(
              canPop: false,
              child: pageBuilder(ctx, _updateInfo!, statusNotifier, progressNotifier),
            ),
          ),
        );
      } else if (_dialogBuilder != null) {
        _emit(UpgraderEventType.log, '弹出更新对话框 (${strategy.name})');

        showDialog(
          context: context,
          barrierDismissible: true,
          builder: (ctx) => PopScope(
            canPop: true,
            child: _dialogBuilder!(ctx, _updateInfo!, statusNotifier, progressNotifier),
          ),
        );
      } else {
        _emit(UpgraderEventType.log, '警告: 未设置 dialogBuilder 和 onUpdateAvailable');
      }
    } catch (e) {
      _emit(UpgraderEventType.checkError, '检查更新出错: $e', {'error': e.toString()});
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
      _emit(UpgraderEventType.downloadError, '更新信息为空，无法开始下载');
      statusNotifier.value = DownloadStatus.error;
      return;
    }

    if (statusNotifier.value == DownloadStatus.downloading) {
      _emit(UpgraderEventType.log, '下载已在进行中，跳过重复请求');
      return;
    }

    statusNotifier.value = DownloadStatus.downloading;
    _cancelToken = CancelToken();

    final latest = _updateInfo!.latestVersion!;

    try {
      final tempDir = await getTemporaryDirectory();
      // 文件名包含 version + buildVersion，避免版本切换时复用旧文件
      _savePath = '${tempDir.path}/app-v${latest.version}-${latest.buildVersion}.apk';

      _emit(UpgraderEventType.downloadStart, '准备下载', {
        'savePath': _savePath,
        'downloadUrl': latest.downloadUrl,
        'apkSize': latest.apkSize,
        'version': latest.version,
        'buildVersion': latest.buildVersion,
      });

      // 清理其他版本的残留文件
      await _cleanOldApkFiles(tempDir, _savePath!);

      final file = File(_savePath!);
      int existingLength = 0;

      if (await file.exists()) {
        existingLength = await file.length();

        _emit(UpgraderEventType.downloadResume, '检测到本地已有文件', {
          'existingBytes': existingLength,
          'expectedBytes': latest.apkSize,
        });

        // 本地文件大小超出或等于预期大小
        if (latest.apkSize > 0 && existingLength >= latest.apkSize) {
          if (existingLength == latest.apkSize) {
            _emit(UpgraderEventType.log, '文件大小匹配，直接进入校验');
            await _onDownloadCompleted();
            return;
          }
          // 大小超出，说明文件损坏，删除重来
          _emit(UpgraderEventType.downloadConflict, '本地文件大小异常，删除重下', {
            'existingBytes': existingLength,
            'expectedBytes': latest.apkSize,
          });
          await file.delete();
          existingLength = 0;
        }
      }

      // 执行下载
      final useRange = existingLength > 0;

      // 构建请求头：OSS 签名 + 断点续传 Range
      final Map<String, String> downloadHeaders = {};

      if (_ossConfig != null && !_ossConfig!.isPublicRead) {
        downloadHeaders.addAll(
          OssSigner.generateHeaders(
            config: _ossConfig!,
            downloadUrl: latest.downloadUrl,
          ),
        );
      }

      if (useRange) {
        downloadHeaders['Range'] = 'bytes=$existingLength-';
      }

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
          _emit(UpgraderEventType.downloadProgress, '下载进度', {
            'received': received,
            'total': total,
            'currentTotal': currentTotal,
            'totalSize': totalSize,
            'progress': totalSize > 0
                ? (currentTotal / totalSize).clamp(0.0, 1.0)
                : null,
          });
        },
        options: Options(
          headers: downloadHeaders.isEmpty ? null : downloadHeaders,
          validateStatus:
              useRange ? (status) => status == 200 || status == 206 : null,
        ),
        deleteOnError: false,
      );

      // 下载请求完成后，检查文件一致性
      // 如果我们请求了 Range 但服务端返回了完整文件（200），
      // dio.download 在 append 模式下会把完整文件追加到已有内容后面
      // 这里通过大小检测来兜底
      if (latest.apkSize > 0) {
        final actualSize = await file.length();
        if (actualSize != latest.apkSize) {
          _emit(UpgraderEventType.downloadConflict, '文件大小不匹配，重新下载', {
            'actualBytes': actualSize,
            'expectedBytes': latest.apkSize,
          });
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
        _emit(UpgraderEventType.downloadPaused, '下载已暂停', {
          'savePath': _savePath,
          'progress': progressNotifier.value,
        });
      } else if (e.response?.statusCode == 416) {
        // 416 Range Not Satisfiable：本地文件 offset 无效
        _emit(UpgraderEventType.downloadRetry, '收到 416，清理本地文件后重试', {
          'statusCode': 416,
        });
        if (_savePath != null) {
          final file = File(_savePath!);
          if (await file.exists()) await file.delete();
        }
        statusNotifier.value = DownloadStatus.none;
        await startDownload(); // 重试
      } else {
        statusNotifier.value = DownloadStatus.error;
        _emit(UpgraderEventType.downloadError, '下载出错', {
          'error': e.toString(),
          'message': e.message,
          'statusCode': e.response?.statusCode,
        });
        _errorHandler?.call(e);
      }
    } catch (e) {
      statusNotifier.value = DownloadStatus.error;
      _emit(UpgraderEventType.downloadError, '下载时发生未知错误', {
        'error': e.toString(),
      });
      _errorHandler?.call(e);
    }
  }

  /// 暂停下载
  void pauseDownload() {
    _assertAndroid();
    if (statusNotifier.value == DownloadStatus.downloading) {
      _emit(UpgraderEventType.log, '用户请求暂停下载');
      _cancelToken?.cancel();
    }
  }

  /// 安装APK（仅 Android）
  Future<void> install() async {
    _assertAndroid();

    if (statusNotifier.value != DownloadStatus.finished || _savePath == null) {
      _emit(UpgraderEventType.installError, '文件未下载完成，无法安装', {
        'status': statusNotifier.value.name,
        'savePath': _savePath,
      });
      return;
    }

    _emit(UpgraderEventType.installStart, '准备安装 APK', {
      'filePath': _savePath,
    });

    try {
      await TinyUpgraderPlatform.instance.installApk(_savePath!);
      _emit(UpgraderEventType.installComplete, 'APK 安装请求已发送');
    } catch (e) {
      _emit(UpgraderEventType.installError, '安装失败', {
        'error': e.toString(),
        'filePath': _savePath,
      });
      _errorHandler?.call(e);
    }
  }

  /// 重置所有状态（用于需要重新开始的场景）
  void reset() {
    _emit(UpgraderEventType.log, '重置所有状态');
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
      _emit(UpgraderEventType.log, '版本号不一致: ${packageInfo.version} → ${newVersion.version}');
      return true;
    }
    if (newVersion.buildVersion.toString() != packageInfo.buildNumber) {
      _emit(UpgraderEventType.log, '构建号不一致: ${packageInfo.buildNumber} → ${newVersion.buildVersion}');
      return true;
    }
    return false;
  }

  /// 下载完成后的校验处理
  Future<void> _onDownloadCompleted() async {
    _emit(UpgraderEventType.downloadComplete, '下载完成', {
      'filePath': _savePath,
    });

    final latestVersion = _updateInfo?.latestVersion;
    if (latestVersion == null) {
      _emit(UpgraderEventType.validationFailed, '没有版本信息，无法校验');
      statusNotifier.value = DownloadStatus.error;
      return;
    }

    final file = File(_savePath!);
    if (!await file.exists()) {
      _emit(UpgraderEventType.validationFailed, '文件不存在，无法校验', {
        'filePath': _savePath,
      });
      statusNotifier.value = DownloadStatus.error;
      return;
    }

    // MD5 校验（如果提供了 hash）
    if (latestVersion.apkHashCode.isNotEmpty) {
      _emit(UpgraderEventType.validationStart, '开始 MD5 校验', {
        'expectedMd5': latestVersion.apkHashCode.toLowerCase(),
      });

      final bytes = await file.readAsBytes();
      final fileMd5 = md5.convert(bytes).toString();
      final expectedMd5 = latestVersion.apkHashCode.toLowerCase();

      if (fileMd5 != expectedMd5) {
        _emit(UpgraderEventType.validationFailed, 'MD5 校验失败，文件已损坏', {
          'fileMd5': fileMd5,
          'expectedMd5': expectedMd5,
        });
        await file.delete();
        statusNotifier.value = DownloadStatus.error;
        progressNotifier.value = 0.0;
        _errorHandler?.call('MD5_VALIDATION_FAILED');
        return;
      }
      _emit(UpgraderEventType.validationSuccess, 'MD5 校验通过', {
        'fileMd5': fileMd5,
      });
    } else {
      _emit(UpgraderEventType.validationSkipped, '未提供 MD5 校验值，跳过校验');
    }

    statusNotifier.value = DownloadStatus.finished;
    progressNotifier.value = 1.0;
  }

  /// 清理临时目录中其他版本的 APK 残留文件
  Future<void> _cleanOldApkFiles(Directory tempDir, String currentPath) async {
    try {
      final entities = tempDir.listSync();
      bool hasCleaned = false;
      for (final entity in entities) {
        if (entity is File && entity.path.endsWith('.apk') && entity.path != currentPath) {
          _emit(UpgraderEventType.cleanOldFiles, '清理旧版 APK', {
            'filePath': entity.path,
          });
          await entity.delete();
          hasCleaned = true;
        }
      }
      if (!hasCleaned) {
        // 没有旧文件需要清理，不单独发事件
      }
    } catch (e) {
      _emit(UpgraderEventType.log, '清理旧文件时出错: $e');
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

  /// 统一的日志/事件发射方法。
  ///
  /// 当 [_enableLog] 为 `true` 且 [_onEvent] 不为 `null` 时触发回调。
  /// 同时，如果 [_isDebugging] 为 `true`，会通过 [debugPrint] 输出到控制台。
  void _emit(UpgraderEventType type, String message, [Map<String, dynamic>? data]) {
    if (_isDebugging) {
      debugPrint('[TinyUpgrader] ${type.name}: $message');
    }
    if (_enableLog && _onEvent != null) {
      _onEvent!(UpgraderEvent(type: type, message: message, data: data));
    }
  }
}
