import 'package:app/config/app_distribution.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('self-updates are available only in the direct distribution', () {
    expect(
      AppBuild.supportsSelfUpdates,
      AppBuild.distribution == AppDistribution.direct,
    );
  });

  test('Play Billing is available only in the Play distribution', () {
    expect(
      AppBuild.supportsPlayBilling,
      AppBuild.distribution == AppDistribution.play,
    );
  });
}
