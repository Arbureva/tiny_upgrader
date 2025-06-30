import 'package:flutter_test/flutter_test.dart';
import 'package:tiny_upgrader/upgrader.dart';
import 'package:tiny_upgrader/upgrader_platform_interface.dart';
import 'package:tiny_upgrader/upgrader_method_channel.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

class MockTinyUpgraderPlatform with MockPlatformInterfaceMixin implements TinyUpgraderPlatform {
  @override
  Future<String?> getPlatformVersion() => Future.value('42');

  @override
  Future<bool> installApk(String filePath) async {
    print('testing');
    return true;
  }
}

void main() {
  final TinyUpgraderPlatform initialPlatform = TinyUpgraderPlatform.instance;

  test('$MethodChannelTinyUpgrader is the default instance', () {
    expect(initialPlatform, isInstanceOf<MethodChannelTinyUpgrader>());
  });
}
