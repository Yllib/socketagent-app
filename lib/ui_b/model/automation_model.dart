import 'package:flutter/material.dart';

/// One scheduled task as the automations screen shows it.
class AutomationItem {
  const AutomationItem({
    required this.id,
    required this.serverId,
    required this.name,
    required this.status,
    this.computerName = '',
    this.computerColor,
    this.prompt = '',
    this.cwd = '',
    this.harness = 'claude',
    this.recurrence,
    this.nextRunAt,
    this.lastRunAt,
    this.lastResult = '',
    this.error,
    this.runCount = 0,
    this.unread = false,
    this.archived = false,
    this.sessionId,
    this.linkedSessionId,
  });

  final String id;
  final String serverId;
  final String name;

  /// scheduled, running, completed, failed, cancelled.
  final String status;
  final String computerName;
  final Color? computerColor;
  final String prompt;
  final String cwd;
  final String harness;

  /// Human text such as "daily 06:00" or null for a one-off.
  final String? recurrence;
  final DateTime? nextRunAt;
  final DateTime? lastRunAt;
  final String lastResult;
  final String? error;
  final int runCount;
  final bool unread;
  final bool archived;
  final String? sessionId;
  final String? linkedSessionId;

  bool get running => status == 'running';
  bool get failed => status == 'failed' || error != null;
  bool get canRun => !running && !archived;
  bool get canCancel => (status == 'scheduled' || running) && !archived;
}
