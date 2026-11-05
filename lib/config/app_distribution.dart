enum AppDistribution { direct, play, windows, ios }

abstract final class AppBuild {
  static const distributionName = String.fromEnvironment(
    'SOCKETAGENT_DISTRIBUTION',
    defaultValue: 'direct',
  );

  static const distribution = distributionName == 'windows'
      ? AppDistribution.windows
      : distributionName == 'ios'
      ? AppDistribution.ios
      : distributionName == 'play'
      ? AppDistribution.play
      : AppDistribution.direct;

  static const supportsApkInstalls =
      distribution == AppDistribution.direct ||
      distribution == AppDistribution.play;
  static const supportsPlayBilling = distribution == AppDistribution.play;
  static const supportsExactAlarms = distribution == AppDistribution.direct;
  static const supportsSystemOverlays = distribution == AppDistribution.direct;
}
