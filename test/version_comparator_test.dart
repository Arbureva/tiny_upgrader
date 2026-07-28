import 'package:flutter_test/flutter_test.dart';
import 'package:tiny_upgrader/version_comparator.dart';

void main() {
  group('VersionComparator', () {
    test('treats omitted zero segments as equivalent', () {
      expect(VersionComparator.compare('1.2', '1.2.0'), 0);
      expect(VersionComparator.compare('v1.2.0', '1.2'), 0);
    });

    test('only considers strictly newer versions an update', () {
      expect(
        VersionComparator.isUpdateAvailable(
          candidateVersion: '1.9.0',
          candidateBuildNumber: 19,
          currentVersion: '2.0.0',
          currentBuildNumber: '20',
        ),
        isFalse,
      );
      expect(
        VersionComparator.isUpdateAvailable(
          candidateVersion: '2.0',
          candidateBuildNumber: 21,
          currentVersion: '2.0.0',
          currentBuildNumber: '20',
        ),
        isTrue,
      );
    });

    test('reports invalid versions clearly', () {
      expect(
        () => VersionComparator.compare('release-1.2', '1.2.0'),
        throwsFormatException,
      );
      expect(
        () => VersionComparator.isUpdateAvailable(
          candidateVersion: '1.2.0',
          candidateBuildNumber: 2,
          currentVersion: '1.2.0',
          currentBuildNumber: 'invalid',
        ),
        throwsFormatException,
      );
    });
  });
}
