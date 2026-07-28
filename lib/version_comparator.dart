/// Compares numeric dotted versions such as `1.2`, `1.2.0`, and `v1.2.0`.
class VersionComparator {
  const VersionComparator._();

  /// Returns a negative value when [left] is older, zero when equivalent,
  /// and a positive value when [left] is newer than [right].
  static int compare(String left, String right) {
    final leftParts = _parse(left);
    final rightParts = _parse(right);
    final length = leftParts.length > rightParts.length
        ? leftParts.length
        : rightParts.length;

    for (var index = 0; index < length; index++) {
      final leftPart = index < leftParts.length
          ? leftParts[index]
          : BigInt.zero;
      final rightPart = index < rightParts.length
          ? rightParts[index]
          : BigInt.zero;
      final comparison = leftPart.compareTo(rightPart);
      if (comparison != 0) return comparison;
    }
    return 0;
  }

  /// Returns whether the candidate version/build is strictly newer.
  static bool isUpdateAvailable({
    required String candidateVersion,
    required int candidateBuildNumber,
    required String currentVersion,
    required String currentBuildNumber,
  }) {
    if (candidateBuildNumber < 0) {
      throw FormatException(
        'Invalid candidate build number: $candidateBuildNumber',
      );
    }
    final parsedCurrentBuild = int.tryParse(currentBuildNumber);
    if (parsedCurrentBuild == null || parsedCurrentBuild < 0) {
      throw FormatException(
        'Invalid current build number: $currentBuildNumber',
      );
    }

    final versionComparison = compare(candidateVersion, currentVersion);
    if (versionComparison != 0) return versionComparison > 0;
    return candidateBuildNumber > parsedCurrentBuild;
  }

  static List<BigInt> _parse(String value) {
    final normalized = value.trim().replaceFirst(RegExp(r'^[vV]'), '');
    if (!RegExp(r'^\d+(?:\.\d+)*$').hasMatch(normalized)) {
      throw FormatException('Invalid version: "$value"');
    }
    return normalized.split('.').map(BigInt.parse).toList(growable: false);
  }
}
