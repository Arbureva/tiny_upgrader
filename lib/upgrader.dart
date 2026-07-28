import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:tiny_upgrader/dialog.dart';
import 'package:tiny_upgrader/download_exception.dart';
import 'package:tiny_upgrader/file_hash.dart';
import 'package:tiny_upgrader/forced_update_page.dart';
import 'package:tiny_upgrader/install_result.dart';
import 'package:tiny_upgrader/oss_config.dart';
import 'package:tiny_upgrader/oss_signer.dart';
import 'package:tiny_upgrader/update_check_result.dart';
import 'package:tiny_upgrader/upgrader_event.dart';
import 'package:tiny_upgrader/upgrader_platform_interface.dart';
import 'package:tiny_upgrader/update_info.dart';
import 'package:tiny_upgrader/version_comparator.dart';

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
typedef UpdateAvailableCallback =
    void Function(BuildContext context, UpdateInfo updateInfo);

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
  /// 只控制 [UpgraderEventType.log]；业务事件始终发送给 [onEvent]。
  bool _enableLog = false;

  int _maxValidationRetryCount = 3;
  int _maxNetworkRetryCount = 2;
  bool _autoStartForcedDownload = false;
  bool _barrierDismissible = true;
  int _minFreeSpaceMarginBytes = 64 * 1024 * 1024;

  // ========== 运行时状态 ==========
  CancelToken? _cancelToken;
  UpdateInfo? _updateInfo;
  String? _savePath;
  Future<UpdateCheckResult>? _checkInProgress;
  Future<void>? _downloadOperation;
  int _sessionSequence = 0;
  int _checkSequence = 0;
  int? _activeDownloadSession;
  String? _presentedVersionKey;
  DateTime? _lastProgressAt;
  int _lastProgressPercent = -1;

  final ValueNotifier<DownloadStatus> statusNotifier = ValueNotifier(
    DownloadStatus.none,
  );
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
  /// [enableLog]：是否发送通用日志事件，默认为 `false`。
  /// 检查、下载和安装等业务事件不受此开关影响。
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
    @Deprecated('Use maxValidationRetryCount instead') int maxRetryCount = 3,
    int? maxValidationRetryCount,
    int maxNetworkRetryCount = 2,
    int minFreeSpaceMarginBytes = 64 * 1024 * 1024,
    bool autoStartForcedDownload = false,
    bool barrierDismissible = true,
  }) {
    final validationRetryCount = maxValidationRetryCount ?? maxRetryCount;
    if (validationRetryCount < 0) {
      throw ArgumentError.value(
        validationRetryCount,
        'maxValidationRetryCount',
        'must not be negative',
      );
    }
    if (maxNetworkRetryCount < 0) {
      throw ArgumentError.value(
        maxNetworkRetryCount,
        'maxNetworkRetryCount',
        'must not be negative',
      );
    }
    if (minFreeSpaceMarginBytes < 0) {
      throw ArgumentError.value(
        minFreeSpaceMarginBytes,
        'minFreeSpaceMarginBytes',
        'must not be negative',
      );
    }
    final inst = instance;
    inst._isDebugging = isDebug;
    if (parser != null) inst._parser = parser;
    inst._errorHandler = errorHandler;
    inst._forcedUpdatePageBuilder = forcedUpdatePageBuilder;
    inst._ossConfig = ossConfig;
    inst._onEvent = onEvent;
    inst._enableLog = enableLog;
    inst._maxValidationRetryCount = validationRetryCount;
    inst._maxNetworkRetryCount = maxNetworkRetryCount;
    inst._minFreeSpaceMarginBytes = minFreeSpaceMarginBytes;
    inst._autoStartForcedDownload = autoStartForcedDownload;
    inst._barrierDismissible = barrierDismissible;

    inst._dialogBuilder =
        dialogBuilder ??
        (context, updateInfo, statusNotifier, progressNotifier) =>
            MyUpdateDialog(
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
      'maxValidationRetryCount': inst._maxValidationRetryCount,
      'maxNetworkRetryCount': maxNetworkRetryCount,
      'minFreeSpaceMarginBytes': minFreeSpaceMarginBytes,
      'autoStartForcedDownload': autoStartForcedDownload,
      'barrierDismissible': barrierDismissible,
      'hasOssConfig': ossConfig != null,
      'hasCustomParser': parser != null,
      'hasCustomDialog': dialogBuilder != null,
      'hasForcedPage': forcedUpdatePageBuilder != null,
    });
  }

  // ========== 公开方法 ==========

  Future<String?> getPlatformVersion() async {
    _ensureAndroid();
    _ensureInitialized();
    return TinyUpgraderPlatform.instance.getPlatformVersion();
  }

  /// 检查更新
  ///
  /// 流程：请求API → 解析版本 → 判断是否需要更新 → 触发回调或弹窗
  Future<UpdateCheckResult> check(
    BuildContext context, {
    required String url,
    UpdateAvailableCallback? onUpdateAvailable,
    bool Function(VersionInfo newVersion, PackageInfo currentPackage)?
    shouldUpdate,
    Map<String, dynamic>? params,
  }) {
    if (!Platform.isAndroid) {
      return Future.value(const UpdateUnsupported());
    }
    _ensureInitialized();

    final runningCheck = _checkInProgress;
    if (runningCheck != null) return runningCheck;

    if (statusNotifier.value == DownloadStatus.downloading ||
        statusNotifier.value == DownloadStatus.paused) {
      final requestId = ++_checkSequence;
      return Future.value(
        _handleCheckFailure(
          const UpgraderException(
            type: UpdateCheckFailureType.busy,
            message: 'A download is active. Reset it before checking again.',
          ),
          requestId: requestId,
        ),
      );
    }

    final requestId = ++_checkSequence;
    late final Future<UpdateCheckResult> operation;
    operation =
        _performCheck(
          context,
          requestId: requestId,
          url: url,
          onUpdateAvailable: onUpdateAvailable,
          shouldUpdate: shouldUpdate,
          params: params,
        ).whenComplete(() {
          if (identical(_checkInProgress, operation)) {
            _checkInProgress = null;
          }
        });
    _checkInProgress = operation;
    return operation;
  }

  Future<UpdateCheckResult> _performCheck(
    BuildContext context, {
    required int requestId,
    required String url,
    UpdateAvailableCallback? onUpdateAvailable,
    bool Function(VersionInfo newVersion, PackageInfo currentPackage)?
    shouldUpdate,
    Map<String, dynamic>? params,
  }) async {
    _emit(UpgraderEventType.checkStart, '开始检查更新', {
      'requestId': requestId,
      'url': _redactUrl(url),
    });

    try {
      final response = await _dio.get(
        url,
        queryParameters: params,
        options: Options(validateStatus: (_) => true),
      );
      if (response.statusCode != 200) {
        throw UpgraderException(
          type: UpdateCheckFailureType.http,
          message: '网络请求失败，状态码: ${response.statusCode}',
          statusCode: response.statusCode,
        );
      }

      _emit(UpgraderEventType.checkResponse, '检查更新响应', {
        'requestId': requestId,
        'statusCode': response.statusCode,
        'dataType': response.data.runtimeType.toString(),
      });

      final VersionInfo newVersionInfo;
      try {
        newVersionInfo = await _parser(response.data);
      } on FormatException catch (error) {
        throw UpgraderException(
          type: UpdateCheckFailureType.parsing,
          message: error.message,
          cause: error,
        );
      } catch (error) {
        throw UpgraderException(
          type: UpdateCheckFailureType.parsing,
          message: '无法解析更新响应',
          cause: error,
        );
      }

      final packageInfo = await PackageInfo.fromPlatform();
      _emit(UpgraderEventType.checkCurrentVersion, '当前版本信息', {
        'requestId': requestId,
        'version': packageInfo.version,
        'buildNumber': packageInfo.buildNumber,
        'appName': packageInfo.appName,
        'packageName': packageInfo.packageName,
      });

      final updateInfo = UpdateInfo(
        currentVersion: packageInfo.version,
        currentBuildNumber: packageInfo.buildNumber,
        latestVersion: newVersionInfo,
      );

      final bool hasUpdate;
      try {
        hasUpdate = shouldUpdate != null
            ? shouldUpdate(newVersionInfo, packageInfo)
            : _defaultShouldUpdate(newVersionInfo, packageInfo);
      } on FormatException catch (error) {
        throw UpgraderException(
          type: UpdateCheckFailureType.version,
          message: error.message,
          cause: error,
        );
      }

      if (!hasUpdate) {
        _emit(UpgraderEventType.checkNoUpdate, '当前已是最新版本', {
          'requestId': requestId,
          'currentVersion': packageInfo.version,
          'currentBuildNumber': packageInfo.buildNumber,
        });
        return NoUpdate(updateInfo);
      }

      _updateInfo = updateInfo;
      _emit(UpgraderEventType.checkNewVersion, '发现新版本', {
        'requestId': requestId,
        'currentVersion': packageInfo.version,
        'currentBuildNumber': packageInfo.buildNumber,
        'latestVersion': newVersionInfo.version,
        'latestBuildVersion': newVersionInfo.buildVersion,
        'updateStrategy': newVersionInfo.updateStrategy.name,
        'apkSize': newVersionInfo.apkSize,
        'hashAlgorithm': newVersionInfo.apkHashAlgorithm.name,
        'hasHash': newVersionInfo.apkHashCode.isNotEmpty,
      });

      statusNotifier.value = DownloadStatus.none;
      progressNotifier.value = 0.0;

      final result = UpdateAvailable(updateInfo);
      final versionKey =
          '${newVersionInfo.version}+${newVersionInfo.buildVersion}';
      if (_presentedVersionKey == versionKey) return result;
      _presentedVersionKey = versionKey;

      if (onUpdateAvailable != null) {
        if (context.mounted) {
          _safeCallback(() => onUpdateAvailable(context, updateInfo));
        }
        return result;
      }

      if (!context.mounted) return result;
      final strategy = newVersionInfo.updateStrategy;

      if (strategy == UpdateStrategy.forced) {
        _emit(UpgraderEventType.log, '触发强制更新页面');
        final pageBuilder =
            _forcedUpdatePageBuilder ??
            (ctx, info, st, pr) => DefaultForcedUpdatePage(
              updateInfo: info,
              statusNotifier: st,
              progressNotifier: pr,
              autoStartDownload: _autoStartForcedDownload,
            );
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (ctx) => PopScope(
              canPop: false,
              child: pageBuilder(
                ctx,
                updateInfo,
                statusNotifier,
                progressNotifier,
              ),
            ),
          ),
        );
      } else if (_dialogBuilder != null) {
        _emit(UpgraderEventType.log, '弹出更新对话框 (${strategy.name})');
        showDialog<void>(
          context: context,
          barrierDismissible: _barrierDismissible,
          builder: (ctx) => PopScope(
            canPop: _barrierDismissible,
            child: _dialogBuilder!(
              ctx,
              updateInfo,
              statusNotifier,
              progressNotifier,
            ),
          ),
        );
      }
      return result;
    } on DioException catch (error) {
      final failure = UpgraderException(
        type: UpdateCheckFailureType.network,
        message: error.message ?? '网络请求失败',
        cause: error,
        statusCode: error.response?.statusCode,
      );
      return _handleCheckFailure(failure, requestId: requestId);
    } on UpgraderException catch (error) {
      return _handleCheckFailure(error, requestId: requestId);
    } catch (error) {
      return _handleCheckFailure(
        UpgraderException(
          type: UpdateCheckFailureType.unknown,
          message: '检查更新失败',
          cause: error,
        ),
        requestId: requestId,
      );
    }
  }

  UpdateCheckFailed _handleCheckFailure(
    UpgraderException error, {
    int? requestId,
  }) {
    _emit(UpgraderEventType.checkError, error.message, {
      'requestId': requestId,
      'type': error.type.name,
      'statusCode': error.statusCode,
    });
    _safeErrorCallback(error);
    return UpdateCheckFailed(error);
  }

  /// 开始或恢复下载
  ///
  /// 断点续传策略：
  /// 1. 文件名包含 version+buildVersion，版本变化自动重新下载
  /// 2. 检测本地文件大小，若超出预期则删除重来
  /// 3. 服务端不支持 Range（返回200而非206）时，自动清理本地文件从头写入
  /// 4. 大小不匹配或 HTTP 416 时自动重试
  Future<void> startDownload() async {
    _ensureAndroid();
    _ensureInitialized();

    if (_updateInfo?.latestVersion == null) {
      statusNotifier.value = DownloadStatus.error;
      final error = StateError('No update is available to download.');
      _emit(UpgraderEventType.downloadError, error.message);
      _safeErrorCallback(error);
      return;
    }
    if (statusNotifier.value == DownloadStatus.downloading) {
      _emit(UpgraderEventType.log, '下载已在进行中，跳过重复请求');
      return;
    }

    // Wait until a cancelled writer releases the file before resuming.
    final previousOperation = _downloadOperation;
    if (previousOperation != null) {
      await previousOperation;
    }

    final session = ++_sessionSequence;
    _activeDownloadSession = session;
    _lastProgressAt = null;
    _lastProgressPercent = -1;
    statusNotifier.value = DownloadStatus.downloading;
    _cancelToken = CancelToken();

    late final Future<void> operation;
    operation = _doStartDownload(0, session).whenComplete(() {
      if (identical(_downloadOperation, operation)) {
        _downloadOperation = null;
      }
    });
    _downloadOperation = operation;
    await operation;
  }

  Future<void> _doStartDownload(
    int retryCount,
    int session, {
    int networkRetryCount = 0,
  }) async {
    if (!_isActiveSession(session)) return;
    final latest = _updateInfo!.latestVersion!;

    try {
      final tempDir = await getTemporaryDirectory();
      if (!_isActiveSession(session)) return;

      final fileName = _buildSafeApkFileName(latest);
      _savePath = '${tempDir.path}${Platform.pathSeparator}$fileName';
      _emit(UpgraderEventType.downloadStart, '准备下载', {
        'sessionId': session,
        'fileName': fileName,
        'downloadUrl': _redactUrl(latest.downloadUrl),
        'apkSize': latest.apkSize,
        'version': latest.version,
        'buildVersion': latest.buildVersion,
        'retryCount': retryCount,
        'maxValidationRetryCount': _maxValidationRetryCount,
        'networkRetryCount': networkRetryCount,
        'maxNetworkRetryCount': _maxNetworkRetryCount,
      });

      await _cleanOldApkFiles(tempDir, _savePath!);
      if (!_isActiveSession(session)) return;

      final file = File(_savePath!);
      var existingLength = await file.exists() ? await file.length() : 0;
      if (existingLength > 0) {
        _emit(UpgraderEventType.downloadResume, '检测到本地已有文件', {
          'existingBytes': existingLength,
          'expectedBytes': latest.apkSize,
        });
      }

      if (latest.apkSize > 0 && existingLength >= latest.apkSize) {
        if (existingLength == latest.apkSize) {
          if (await _onDownloadCompleted(session)) return;
        }
        if (await file.exists()) await file.delete();
        existingLength = 0;
      }

      if (latest.apkSize > 0) {
        final availableBytes = await TinyUpgraderPlatform.instance
            .getAvailableStorageBytes(tempDir.path);
        final remainingDownloadBytes = latest.apkSize - existingLength;
        final requiredBytes =
            remainingDownloadBytes + latest.apkSize + _minFreeSpaceMarginBytes;
        if (availableBytes < requiredBytes) {
          final error = InsufficientStorageException(
            availableBytes: availableBytes,
            requiredBytes: requiredBytes,
          );
          statusNotifier.value = DownloadStatus.error;
          _emit(UpgraderEventType.downloadError, '存储空间不足，无法下载更新', {
            'sessionId': session,
            'availableBytes': availableBytes,
            'requiredBytes': requiredBytes,
          });
          _safeErrorCallback(error);
          return;
        }
      }

      final headers = <String, String>{};
      if (_ossConfig != null && !_ossConfig!.isPublicRead) {
        headers.addAll(
          OssSigner.generateHeaders(
            config: _ossConfig!,
            downloadUrl: latest.downloadUrl,
          ),
        );
      }
      if (existingLength > 0) {
        headers['Range'] = 'bytes=$existingLength-';
      }

      final response = await _dio.get<ResponseBody>(
        latest.downloadUrl,
        cancelToken: _cancelToken,
        options: Options(
          headers: headers.isEmpty ? null : headers,
          responseType: ResponseType.stream,
          validateStatus: (status) =>
              status == 200 || status == 206 || status == 416,
        ),
      );
      if (!_isActiveSession(session)) return;

      final statusCode = response.statusCode;
      if (statusCode == 416) {
        if (existingLength > 0 &&
            (latest.apkSize == 0 || existingLength == latest.apkSize) &&
            await _onDownloadCompleted(session)) {
          return;
        }
        await _retryDownload(
          retryCount,
          session,
          file,
          reason: 'HTTP 416',
          statusCode: 416,
        );
        return;
      }

      var writeOffset = 0;
      var fileMode = FileMode.write;
      var responseTotal = _contentLength(response);

      if (statusCode == 206) {
        final contentRange = _parseContentRange(
          response.headers.value('content-range'),
        );
        final rangeLength = contentRange == null
            ? null
            : contentRange.end - contentRange.start + 1;
        final rangeIsValid =
            contentRange != null &&
            contentRange.start == existingLength &&
            contentRange.end >= contentRange.start &&
            (contentRange.total == null ||
                contentRange.end < contentRange.total!) &&
            (responseTotal == 0 || responseTotal == rangeLength) &&
            (contentRange.total == null ||
                latest.apkSize == 0 ||
                contentRange.total == latest.apkSize);
        if (!rangeIsValid) {
          await _retryDownload(
            retryCount,
            session,
            file,
            reason: 'Invalid Content-Range',
          );
          return;
        }
        writeOffset = existingLength;
        fileMode = existingLength > 0 ? FileMode.append : FileMode.write;
        responseTotal = contentRange.total ?? (existingLength + responseTotal);
      } else if (statusCode == 200 && existingLength > 0) {
        // The server ignored Range. Truncate before the first response byte is
        // written so a full APK is never appended to the partial file.
        _emit(UpgraderEventType.downloadConflict, '服务端未接受断点续传，改为从头下载', {
          'discardedBytes': existingLength,
        });
      }

      final body = response.data;
      if (body == null) {
        throw StateError('Download response body is empty.');
      }

      final sink = file.openWrite(mode: fileMode);
      var received = 0;
      try {
        await for (final chunk in body.stream) {
          if (!_isActiveSession(session)) break;
          sink.add(chunk);
          received += chunk.length;
          _updateProgress(
            session: session,
            received: received,
            writeOffset: writeOffset,
            totalSize: latest.apkSize > 0 ? latest.apkSize : responseTotal,
          );
        }
        await sink.flush();
      } finally {
        await sink.close();
      }
      if (!_isActiveSession(session)) return;

      if (latest.apkSize > 0) {
        final actualSize = await file.length();
        if (actualSize != latest.apkSize) {
          await _retryDownload(
            retryCount,
            session,
            file,
            reason: '文件大小不匹配',
            actualBytes: actualSize,
            expectedBytes: latest.apkSize,
          );
          return;
        }
      }

      await _onDownloadCompleted(session);
    } on DioException catch (error) {
      if (!_isActiveSession(session)) return;
      if (CancelToken.isCancel(error)) {
        statusNotifier.value = DownloadStatus.paused;
        _emit(UpgraderEventType.downloadPaused, '下载已暂停', {
          'sessionId': session,
          'progress': progressNotifier.value,
        });
        return;
      }
      if (_isRetryableNetworkError(error) &&
          networkRetryCount < _maxNetworkRetryCount) {
        final nextRetry = networkRetryCount + 1;
        _emit(UpgraderEventType.downloadRetry, '网络异常，稍后重试', {
          'sessionId': session,
          'statusCode': error.response?.statusCode,
          'networkRetryCount': nextRetry,
          'maxNetworkRetryCount': _maxNetworkRetryCount,
        });
        await Future<void>.delayed(
          Duration(
            milliseconds: networkRetryCount >= 3
                ? 4000
                : 500 * (1 << networkRetryCount),
          ),
        );
        if (_isActiveSession(session)) {
          await _doStartDownload(
            retryCount,
            session,
            networkRetryCount: nextRetry,
          );
        }
        return;
      }
      statusNotifier.value = DownloadStatus.error;
      _emit(UpgraderEventType.downloadError, '下载出错', {
        'sessionId': session,
        'errorType': error.type.name,
        'statusCode': error.response?.statusCode,
        'networkRetryCount': networkRetryCount,
      });
      _safeErrorCallback(error);
    } catch (error) {
      if (!_isActiveSession(session)) return;
      statusNotifier.value = DownloadStatus.error;
      _emit(UpgraderEventType.downloadError, '下载时发生未知错误', {
        'sessionId': session,
        'error': error.toString(),
      });
      _safeErrorCallback(error);
    }
  }

  Future<void> _retryDownload(
    int retryCount,
    int session,
    File file, {
    required String reason,
    int? statusCode,
    int? actualBytes,
    int? expectedBytes,
  }) async {
    if (!_isActiveSession(session)) return;
    if (retryCount >= _maxValidationRetryCount) {
      if (await file.exists()) await file.delete();
      statusNotifier.value = DownloadStatus.error;
      progressNotifier.value = 0.0;
      _emit(UpgraderEventType.downloadError, '校验重试次数已耗尽', {
        'sessionId': session,
        'reason': reason,
        'statusCode': statusCode,
        'actualBytes': actualBytes,
        'expectedBytes': expectedBytes,
        'retryCount': retryCount,
        'maxValidationRetryCount': _maxValidationRetryCount,
      });
      _safeErrorCallback(StateError('RETRY_EXHAUSTED: $reason'));
      return;
    }

    if (await file.exists()) await file.delete();
    progressNotifier.value = 0.0;
    _emit(UpgraderEventType.downloadRetry, '清理本地文件后重试', {
      'sessionId': session,
      'reason': reason,
      'statusCode': statusCode,
      'retryCount': retryCount + 1,
      'maxValidationRetryCount': _maxValidationRetryCount,
    });
    await _doStartDownload(retryCount + 1, session);
  }

  /// 暂停下载
  void pauseDownload() {
    _ensureAndroid();
    _ensureInitialized();
    if (statusNotifier.value == DownloadStatus.downloading) {
      _emit(UpgraderEventType.log, '用户请求暂停下载');
      _cancelToken?.cancel();
      statusNotifier.value = DownloadStatus.paused;
    }
  }

  Future<bool> canRequestPackageInstalls() {
    _ensureAndroid();
    _ensureInitialized();
    return TinyUpgraderPlatform.instance.canRequestPackageInstalls();
  }

  Future<void> openInstallPermissionSettings() {
    _ensureAndroid();
    _ensureInitialized();
    return TinyUpgraderPlatform.instance.openInstallPermissionSettings();
  }

  /// 安装APK（仅 Android）
  Future<InstallResult> install() async {
    _ensureAndroid();
    _ensureInitialized();

    if (statusNotifier.value != DownloadStatus.finished || _savePath == null) {
      _emit(UpgraderEventType.installError, '文件未下载完成，无法安装', {
        'status': statusNotifier.value.name,
      });
      return const InstallResult(
        InstallStatus.fileNotFound,
        message: 'The APK has not finished downloading.',
      );
    }

    _emit(UpgraderEventType.installStart, '准备安装 APK');

    try {
      final result = await TinyUpgraderPlatform.instance.installApk(_savePath!);
      if (result.installerLaunched) {
        _emit(UpgraderEventType.installIntentLaunched, 'APK 安装器已启动');
      } else {
        _emit(UpgraderEventType.installError, '未能启动 APK 安装器', {
          'status': result.status.name,
          'message': result.message,
        });
      }
      return result;
    } catch (error) {
      _emit(UpgraderEventType.installError, '安装失败', {
        'error': error.toString(),
      });
      _safeErrorCallback(error);
      return InstallResult(InstallStatus.failed, message: error.toString());
    }
  }

  /// 重置所有状态（用于需要重新开始的场景）
  void reset() {
    _ensureAndroid();
    _ensureInitialized();
    _emit(UpgraderEventType.log, '重置所有状态');
    _activeDownloadSession = null;
    _sessionSequence++;
    _cancelToken?.cancel();
    _cancelToken = null;
    _updateInfo = null;
    _savePath = null;
    _presentedVersionKey = null;
    statusNotifier.value = DownloadStatus.none;
    progressNotifier.value = 0.0;
  }

  // ========== 私有方法 ==========

  /// 默认的更新判断逻辑
  bool _defaultShouldUpdate(VersionInfo newVersion, PackageInfo packageInfo) {
    return VersionComparator.isUpdateAvailable(
      candidateVersion: newVersion.version,
      candidateBuildNumber: newVersion.buildVersion,
      currentVersion: packageInfo.version,
      currentBuildNumber: packageInfo.buildNumber,
    );
  }

  /// 下载完成后的校验处理
  Future<bool> _onDownloadCompleted(int session) async {
    if (!_isActiveSession(session)) return false;
    _emit(UpgraderEventType.downloadComplete, '下载完成', {
      'sessionId': session,
      'fileName': _savePath?.split(Platform.pathSeparator).last,
    });

    final latestVersion = _updateInfo?.latestVersion;
    if (latestVersion == null) {
      _emit(UpgraderEventType.validationFailed, '没有版本信息，无法校验');
      statusNotifier.value = DownloadStatus.error;
      return false;
    }

    final file = File(_savePath!);
    if (!await file.exists()) {
      _emit(UpgraderEventType.validationFailed, '文件不存在，无法校验');
      statusNotifier.value = DownloadStatus.error;
      return false;
    }

    final fileLength = await file.length();
    if (fileLength < 4 || !await _hasZipHeader(file)) {
      _emit(UpgraderEventType.validationFailed, '下载内容不是有效的 APK/ZIP 文件');
      await file.delete();
      statusNotifier.value = DownloadStatus.error;
      progressNotifier.value = 0.0;
      _safeErrorCallback(StateError('INVALID_APK_HEADER'));
      return false;
    }

    if (latestVersion.apkHashCode.isNotEmpty) {
      final algorithm = latestVersion.apkHashAlgorithm;
      _emit(UpgraderEventType.validationStart, '开始 ${algorithm.name} 校验', {
        'algorithm': algorithm.name,
      });

      final fileHash = await computeFileHash(file, algorithm: algorithm);
      if (!_isActiveSession(session)) return false;
      final expectedHash = latestVersion.apkHashCode.trim().toLowerCase();

      if (fileHash != expectedHash) {
        _emit(
          UpgraderEventType.validationFailed,
          '${algorithm.name} 校验失败，文件已损坏',
          {'algorithm': algorithm.name, 'actualHash': fileHash},
        );
        await file.delete();
        statusNotifier.value = DownloadStatus.error;
        progressNotifier.value = 0.0;
        _safeErrorCallback(StateError('HASH_VALIDATION_FAILED'));
        return false;
      }
      _emit(UpgraderEventType.validationSuccess, '${algorithm.name} 校验通过', {
        'algorithm': algorithm.name,
      });
    } else {
      _emit(UpgraderEventType.validationSkipped, '未提供摘要值，仅校验 APK 文件头');
    }

    if (!_isActiveSession(session)) return false;
    statusNotifier.value = DownloadStatus.finished;
    progressNotifier.value = 1.0;
    return true;
  }

  /// 清理临时目录中其他版本的 APK 残留文件
  Future<void> _cleanOldApkFiles(Directory tempDir, String currentPath) async {
    try {
      await for (final entity in tempDir.list(followLinks: false)) {
        final fileName = entity.path.split(Platform.pathSeparator).last;
        if (entity is File &&
            fileName.startsWith('tiny_upgrader_') &&
            fileName.endsWith('.apk') &&
            entity.path != currentPath) {
          _emit(UpgraderEventType.cleanOldFiles, '清理旧版 APK', {
            'fileName': fileName,
          });
          await entity.delete();
        }
      }
    } catch (error) {
      _emit(UpgraderEventType.log, '清理旧文件时出错: $error');
    }
  }

  String _buildSafeApkFileName(VersionInfo version) {
    var safeVersion = version.version
        .trim()
        .replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_')
        .replaceAll(RegExp(r'\.{2,}'), '_');
    safeVersion = safeVersion.replaceAll(RegExp(r'^[._-]+|[._-]+$'), '');
    if (safeVersion.isEmpty) safeVersion = 'version';
    if (safeVersion.length > 64) {
      safeVersion = safeVersion.substring(0, 64);
    }
    return 'tiny_upgrader_${safeVersion}_${version.buildVersion}.apk';
  }

  int _contentLength(Response<ResponseBody> response) {
    return int.tryParse(response.headers.value('content-length') ?? '') ?? 0;
  }

  bool _isRetryableNetworkError(DioException error) {
    final statusCode = error.response?.statusCode;
    return statusCode == null ||
        statusCode == 408 ||
        statusCode == 429 ||
        statusCode >= 500;
  }

  _ContentRange? _parseContentRange(String? value) {
    if (value == null) return null;
    final match = RegExp(
      r'^bytes (\d+)-(\d+)/(\d+|\*)$',
    ).firstMatch(value.trim());
    if (match == null) return null;
    return _ContentRange(
      start: int.parse(match.group(1)!),
      end: int.parse(match.group(2)!),
      total: match.group(3) == '*' ? null : int.parse(match.group(3)!),
    );
  }

  void _updateProgress({
    required int session,
    required int received,
    required int writeOffset,
    required int totalSize,
  }) {
    if (!_isActiveSession(session)) return;
    final currentTotal = writeOffset + received;
    final progress = totalSize > 0
        ? (currentTotal / totalSize).clamp(0.0, 1.0)
        : null;
    final percent = progress == null ? -1 : (progress * 100).floor();
    final now = DateTime.now();
    final shouldNotify =
        _lastProgressAt == null ||
        now.difference(_lastProgressAt!) >= const Duration(milliseconds: 200) ||
        percent >= _lastProgressPercent + 1 ||
        progress == 1.0;
    if (!shouldNotify) return;

    _lastProgressAt = now;
    _lastProgressPercent = percent;
    if (progress != null) progressNotifier.value = progress;
    _emit(UpgraderEventType.downloadProgress, '下载进度', {
      'sessionId': session,
      'currentTotal': currentTotal,
      'totalSize': totalSize,
      'progress': progress,
    });
  }

  Future<bool> _hasZipHeader(File file) async {
    final bytes = await file.openRead(0, 4).first;
    if (bytes.length < 4 || bytes[0] != 0x50 || bytes[1] != 0x4b) {
      return false;
    }
    return (bytes[2] == 0x03 && bytes[3] == 0x04) ||
        (bytes[2] == 0x05 && bytes[3] == 0x06) ||
        (bytes[2] == 0x07 && bytes[3] == 0x08);
  }

  bool _isActiveSession(int session) => _activeDownloadSession == session;

  String _redactUrl(String value) {
    final uri = Uri.tryParse(value);
    if (uri == null || !uri.hasQuery) return value;
    return uri.replace(query: null).toString();
  }

  void _safeCallback(void Function() callback) {
    try {
      callback();
    } catch (error, stackTrace) {
      if (_isDebugging) {
        debugPrint('[TinyUpgrader] callback error: $error\n$stackTrace');
      }
    }
  }

  void _safeErrorCallback(Object error) {
    final callback = _errorHandler;
    if (callback != null) _safeCallback(() => callback(error));
  }

  /// 默认的 API 响应解析器
  static Future<VersionInfo> _defaultParser(dynamic data) async {
    return VersionInfo.fromMap((data as Map<String, dynamic>)['data']);
  }

  void _ensureAndroid() {
    if (!Platform.isAndroid) {
      throw UnsupportedError('TinyUpgrader only supports Android');
    }
  }

  void _ensureInitialized() {
    if (!_initialized) {
      throw StateError('TinyUpgrader.init() must be called before use');
    }
  }

  /// 统一的日志/事件发射方法。
  ///
  /// 业务事件始终触发回调；[_enableLog] 只控制通用 [UpgraderEventType.log]。
  /// 同时，如果 [_isDebugging] 为 `true`，会通过 [debugPrint] 输出到控制台。
  void _emit(
    UpgraderEventType type,
    String message, [
    Map<String, dynamic>? data,
  ]) {
    if (_isDebugging) {
      debugPrint('[TinyUpgrader] ${type.name}: $message');
    }
    final callback = _onEvent;
    if (callback != null && (type != UpgraderEventType.log || _enableLog)) {
      _safeCallback(
        () => callback(UpgraderEvent(type: type, message: message, data: data)),
      );
    }
  }
}

class _ContentRange {
  final int start;
  final int end;
  final int? total;

  const _ContentRange({
    required this.start,
    required this.end,
    required this.total,
  });
}
