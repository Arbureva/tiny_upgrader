/// OSS (Alibaba Cloud Object Storage Service) configuration.
///
/// Supports two modes:
/// - **STS token**: Provide [accessKeyId], [accessKeySecret], and [securityToken].
///   Requests will be signed automatically.
/// - **Public-read**: Leave [accessKeyId] empty. No signing is performed, the
///   download URL is used directly.
class OssConfig {
  /// OSS AccessKeyId (from STS response or permanent AK).
  final String accessKeyId;

  /// OSS AccessKeySecret (from STS response or permanent AK).
  final String accessKeySecret;

  /// STS SecurityToken. `null` or empty for permanent AK or public-read.
  final String? securityToken;

  /// OSS endpoint, e.g. `"oss-cn-hangzhou.aliyuncs.com"`.
  final String endpoint;

  /// OSS bucket name.
  final String bucket;

  const OssConfig({
    required this.accessKeyId,
    required this.accessKeySecret,
    this.securityToken,
    required this.endpoint,
    required this.bucket,
  });

  /// Whether no credentials are provided (public-read bucket).
  bool get isPublicRead => accessKeyId.isEmpty;

  /// Whether an STS security token is in use.
  bool get useStsToken => securityToken != null && securityToken!.isNotEmpty;
}
