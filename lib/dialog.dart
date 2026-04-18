import 'package:flutter/material.dart';
import 'package:tiny_upgrader/upgrader.dart';
import 'package:tiny_upgrader/update_info.dart';

class MyUpdateDialog extends StatelessWidget {
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
  Widget build(BuildContext context) {
    final latestVersion = updateInfo.latestVersion!;
    final isForced = latestVersion.updateStrategy == UpdateStrategy.forced;

    return AlertDialog(
      title: const Text('发现新版本'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('最新版本: ${latestVersion.version}+${latestVersion.buildVersion}'),
          const SizedBox(height: 8),
          Text(latestVersion.modifyContent),
          const SizedBox(height: 16),
          ValueListenableBuilder<DownloadStatus>(
            valueListenable: statusNotifier,
            builder: (context, status, _) {
              switch (status) {
                case DownloadStatus.downloading:
                case DownloadStatus.paused:
                  return ValueListenableBuilder<double>(
                    valueListenable: progressNotifier,
                    builder: (context, progress, _) {
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          LinearProgressIndicator(value: progress),
                          const SizedBox(height: 4),
                          Text(
                            '${(progress * 100).toStringAsFixed(1)}%',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                      );
                    },
                  );
                case DownloadStatus.finished:
                  return const Text(
                    '下载完成，可以安装了！',
                    style: TextStyle(color: Colors.green),
                  );
                case DownloadStatus.error:
                  return const Text(
                    '下载失败，请重试',
                    style: TextStyle(color: Colors.red),
                  );
                case DownloadStatus.none:
                  return const SizedBox.shrink();
              }
            },
          ),
        ],
      ),
      actions: [
        if (!isForced)
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('以后再说'),
          ),
        ValueListenableBuilder<DownloadStatus>(
          valueListenable: statusNotifier,
          builder: (context, status, _) {
            return TextButton(
              onPressed: () => _onActionPressed(status),
              child: Text(_getButtonText(status)),
            );
          },
        ),
      ],
    );
  }

  void _onActionPressed(DownloadStatus status) {
    switch (status) {
      case DownloadStatus.none:
      case DownloadStatus.error:
        TinyUpgrader.instance.startDownload();
        break;
      case DownloadStatus.downloading:
        TinyUpgrader.instance.pauseDownload();
        break;
      case DownloadStatus.paused:
        TinyUpgrader.instance.startDownload();
        break;
      case DownloadStatus.finished:
        TinyUpgrader.instance.install();
        break;
    }
  }

  String _getButtonText(DownloadStatus status) {
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
}
