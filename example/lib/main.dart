import 'package:flutter/material.dart';
import 'package:tiny_upgrader/forced_update_page.dart';
import 'package:tiny_upgrader/oss_config.dart';
import 'package:tiny_upgrader/update_info.dart';
import 'package:tiny_upgrader/upgrader.dart';

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
        // 返回你自己的全屏拦截页 Widget
        // 这里演示使用默认页面
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
      // 获取平台版本，测试插件是否正常工作
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

      await _upgrader.check(context, url: checkUrl);
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: Column(
        children: [
          Text('测试平台: $_platformVersion'),
          const SizedBox(height: 16),
          ElevatedButton(onPressed: _checkForUpdate, child: const Text('更新测试')),
          const SizedBox(height: 24),
          Text('下载方式: ${_useOss ? "OSS (STS Token)" : "直链"}'),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              ElevatedButton(
                onPressed: !_useOss ? null : () => _toggleOss(false),
                child: const Text('切换到直链模式'),
              ),
              const SizedBox(width: 16),
              ElevatedButton(
                onPressed: _useOss ? null : () => _toggleOss(true),
                child: const Text('切换到 OSS 模式'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
