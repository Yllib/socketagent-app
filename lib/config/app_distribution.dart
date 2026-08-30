enum AppDistribution { direct, play }

abstract final class AppBuild {
  static const distributionName = String.fromEnvironment(
    'SOCKETAGENT_DISTRIBUTION',
    defaultValue: 'direct',
  );

  static const distribution = distributionName == 'play'
      ? AppDistribution.play
      : AppDistribution.direct;

  static const supportsSelfUpdates = distribution == AppDistribution.direct;
  static const supportsApkInstalls = true;
  static const supportsPlayBilling = distribution == AppDistribution.play;
  static const supportsExactAlarms = distribution == AppDistribution.direct;
  static const supportsSystemOverlays = distribution == AppDistribution.direct;
}
