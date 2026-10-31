import 'package:flutter/material.dart';

import '../../models/computer_access.dart';
import '../../models/message.dart';

/// Where a computer's connection stands, flattened for the fleet strip.
enum LinkState { connected, connecting, offline, error }

/// One computer in the fleet, with the counts the strip and board show.
class FleetComputer {
  const FleetComputer({
    required this.id,
    required this.name,
    required this.color,
    required this.link,
    required this.running,
    required this.waiting,
    this.expectedOnline = false,
    this.harnesses = const ['claude'],
    this.version = '',
    this.issues = 0,
  });

  final String id;
  final String name;
  final Color color;
  final LinkState link;

  /// Sessions running on this computer right now.
  final int running;

  /// Items on this computer waiting for the user.
  final int waiting;
  final bool expectedOnline;
  final List<String> harnesses;
  final String version;
  final int issues;

  bool get isConnected => link == LinkState.connected;

  /// Two or three letters for a chip when the full name will not fit.
  String get shortName {
    final words = name
        .split(RegExp(r'[\s_\-]+'))
        .where((word) => word.isNotEmpty)
        .toList();
    if (words.length >= 2) {
      return (words[0][0] + words[1][0]).toUpperCase();
    }
    return name.length <= 3 ? name.toUpperCase() : name.substring(0, 3);
  }
}

/// A session's state in one word, as the board and lists show it.
enum SessionPhase {
  waitingOnUser,
  running,
  compacting,
  waitingOnAgent,
  unreadFinished,
  idle,
  offline,
}

/// Live facts about a session the [Session] model does not carry.
class SessionLive {
  const SessionLive({
    required this.phase,
    this.startedAt,
    this.pinned = false,
    this.muted = false,
    this.children = 0,
    this.lastFinishedOutcome,
  });

  final SessionPhase phase;

  /// When the current run began. Null unless running or compacting.
  final DateTime? startedAt;
  final bool pinned;
  final bool muted;

  /// Delegated child sessions still running.
  final int children;

  /// Outcome of the last completed run: completed, stopped, failed.
  final String? lastFinishedOutcome;

  bool get isRunning =>
      phase == SessionPhase.running || phase == SessionPhase.compacting;
}

/// What kind of thing the user has to act on.
enum InboxKind {
  question,
  toolApproval,
  secret,
  computerAccess,
  device,
  signIn,
  review,
  taskResult,
  delivery,
}

/// One item waiting on the user. The board lists these first, newest wait
/// first, and most can be answered in place.
class InboxItem {
  const InboxItem({
    required this.id,
    required this.kind,
    required this.serverId,
    required this.computerName,
    required this.sessionId,
    required this.sessionTitle,
    required this.title,
    required this.since,
    this.detail = '',
    this.expiresAt,
    this.message,
    this.access,
    this.options = const [],
    this.deliverable = true,
    this.payload,
  });

  final String id;
  final InboxKind kind;
  final String serverId;
  final String computerName;
  final String sessionId;
  final String sessionTitle;
  final String title;
  final String detail;
  final DateTime since;
  final DateTime? expiresAt;

  /// The transcript card behind the item, when it is one.
  final ChatMessage? message;
  final ComputerAccessRequest? access;

  /// Short answers the board can offer inline.
  final List<String> options;

  /// False when the computer is offline, so an answer cannot reach it.
  final bool deliverable;

  /// Kind-specific extra, such as a scheduled task or review id.
  final Object? payload;

  bool get canAnswerInline => options.isNotEmpty && options.length <= 3;
}

/// What a child agent, background command, monitor or workflow looks like in
/// the activity dock.
enum ActivityKind { subagent, delegated, command, monitor, workflow }

enum ActivityStatus {
  pending,
  running,
  paused,
  completed,
  failed,
  stopped,
  unknown;

  bool get isLive => this == running || this == pending || this == paused;

  static ActivityStatus parse(Object? raw) => switch (raw?.toString()) {
    'pending' => pending,
    'running' || 'started' || 'monitoring' => running,
    'paused' => paused,
    'completed' || 'success' => completed,
    'failed' || 'errored' || 'error' || 'timed_out' => failed,
    'killed' || 'stopped' || 'interrupted' || 'shutdown' => stopped,
    _ => unknown,
  };
}

class ActivityItem {
  const ActivityItem({
    required this.key,
    required this.kind,
    required this.title,
    required this.status,
    this.detail = '',
    this.lastTool = '',
    this.startedAt,
    this.tokens,
    this.toolUses,
    this.canStop = false,
    this.canDismiss = false,
    this.backgrounded = false,
    this.childSessionId,
    this.phases = const [],
  });

  final String key;
  final ActivityKind kind;
  final String title;
  final ActivityStatus status;
  final String detail;
  final String lastTool;
  final DateTime? startedAt;
  final int? tokens;
  final int? toolUses;
  final bool canStop;
  final bool canDismiss;
  final bool backgrounded;

  /// For a delegated full session: the child session to open.
  final String? childSessionId;
  final List<String> phases;
}

/// One step of a Codex plan or a Claude task list.
class PlanStep {
  const PlanStep({required this.key, required this.text, required this.status});

  final String key;
  final String text;

  /// pending, in_progress, completed.
  final String status;
}

/// Context window use for the gauge in the session header.
class ContextGauge {
  const ContextGauge({
    required this.used,
    required this.total,
    this.categories = const [],
  });

  final int used;
  final int total;
  final List<({String name, int tokens})> categories;

  double get fraction => total <= 0 ? 0 : (used / total).clamp(0, 1);
}

/// A rate or usage limit the harness reported.
class LimitNotice {
  const LimitNotice({
    required this.label,
    required this.percent,
    this.resetsAt,
    this.rejected = false,
  });

  final String label;
  final double? percent;
  final DateTime? resetsAt;
  final bool rejected;
}

/// A model the computer offers for the session.
class ModelChoice {
  const ModelChoice({
    required this.id,
    required this.label,
    this.current = false,
  });

  final String id;
  final String label;
  final bool current;
}

/// How a queued message should reach a busy agent.
enum SendPriority {
  now('Now', 'Interrupts the current step'),
  next('Next', 'After the current step'),
  later('Later', 'After the whole run');

  const SendPriority(this.label, this.hint);
  final String label;
  final String hint;

  String? get wire => switch (this) {
    now => 'now',
    next => 'next',
    later => 'later',
  };
}

/// Permission modes with the label and one-line meaning the composer shows.
class PermissionModeInfo {
  const PermissionModeInfo(this.id, this.label, this.meaning);

  final String id;
  final String label;
  final String meaning;

  static const claude = [
    PermissionModeInfo(
      'bypassPermissions',
      'Auto',
      'Auto-approve, ask on safety checks',
    ),
    PermissionModeInfo('superYolo', 'Auto+', 'Auto-approve everything'),
    PermissionModeInfo('auto', 'Smart', 'Classifier approves safe actions'),
    PermissionModeInfo(
      'acceptEdits',
      'Edits',
      'Auto-approve edits, ask for commands',
    ),
    PermissionModeInfo('default', 'Ask', 'Ask before risky actions'),
    PermissionModeInfo('plan', 'Plan', 'Plan only, no changes'),
  ];

  static const codex = [
    PermissionModeInfo(
      'bypassPermissions',
      'Auto',
      'Auto-approve except protected files',
    ),
    PermissionModeInfo('superYolo', 'Auto+', 'Auto-approve everything'),
    PermissionModeInfo(
      'default',
      'Ask',
      'Ask before commands and file changes',
    ),
    PermissionModeInfo('plan', 'Read', 'Read only'),
  ];

  static List<PermissionModeInfo> forBackend(String? backend) =>
      backend == 'codex' ? codex : claude;

  static PermissionModeInfo describe(String? id, String? backend) {
    final list = forBackend(backend);
    return list.where((mode) => mode.id == id).firstOrNull ??
        PermissionModeInfo(id ?? '', id ?? 'Mode', '');
  }
}
