# TinyUpgrader Example

这个 App 展示 TinyUpgrader 的默认更新弹窗、强制更新页面、下载控制、安装流程和结构化事件日志。

## 运行

连接 Android 设备后执行：

```bash
flutter run
```

默认服务地址仅为占位值。可通过编译参数传入自己的更新服务：

```bash
flutter run \
  --dart-define=TINY_UPGRADER_BASE_URL=https://your-update-service.example/
```

App 启动后：

- 点击“更新测试”请求最新版本并显示更新 UI。
- 在弹窗中开始、暂停或继续下载。
- 使用“重置状态”取消当前任务并清理下载状态。
- 页面下方会展示检查、下载、校验和安装事件。

Android 13 及以上首次运行会请求通知权限，以便在通知栏展示前台下载进度。

Git 仓库中的 `example/tool/run_foreground_download_test.py` 可以启动真实 example App 和本机模拟更新服务，无需部署后端；该维护脚本不会包含在 pub.dev 发布包中。
