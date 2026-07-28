enum InstallStatus {
  permissionRequired,
  installerLaunched,
  fileNotFound,
  activityUnavailable,
  providerError,
  failed,
}

class InstallResult {
  final InstallStatus status;
  final String? message;

  const InstallResult(this.status, {this.message});

  bool get installerLaunched => status == InstallStatus.installerLaunched;
}
