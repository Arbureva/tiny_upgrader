import 'package:flutter/material.dart';
import 'package:tiny_upgrader/forced_update_page.dart';
import 'package:tiny_upgrader/oss_config.dart';
import 'package:tiny_upgrader/update_info.dart';
import 'package:tiny_upgrader/update_check_result.dart';
import 'package:tiny_upgrader/upgrader.dart';
import 'package:tiny_upgrader/upgrader_event.dart';

void main() {
  runApp(MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'TinyUpgrader Demo',
      theme: ThemeData(primarySwatch: Colors.blue),
      home: MyHomePage(title: 'TinyUpgrader 示例'),
    );
  }
}

class MyHomePage extends StatefulWidget {
  const MyHomePage({super.key, required this.title});

  final String title;

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  final TinyUpgrader _upgrader = TinyUpgrader();
  String _platformVersion = '未知';
  bool _useOss = false;

  /// 收集的事件日志，用于在 UI 中展示
  final List<UpgraderEvent> _eventLogs = [];

  @override
  void initState() {
    super.initState();
    _initUpgrader(useOss: false);
    initPlatformState();
  }

  void _initUpgrader({required bool useOss}) {
    TinyUpgrader.init(
      isDebug: true,
      baseUrl: 'https://example:8080/',
      enableLog: true,
      onEvent: (event) {
        setState(() {
          _eventLogs.insert(0, event);
          // 最多保留 100 条，避免内存溢出
          if (_eventLogs.length > 100) {
            _eventLogs.removeLast();
          }
        });
        // 同时输出到控制台，方便调试
        debugPrint(event.toString());
      },
      errorHandler: (error) {
        debugPrint('出现错误: $error');
      },
      parser: (response) async {
        var res = VersionInfo.fromMap((response as Map<String, dynamic>)['data']);
        res.downloadUrl = '${res.downloadUrl}?token=123123';
        return res;
      },
      // 自定义强制更新拦截页（可选，不传则使用 DefaultForcedUpdatePage）
      forcedUpdatePageBuilder: (context, info, statusNotifier, progressNotifier) {
        return DefaultForcedUpdatePage(
          updateInfo: info,
          statusNotifier: statusNotifier,
          progressNotifier: progressNotifier,
        );
      },
      // OSS 配置示例（根据实际情况填写）
      ossConfig: useOss
          ? OssConfig(
              accessKeyId: 'STS.NJxxxxxx',
              accessKeySecret: 'B9xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx',
              securityToken: 'CAISxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx',
              endpoint: 'oss-cn-hangzhou.aliyuncs.com',
              bucket: 'your-bucket-name',
            )
          : null,
    );
  }

  /// 初始化平台状态
  Future<void> initPlatformState() async {
    String platformVersion;
    try {
      platformVersion = await _upgrader.getPlatformVersion() ?? '未知平台版本';
    } catch (e) {
      platformVersion = '获取平台版本失败: $e';
    }

    if (!mounted) return;

    setState(() {
      _platformVersion = platformVersion;
    });
  }

  /// 检查更新
  Future<void> _checkForUpdate() async {
    try {
      const String checkUrl = 'api/apk-manager-v1/latest?token=123123';

      final result = await _upgrader.check(context, url: checkUrl);
      if (!mounted) return;
      switch (result) {
        case UpdateAvailable():
          break;
        case NoUpdate():
          _showSnackBar('当前已是最新版本');
        case UpdateCheckFailed(:final error):
          _showSnackBar('检查更新失败: ${error.message}');
        case UpdateUnsupported(:final message):
          _showSnackBar(message);
      }
    } catch (e) {
      _showSnackBar('检查更新失败: $e');
    }
  }

  /// 显示提示信息
  void _showSnackBar(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message), duration: Duration(seconds: 3)));
  }

  void _toggleOss(bool useOss) {
    setState(() => _useOss = useOss);
    _initUpgrader(useOss: useOss);
  }

  void _toggleLog() {
    final newValue = !_upgrader.enableLog;
    _upgrader.enableLog = newValue;
    setState(() {
      if (newValue) {
        _showSnackBar('日志回调已开启');
      } else {
        _showSnackBar('日志回调已关闭');
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        actions: [
          // 日志开关按钮
          ValueListenableBuilder<DownloadStatus>(
            valueListenable: _upgrader.statusNotifier,
            builder: (_, __, ___) {
              final enabled = _upgrader.enableLog;
              return IconButton(
                icon: Icon(
                  enabled ? Icons.bug_report : Icons.bug_report_outlined,
                  color: enabled ? Colors.orange : null,
                ),
                tooltip: enabled ? '关闭日志' : '开启日志',
                onPressed: _toggleLog,
              );
            },
          ),
        ],
      ),
      body: Column(
        children: [
          // 控制区
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                Text('测试平台: $_platformVersion'),
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    ElevatedButton(
                      onPressed: _checkForUpdate,
                      child: const Text('更新测试'),
                    ),
                    const SizedBox(width: 16),
                    OutlinedButton(
                      onPressed: () => _upgrader.reset(),
                      child: const Text('重置状态'),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Text('下载方式: ${_useOss ? "OSS (STS Token)" : "直链"}'),
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    ElevatedButton(
                      onPressed: !_useOss ? null : () => _toggleOss(false),
                      child: const Text('直链模式'),
                    ),
                    const SizedBox(width: 16),
                    ElevatedButton(
                      onPressed: _useOss ? null : () => _toggleOss(true),
                      child: const Text('OSS 模式'),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const Divider(height: 1),

          // 事件日志列表
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                Text(
                  '事件日志 (${_eventLogs.length})',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                const Spacer(),
                TextButton(
                  onPressed: () => setState(() => _eventLogs.clear()),
                  child: const Text('清空'),
                ),
              ],
            ),
          ),
          Expanded(
            child: _eventLogs.isEmpty
                ? const Center(child: Text('暂无日志，点击"更新测试"开始'))
                : ListView.builder(
                    itemCount: _eventLogs.length,
                    itemBuilder: (context, index) {
                      final event = _eventLogs[index];
                      final color = _colorForType(event.type);
                      return ListTile(
                        dense: true,
                        leading: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: color.withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            event.type.name,
                            style: TextStyle(
                              fontSize: 11,
                              color: color,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        title: Text(
                          event.message,
                          style: const TextStyle(fontSize: 13),
                        ),
                        subtitle: event.data != null && event.data!.isNotEmpty
                            ? Text(
                                event.data.toString(),
                                style: const TextStyle(fontSize: 11),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              )
                            : null,
                        trailing: Text(
                          _formatTime(event.timestamp),
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Color _colorForType(UpgraderEventType type) {
    switch (type) {
      case UpgraderEventType.init:
        return Colors.teal;
      case UpgraderEventType.checkStart:
      case UpgraderEventType.checkResponse:
      case UpgraderEventType.checkCurrentVersion:
        return Colors.blue;
      case UpgraderEventType.checkNewVersion:
        return Colors.green;
      case UpgraderEventType.checkNoUpdate:
        return Colors.grey;
      case UpgraderEventType.checkError:
      case UpgraderEventType.downloadError:
      case UpgraderEventType.installError:
      case UpgraderEventType.validationFailed:
        return Colors.red;
      case UpgraderEventType.downloadStart:
      case UpgraderEventType.downloadProgress:
      case UpgraderEventType.downloadResume:
      case UpgraderEventType.downloadPaused:
        return Colors.blue;
      case UpgraderEventType.downloadComplete:
      case UpgraderEventType.installIntentLaunched:
      // ignore: deprecated_member_use
      case UpgraderEventType.installComplete:
      case UpgraderEventType.validationSuccess:
        return Colors.green;
      case UpgraderEventType.downloadConflict:
      case UpgraderEventType.downloadRetry:
        return Colors.orange;
      case UpgraderEventType.cleanOldFiles:
        return Colors.purple;
      case UpgraderEventType.validationStart:
      case UpgraderEventType.validationSkipped:
      case UpgraderEventType.installStart:
        return Colors.indigo;
      case UpgraderEventType.log:
        return Colors.grey;
    }
  }

  String _formatTime(DateTime time) {
    return '${time.hour.toString().padLeft(2, '0')}:'
        '${time.minute.toString().padLeft(2, '0')}:'
        '${time.second.toString().padLeft(2, '0')}';
  }
}
