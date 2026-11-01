import 'dart:io';

import '../../models/server_build_info.dart';
import '../../models/server_config.dart';
import '../../services/chat_provider.dart';
import '../../services/device_auth.dart';
import '../../services/websocket_service.dart' show ConnectionStatus;
import '../../services/account_crypto.dart' show formatFingerprintCode;

/// What the Computers tab shows for one computer, read once per build so the
/// rows stay pure and renderable without a provider.
class ComputerSummary {
  const ComputerSummary({
    required this.config,
    required this.status,
    this.auth = DeviceAuthState.idle,
    this.runningCount = 0,
    this.waitingCount = 0,
    this.sessionCount = 0,
    this.version,
    this.pushRegistered,
    this.warnings = const [],
    this.limitedInstall = false,
  });

  final ServerConfig config;
  final ConnectionStatus status;
  final DeviceAuthState auth;

  /// Sessions with a run in progress on this computer.
  final int runningCount;

  /// Sessions waiting on the user, such as an open question or approval.
  final int waitingCount;
  final int sessionCount;

  /// SocketAgent server version, when the computer has reported one.
  final String? version;

  /// Whether this phone receives push from the computer. Null when push does
  /// not apply: not Android, disabled for this computer, or offline.
  final bool? pushRegistered;

  /// Backend and config problems, one line each.
  final List<String> warnings;

  /// A Windows computer set up without administrator rights.
  final bool limitedInstall;

  String get id => config.id;
  String get name => config.name;
  bool get online => status == ConnectionStatus.connected;

  /// The direct address, or empty when only the relay is known.
  String get address =>
      config.host.isEmpty ? '' : '${config.host}:${config.port}';

  /// The status word beside the name. Anything short of connected reads as
  /// offline: the connection manager retries on its own, so "connecting" and
  /// "connection error" only describe its retry loop.
  String get statusLabel {
    if (online) return config.useRelay ? 'connected via relay' : 'connected';
    if (auth.awaitingApproval) {
      return 'waiting for approval, code ${formatFingerprintCode(auth.code)}';
    }
    return config.expectedOnline ? 'offline, expected online' : 'offline';
  }
}

/// One summary per configured computer, online ones first, each group in the
/// owner's order. Push state is
/// reported only where push applies, Android unless [pushApplies] says so.
List<ComputerSummary> computerSummaries(
  ChatProvider provider, {
  bool? pushApplies,
}) {
  final activeServerId =
      provider.activeSessionServerId ?? provider.connMgr.activeServerId;
  final push = pushApplies ?? Platform.isAndroid;
  final all = [
    for (final config in provider.serverConfigs)
      _summarize(provider, config, activeServerId, pushApplies: push),
  ];
  return [...all.where((c) => c.online), ...all.where((c) => !c.online)];
}

ComputerSummary _summarize(
  ChatProvider provider,
  ServerConfig config,
  String? activeServerId, {
  required bool pushApplies,
}) {
  final status = provider.connMgr.statusOf(config.id);
  final online = status == ConnectionStatus.connected;
  final sessions = provider.sessions.where((s) => s.serverId == config.id);
  var running = 0;
  var waiting = 0;
  for (final session in sessions) {
    final isActive =
        session.id == provider.activeSessionId &&
        (session.serverId.isEmpty || session.serverId == activeServerId);
    if (online && isActive && provider.requiresAction) {
      waiting += 1;
    } else if (online &&
        (session.running ||
            (isActive && (provider.isProcessing || provider.isCompacting)))) {
      running += 1;
    }
  }
  final warning = provider.backendWarningForServer(config.id);
  final warningLabel = warning?['label']?.toString();
  final warningDetail = warning?['reason']?.toString();
  final build = ServerBuildInfo.fromRuntime(
    provider.serverRuntimeInfo(config.id),
  );
  return ComputerSummary(
    config: config,
    status: status,
    auth: provider.deviceAuthFor(config.id),
    runningCount: running,
    waitingCount: waiting,
    sessionCount: sessions.length,
    version: build.versionLabel.isEmpty ? null : build.versionLabel,
    pushRegistered:
        !pushApplies || !online || provider.isPushDisabledForServer(config.id)
        ? null
        : provider.isPushRegisteredForServer(config.id),
    warnings: [
      if (warningLabel != null && warningLabel.isNotEmpty)
        warningDetail == null || warningDetail.isEmpty
            ? warningLabel
            : '$warningLabel: $warningDetail',
      for (final issue in provider.issuesForServer(config.id))
        issue.backend.isEmpty
            ? issue.message
            : '${issue.backend}: ${issue.message}',
    ],
    limitedInstall: provider.isLimitedWindowsInstall(config.id),
  );
}
