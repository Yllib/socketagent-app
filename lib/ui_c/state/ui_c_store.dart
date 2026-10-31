import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../models/composer_attachment.dart';
import '../../models/device_registry.dart';
import '../../models/message.dart';
import '../../models/work_review.dart';
import 'ui_c_models.dart';

/// Everything interface C reads and every action it takes, behind one
/// notifier. The live implementation adapts ChatProvider; tests render with
/// a fake. Widgets never touch ChatProvider directly.
abstract class UiCStore extends ChangeNotifier {
  // Fleet

  List<FleetComputer> get computers;
  FleetComputer? computer(String serverId) =>
      computers.where((c) => c.id == serverId).firstOrNull;

  /// Every known session across computers, newest activity first.
  List<Session> get sessions;
  SessionLive live(Session session);
  bool get sessionsLoading;

  /// Items waiting on the user across every computer, longest wait first.
  List<InboxItem> get inbox;

  /// Sessions whose last run finished since the user last opened them.
  List<Session> get finishedSinceLooked;
  int get unreadAutomationResults;
  int get openReviews;

  /// Work reviews across computers, newest first, archived ones left out.
  List<WorkReview> get reviews;

  /// Scheduled tasks across computers, raw as the server lists them.
  List<Map<String, dynamic>> get scheduledTasks;
  List<SecretMetadata> get secrets;

  // Open session

  String? get activeSessionId;
  String? get activeServerId;
  String get activeTitle;
  String? get activeBackend;
  String get activeCwd;
  Session? get activeSession => activeSessionId == null
      ? null
      : sessions
            .where(
              (s) =>
                  s.id == activeSessionId &&
                  (activeServerId == null || s.serverId == activeServerId),
            )
            .firstOrNull;

  /// True after a new session was asked for and before its first prompt.
  bool get isDraftSession;
  bool get activeOffline;

  List<ChatMessage> get messages;
  bool get isProcessing;
  bool get isCompacting;
  bool get requiresAction;
  bool get waitingOnAgent;
  DateTime? get runStartedAt;
  bool get historyLoading;
  bool get hasOlderHistory;
  int get olderHistoryCount;
  String? get historyError;
  String? get permissionMode;
  String? get model;
  List<ModelChoice> get models;
  String get effort;
  List<String> get effortLevels;
  ContextGauge? get context;
  List<LimitNotice> get limits;
  List<String> get promptSuggestions;
  List<ActivityItem> get activity;
  List<PlanStep> get plan;
  String get planExplanation;
  bool get condensedTools;
  List<PendingFileAttachment> get pendingFiles;
  List<PendingSecretAttachment> get pendingSecrets;
  bool get isListening;

  /// Final dictation results, to append to the composer.
  Stream<String> get dictation;

  /// Transcript entry a notification asked to land on, if any.
  String? get focusEntryId;

  // Actions

  void openSession(Session session);
  void openSessionById(String sessionId, {String? serverId});
  void leaveSession();
  void newSession({
    String? serverId,
    String? cwd,
    String? backend,
    bool fleeting,
  });
  void refreshSessions();
  void loadOlderHistory();
  Future<bool> send(String text, {SendPriority? priority});
  Future<void> stop();
  void interrupt();
  Future<void> answerQuestion(String questionId, Map<String, String> answers);
  void submitSecret(String requestId, String value);
  void useStoredSecret(String requestId, SecretMetadata secret);
  void cancelSecret(String requestId);
  Future<void> answerAccess(String requestId, String decision);
  void stopActivity(ActivityItem item);
  void dismissActivity(ActivityItem item);
  void backgroundTool(String toolUseId);

  /// Whether a running command or agent can be moved to the background.
  bool get canBackground;

  /// Pulls back a queued message the agent has not taken yet. Returns its
  /// text so the composer can restore it.
  String? retractQueued(String messageId);
  void dismissPlanStep(String key);
  void setPermissionMode(String mode);
  void setModel(String id);
  void setEffort(String level);
  void setCondensedTools(bool value);
  void togglePin(Session session);
  void toggleMute(Session session);
  void renameSession(Session session, String title);
  void archiveSession(Session session);
  void deleteSession(Session session);
  void makePermanent(Session session);
  void compactContext();
  void clearContext();
  void requestFullOutput(ChatMessage message);
  Future<void> pickFiles({bool imagesOnly = false});
  void removeFile(String id);
  void removeSecretAttachment(String id);
  void attachSecret(SecretMetadata secret);
  Future<void> toggleListening();
  void saveDraft(String text);
  String draft();
  void markTaskRead(Map<String, dynamic> task);
  void clearFocusEntry();

  /// Marks the open session as looked at, so it leaves the finished list.
  void markLooked(Session session);

  Future<void> approveDevice(PendingDevice device);
  Future<void> denyDevice(PendingDevice device);

  /// The user's named groups of sessions, sorted by name.
  List<({String id, String name})> get projects;
  String? projectOf(Session session);

  /// Working folders recently used on a computer, most recent first.
  List<String> recentFolders(String serverId);
  String defaultFolder(String serverId);
}
