import 'package:flutter/material.dart';

import '../../models/message.dart';
import '../../models/scheduled_task_unread.dart';
import '../../models/server_config.dart';
import '../../services/chat_provider.dart';
import '../../services/websocket_service.dart' show ConnectionStatus;
import '../../services/work_review_repository.dart';
import '../model/automation_model.dart';
import '../model/board_model.dart';
import '../model/log_model.dart';
import '../model/session_model.dart';
import 'seen_ledger.dart';

/// Builds the board from the services. Pure: same inputs, same board.
BoardModel buildBoard(
  ChatProvider p,
  WorkReviewRepository reviews,
  SeenLedger seen, {
  required DateTime now,
}) {
  final configs = p.serverConfigs;
  final byServer = {for (final c in configs) c.id: c};
  final sessions = <BoardSession>[];
  final childCounts = <String, int>{};
  for (final s in p.sessions) {
    if (s.delegatedBySessionId case final parent?) {
      childCounts.update(
        '${s.serverId}\u0001$parent',
        (v) => v + 1,
        ifAbsent: () => 1,
      );
    }
  }
  for (final s in p.sessions) {
    final cfg = byServer[s.serverId];
    final status = p.sessionServerStatus(s);
    final isActive =
        s.id == p.activeSessionId &&
        (s.serverId.isEmpty ||
            s.serverId ==
                (p.activeSessionServerId ?? p.connMgr.activeServerId));
    final activity = status != ConnectionStatus.connected
        ? SessionActivity.offline
        : isActive && p.requiresAction
        ? SessionActivity.waitingOnUser
        : (isActive ? p.isCompacting : false)
        ? SessionActivity.compacting
        : s.running || (isActive && p.isProcessing)
        ? SessionActivity.running
        : p.isSessionWaitingOnAgent(s)
        ? SessionActivity.waitingOnAgent
        : SessionActivity.idle;
    final last = s.runStats?.recentRuns.lastOrNull;
    sessions.add(
      BoardSession(
        id: s.id,
        serverId: s.serverId,
        computerName: s.serverName.isNotEmpty
            ? s.serverName
            : (cfg?.name ?? 'computer'),
        computerColor: _color(s.serverColor ?? cfg?.colorValue),
        title: s.title,
        harness: s.backend ?? 'claude',
        cwd: s.cwd,
        activity: activity,
        runStartedAt:
            DateTime.tryParse(s.activeStartedAt ?? '') ??
            (s.runStats?.current?.startedAt),
        lastActive: s.lastActive,
        turnCount: s.turnCount,
        preview: s.messagePreview,
        pinned: p.isSessionPinned(s.id),
        muted: !p.isNotifEnabled(s.id),
        fleeting: s.isFleeting,
        expiresAt: s.expiresAt,
        childCount: childCounts['${s.serverId}\u0001${s.id}'] ?? 0,
        parentId: s.delegatedBySessionId,
        fromScheduledTask: s.scheduledTaskId != null,
        lastRunOutcome: last?.outcome,
        unread: seen.isUnread(s),
        lastRunDuration: last == null
            ? null
            : Duration(milliseconds: last.durationMs),
        runCount: s.runStats?.completedCount ?? 0,
      ),
    );
  }
  sessions.sort(compareBoardSessions);

  final computers = <ComputerChip>[];
  for (final c in configs) {
    final status = p.connMgr.statusOf(c.id);
    final mine = sessions.where((s) => s.serverId == c.id);
    final info = p.serverRuntimeInfo(c.id);
    computers.add(
      ComputerChip(
        id: c.id,
        name: c.name,
        link: switch (status) {
          ConnectionStatus.connected => ComputerLink.connected,
          ConnectionStatus.connecting => ComputerLink.connecting,
          ConnectionStatus.error => ComputerLink.error,
          ConnectionStatus.disconnected => ComputerLink.offline,
        },
        color: _color(c.colorValue),
        runningCount: mine.where((s) => s.busy).length,
        waitingCount: mine
            .where((s) => s.activity == SessionActivity.waitingOnUser)
            .length,
        expectedOnline: c.expectedOnline,
        version: info['version']?.toString(),
        issueCount: p.issuesForServer(c.id).length,
        pushRegistered: p.isPushDisabledForServer(c.id)
            ? null
            : p.isPushRegisteredForServer(c.id),
        viaRelay: c.useRelay,
        issues: [
          for (final i in p.issuesForServer(c.id)) '${i.backend}: ${i.message}',
        ],
        sessionCount: mine.length,
        host: c.useRelay ? 'relay' : '${c.host}:${c.port}',
        backends: p.backendsForServer(c.id),
        recentCwds: p.getRecentCwds(serverId: c.id),
        defaultCwd: c.defaultCwd.isEmpty ? null : c.defaultCwd,
      ),
    );
  }

  final inbox = <InboxItem>[];
  final activeKey = p.activeSessionId;
  final active = activeKey == null
      ? null
      : sessions.where((s) => s.id == activeKey).firstOrNull;
  final activeView = active == null ? null : _activeViewForInbox(p, active);
  if (activeView != null) {
    for (final m in activeView.pendingCards) {
      final item = inboxItemFromMessage(m, activeView);
      if (item != null) inbox.add(item);
    }
  }
  for (final d in p.pendingDevices) {
    final cfg = byServer[d.serverId];
    inbox.add(
      InboxItem(
        id: 'device:${d.publicKey}',
        kind: InboxKind.device,
        title: '${d.name} wants to pair',
        detail: '${d.platform} · code ${d.code}',
        since: now,
        serverId: d.serverId,
        computerName: cfg?.name ?? '',
        computerColor: _color(cfg?.colorValue),
        payload: d,
      ),
    );
  }
  for (final r in p.activeDeliveryProblems) {
    final cfg = byServer[r.serverId];
    inbox.add(
      InboxItem(
        id: r.id,
        kind: InboxKind.delivery,
        title: r.displayText,
        detail: r.error ?? 'not delivered',
        since: r.createdAt,
        serverId: r.serverId,
        computerName: cfg?.name ?? '',
        computerColor: _color(cfg?.colorValue),
      ),
    );
  }
  for (final t in p.scheduledTasks) {
    if (!scheduledTaskHasUnreadResult(t)) continue;
    final lastRun = scheduledTaskLatestResultAt(t) ?? now;
    final serverId = t['serverId']?.toString();
    final cfg = serverId == null ? null : byServer[serverId];
    final failed = t['error'] != null || t['status'] == 'failed';
    inbox.add(
      InboxItem(
        id: t['id']?.toString() ?? '',
        kind: InboxKind.automation,
        title:
            '${t['name'] ?? t['prompt'] ?? 'Scheduled task'}${failed ? ' failed' : ' finished'}',
        detail: (t['error'] ?? t['resultSummary'] ?? '').toString(),
        since: lastRun,
        sessionId: t['sessionId']?.toString(),
        serverId: serverId,
        computerName: cfg?.name ?? '',
        computerColor: _color(cfg?.colorValue),
      ),
    );
  }
  var reviewsPending = 0;
  for (final c in configs) {
    reviewsPending += reviews.pendingCount(c.id);
  }
  inbox.sort((a, b) => b.since.compareTo(a.since));
  return BoardModel(
    computers: computers,
    inbox: inbox,
    sessions: sessions,
    automationUnread: p.unreadScheduledTaskCount,
    reviewsPending: reviewsPending,
    filesReceived: 0,
    browserWindows: p.activeBrowserSessions.length,
    loading:
        p.sessions.isEmpty &&
        computers.any((c) => c.link == ComputerLink.connecting),
  );
}

SessionView _activeViewForInbox(ChatProvider p, BoardSession s) => SessionView(
  id: s.id,
  serverId: s.serverId,
  computerName: s.computerName,
  computerColor: s.computerColor,
  title: s.title,
  harness: s.harness,
  online: s.activity != SessionActivity.offline,
  messages: p.messages,
);

Color? _color(int? argb) => argb == null ? null : Color(argb);

/// The open session, or the new-session state when nothing is open yet.
SessionView buildSessionView(ChatProvider p, WorkReviewRepository reviews) {
  final serverId = p.activeSessionServerId ?? p.connMgr.activeServerId ?? '';
  final cfg = p.serverConfigs.where((c) => c.id == serverId).firstOrNull;
  final session = p.sessions
      .where(
        (s) =>
            s.id == p.activeSessionId &&
            (s.serverId.isEmpty || s.serverId == serverId),
      )
      .firstOrNull;
  final harness = p.activeSessionBackend ?? session?.backend ?? 'claude';
  final codex = harness == 'codex';
  final tasks = <TaskItem>[];
  final dismissKeys = <String, String>{};
  for (final e in p.activePaneTasks.entries) {
    final t = e.value;
    final kind = switch (t['_kind']) {
      'subagent' =>
        (t['source'] == 'agent_session' || t['taskType'] == 'agent_session')
            ? TaskKind.delegated
            : TaskKind.subagent,
      'workflow' => TaskKind.workflow,
      _ =>
        (t['isMonitor'] == true || t['taskType'] == 'monitor')
            ? TaskKind.monitor
            : TaskKind.background,
    };
    final usage = t['usage'] is Map ? t['usage'] as Map : const {};
    final status = t['status']?.toString() ?? 'running';
    final live =
        status == 'running' ||
        status == 'started' ||
        status == 'pending' ||
        status == 'paused';
    final taskId = t['taskId']?.toString();
    dismissKeys[e.key] = e.key;
    tasks.add(
      TaskItem(
        id: e.key,
        kind: kind,
        description:
            (t['description'] ??
                    t['summary'] ??
                    t['prompt'] ??
                    t['command'] ??
                    'task')
                .toString(),
        status: status,
        startedAt:
            DateTime.tryParse(t['startedAt']?.toString() ?? '') ??
            (t['startedAt'] is num
                ? DateTime.fromMillisecondsSinceEpoch(
                    (t['startedAt'] as num).toInt(),
                  )
                : null),
        lastTool: t['lastToolName']?.toString(),
        progress: (t['progressSummary'] ?? '').toString(),
        tokens: (usage['totalTokens'] as num?)?.toInt(),
        toolUses: (usage['toolUses'] as num?)?.toInt(),
        durationMs: (usage['durationMs'] as num?)?.toInt(),
        backgrounded: t['isBackgrounded'] == true,
        canStop: live && taskId != null,
        canDismiss:
            !live && kind != TaskKind.background && kind != TaskKind.monitor,
        childSessionId:
            t['childSessionId']?.toString() ?? t['sessionId']?.toString(),
        childServerId: serverId,
      ),
    );
  }
  final todos = p.todos;
  final plan = [
    for (final t in todos)
      PlanStep(
        (t['content'] ?? t['subject'] ?? t['step'] ?? '').toString(),
        (t['status'] ?? 'pending').toString(),
      ),
  ];
  final usage = p.contextUsage;
  final last = p.lastUsage;
  ContextGauge? gauge;
  if (usage != null && usage['maxTokens'] is num) {
    final cats = usage['categories'];
    gauge = ContextGauge(
      used: (usage['totalTokens'] as num?)?.toInt() ?? 0,
      total: (usage['maxTokens'] as num).toInt(),
      slices: [
        if (cats is List)
          for (final c in cats.whereType<Map>())
            ContextSlice(
              c['name']?.toString() ?? '',
              (c['tokens'] as num?)?.toInt() ?? 0,
              _parseHex(c['color']?.toString()),
            ),
      ],
    );
  } else if (last != null && last['contextWindow'] is num) {
    final used =
        ((last['inputTokens'] as num?) ?? 0).toInt() +
        ((last['cacheReadTokens'] as num?) ?? 0).toInt() +
        ((last['cacheCreateTokens'] as num?) ?? 0).toInt();
    gauge = ContextGauge(
      used: used,
      total: (last['contextWindow'] as num).toInt(),
      autoCompactAt: p.claudeAutoCompactEnabled
          ? p.claudeAutoCompactWindowEffective
          : null,
    );
  }
  final queued = [
    for (final m in p.messages)
      if (m.sender == MessageSender.user && m.isPending)
        QueuedPrompt(
          id: m.id,
          text: m.textContent,
          priority: m.injectionPriority ?? 'next',
          failed: m.delivery == MessageDelivery.failed ? 'not delivered' : null,
        ),
  ];
  final children = <BoardSession>[];
  final parentSession = session?.delegatedBySessionId == null
      ? null
      : p.sessions
            .where(
              (s) =>
                  s.id == session!.delegatedBySessionId &&
                  s.serverId == session.serverId,
            )
            .firstOrNull;
  BoardSession brief(Session s) => BoardSession(
    id: s.id,
    serverId: s.serverId,
    computerName: s.serverName,
    computerColor: _color(s.serverColor),
    title: s.title,
    harness: s.backend ?? 'claude',
    activity: s.running
        ? SessionActivity.running
        : p.isSessionWaitingOnAgent(s)
        ? SessionActivity.waitingOnAgent
        : SessionActivity.idle,
    lastActive: s.lastActive,
    fleeting: s.isFleeting,
    parentId: s.delegatedBySessionId,
  );
  if (session != null) {
    for (final s in p.sessions) {
      if (s.delegatedBySessionId == session.id &&
          s.serverId == session.serverId) {
        children.add(brief(s));
      }
    }
  }
  final sessionId = p.activeSessionId;
  return SessionView(
    id: sessionId,
    serverId: serverId,
    computerName: session?.serverName ?? cfg?.name ?? 'computer',
    computerColor: _color(session?.serverColor ?? cfg?.colorValue),
    title: p.activeSessionTitle ?? session?.title ?? 'New session',
    harness: harness,
    cwd: p.activeSessionCwd ?? session?.cwd ?? '',
    online: !p.activeSessionOffline,
    running: p.isProcessing,
    compacting: p.isCompacting,
    requiresAction: p.requiresAction,
    retrying: p.isRetrying,
    hookName: p.activeHookName,
    runStartedAt: p.currentPromptStartedAt,
    permissionMode: p.permissionMode,
    model:
        p.sessionModel ??
        p.supportedModels
            .where((m) => m['isDefault'] == true)
            .firstOrNull?['value']
            ?.toString(),
    models: [
      for (final m in p.supportedModels)
        ModelChoice(
          m['value']?.toString() ?? '',
          label: (m['label'] ?? m['displayName'])?.toString(),
          isDefault: m['isDefault'] == true,
        ),
    ],
    effort: p.effort,
    efforts: p.selectedModelEffortLevels,
    messages: p.filteredMessages,
    hasMoreHistory: p.hasMoreHistory,
    olderCount: p.olderHistoryCount,
    loadingHistory: p.isLoadingHistory,
    tasks: tasks,
    plan: plan,
    planFromClaude: !codex,
    context: gauge,
    rateLimits: [
      if (p.fiveHourRateLimit case final r? when r.shouldDisplay) r,
      if (p.weeklyRateLimit case final r? when r.shouldDisplay) r,
    ],
    runStats: p.activeSessionRunStats ?? session?.runStats,
    suggestions: p.promptSuggestions,
    slashCommands: [
      for (final c in p.slashCommands)
        SlashCommand(
          c['name']?.toString() ?? '',
          description: (c['description'] ?? '').toString(),
          kind: (c['kind'] ?? 'command').toString(),
        ),
    ],
    draft: p.getDraft(),
    attachments: p.pendingFileAttachments,
    secretAttachments: p.pendingSecretAttachments,
    secretInventory: p.secretInventory,
    queued: queued,
    pinned: sessionId != null && p.isSessionPinned(sessionId),
    muted: sessionId != null && !p.isNotifEnabled(sessionId),
    fleeting: session?.isFleeting ?? false,
    expiresAt: session?.expiresAt,
    parent: parentSession == null ? null : brief(parentSession),
    children: children,
    turnCount: session?.turnCount ?? 0,
    condensed: p.condensedToolUsage,
    canBackgroundTasks: p.canBackgroundClaudeTasks,
    listening: p.isListening,
    plansCount: p.htmlPlans.where((h) => h.sessionId == sessionId).length,
    reviewsCount: serverId.isEmpty
        ? 0
        : reviews
              .reviewsForServer(serverId)
              .where((r) => r.sessionId == sessionId)
              .length,
    browserWindows: p.activeBrowserSessions
        .where((b) => b.sessionId == sessionId)
        .length,
  );
}

Color? _parseHex(String? hex) {
  if (hex == null) return null;
  final h = hex.replaceFirst('#', '');
  final v = int.tryParse(h.length == 6 ? 'FF$h' : h, radix: 16);
  return v == null ? null : Color(v);
}

/// Scheduled tasks from every computer, as the automations screen shows them.
List<AutomationItem> buildAutomations(ChatProvider p) {
  final byServer = {for (final c in p.serverConfigs) c.id: c};
  final out = <AutomationItem>[];
  for (final t in p.scheduledTasks) {
    final serverId = t['serverId']?.toString() ?? '';
    final ServerConfig? cfg = byServer[serverId];
    final rec = t['recurrence'];
    String? recurrence;
    if (rec is Map) {
      final type = rec['type']?.toString();
      recurrence = switch (type) {
        null || 'once' => null,
        'custom' => 'every ${_interval((rec['intervalMs'] as num?)?.toInt())}',
        _ => type,
      };
    }
    final runs = t['runs'];
    final lastRun = runs is List && runs.isNotEmpty && runs.last is Map
        ? runs.last as Map
        : null;
    out.add(
      AutomationItem(
        id: t['id']?.toString() ?? '',
        serverId: serverId,
        name: (t['name'] ?? t['prompt'] ?? 'Scheduled task').toString(),
        status: (t['status'] ?? 'scheduled').toString(),
        computerName: cfg?.name ?? '',
        computerColor: _color(cfg?.colorValue),
        prompt: (t['prompt'] ?? '').toString(),
        cwd: (t['cwd'] ?? '').toString(),
        harness: (t['backend'] ?? 'claude').toString(),
        recurrence: recurrence,
        nextRunAt: DateTime.tryParse(t['scheduledTime']?.toString() ?? ''),
        lastRunAt:
            scheduledTaskLatestResultAt(t) ??
            DateTime.tryParse(t['lastRunAt']?.toString() ?? ''),
        lastResult: (t['resultSummary'] ?? lastRun?['resultSummary'] ?? '')
            .toString(),
        error: (t['error'] ?? lastRun?['error'])?.toString(),
        runCount:
            (t['runCount'] as num?)?.toInt() ??
            (runs is List ? runs.length : 0),
        unread: scheduledTaskHasUnreadResult(t),
        archived: scheduledTaskIsArchived(t),
        sessionId: t['sessionId']?.toString(),
        linkedSessionId: t['linkedSessionId']?.toString(),
      ),
    );
  }
  return out;
}

String _interval(int? ms) {
  if (ms == null) return '?';
  final d = Duration(milliseconds: ms);
  if (d.inDays >= 1) return '${d.inDays}d';
  if (d.inHours >= 1) return '${d.inHours}h';
  return '${d.inMinutes}m';
}
