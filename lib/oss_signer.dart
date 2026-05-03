import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:tiny_upgrader/oss_config.dart';

/// Generates OSS request signatures for authenticated downloads.
///
/// Implements the [OSS signature v1 algorithm](https://help.aliyun.com/document_detail/31951.html)
/// using HMAC-SHA1.
class OssSigner {
  /// Build the HTTP headers required to authenticate an OSS GET request.
  ///
  /// [config] holds the credentials and bucket/endpoint info.
  /// [downloadUrl] is the full OSS object URL (virtual-hosted or path style).
  /// [additionalHeaders] can include `Range` etc. — standard HTTP headers are
  /// passed through but only `x-oss-*` headers are included in the signature.
  static Map<String, String> generateHeaders({
    required OssConfig config,
    required String downloadUrl,
    String httpMethod = 'GET',
    Map<String, String>? additionalHeaders,
  }) {
    final Map<String, String> headers = {};

    final String date = HttpDate.format(DateTime.now().toUtc());
    headers['Date'] = date;

    if (config.useStsToken) {
      headers['x-oss-security-token'] = config.securityToken!;
    }

    if (additionalHeaders != null) {
      headers.addAll(additionalHeaders);
    }

    final String objectKey = _extractObjectKey(downloadUrl, config);
    final String canonicalizedResource = '/${config.bucket}/$objectKey';

    // Collect x-oss-* headers for signing (sorted, lowercased).
    final Map<String, String> ossHeaders = {};
    headers.forEach((key, value) {
      if (key.toLowerCase().startsWith('x-oss-')) {
        ossHeaders[key.toLowerCase()] = value.trim();
      }
    });
    final List<String> sortedKeys = ossHeaders.keys.toList()..sort();
    final String canonicalizedOssHeaders =
        sortedKeys.map((k) => '$k:${ossHeaders[k]}').join('\n');

    // Build StringToSign per OSS spec:
    //   VERB + "\n" +
    //   Content-MD5 + "\n" +
    //   Content-Type + "\n" +
    //   Date + "\n" +
    //   CanonicalizedOSSHeaders + "\n" +
    //   CanonicalizedResource
    final String stringToSign = [
      httpMethod,
      '', // Content-MD5 (empty for GET)
      '', // Content-Type (empty for GET)
      date,
      canonicalizedOssHeaders,
      canonicalizedResource,
    ].join('\n');

    // HMAC-SHA1 signature.
    final List<int> key = utf8.encode(config.accessKeySecret);
    final List<int> message = utf8.encode(stringToSign);
    final Hmac hmacSha1 = Hmac(sha1, key);
    final Digest digest = hmacSha1.convert(message);
    final String signature = base64.encode(digest.bytes);

    headers['Authorization'] = 'OSS ${config.accessKeyId}:$signature';

    return headers;
  }

  /// Extract the object key from a full OSS download URL.
  ///
  /// Supports virtual-hosted style (`bucket.endpoint/object`) and path style
  /// (`endpoint/bucket/object`).
  static String _extractObjectKey(String url, OssConfig config) {
    final Uri uri = Uri.parse(url);
    String path = uri.path;
    if (path.startsWith('/')) path = path.substring(1);

    // Virtual-hosted: https://{bucket}.{endpoint}/{objectKey}
    if (uri.host.startsWith('${config.bucket}.')) {
      return path;
    }

    // Path-style: https://{endpoint}/{bucket}/{objectKey}
    if (path.startsWith('${config.bucket}/')) {
      return path.substring(config.bucket.length + 1);
    }

    // Fallback for custom domains — return the path as-is.
    return path;
  }
}
