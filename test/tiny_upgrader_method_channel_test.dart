import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tiny_upgrader/install_result.dart';
import 'package:tiny_upgrader/upgrader_method_channel.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  MethodChannelTinyUpgrader platform = MethodChannelTinyUpgrader();
  const MethodChannel channel = MethodChannel('tiny_upgrader');

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
          return switch (methodCall.method) {
            'getPlatformVersion' => '42',
            'installApk' => 'permissionRequired',
            'canRequestPackageInstalls' => true,
            'getAvailableStorageBytes' => 1024,
            'openInstallPermissionSettings' => null,
            _ => throw MissingPluginException(),
          };
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('getPlatformVersion', () async {
    expect(await platform.getPlatformVersion(), '42');
  });

  test('returns structured install status', () async {
    final result = await platform.installApk('/tmp/update.apk');
    expect(result.status, InstallStatus.permissionRequired);
  });

  test('exposes permission and storage methods', () async {
    expect(await platform.canRequestPackageInstalls(), isTrue);
    expect(await platform.getAvailableStorageBytes('/tmp'), 1024);
    await platform.openInstallPermissionSettings();
  });
}
