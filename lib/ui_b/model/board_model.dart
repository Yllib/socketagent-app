import 'package:flutter/material.dart';

import '../../models/message.dart';

/// Which lane of the board a session sits in. Order is display order.
enum SessionLane { needsMe, running, finished, idle }

String sessionLaneLabel(SessionLane lane) => switch (lane) {
  SessionLane.needsMe => 'Needs me',
  SessionLane.running => 'Running',
  SessionLane.finished => 'Finished',
  SessionLane.idle => 'Idle',
};

/// What the agent in a session is doing right now.
enum SessionActivity {
  idle,
  running,
  compacting,
  waitingOnUser,
  waitingOnAgent,
  offline,
}

/// How this device reaches a computer.
enum ComputerLink { connected, connecting, offline, error }

/// One computer on the strip at the top of the board.
class ComputerChip {
  const ComputerChip({
    required this.id,
    required this.name,
    required this.link,
    this.color,
    this.runningCount = 0,
    this.waitingCount = 0,
    this.expectedOnline = false,
    this.version,
    this.issueCount = 0,
    this.pushRegistered,
    this.viaRelay = false,
    this.issues = const [],
    this.sessionCount = 0,
    this.host = '',
    this.backends = const ['claude'],
    this.recentCwds = const [],
    this.defaultCwd,
  });

  final String id;
  final String name;
  final ComputerLink link;
  final Color? color;
  final int runningCount;
  final int waitingCount;
  final bool expectedOnline;
  final String? version;
  final int issueCount;

  /// Null when unknown.
  final bool? pushRegistered;
  final bool viaRelay;

  /// Problems the computer reported about its harnesses, as text.
  final List<String> issues;
  final int sessionCount;
  final String host;

  /// Harnesses the computer can run, for the new-session chooser.
  final List<String> backends;
  final List<String> recentCwds;
  final String? defaultCwd;

  bool get online => link == ComputerLink.connected;

  /// Offline when the user expects it online.
  bool get worrying => !online && expectedOnline;
}

/// One session row on the board. A pure snapshot; the board rebuilds these
/// from ChatProvider on every change.
class BoardSession {
  const BoardSession({
    required this.id,
    required this.serverId,
    required this.computerName,
    required this.title,
    required this.activity,
    required this.lastActive,
    this.computerColor,
    this.harness = 'claude',
    this.cwd = '',
    this.runStartedAt,
    this.turnCount = 0,
    this.preview = '',
    this.pinned = false,
    this.muted = false,
    this.fleeting = false,
    this.expiresAt,
    this.childCount = 0,
    this.parentId,
    this.fromScheduledTask = false,
    this.lastRunOutcome,
    this.unread = false,
    this.lastRunDuration,
    this.runCount = 0,
  });

  final String id;
  final String serverId;
  final String computerName;
  final Color? computerColor;
  final String title;
  final String harness;
  final String cwd;
  final SessionActivity activity;
  final DateTime? runStartedAt;
  final DateTime lastActive;
  final int turnCount;
  final String preview;
  final bool pinned;
  final bool muted;
  final bool fleeting;
  final DateTime? expiresAt;
  final int childCount;
  final String? parentId;
  final bool fromScheduledTask;

  /// completed, stopped or failed.
  final String? lastRunOutcome;

  /// A run finished since this device last opened the session.
  final bool unread;
  final Duration? lastRunDuration;
  final int runCount;

  String get key => '$serverId\u0001$id';
  bool get isChild => parentId != null;
  bool get busy =>
      activity == SessionActivity.running ||
      activity == SessionActivity.compacting;

  SessionLane get lane {
    if (activity == SessionActivity.waitingOnUser) return SessionLane.needsMe;
    if (busy || activity == SessionActivity.waitingOnAgent) {
      return SessionLane.running;
    }
    if (unread) return SessionLane.finished;
    return SessionLane.idle;
  }

  String get folderName {
    final trimmed = cwd.replaceAll(RegExp(r'[\\/]+$'), '');
    final parts = trimmed.split(RegExp(r'[\\/]'));
    return parts.isEmpty ? cwd : parts.last;
  }
}

/// Everything the agent, a computer or the app itself is waiting on the user
/// for. Each kind opens the same answer sheet with a different body.
enum InboxKind {
  question,
  toolApproval,
  secret,
  access,
  device,
  signIn,
  delivery,
  automation,
  review,
}

class InboxItem {
  const InboxItem({
    required this.id,
    required this.kind,
    required this.title,
    required this.since,
    this.detail = '',
    this.sessionId,
    this.serverId,
    this.sessionTitle = '',
    this.computerName = '',
    this.computerColor,
    this.expiresAt,
    this.deliverable = true,
    this.message,
    this.payload,
  });

  final String id;
  final InboxKind kind;
  final String title;
  final String detail;
  final DateTime since;
  final String? sessionId;
  final String? serverId;
  final String sessionTitle;
  final String computerName;
  final Color? computerColor;
  final DateTime? expiresAt;

  /// False when the computer that must receive the answer is offline.
  final bool deliverable;

  /// The transcript card behind a question, secret, access or sign-in item.
  final ChatMessage? message;

  /// Anything else the answer needs: a pending device, a task map, a request.
  final Object? payload;

  bool get fromSession => sessionId != null;
}

/// The whole board in one immutable snapshot.
class BoardModel {
  const BoardModel({
    this.computers = const [],
    this.inbox = const [],
    this.sessions = const [],
    this.automationUnread = 0,
    this.reviewsPending = 0,
    this.filesReceived = 0,
    this.browserWindows = 0,
    this.loading = false,
  });

  final List<ComputerChip> computers;
  final List<InboxItem> inbox;
  final List<BoardSession> sessions;
  final int automationUnread;
  final int reviewsPending;
  final int filesReceived;
  final int browserWindows;
  final bool loading;

  List<BoardSession> inLane(SessionLane lane) =>
      sessions.where((s) => s.lane == lane).toList();

  int get runningCount => inLane(SessionLane.running).length;
  int get needsMeCount => inbox.length + inLane(SessionLane.needsMe).length;
  bool get anythingRunning => sessions.any((s) => s.busy);
}

/// Session list ordering: pinned first, then by lane, then newest activity.
int compareBoardSessions(BoardSession a, BoardSession b) {
  if (a.pinned != b.pinned) return a.pinned ? -1 : 1;
  final lane = a.lane.index.compareTo(b.lane.index);
  if (lane != 0) return lane;
  return b.lastActive.compareTo(a.lastActive);
}
