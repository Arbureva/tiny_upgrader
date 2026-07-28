import 'package:flutter/material.dart';
import 'package:tiny_upgrader/upgrader.dart';
import 'package:tiny_upgrader/update_info.dart';

/// Default full-screen page shown when a forced update is required.
///
/// Blocks all access to the underlying app — the user cannot dismiss this page
/// or navigate back until the APK is downloaded and installed.
class DefaultForcedUpdatePage extends StatefulWidget {
  final UpdateInfo updateInfo;
  final ValueNotifier<DownloadStatus> statusNotifier;
  final ValueNotifier<double> progressNotifier;
  final bool autoStartDownload;

  const DefaultForcedUpdatePage({
    super.key,
    required this.updateInfo,
    required this.statusNotifier,
    required this.progressNotifier,
    this.autoStartDownload = false,
  });

  @override
  State<DefaultForcedUpdatePage> createState() =>
      _DefaultForcedUpdatePageState();
}

class _DefaultForcedUpdatePageState extends State<DefaultForcedUpdatePage> {
  @override
  void initState() {
    super.initState();
    // Auto-start the download when the page first appears.
    if (!widget.autoStartDownload) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (widget.statusNotifier.value == DownloadStatus.none ||
          widget.statusNotifier.value == DownloadStatus.error) {
        TinyUpgrader.instance.startDownload();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final latest = widget.updateInfo.latestVersion!;
    final colors = Theme.of(context).colorScheme;

    return PopScope(
      canPop: false,
      child: Scaffold(
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 48),
            child: Column(
              children: [
                const Spacer(flex: 1),

                // App icon
                Icon(
                  Icons.system_update_rounded,
                  size: 64,
                  color: colors.primary,
                ),
                const SizedBox(height: 24),

                // Title
                Text(
                  '发现新版本',
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 8),

                // Version info
                Text(
                  'v${latest.version} (build ${latest.buildVersion})',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: colors.primary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 24),

                // Changelog
                if (latest.modifyContent.isNotEmpty) ...[
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: colors.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    constraints: const BoxConstraints(maxHeight: 120),
                    child: SingleChildScrollView(
                      child: Text(
                        latest.modifyContent,
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                    ),
                  ),
                ],

                const Spacer(flex: 1),

                // Download progress section
                ValueListenableBuilder<DownloadStatus>(
                  valueListenable: widget.statusNotifier,
                  builder: (context, status, _) {
                    return _ProgressSection(
                      status: status,
                      progressNotifier: widget.progressNotifier,
                      apkSize: latest.apkSize,
                    );
                  },
                ),

                const SizedBox(height: 32),

                // Action button
                ValueListenableBuilder<DownloadStatus>(
                  valueListenable: widget.statusNotifier,
                  builder: (context, status, _) {
                    return _ActionButton(status: status);
                  },
                ),

                const SizedBox(height: 16),

                // Hint text
                ValueListenableBuilder<DownloadStatus>(
                  valueListenable: widget.statusNotifier,
                  builder: (context, status, _) {
                    if (status == DownloadStatus.downloading ||
                        status == DownloadStatus.paused) {
                      return Text(
                        '更新完成前无法使用应用',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: colors.onSurface.withValues(alpha: 0.5),
                        ),
                      );
                    }
                    return const SizedBox.shrink();
                  },
                ),

                const Spacer(flex: 1),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Internal widget: download progress indicator.
class _ProgressSection extends StatelessWidget {
  final DownloadStatus status;
  final ValueNotifier<double> progressNotifier;
  final int apkSize;

  const _ProgressSection({
    required this.status,
    required this.progressNotifier,
    required this.apkSize,
  });

  @override
  Widget build(BuildContext context) {
    switch (status) {
      case DownloadStatus.none:
        return Text(
          '更新包大小: ${_formatSize(apkSize)}',
          style: Theme.of(context).textTheme.bodyLarge,
        );

      case DownloadStatus.downloading:
      case DownloadStatus.paused:
        return ValueListenableBuilder<double>(
          valueListenable: progressNotifier,
          builder: (context, progress, _) {
            return Column(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(value: progress, minHeight: 8),
                ),
                const SizedBox(height: 8),
                Text(
                  status == DownloadStatus.paused
                      ? '已暂停 — ${(progress * 100).toStringAsFixed(1)}%'
                      : '下载中 — ${(progress * 100).toStringAsFixed(1)}%',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ],
            );
          },
        );

      case DownloadStatus.finished:
        return const Column(
          children: [
            Icon(Icons.check_circle, color: Colors.green, size: 32),
            SizedBox(height: 8),
            Text('下载完成，可以安装了', style: TextStyle(color: Colors.green)),
          ],
        );

      case DownloadStatus.error:
        return const Column(
          children: [
            Icon(Icons.error_outline, color: Colors.red, size: 32),
            SizedBox(height: 8),
            Text('下载失败，请重试', style: TextStyle(color: Colors.red)),
          ],
        );
    }
  }

  static String _formatSize(int bytes) {
    if (bytes <= 0) return '未知';
    final mb = bytes / (1024 * 1024);
    return '${mb.toStringAsFixed(1)} MB';
  }
}

/// Internal widget: the main action button.
class _ActionButton extends StatelessWidget {
  final DownloadStatus status;

  const _ActionButton({required this.status});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      height: 48,
      child: FilledButton(onPressed: () => _handlePress(), child: Text(_label)),
    );
  }

  String get _label {
    switch (status) {
      case DownloadStatus.none:
      case DownloadStatus.error:
        return '立即更新';
      case DownloadStatus.downloading:
        return '暂停下载';
      case DownloadStatus.paused:
        return '继续下载';
      case DownloadStatus.finished:
        return '立即安装';
    }
  }

  void _handlePress() {
    switch (status) {
      case DownloadStatus.none:
      case DownloadStatus.error:
      case DownloadStatus.paused:
        TinyUpgrader.instance.startDownload();
        break;
      case DownloadStatus.downloading:
        TinyUpgrader.instance.pauseDownload();
        break;
      case DownloadStatus.finished:
        TinyUpgrader.instance.install();
        break;
    }
  }
}
