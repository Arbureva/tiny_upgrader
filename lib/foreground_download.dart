enum ForegroundDownloadEventType {
  state,
  progress,
  retry,
  rangeReset,
  validation,
  paused,
  finished,
  error,
  cancelled;

  static ForegroundDownloadEventType parse(String? value) {
    return ForegroundDownloadEventType.values.firstWhere(
      (type) => type.name == value,
      orElse: () => ForegroundDownloadEventType.state,
    );
  }
}

enum ForegroundDownloadState {
  none,
  downloading,
  paused,
  finished,
  error;

  static ForegroundDownloadState parse(String? value) {
    return ForegroundDownloadState.values.firstWhere(
      (state) => state.name == value,
      orElse: () => ForegroundDownloadState.none,
    );
  }
}

class ForegroundDownloadRequest {
  final int sessionId;
  final String url;
  final String savePath;
  final Map<String, String> headers;
  final int expectedSize;
  final String expectedHash;
  final String hashAlgorithm;
  final int maxNetworkRetryCount;
  final int maxValidationRetryCount;
  final int minFreeSpaceMarginBytes;

  const ForegroundDownloadRequest({
    required this.sessionId,
    required this.url,
    required this.savePath,
    required this.headers,
    required this.expectedSize,
    required this.expectedHash,
    required this.hashAlgorithm,
    required this.maxNetworkRetryCount,
    required this.maxValidationRetryCount,
    required this.minFreeSpaceMarginBytes,
  });

  Map<String, Object> toMap() => {
    'sessionId': sessionId,
    'url': url,
    'savePath': savePath,
    'headers': headers,
    'expectedSize': expectedSize,
    'expectedHash': expectedHash,
    'hashAlgorithm': hashAlgorithm,
    'maxNetworkRetryCount': maxNetworkRetryCount,
    'maxValidationRetryCount': maxValidationRetryCount,
    'minFreeSpaceMarginBytes': minFreeSpaceMarginBytes,
  };
}

class ForegroundDownloadEvent {
  final ForegroundDownloadEventType type;
  final ForegroundDownloadState state;
  final int? sessionId;
  final String? savePath;
  final int downloadedBytes;
  final int totalBytes;
  final double? progress;
  final String? code;
  final String? message;
  final int networkRetryCount;
  final int validationRetryCount;

  const ForegroundDownloadEvent({
    required this.type,
    required this.state,
    this.sessionId,
    this.savePath,
    this.downloadedBytes = 0,
    this.totalBytes = 0,
    this.progress,
    this.code,
    this.message,
    this.networkRetryCount = 0,
    this.validationRetryCount = 0,
  });

  factory ForegroundDownloadEvent.fromMap(Map<Object?, Object?> map) {
    final downloadedBytes = (map['downloadedBytes'] as num?)?.toInt() ?? 0;
    final totalBytes = (map['totalBytes'] as num?)?.toInt() ?? 0;
    return ForegroundDownloadEvent(
      type: ForegroundDownloadEventType.parse(map['type'] as String?),
      state: ForegroundDownloadState.parse(map['state'] as String?),
      sessionId: (map['sessionId'] as num?)?.toInt(),
      savePath: map['savePath'] as String?,
      downloadedBytes: downloadedBytes,
      totalBytes: totalBytes,
      progress: totalBytes > 0
          ? (downloadedBytes / totalBytes).clamp(0.0, 1.0)
          : null,
      code: map['code'] as String?,
      message: map['message'] as String?,
      networkRetryCount: (map['networkRetryCount'] as num?)?.toInt() ?? 0,
      validationRetryCount: (map['validationRetryCount'] as num?)?.toInt() ?? 0,
    );
  }
}
