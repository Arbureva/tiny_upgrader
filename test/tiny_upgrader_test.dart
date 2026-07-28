import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:tiny_upgrader/foreground_download.dart';
import 'package:tiny_upgrader/upgrader_platform_interface.dart';
import 'package:tiny_upgrader/upgrader_method_channel.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:tiny_upgrader/install_result.dart';

class MockTinyUpgraderPlatform
    with MockPlatformInterfaceMixin
    implements TinyUpgraderPlatform {
  @override
  Future<String?> getPlatformVersion() => Future.value('42');

  @override
  Future<InstallResult> installApk(String filePath) async {
    return const InstallResult(InstallStatus.installerLaunched);
  }

  @override
  Future<bool> canRequestPackageInstalls() async => true;

  @override
  Future<void> openInstallPermissionSettings() async {}

  @override
  Future<int> getAvailableStorageBytes(String directoryPath) async =>
      1024 * 1024 * 1024;

  @override
  Stream<ForegroundDownloadEvent> get foregroundDownloadEvents =>
      const Stream.empty();

  @override
  Future<void> startForegroundDownload(
    ForegroundDownloadRequest request,
  ) async {}

  @override
  Future<void> pauseForegroundDownload() async {}

  @override
  Future<void> cancelForegroundDownload({bool deleteFile = true}) async {}

  @override
  Future<ForegroundDownloadEvent> getForegroundDownloadState() async =>
      const ForegroundDownloadEvent(
        type: ForegroundDownloadEventType.state,
        state: ForegroundDownloadState.none,
      );
}

void main() {
  final TinyUpgraderPlatform initialPlatform = TinyUpgraderPlatform.instance;

  test('$MethodChannelTinyUpgrader is the default instance', () {
    expect(initialPlatform, isInstanceOf<MethodChannelTinyUpgrader>());
  });
}
