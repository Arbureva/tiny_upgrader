import 'dart:io';

import 'package:crypto/crypto.dart';

/// Supported APK digest algorithms.
enum ApkHashAlgorithm {
  md5,
  sha256;

  static ApkHashAlgorithm parse(String? value) {
    switch (value?.trim().toLowerCase().replaceAll('-', '')) {
      case null:
      case '':
      case 'md5':
        return ApkHashAlgorithm.md5;
      case 'sha256':
        return ApkHashAlgorithm.sha256;
      default:
        throw FormatException('Unsupported APK hash algorithm: $value');
    }
  }
}

/// Calculates a file digest without loading the complete file into memory.
Future<String> computeFileHash(
  File file, {
  ApkHashAlgorithm algorithm = ApkHashAlgorithm.md5,
}) async {
  final hash = switch (algorithm) {
    ApkHashAlgorithm.md5 => md5,
    ApkHashAlgorithm.sha256 => sha256,
  };
  final digest = await hash.bind(file.openRead()).first;
  return digest.toString();
}
