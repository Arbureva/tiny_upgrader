import 'package:tiny_upgrader/update_info.dart';

enum UpdateCheckFailureType { network, http, parsing, version, busy, unknown }

class UpgraderException implements Exception {
  final UpdateCheckFailureType type;
  final String message;
  final Object? cause;
  final int? statusCode;

  const UpgraderException({
    required this.type,
    required this.message,
    this.cause,
    this.statusCode,
  });

  @override
  String toString() => 'UpgraderException(${type.name}): $message';
}

sealed class UpdateCheckResult {
  const UpdateCheckResult();
}

final class UpdateAvailable extends UpdateCheckResult {
  final UpdateInfo info;

  const UpdateAvailable(this.info);
}

final class NoUpdate extends UpdateCheckResult {
  final UpdateInfo info;

  const NoUpdate(this.info);
}

final class UpdateCheckFailed extends UpdateCheckResult {
  final UpgraderException error;

  const UpdateCheckFailed(this.error);
}

final class UpdateUnsupported extends UpdateCheckResult {
  final String message;

  const UpdateUnsupported([
    this.message = 'TinyUpgrader only supports Android',
  ]);
}
