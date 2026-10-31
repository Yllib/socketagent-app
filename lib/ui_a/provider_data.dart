import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/composer_attachment.dart';
import '../models/device_registry.dart';
import '../services/chat_provider.dart';
import 'data.dart';

/// [TowerData] backed by the app's [ChatProvider]. Forwards its change
/// notifications and keeps one piece of Tower-only state: when the user last
/// looked at each session, so the board can show what finished since.
class ProviderTowerData extends TowerData {
  ProviderTowerData(this.chat) {
    chat.addListener(_onChat);
    unawaited(_loadSeen());
  }

  final ChatProvider chat;

  static const _seenKey = 'ui_a_seen_v1';
  static const _baselineKey = 'ui_a_seen_baseline';

  /// `serverId|sessionId` to the time the user last viewed it.
  final Map<String, DateTime> _seen = {};

  /// Runs that finished before Tower was first opened count as seen.
  DateTime _baseline = DateTime.now();
  bool _viewing = false;

  void _onChat() {
    // A run that finishes while its session is on screen counts as seen.
    if (_viewing) {
      final open = openSession;
      if (open != null) _markSeen(open, persist: false);
    }
    notifyListeners();
  }

  Future<void> _loadSeen() async {
    final prefs = await SharedPreferences.getInstance();
    final baseline = prefs.getInt(_baselineKey);
    if (baseline == null) {
      await prefs.setInt(_baselineKey, _baseline.millisecondsSinceEpoch);
    } else {
      _baseline = DateTime.fromMillisecondsSinceEpoch(baseline);
    }
    final raw = prefs.getString(_seenKey);
    if (raw != null) {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        for (final entry in decoded.entries) {
          final ms = entry.value;
          if (ms is int) {
            _seen[entry.key.toString()] = DateTime.fromMillisecondsSinceEpoch(
              ms,
            );
          }
        }
      }
    }
    notifyListeners();
  }

  void _markSeen(Session s, {bool persist = true}) {
    _seen['${s.serverId}|${s.id}'] = DateTime.now();
    if (!persist) return;
    unawaited(
      SharedPreferences.getInstance().then(
        (prefs) => prefs.setString(
          _seenKey,
          jsonEncode({
            for (final e in _seen.entries)
              e.key: e.value.millisecondsSinceEpoch,
          }),
        ),
      ),
    );
  }

  @override
  void dispose() {
    chat.removeListener(_onChat);
    chat.clearViewingSession(this);
    super.dispose();
  }

  // Fleet

  @override
  List<TowerComputer> get computers => [
    for (final c in chat.serverConfigs)
      TowerComputer(
        id: c.id,
        name: c.name,
        status: chat.connMgr.statusOf(c.id),
        color: c.colorValue,
        expectedOnline: c.expectedOnline,
        relay: c.useRelay,
        pushRegistered: chat.isPushRegisteredForServer(c.id),
      ),
  ];

  @override
  List<Session> get sessions => chat.sessions;

  bool _isOpen(Session s) =>
      s.id == chat.activeSessionId &&
      (chat.activeSessionServerId == null ||
          s.serverId == chat.activeSessionServerId);

  @override
  Live liveOf(Session session) {
    if (_isOpen(session)) {
      if (chat.isCompacting) return Live.compacting;
      if (chat.isProcessing) return Live.running;
      return Live.idle;
    }
    if (session.runStats?.current != null || session.running) {
      return Live.running;
    }
    return Live.idle;
  }

  @override
  DateTime? runStartedAt(Session session) {
    if (_isOpen(session)) return chat.currentPromptStartedAt;
    return session.runStats?.current?.startedAt ??
        DateTime.tryParse(session.activeStartedAt ?? '');
  }

  @override
  bool hasUnread(Session session) {
    if (liveOf(session) != Live.idle) return false;
    final finished = session.runStats?.lastCompletedAt;
    if (finished == null || finished.isBefore(_baseline)) return false;
    final seen = _seen['${session.serverId}|${session.id}'];
    return seen == null || finished.isAfter(seen);
  }

  @override
  bool isPinned(Session session) => chat.isSessionPinned(session.id);
  @override
  bool isMuted(Session session) => !chat.isNotifEnabled(session.id);
  @override
  void togglePin(Session session) => chat.toggleSessionPin(session.id);
  @override
  void toggleMute(Session session) =>
      chat.toggleSessionNotifications(session.id);

  @override
  List<PendingDevice> get pendingDevices => chat.pendingDevices;
  @override
  Future<void> approveDevice(PendingDevice device) =>
      chat.approveDevice(device);
  @override
  Future<void> denyDevice(PendingDevice device) => chat.denyDevice(device);

  @override
  List<Map<String, dynamic>> get scheduledTasks => chat.scheduledTasks;
  @override
  int get unreadScheduledTaskCount => chat.unreadScheduledTaskCount;
  @override
  void runScheduledTask(String taskId) => chat.executeScheduledTask(taskId);
  @override
  void markScheduledTaskRead(String taskId) =>
      chat.markScheduledTaskRead(taskId);

  // Open session

  @override
  String? get openSessionId => chat.activeSessionId;
  @override
  String? get openServerId => chat.activeSessionServerId;
  @override
  bool get isDraftSession => chat.isPendingNewSession;
  @override
  String? get openTitle => openSession?.title ?? chat.activeSessionTitle;
  @override
  String? get openCwd => chat.activeSessionCwd;
  @override
  String? get openBackend => chat.activeSessionBackend;
  @override
  bool get openOffline => chat.activeSessionOffline;
  @override
  List<ChatMessage> get messages => chat.filteredMessages;
  @override
  bool get isProcessing => chat.isProcessing;
  @override
  bool get isCompacting => chat.isCompacting;
  @override
  DateTime? get openRunStartedAt => chat.currentPromptStartedAt;
  @override
  bool get hasMoreHistory => chat.hasMoreHistory;
  @override
  bool get isLoadingHistory => chat.isLoadingHistory || chat.isLoadingMore;
  @override
  void loadMoreHistory() => chat.loadMoreHistory();
  @override
  List<String> get promptSuggestions => chat.promptSuggestions;
  @override
  List<Map<String, dynamic>> get slashCommands => chat.slashCommands;
  @override
  Map<String, Map<String, dynamic>> get tasks => chat.activePaneTasks;
  @override
  List<Map<String, dynamic>> get todos => chat.todos;
  @override
  Map<String, dynamic>? get contextUsage => chat.contextUsage;
  @override
  bool get condensedTools => chat.condensedToolUsage;
  @override
  void setCondensedTools(bool value) =>
      unawaited(chat.setCondensedToolUsage(value));

  @override
  String? get permissionMode => chat.permissionMode;
  @override
  String? get model => chat.sessionModel;
  @override
  String get effort => chat.effort;
  @override
  List<Map<String, dynamic>> get models => chat.supportedModels;
  @override
  List<String> get effortLevels => chat.selectedModelEffortLevels;
  @override
  void setModel(String model) => chat.setModel(model);
  @override
  void setEffort(String effort) => chat.setEffort(effort);
  @override
  void setPermissionMode(String mode) => chat.setPermissionMode(mode);

  @override
  void open(Session session) {
    if (!_isOpen(session)) {
      chat.resumeSession(session.id, serverId: session.serverId);
    }
    chat.setViewingSession(session.id, serverId: session.serverId, owner: this);
    chat.markScheduledTaskReadForSession(
      session.id,
      serverId: session.serverId,
    );
    _viewing = true;
    _markSeen(session);
    notifyListeners();
  }

  @override
  void closeOpen() {
    final open = openSession;
    if (open != null) _markSeen(open);
    _viewing = false;
    chat.clearViewingSession(this);
    notifyListeners();
  }

  @override
  void startDraft({
    required String serverId,
    required String backend,
    String? cwd,
    bool fleeting = false,
  }) {
    chat.createNewSession(
      serverId: serverId,
      backend: backend,
      cwd: cwd,
      fleeting: fleeting,
    );
    _viewing = true;
  }

  @override
  Future<bool> send(String text, {Priority? priority}) =>
      chat.sendPrompt(text, priority: priority?.name);
  @override
  String? retract(String messageId) => chat.retractQueuedMessage(messageId);
  @override
  Future<void> stop() => chat.abortQuery();
  @override
  void interrupt() => chat.interruptQuery();
  @override
  void stopTask(String taskId) => chat.stopTask(taskId);
  @override
  void backgroundTask(String toolUseId) => chat.backgroundTask(toolUseId);
  @override
  bool get canBackgroundTasks => chat.canBackgroundClaudeTasks;
  @override
  void dismissTask(String id, String kind) {
    if (kind == 'workflow') {
      chat.dismissWorkflow(id);
    } else if (kind == 'subagent') {
      chat.dismissSubagent(id);
    }
  }

  @override
  void requestFullOutput(ChatMessage message) =>
      chat.requestFullOutput(message);

  @override
  void compact() {
    final id = chat.activeSessionId;
    if (id == null) return;
    if (chat.activeSessionBackend == 'codex') {
      chat.compactCodexThread(id);
    } else {
      unawaited(chat.sendPrompt('/compact'));
    }
  }

  @override
  String draft() => chat.getDraft();
  @override
  void saveDraft(String text) => chat.saveDraft(text);
  @override
  List<PendingFileAttachment> get fileAttachments =>
      chat.pendingFileAttachments;
  @override
  List<PendingSecretAttachment> get secretAttachments =>
      chat.pendingSecretAttachments;
  @override
  Future<void> pickFiles({bool images = false}) =>
      chat.pickFiles(imagesOnly: images);
  @override
  void removeFile(String id) => chat.removeFileAttachment(id);
  @override
  void removeSecret(String id) => chat.removeSecretAttachment(id);

  @override
  Future<void> answerQuestion(String questionId, Map<String, String> answers) =>
      chat.answerQuestion(questionId, answers);
  @override
  void submitSecret(String requestId, String value) =>
      chat.submitSecureInput(requestId, value);
  @override
  void cancelSecret(String requestId) => chat.cancelSecureInput(requestId);
  @override
  void useStoredSecret(String requestId, SecretMetadata secret) =>
      chat.submitStoredSecureInput(requestId, secret);
  @override
  List<SecretMetadata> get storedSecrets => chat.secretInventory;
  @override
  Future<void> answerAccess(
    String requestId,
    String decision, {
    ComputerAccess? access,
  }) => chat.answerComputerAccess(requestId, decision, access: access);

  @override
  void rename(Session session, String title) =>
      chat.renameSession(session.id, title);
  @override
  void archive(Session session) =>
      chat.archiveSession(session.id, serverId: session.serverId);
  @override
  void delete(Session session) =>
      chat.deleteSession(session.id, serverId: session.serverId);
  @override
  void makePermanent(Session session) =>
      chat.makeSessionPermanent(session.id, serverId: session.serverId);

  @override
  List<String> backendsFor(String serverId) => chat.backendsForServer(serverId);
  @override
  List<String> recentFolders(String serverId) =>
      chat.getRecentCwds(serverId: serverId);
  @override
  void refreshFolders(String serverId) =>
      chat.requestRecentCwds(serverId: serverId);

  @override
  String defaultFolder(String serverId) =>
      chat.serverConfigs
          .where((c) => c.id == serverId)
          .firstOrNull
          ?.defaultCwd ??
      '';
}
