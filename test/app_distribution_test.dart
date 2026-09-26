import 'package:app/config/app_distribution.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('direct and Windows distributions support self-updates', () {
    expect(
      AppBuild.supportsSelfUpdates,
      AppBuild.distribution != AppDistribution.play,
    );
  });

  test('APK installs are available on Android distributions', () {
    expect(
      AppBuild.supportsApkInstalls,
      AppBuild.distribution != AppDistribution.windows,
    );
  });

  test('Play Billing is available only in the Play distribution', () {
    expect(
      AppBuild.supportsPlayBilling,
      AppBuild.distribution == AppDistribution.play,
    );
  });
}
