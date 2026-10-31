import 'package:flutter/material.dart';

import '../../models/composer_attachment.dart';
import '../../models/harness_rate_limit.dart';
import '../../models/message.dart';
import 'board_model.dart';

/// A sub-agent, delegated session, workflow, background command or monitor.
enum TaskKind { subagent, delegated, workflow, background, monitor }

class TaskItem {
  const TaskItem({
    required this.id,
    required this.kind,
    required this.description,
    required this.status,
    this.startedAt,
    this.lastTool,
    this.progress = '',
    this.tokens,
    this.toolUses,
    this.durationMs,
    this.backgrounded = false,
    this.canStop = false,
    this.canDismiss = false,
    this.childSessionId,
    this.childServerId,
    this.phases = const [],
  });

  final String id;
  final TaskKind kind;
  final String description;

  /// pending, running, completed, failed, stopped, killed, paused,
  /// interrupted, unavailable.
  final String status;
  final DateTime? startedAt;
  final String? lastTool;
  final String progress;
  final int? tokens;
  final int? toolUses;
  final int? durationMs;
  final bool backgrounded;
  final bool canStop;
  final bool canDismiss;

  /// Set when the task is a delegated full session the user can open.
  final String? childSessionId;
  final String? childServerId;

  /// Workflow phases as "title: state".
  final List<String> phases;

  bool get live =>
      status == 'running' || status == 'pending' || status == 'paused';
  bool get failed => status == 'failed' || status == 'killed';
}

class PlanStep {
  const PlanStep(this.text, this.status);
  final String text;

  /// pending, in_progress, completed.
  final String status;
  bool get done => status == 'completed';
  bool get active => status == 'in_progress';
}

class ContextSlice {
  const ContextSlice(this.name, this.tokens, [this.color]);
  final String name;
  final int tokens;
  final Color? color;
}

class ContextGauge {
  const ContextGauge({
    required this.used,
    required this.total,
    this.slices = const [],
    this.autoCompactAt,
    this.stale = false,
  });
  final int used;
  final int total;
  final List<ContextSlice> slices;
  final int? autoCompactAt;
  final bool stale;
  double get fraction => total == 0 ? 0 : (used / total).clamp(0, 1);
}

/// A message this device sent that the agent has not taken yet.
class QueuedPrompt {
  const QueuedPrompt({
    required this.id,
    required this.text,
    required this.priority,
    this.failed,
  });
  final String id;
  final String text;

  /// now, next or later.
  final String priority;

  /// Failure text when delivery broke.
  final String? failed;
}

class SlashCommand {
  const SlashCommand(this.name, {this.description = '', this.kind = 'command'});
  final String name;
  final String description;
  final String kind;
}

class ModelChoice {
  const ModelChoice(this.value, {this.label, this.isDefault = false});
  final String value;
  final String? label;
  final bool isDefault;
}

/// One open session, as the log screen sees it. [messages] is the provider's
/// own list, so streaming updates show without copying 200k entries.
class SessionView {
  const SessionView({
    required this.serverId,
    required this.computerName,
    required this.title,
    required this.harness,
    required this.messages,
    this.id,
    this.computerColor,
    this.cwd = '',
    this.online = true,
    this.running = false,
    this.compacting = false,
    this.requiresAction = false,
    this.retrying = false,
    this.hookName,
    this.runStartedAt,
    this.permissionMode,
    this.model,
    this.models = const [],
    this.effort = 'high',
    this.efforts = const [],
    this.hasMoreHistory = false,
    this.olderCount = 0,
    this.loadingHistory = false,
    this.tasks = const [],
    this.plan = const [],
    this.planExplanation = '',
    this.planFromClaude = false,
    this.context,
    this.rateLimits = const [],
    this.runStats,
    this.suggestions = const [],
    this.slashCommands = const [],
    this.draft = '',
    this.attachments = const [],
    this.secretAttachments = const [],
    this.secretInventory = const [],
    this.queued = const [],
    this.pinned = false,
    this.muted = false,
    this.fleeting = false,
    this.expiresAt,
    this.parent,
    this.children = const [],
    this.lastCostUsd,
    this.turnCount = 0,
    this.condensed = true,
    this.canBackgroundTasks = false,
    this.listening = false,
    this.plansCount = 0,
    this.reviewsCount = 0,
    this.browserWindows = 0,
  });

  /// Null before the first prompt of a new session.
  final String? id;
  final String serverId;
  final String computerName;
  final Color? computerColor;
  final String title;
  final String harness;
  final String cwd;
  final bool online;
  final bool running;
  final bool compacting;
  final bool requiresAction;
  final bool retrying;
  final String? hookName;
  final DateTime? runStartedAt;
  final String? permissionMode;
  final String? model;
  final List<ModelChoice> models;
  final String effort;
  final List<String> efforts;
  final List<ChatMessage> messages;
  final bool hasMoreHistory;
  final int olderCount;
  final bool loadingHistory;
  final List<TaskItem> tasks;
  final List<PlanStep> plan;
  final String planExplanation;
  final bool planFromClaude;
  final ContextGauge? context;
  final List<HarnessRateLimit> rateLimits;
  final SessionRunStats? runStats;
  final List<String> suggestions;
  final List<SlashCommand> slashCommands;
  final String draft;
  final List<PendingFileAttachment> attachments;
  final List<PendingSecretAttachment> secretAttachments;
  final List<SecretMetadata> secretInventory;
  final List<QueuedPrompt> queued;
  final bool pinned;
  final bool muted;
  final bool fleeting;
  final DateTime? expiresAt;
  final BoardSession? parent;
  final List<BoardSession> children;
  final double? lastCostUsd;
  final int turnCount;
  final bool condensed;
  final bool canBackgroundTasks;
  final bool listening;
  final int plansCount;
  final int reviewsCount;
  final int browserWindows;

  bool get isNew => id == null;
  bool get isCodex => harness == 'codex';
  bool get busy => running || compacting;
  List<TaskItem> get liveTasks => tasks.where((t) => t.live).toList();

  /// Cards still waiting for the user, newest last.
  List<ChatMessage> get pendingCards => messages
      .where(
        (m) =>
            !m.answered &&
            !m.expired &&
            (m.type == MessageType.question ||
                m.type == MessageType.secureInput ||
                m.type == MessageType.computerAccess ||
                m.type == MessageType.elicitationUrl) &&
            (m.toolInput?['status'] ?? 'pending') == 'pending',
      )
      .toList();
}

/// One-line meaning of each permission mode, per harness.
String permissionModeLabel(String? mode, {required bool codex}) {
  if (codex) {
    return switch (mode) {
      'dangerFullAccess' || 'superYolo' => 'Auto, everything',
      'onRequest' || 'default' => 'Ask before acting',
      'readOnly' || 'plan' => 'Read only',
      'bypassPermissions' || null => 'Auto, protected files ask',
      _ => mode,
    };
  }
  return switch (mode) {
    'bypassPermissions' => 'Auto, safety checks',
    'superYolo' => 'Auto, everything',
    'acceptEdits' => 'Auto edits, ask commands',
    'default' => 'Ask before risky',
    'plan' => 'Plan only',
    'classifier' => 'Classifier approves',
    null => 'Auto, safety checks',
    _ => mode,
  };
}

List<(String, String)> permissionModeChoices({required bool codex}) => codex
    ? const [
        ('bypassPermissions', 'Auto, protected files ask'),
        ('dangerFullAccess', 'Auto, everything'),
        ('onRequest', 'Ask before commands and edits'),
        ('readOnly', 'Read only'),
      ]
    : const [
        ('bypassPermissions', 'Auto, safety checks'),
        ('superYolo', 'Auto, everything'),
        ('acceptEdits', 'Auto edits, ask commands'),
        ('default', 'Ask before risky actions'),
        ('plan', 'Plan only'),
      ];
