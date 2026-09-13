enum AppDistribution { direct, play, windows }

abstract final class AppBuild {
  static const distributionName = String.fromEnvironment(
    'SOCKETAGENT_DISTRIBUTION',
    defaultValue: 'direct',
  );

  static const distribution = distributionName == 'windows'
      ? AppDistribution.windows
      : distributionName == 'play'
      ? AppDistribution.play
      : AppDistribution.direct;

  static const supportsSelfUpdates = distribution == AppDistribution.direct;
  static const supportsApkInstalls = distribution != AppDistribution.windows;
  static const supportsPlayBilling = distribution == AppDistribution.play;
  static const supportsExactAlarms = distribution == AppDistribution.direct;
  static const supportsSystemOverlays = distribution == AppDistribution.direct;
}
