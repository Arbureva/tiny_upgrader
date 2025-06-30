import 'package:flutter/material.dart';
import 'package:tiny_upgrader/upgrader.dart';
import 'package:tiny_upgrader/update_info.dart';

class MyUpdateDialog extends StatefulWidget {
  final UpdateInfo updateInfo;
  final ValueNotifier<DownloadStatus> statusNotifier;
  final ValueNotifier<double> progressNotifier;

  const MyUpdateDialog({
    super.key,
    required this.updateInfo,
    required this.statusNotifier,
    required this.progressNotifier,
  });

  @override
  State<MyUpdateDialog> createState() => _MyUpdateDialogState();
}

class _MyUpdateDialogState extends State<MyUpdateDialog> {
  @override
  Widget build(BuildContext context) {
    final latestVersion = widget.updateInfo.latestVersion!;

    return AlertDialog(
      title: const Text('发现新版本'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text("最新版本: ${latestVersion.version}"),
          const SizedBox(height: 8),
          Text("${latestVersion.modifyContent}"),
          const SizedBox(height: 16),
          // 使用 ValueListenableBuilder 来监听并根据状态和进度构建UI
          ValueListenableBuilder<DownloadStatus>(
            valueListenable: widget.statusNotifier,
            builder: (context, status, child) {
              // 根据不同状态显示不同内容
              switch (status) {
                case DownloadStatus.downloading:
                case DownloadStatus.paused:
                  return ValueListenableBuilder<double>(
                    valueListenable: widget.progressNotifier,
                    builder: (context, progress, child) {
                      return LinearProgressIndicator(value: progress);
                    },
                  );
                case DownloadStatus.finished:
                  return const Text('下载完成，可以安装了！', style: TextStyle(color: Colors.green));
                case DownloadStatus.error:
                  return const Text('下载失败，请重试', style: TextStyle(color: Colors.red));
                default: // none
                  return const SizedBox.shrink();
              }
            },
          ),
        ],
      ),
      actions: [
        if (latestVersion.updateStatus != UpdateStatus.mustUpToDate)
          TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('以后再说')),
        // 使用 ValueListenableBuilder 来构建操作按钮
        ValueListenableBuilder<DownloadStatus>(
          valueListenable: widget.statusNotifier,
          builder: (context, status, child) {
            return TextButton(
              onPressed: () {
                switch (status) {
                  case DownloadStatus.none:
                  case DownloadStatus.error:
                    TinyUpgrader.instance.startDownload();
                    break;
                  case DownloadStatus.downloading:
                    TinyUpgrader.instance.pauseDownload();
                    break;
                  case DownloadStatus.paused:
                    TinyUpgrader.instance.startDownload(); // 恢复下载
                    break;
                  case DownloadStatus.finished:
                    TinyUpgrader.instance.install();
                    break;
                }
              },
              child: Text(getButtonText(status)),
            );
          },
        ),
      ],
    );
  }
}

String getButtonText(DownloadStatus status) {
  switch (status) {
    case DownloadStatus.none:
    case DownloadStatus.error:
      return '立即更新';
    case DownloadStatus.downloading:
      return '暂停';
    case DownloadStatus.paused:
      return '继续下载';
    case DownloadStatus.finished:
      return '立即安装';
  }
}

Icon getButtonIcon(DownloadStatus status) {
  switch (status) {
    case DownloadStatus.none:
    case DownloadStatus.error:
      return const Icon(Icons.download);
    case DownloadStatus.downloading:
      return const Icon(Icons.pause);
    case DownloadStatus.paused:
      return const Icon(Icons.play_arrow);
    case DownloadStatus.finished:
      return const Icon(Icons.update);
  }
}
