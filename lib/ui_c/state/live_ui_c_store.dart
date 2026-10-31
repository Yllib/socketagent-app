import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../models/composer_attachment.dart';
import '../../models/computer_access.dart';
import '../../models/device_registry.dart';
import '../../models/message.dart';
import '../../models/task_display.dart';
import '../../models/work_review.dart';
import '../../services/chat_provider.dart';
import '../../services/websocket_service.dart';
import '../../services/work_review_repository.dart';
import 'ui_c_models.dart';
import 'ui_c_store.dart';

/// Interface C over the app's live state. Reads ChatProvider and the work
/// review repository, derives the fleet, inbox and activity views, and
/// forwards every action. Adds two things the provider does not keep: when
/// the user last looked at each session, and waiting items remembered from
/// sessions that are no longer open.
class LiveUiCStore extends UiCStore {
  LiveUiCStore(this._chat, this._reviews) {
    _chat.addListener(_onChange);
    _reviews.addListener(_onChange);
    unawaited(_loadSeen());
  }

  final ChatProvider _chat;
  final WorkReviewRepository _reviews;

  static const _seenKey = 'ui_c_seen_v1';

  /// Session key to the last time the user had it open here.
  final Map<String, int> _seen = {};

  /// When this interface first ran. Sessions never opened here count as
  /// finished only if they moved after this.
  int _since = DateTime.now().millisecondsSinceEpoch;
  bool _seenLoaded = false;
  Timer? _seenSaveTimer;

  /// Waiting items seen in sessions that are not open now, by session key.
  final Map<String, List<InboxItem>> _rememberedWaits = {};

  List<Session>? _finishedCache;
  List<InboxItem>? _inboxCache;
  List<FleetComputer>? _computersCache;

  static String _key(String serverId, String sessionId) =>
      '$serverId/$sessionId';

  void _onChange() {
    _finishedCache = null;
    _inboxCache = null;
    _computersCache = null;
    final sessionId = _chat.activeSessionId;
    final serverId = _chat.activeSessionServerId;
    if (sessionId != null && serverId != null && _viewing) {
      _seen[_key(serverId, sessionId)] = DateTime.now().millisecondsSinceEpoch;
      _rememberedWaits.remove(_key(serverId, sessionId));
      _saveSeenSoon();
    }
    notifyListeners();
  }

  bool _viewing = false;

  Future<void> _loadSeen() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_seenKey);
    if (raw != null) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          final since = decoded['since'];
          if (since is int) _since = since;
          final seen = decoded['seen'];
          if (seen is Map) {
            for (final entry in seen.entries) {
              final value = entry.value;
              if (value is int) _seen[entry.key.toString()] = value;
            }
          }
        }
      } catch (_) {
        // A bad record only loses the read markers.
      }
    } else {
      _saveSeenSoon();
    }
    _seenLoaded = true;
    _finishedCache = null;
    notifyListeners();
  }

  void _saveSeenSoon() {
    _seenSaveTimer?.cancel();
    _seenSaveTimer = Timer(const Duration(seconds: 2), () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _seenKey,
        jsonEncode({'since': _since, 'seen': _seen}),
      );
    });
  }

  // Fleet

  @override
  List<FleetComputer> get computers => _computersCache ??= _buildComputers();

  List<FleetComputer> _buildComputers() {
    final waits = inbox;
    return [
      for (final config in _chat.serverConfigs)
        FleetComputer(
          id: config.id,
          name: config.name,
          color: computerColor(config.id, config.name, config.colorValue),
          link: switch (_chat.connMgr.statusOf(config.id)) {
            ConnectionStatus.connected => LinkState.connected,
            ConnectionStatus.connecting => LinkState.connecting,
            ConnectionStatus.error => LinkState.error,
            ConnectionStatus.disconnected => LinkState.offline,
          },
          running: _chat.sessions
              .where((s) => s.serverId == config.id && s.running)
              .length,
          waiting: waits.where((item) => item.serverId == config.id).length,
          expectedOnline: config.expectedOnline,
          harnesses: _chat.backendsForServer(config.id),
          version:
              _chat.serverRuntimeInfo(config.id)['version']?.toString() ?? '',
          issues: _chat.issuesForServer(config.id).length,
        ),
    ];
  }

  /// A stable color per computer: the badge color the user picked, or one
  /// from a small palette by name.
  static Color computerColor(String id, String name, int? picked) {
    if (picked != null) return Color(picked);
    const palette = [
      Color(0xFF5FA8FF),
      Color(0xFF6CCB5F),
      Color(0xFFE08A6A),
      Color(0xFFC792EA),
      Color(0xFF4FD1FF),
      Color(0xFFFFC857),
      Color(0xFFFF7AB6),
    ];
    return palette[(name.hashCode ^ id.hashCode).abs() % palette.length];
  }

  @override
  List<Session> get sessions => _chat.sessions;

  @override
  bool get sessionsLoading => _chat.isLoadingSessionCache;

  @override
  SessionLive live(Session session) {
    final offline =
        _chat.sessionServerStatus(session) != ConnectionStatus.connected;
    final isActive =
        session.id == _chat.activeSessionId &&
        (_chat.activeSessionServerId == null ||
            session.serverId == _chat.activeSessionServerId);
    final children = _chat.sessions
        .where(
          (s) =>
              s.delegatedBySessionId == session.id &&
              s.serverId == session.serverId &&
              s.running,
        )
        .length;
    SessionPhase phase;
    if (offline) {
      phase = SessionPhase.offline;
    } else if (isActive && _chat.requiresAction) {
      phase = SessionPhase.waitingOnUser;
    } else if (_rememberedWaits[_key(session.serverId, session.id)]
            ?.isNotEmpty ==
        true) {
      phase = SessionPhase.waitingOnUser;
    } else if (session.running) {
      phase = isActive && _chat.isCompacting
          ? SessionPhase.compacting
          : SessionPhase.running;
    } else if (_chat.isSessionWaitingOnAgent(session) || children > 0) {
      phase = SessionPhase.waitingOnAgent;
    } else if (_isUnreadFinished(session)) {
      phase = SessionPhase.unreadFinished;
    } else {
      phase = SessionPhase.idle;
    }
    final recent = session.runStats?.recentRuns;
    String? outcome;
    if (recent != null && recent.isNotEmpty) {
      outcome = recent
          .reduce((a, b) => a.finishedAt.isAfter(b.finishedAt) ? a : b)
          .outcome;
    }
    return SessionLive(
      phase: phase,
      startedAt: session.running
          ? (DateTime.tryParse(session.activeStartedAt ?? '')?.toLocal() ??
                session.runStats?.current?.startedAt.toLocal())
          : null,
      pinned: _chat.isSessionPinned(session.id),
      muted: !_chat.isNotifEnabled(session.id),
      children: children,
      lastFinishedOutcome: outcome,
    );
  }

  bool _isUnreadFinished(Session session) {
    if (session.running) return false;
    final seen = _seen[_key(session.serverId, session.id)] ?? _since;
    if (session.id == _chat.activeSessionId && _viewing) return false;
    return session.lastActive.millisecondsSinceEpoch > seen;
  }

  @override
  List<Session> get finishedSinceLooked => _finishedCache ??= [
    if (_seenLoaded)
      for (final session in _chat.sessions)
        if (_isUnreadFinished(session)) session,
  ];

  @override
  int get unreadAutomationResults => _chat.unreadScheduledTaskCount;

  @override
  int get openReviews => _chat.serverConfigs
      .map((config) => _reviews.pendingCount(config.id))
      .fold(0, (sum, count) => sum + count);

  @override
  List<WorkReview> get reviews => [
    for (final config in _chat.serverConfigs)
      ..._reviews.reviewsForServer(config.id),
  ]..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));

  @override
  List<Map<String, dynamic>> get scheduledTasks => _chat.scheduledTasks;

  @override
  List<SecretMetadata> get secrets => _chat.secretInventory;

  // Inbox

  @override
  List<InboxItem> get inbox => _inboxCache ??= _buildInbox();

  String _computerName(String serverId) =>
      _chat.serverConfigs.where((c) => c.id == serverId).firstOrNull?.name ??
      serverId;

  bool _deliverable(String serverId) =>
      _chat.connMgr.statusOf(serverId) == ConnectionStatus.connected;

  List<InboxItem> _buildInbox() {
    final items = <InboxItem>[];
    final activeId = _chat.activeSessionId;
    final activeServer = _chat.activeSessionServerId;
    if (activeId != null && activeServer != null) {
      final fromCards = _waitsFromMessages(
        _chat.messages,
        serverId: activeServer,
        sessionId: activeId,
        sessionTitle: _chat.activeSessionTitle ?? 'Untitled',
      );
      items.addAll(fromCards);
    }
    for (final entry in _rememberedWaits.entries) {
      if (activeId != null &&
          activeServer != null &&
          entry.key == _key(activeServer, activeId)) {
        continue;
      }
      items.addAll(entry.value);
    }
    for (final device in _chat.pendingDevices) {
      items.add(
        InboxItem(
          id: 'device_${device.serverId}_${device.publicKey}',
          kind: InboxKind.device,
          serverId: device.serverId,
          computerName: _computerName(device.serverId),
          sessionId: '',
          sessionTitle: '',
          title: '${device.name} wants to pair',
          detail: 'Code ${device.code}  ${device.platform}',
          since: DateTime.now(),
          deliverable: _deliverable(device.serverId),
          payload: device,
        ),
      );
    }
    for (final config in _chat.serverConfigs) {
      for (final review in _reviews.reviewsForServer(config.id)) {
        if (review.status != WorkReviewStatus.open) continue;
        items.add(
          InboxItem(
            id: 'review_${config.id}_${review.id}',
            kind: InboxKind.review,
            serverId: config.id,
            computerName: config.name,
            sessionId: review.sessionId,
            sessionTitle: _titleFor(config.id, review.sessionId),
            title: review.title,
            detail: review.summary,
            since: review.updatedAt,
            deliverable: _deliverable(config.id),
            payload: review,
          ),
        );
      }
    }
    for (final request in _chat.activeDeliveryProblems) {
      final problem = _chat.deliveryProblem(request.id);
      items.add(
        InboxItem(
          id: 'delivery_${request.id}',
          kind: InboxKind.delivery,
          serverId: request.serverId,
          computerName: _computerName(request.serverId),
          sessionId: activeId ?? '',
          sessionTitle: _chat.activeSessionTitle ?? '',
          title: 'Message not delivered',
          detail: problem?.message ?? 'Retrying',
          since: DateTime.now(),
        ),
      );
    }
    items.sort((a, b) => a.since.compareTo(b.since));
    return items;
  }

  String _titleFor(String serverId, String sessionId) =>
      _chat.sessions
          .where((s) => s.serverId == serverId && s.id == sessionId)
          .firstOrNull
          ?.title ??
      '';

  /// Waiting cards in a transcript, as inbox items.
  List<InboxItem> _waitsFromMessages(
    List<ChatMessage> messages, {
    required String serverId,
    required String sessionId,
    required String sessionTitle,
  }) {
    final items = <InboxItem>[];
    final deliverable = _deliverable(serverId);
    final computerName = _computerName(serverId);
    for (final message in messages) {
      if (message.answered || message.expired) continue;
      switch (message.type) {
        case MessageType.question:
          final status = message.toolInput?['status']?.toString();
          if (status == 'expired' || status == 'superseded') continue;
          final first = message.questions?.firstOrNull;
          if (first == null) continue;
          final single =
              (message.questions?.length ?? 0) == 1 && !first.multiSelect;
          items.add(
            InboxItem(
              id: 'q_${message.questionId}',
              kind: message.emailPreview != null
                  ? InboxKind.toolApproval
                  : InboxKind.question,
              serverId: serverId,
              computerName: computerName,
              sessionId: sessionId,
              sessionTitle: sessionTitle,
              title: first.header?.isNotEmpty == true
                  ? '${first.header}: ${first.question}'
                  : first.question,
              detail: (message.questions?.length ?? 1) > 1
                  ? '${message.questions!.length} questions'
                  : '',
              since: message.timestamp,
              message: message,
              options: single
                  ? [for (final o in first.options) o.label]
                  : const [],
              deliverable: deliverable,
            ),
          );
        case MessageType.secureInput:
          final status = message.toolInput?['status']?.toString() ?? 'pending';
          if (status != 'pending') continue;
          items.add(
            InboxItem(
              id: 'secret_${message.questionId}',
              kind: InboxKind.secret,
              serverId: serverId,
              computerName: computerName,
              sessionId: sessionId,
              sessionTitle: sessionTitle,
              title: 'Secret: ${message.toolInput?['label'] ?? 'value'}',
              detail: message.textContent,
              since: message.timestamp,
              message: message,
              deliverable: deliverable,
            ),
          );
        case MessageType.computerAccess:
          final request = ComputerAccessRequest.fromJson(message.toolInput);
          if (request == null || !request.pending) continue;
          if (request.isExpired(DateTime.now())) continue;
          items.add(
            InboxItem(
              id: 'access_${request.requestId}',
              kind: InboxKind.computerAccess,
              serverId: serverId,
              computerName: computerName,
              sessionId: sessionId,
              sessionTitle: sessionTitle,
              title: request.isLink
                  ? '${request.askerLabel} wants to link ${request.targetName}'
                  : '${request.askerLabel} on ${request.targetName}: ${request.actionLabel}',
              detail: request.summary.isNotEmpty
                  ? request.summary
                  : request.reason,
              since: message.timestamp,
              expiresAt: request.expiresAt > 0
                  ? DateTime.fromMillisecondsSinceEpoch(request.expiresAt)
                  : null,
              message: message,
              access: request,
              deliverable: deliverable,
            ),
          );
        case MessageType.elicitationUrl:
        case MessageType.backendAuth:
        case MessageType.claudeAuth:
        case MessageType.outlookAuth:
        case MessageType.ibsAuth:
          items.add(
            InboxItem(
              id: 'signin_${message.id}',
              kind: InboxKind.signIn,
              serverId: serverId,
              computerName: computerName,
              sessionId: sessionId,
              sessionTitle: sessionTitle,
              title: switch (message.type) {
                MessageType.elicitationUrl => 'Sign in to ${message.toolName}',
                MessageType.outlookAuth => 'Sign in to Outlook',
                MessageType.ibsAuth => 'Sign in to IBS',
                _ => 'Sign in needed: ${message.toolName ?? 'harness'}',
              },
              detail: message.textContent,
              since: message.timestamp,
              message: message,
              deliverable: deliverable,
            ),
          );
        default:
          break;
      }
    }
    return items;
  }

  // Open session

  @override
  String? get activeSessionId => _chat.activeSessionId;
  @override
  String? get activeServerId => _chat.activeSessionServerId;
  @override
  String get activeTitle => _chat.activeSessionTitle ?? 'Untitled';
  @override
  String? get activeBackend => _chat.activeSessionBackend;
  @override
  String get activeCwd => _chat.activeSessionCwd ?? '';
  @override
  bool get isDraftSession => _chat.isPendingNewSession;
  @override
  bool get activeOffline => _chat.activeSessionOffline;
  @override
  List<ChatMessage> get messages => _chat.filteredMessages;
  @override
  bool get isProcessing => _chat.isProcessing;
  @override
  bool get isCompacting => _chat.isCompacting;
  @override
  bool get requiresAction => _chat.requiresAction;
  @override
  bool get waitingOnAgent => _chat.activeSessionWaitingOnAgent;
  @override
  DateTime? get runStartedAt => _chat.currentPromptStartedAt;
  @override
  bool get historyLoading => _chat.isLoadingHistory;
  @override
  bool get hasOlderHistory => _chat.hasMoreHistory;
  @override
  int get olderHistoryCount => _chat.olderHistoryCount;
  @override
  String? get historyError => _chat.historyRefreshError;
  @override
  String? get permissionMode => _chat.permissionMode;
  @override
  String? get model => _chat.sessionModel;

  @override
  List<ModelChoice> get models => [
    for (final raw in _chat.supportedModels)
      if ((raw['value'] ?? raw['id'])?.toString().isNotEmpty == true)
        ModelChoice(
          id: (raw['value'] ?? raw['id']).toString(),
          label: (raw['name'] ?? raw['label'] ?? raw['value'] ?? raw['id'])
              .toString(),
          current: raw['current'] == true || raw['value'] == _chat.sessionModel,
        ),
  ];

  @override
  String get effort => _chat.effort;
  @override
  List<String> get effortLevels => _chat.selectedModelEffortLevels;

  @override
  ContextGauge? get context {
    final raw = _chat.contextUsage;
    if (raw == null) return null;
    int number(Object? value) => value is num ? value.toInt() : 0;
    final used = number(raw['totalTokens'] ?? raw['usedTokens'] ?? raw['used']);
    final total = number(
      raw['maxTokens'] ?? raw['contextWindow'] ?? raw['total'] ?? raw['limit'],
    );
    if (total <= 0 && used <= 0) return null;
    final categories = <({String name, int tokens})>[];
    final rawCategories = raw['categories'];
    if (rawCategories is List) {
      for (final entry in rawCategories) {
        if (entry is Map) {
          categories.add((
            name: entry['name']?.toString() ?? '',
            tokens: number(entry['tokens']),
          ));
        }
      }
    }
    return ContextGauge(used: used, total: total, categories: categories);
  }

  @override
  List<LimitNotice> get limits => [
    for (final limit in [_chat.fiveHourRateLimit, _chat.weeklyRateLimit])
      if (limit != null)
        LimitNotice(
          label: limit.label,
          percent: limit.utilizationPercent,
          resetsAt: limit.resetsAt,
          rejected: limit.isRejected,
        ),
  ];

  @override
  List<String> get promptSuggestions => _chat.promptSuggestions;

  @override
  List<ActivityItem> get activity {
    final items = <ActivityItem>[];
    for (final entry in _chat.activePaneTasks.entries) {
      final task = entry.value;
      final kind = task['_kind']?.toString();
      final status = ActivityStatus.parse(task['status']);
      final usage = task['usage'];
      final taskId = task['taskId']?.toString() ?? entry.key;
      switch (kind) {
        case 'bash':
          final monitor = task['isMonitor'] == true;
          items.add(
            ActivityItem(
              key: entry.key,
              kind: monitor ? ActivityKind.monitor : ActivityKind.command,
              title:
                  task['summary']?.toString() ??
                  task['description']?.toString() ??
                  'Command',
              status: status,
              detail: task['output']?.toString() ?? '',
              canStop: status.isLive,
              backgrounded: true,
            ),
          );
        case 'subagent':
          items.add(
            ActivityItem(
              key: entry.key,
              kind: ActivityKind.subagent,
              title: task['description']?.toString() ?? 'Agent',
              status: status,
              detail:
                  task['progressSummary']?.toString() ??
                  task['subagentType']?.toString() ??
                  '',
              lastTool: task['lastToolName']?.toString() ?? '',
              startedAt: DateTime.tryParse(task['startedAt']?.toString() ?? ''),
              tokens: usage is Map
                  ? (usage['totalTokens'] as num?)?.toInt()
                  : null,
              toolUses: usage is Map
                  ? (usage['toolUses'] as num?)?.toInt()
                  : null,
              canStop: status.isLive && task['isBackgrounded'] == true,
              canDismiss: !status.isLive,
              backgrounded: task['isBackgrounded'] == true,
            ),
          );
        case 'workflow':
          final phases = task['phases'];
          items.add(
            ActivityItem(
              key: entry.key,
              kind: ActivityKind.workflow,
              title:
                  task['workflowName']?.toString() ??
                  task['summary']?.toString() ??
                  'Workflow',
              status: status,
              detail: task['summary']?.toString() ?? '',
              toolUses: (task['agentCount'] as num?)?.toInt(),
              canStop: status.isLive,
              canDismiss: !status.isLive,
              phases: phases is List
                  ? [
                      for (final p in phases)
                        if (p is Map) p['title']?.toString() ?? '',
                    ]
                  : const [],
              startedAt: task['startTime'] is num
                  ? DateTime.fromMillisecondsSinceEpoch(
                      (task['startTime'] as num).toInt(),
                    )
                  : null,
            ),
          );
        default:
          items.add(
            ActivityItem(
              key: taskId,
              kind: ActivityKind.command,
              title: task['description']?.toString() ?? 'Task',
              status: status,
            ),
          );
      }
    }
    final activeId = _chat.activeSessionId;
    if (activeId != null) {
      for (final child in _chat.sessions) {
        if (child.delegatedBySessionId != activeId ||
            child.serverId != _chat.activeSessionServerId) {
          continue;
        }
        items.add(
          ActivityItem(
            key: 'delegated_${child.id}',
            kind: ActivityKind.delegated,
            title: child.title,
            status: child.running
                ? ActivityStatus.running
                : ActivityStatus.completed,
            detail: child.messagePreview,
            startedAt: DateTime.tryParse(child.activeStartedAt ?? ''),
            childSessionId: child.id,
          ),
        );
      }
    }
    return items;
  }

  @override
  List<PlanStep> get plan {
    final todos = _chat.todos;
    if (todos.isNotEmpty) {
      return [
        for (final todo in todos)
          PlanStep(
            key: taskDisplayKey(todo),
            text:
                (todo['content'] ??
                        todo['subject'] ??
                        todo['description'] ??
                        '')
                    .toString(),
            status: todo['status']?.toString() ?? 'pending',
          ),
      ];
    }
    final codexPlan = _chat.messages.lastWhere(
      (m) => m.type == MessageType.codexPlan,
      orElse: () => ChatMessage(
        id: '',
        sender: MessageSender.system,
        type: MessageType.codexPlan,
        timestamp: DateTime.fromMillisecondsSinceEpoch(0),
      ),
    );
    final steps = codexPlan.toolInput?['steps'];
    if (steps is! List) return const [];
    return [
      for (var i = 0; i < steps.length; i++)
        if (steps[i] is Map)
          PlanStep(
            key: 'codex:$i',
            text: (steps[i] as Map)['step']?.toString() ?? '',
            status: (steps[i] as Map)['status']?.toString() ?? 'pending',
          ),
    ];
  }

  @override
  String get planExplanation {
    if (_chat.todos.isNotEmpty) return '';
    for (final message in _chat.messages.reversed) {
      if (message.type == MessageType.codexPlan) return message.textContent;
    }
    return '';
  }

  @override
  bool get condensedTools => _chat.condensedToolUsage;
  @override
  List<PendingFileAttachment> get pendingFiles => _chat.pendingFileAttachments;
  @override
  List<PendingSecretAttachment> get pendingSecrets =>
      _chat.pendingSecretAttachments;
  @override
  bool get isListening => _chat.isListening;
  @override
  Stream<String> get dictation => _chat.speech.onResult;
  @override
  String? get focusEntryId => _chat.notificationTranscriptFocus?.entryId;

  // Actions

  @override
  void openSession(Session session) =>
      openSessionById(session.id, serverId: session.serverId);

  @override
  void openSessionById(String sessionId, {String? serverId}) {
    _rememberCurrentWaits();
    if (_chat.activeSessionId != sessionId ||
        (serverId != null && _chat.activeSessionServerId != serverId)) {
      _chat.resumeSession(sessionId, serverId: serverId);
    }
    _viewing = true;
    _chat.setViewingSession(sessionId, serverId: serverId, owner: this);
    _seen[_key(serverId ?? '', sessionId)] =
        DateTime.now().millisecondsSinceEpoch;
    _rememberedWaits.remove(_key(serverId ?? '', sessionId));
    _saveSeenSoon();
    _finishedCache = null;
    _inboxCache = null;
    notifyListeners();
  }

  /// Keeps the open session's waiting cards so they stay on the board after
  /// the user moves to another session.
  void _rememberCurrentWaits() {
    final sessionId = _chat.activeSessionId;
    final serverId = _chat.activeSessionServerId;
    if (sessionId == null || serverId == null) return;
    final waits = _waitsFromMessages(
      _chat.messages,
      serverId: serverId,
      sessionId: sessionId,
      sessionTitle: _chat.activeSessionTitle ?? 'Untitled',
    );
    final key = _key(serverId, sessionId);
    if (waits.isEmpty) {
      _rememberedWaits.remove(key);
    } else {
      _rememberedWaits[key] = waits;
    }
  }

  @override
  void leaveSession() {
    _rememberCurrentWaits();
    _viewing = false;
    _chat.clearViewingSession(this);
    _inboxCache = null;
    notifyListeners();
  }

  @override
  void newSession({
    String? serverId,
    String? cwd,
    String? backend,
    bool fleeting = false,
  }) {
    _rememberCurrentWaits();
    _chat.createNewSession(
      cwd: cwd,
      serverId: serverId,
      backend: backend,
      fleeting: fleeting,
    );
    _viewing = true;
    _chat.setViewingSession(null, owner: this);
  }

  @override
  void refreshSessions() {
    _chat.requestSessionList();
    _chat.requestScheduledTasks();
  }

  @override
  void loadOlderHistory() => _chat.loadMoreHistory();

  @override
  Future<bool> send(String text, {SendPriority? priority}) =>
      _chat.sendPrompt(text, priority: priority?.wire);

  @override
  Future<void> stop() => _chat.abortQuery();

  @override
  void interrupt() => _chat.interruptQuery();

  @override
  Future<void> answerQuestion(String questionId, Map<String, String> answers) =>
      _chat.answerQuestion(questionId, answers);

  @override
  void submitSecret(String requestId, String value) =>
      _chat.submitSecureInput(requestId, value);

  @override
  void useStoredSecret(String requestId, SecretMetadata secret) =>
      _chat.submitStoredSecureInput(requestId, secret);

  @override
  void cancelSecret(String requestId) => _chat.cancelSecureInput(requestId);

  @override
  Future<void> answerAccess(String requestId, String decision) =>
      _chat.answerComputerAccess(requestId, decision);

  @override
  void stopActivity(ActivityItem item) {
    switch (item.kind) {
      case ActivityKind.command:
      case ActivityKind.monitor:
      case ActivityKind.workflow:
        _chat.stopTask(item.key);
      case ActivityKind.subagent:
        final task = _chat.subagentTasks[item.key];
        final taskId = task?['taskId']?.toString();
        if (taskId != null && taskId.isNotEmpty) _chat.stopTask(taskId);
      case ActivityKind.delegated:
        break;
    }
  }

  @override
  void dismissActivity(ActivityItem item) {
    switch (item.kind) {
      case ActivityKind.subagent:
        _chat.dismissSubagent(item.key);
      case ActivityKind.workflow:
        _chat.dismissWorkflow(item.key);
      default:
        break;
    }
  }

  @override
  void backgroundTool(String toolUseId) => _chat.backgroundTask(toolUseId);

  @override
  bool get canBackground => _chat.canBackgroundClaudeTasks;

  @override
  String? retractQueued(String messageId) =>
      _chat.retractQueuedMessage(messageId);

  @override
  void dismissPlanStep(String key) => _chat.dismissTasks([key]);

  @override
  void setPermissionMode(String mode) => _chat.setPermissionMode(mode);

  @override
  void setModel(String id) => _chat.setModel(id);

  @override
  void setEffort(String level) => _chat.setEffort(level);

  @override
  void setCondensedTools(bool value) => _chat.setCondensedToolUsage(value);

  @override
  void togglePin(Session session) => _chat.toggleSessionPin(session.id);

  @override
  void toggleMute(Session session) =>
      _chat.toggleSessionNotifications(session.id);

  @override
  void renameSession(Session session, String title) =>
      _chat.renameSession(session.id, title);

  @override
  void archiveSession(Session session) =>
      _chat.archiveSession(session.id, serverId: session.serverId);

  @override
  void deleteSession(Session session) =>
      _chat.deleteSession(session.id, serverId: session.serverId);

  @override
  void makePermanent(Session session) =>
      _chat.makeSessionPermanent(session.id, serverId: session.serverId);

  @override
  void compactContext() {
    final id = _chat.activeSessionId;
    if (id != null) _chat.compactCodexThread(id);
  }

  @override
  void clearContext() {
    final id = _chat.activeSessionId;
    if (id != null) _chat.clearSessionContext(id);
  }

  @override
  void requestFullOutput(ChatMessage message) =>
      _chat.requestFullOutput(message);

  @override
  Future<void> pickFiles({bool imagesOnly = false}) =>
      _chat.pickFiles(imagesOnly: imagesOnly);

  @override
  void removeFile(String id) => _chat.removeFileAttachment(id);

  @override
  void removeSecretAttachment(String id) => _chat.removeSecretAttachment(id);

  @override
  void attachSecret(SecretMetadata secret) => _chat.attachStoredSecret(secret);

  @override
  Future<void> toggleListening() => _chat.toggleListening();

  @override
  void saveDraft(String text) => _chat.saveDraft(text);

  @override
  String draft() => _chat.getDraft();

  @override
  void markTaskRead(Map<String, dynamic> task) {
    final id = task['id']?.toString() ?? task['taskId']?.toString() ?? '';
    if (id.isNotEmpty) _chat.markScheduledTaskRead(id);
  }

  @override
  void clearFocusEntry() {
    final focus = _chat.notificationTranscriptFocus;
    if (focus != null) _chat.clearNotificationTranscriptFocus(focus);
  }

  @override
  void markLooked(Session session) {
    _seen[_key(session.serverId, session.id)] =
        DateTime.now().millisecondsSinceEpoch;
    _finishedCache = null;
    _saveSeenSoon();
    notifyListeners();
  }

  @override
  Future<void> approveDevice(PendingDevice device) =>
      _chat.approveDevice(device);

  @override
  Future<void> denyDevice(PendingDevice device) => _chat.denyDevice(device);

  @override
  List<({String id, String name})> get projects => _chat.sessionProjects.sorted;

  @override
  String? projectOf(Session session) =>
      _chat.sessionProjects.projectOf(session.id);

  @override
  List<String> recentFolders(String serverId) =>
      _chat.getRecentCwds(serverId: serverId);

  @override
  String defaultFolder(String serverId) =>
      _chat.serverConfigs
          .where((c) => c.id == serverId)
          .firstOrNull
          ?.defaultCwd ??
      _chat.defaultCwd;

  @override
  void dispose() {
    _chat.removeListener(_onChange);
    _reviews.removeListener(_onChange);
    _seenSaveTimer?.cancel();
    super.dispose();
  }
}
