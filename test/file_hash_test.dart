import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tiny_upgrader/file_hash.dart';

void main() {
  test('computes MD5 and SHA-256 from a file stream', () async {
    final directory = await Directory.systemTemp.createTemp('tiny_upgrader_');
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/payload.bin');
    await file.writeAsString('tiny-upgrader');

    expect(await computeFileHash(file), 'a75fa92c580548bbeccbd8ab8e93cf56');
    expect(
      await computeFileHash(file, algorithm: ApkHashAlgorithm.sha256),
      '34943b8bf68ae68889e98fa106a3c868549d51969dfede48977bc160cfdc07fc',
    );
  });
}
