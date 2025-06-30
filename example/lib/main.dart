import 'package:flutter/material.dart';
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

  @override
  void initState() {
    super.initState();
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
    );
    initPlatformState();
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: Column(
        children: [
          Text('测试平台: $_platformVersion'),
          ElevatedButton(onPressed: _checkForUpdate, child: Text('更新测试')),
        ],
      ),
    );
  }
}
