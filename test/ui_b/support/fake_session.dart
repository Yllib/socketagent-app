import 'package:flutter/material.dart';
import 'package:app/models/message.dart';
import 'package:app/ui_b/model/board_model.dart';
import 'package:app/ui_b/model/session_model.dart';

import 'fake_data.dart';

const _tower = Color(0xFF4F8EF7);

ChatMessage _m(
  String id,
  MessageSender sender,
  MessageType type,
  int minutesAgo, {
  String text = '',
  String? toolName,
  Map<String, dynamic>? toolInput,
  String? toolUseId,
  String? toolOutput,
  double elapsed = 0,
  bool streaming = false,
  int thinkingTokens = 0,
  int thinkingMs = 0,
  String? agentId,
  String? parentToolUseId,
  MessageDelivery? delivery,
  bool pending = false,
  String? priority,
}) {
  final m = ChatMessage(
    id: id,
    sender: sender,
    type: type,
    timestamp: now.subtract(Duration(minutes: minutesAgo)),
    textContent: text,
    toolName: toolName,
    toolInput: toolInput,
    toolUseId: toolUseId,
    toolOutput: toolOutput,
    toolElapsedSeconds: elapsed,
    toolStreaming: streaming,
    agentId: agentId,
    parentToolUseId: parentToolUseId,
    delivery: delivery,
    isPending: pending,
    injectionPriority: priority,
  );
  m.thinkingTokens = thinkingTokens;
  m.thinkingDurationMs = thinkingMs;
  return m;
}

ChatMessage _tool(
  String id,
  int minutesAgo,
  String name,
  Map<String, dynamic> input, {
  String? output,
  double elapsed = 1.2,
  bool streaming = false,
}) => _m(
  id,
  MessageSender.assistant,
  MessageType.toolCall,
  minutesAgo,
  toolName: name,
  toolInput: input,
  toolUseId: id,
  toolOutput: output,
  elapsed: elapsed,
  streaming: streaming,
);

ChatMessage _result(String callId, int minutesAgo, String output) => _m(
  'r_$callId',
  MessageSender.system,
  MessageType.toolResult,
  minutesAgo,
  toolUseId: callId,
  toolOutput: output,
);

/// A realistic transcript: two finished runs and one live run with a
/// streaming reply, a question waiting, and a queued follow-up.
List<ChatMessage> fakeTranscript({bool withQuestion = true}) {
  final q = ChatMessage(
    id: 'q1',
    sender: MessageSender.assistant,
    type: MessageType.question,
    timestamp: now.subtract(const Duration(minutes: 1)),
    questionId: 'q1',
    questions: fakeQuestion().questions,
  );
  return [
    _m(
      'rb0',
      MessageSender.system,
      MessageType.runBoundary,
      95,
      text: 'completed',
      toolUseId: 'run-11',
      toolInput: {
        'runId': 'run-11',
        'runNumber': 11,
        'runDurationMs': 312000,
        'runOutcome': 'completed',
      },
    ),
    _m(
      'u1',
      MessageSender.user,
      MessageType.text,
      48,
      text:
          'The relay reconnect storm is back on tower. Find out why clients reconnect every 30s and fix it.',
    ),
    _m(
      'th1',
      MessageSender.assistant,
      MessageType.thinking,
      48,
      text:
          'The 30s cadence matches the heartbeat interval, so the server probably closes sockets that miss one pong.',
      thinkingTokens: 1840,
      thinkingMs: 9200,
    ),
    _tool(
      't1',
      47,
      'Grep',
      {'pattern': 'heartbeat|pong', 'path': 'server/src'},
      output:
          'server/src/relay.ts:88\nserver/src/relay.ts:142\nserver/src/ws.ts:31',
      elapsed: 0.4,
    ),
    _result(
      't1',
      47,
      'server/src/relay.ts:88\nserver/src/relay.ts:142\nserver/src/ws.ts:31',
    ),
    _tool(
      't2',
      47,
      'Read',
      {
        'file_path': '/home/billy/agents/socketagent/server/src/relay.ts',
        'description': 'Relay heartbeat handling',
      },
      output: '...',
      elapsed: 0.2,
    ),
    _result(
      't2',
      47,
      '88: const HEARTBEAT_MS = 30_000;\n142: if (!sawPong) ws.terminate();',
    ),
    _tool(
      't3',
      46,
      'Bash',
      {
        'command': 'grep -c "terminate" /var/log/socketagent/relay.log',
        'description': 'Count forced closes in the relay log',
      },
      output: '4127',
      elapsed: 0.3,
    ),
    _result('t3', 46, '4127'),
    _m(
      'a1',
      MessageSender.assistant,
      MessageType.text,
      45,
      text:
          'The relay terminates any socket that misses one pong, and the phone misses one whenever Android dozes the radio. That is 4,127 forced closes since midnight.\n\nTwo fixes are possible:\n\n1. **Backoff.** Reconnect with jitter so a storm cannot form.\n2. **Dedupe sockets.** Keep the newest socket per device and let the stale one die quietly.',
    ),
    _m(
      'rb1',
      MessageSender.system,
      MessageType.runBoundary,
      44,
      text: 'completed',
      toolUseId: 'run-12',
      toolInput: {
        'runId': 'run-12',
        'runNumber': 12,
        'runDurationMs': 228000,
        'runOutcome': 'completed',
      },
    ),
    _m(
      'u2',
      MessageSender.user,
      MessageType.text,
      6,
      text: 'Do both. Keep the heartbeat at 30s.',
    ),
    _m(
      'th2',
      MessageSender.assistant,
      MessageType.thinking,
      6,
      thinkingTokens: 620,
      thinkingMs: 4100,
    ),
    _tool(
      't4',
      5,
      'Edit',
      {
        'file_path': '/home/billy/agents/socketagent/server/src/relay.ts',
        'old_string': 'if (!sawPong) ws.terminate();',
        'new_string':
            'if (!sawPong) {\n  missed += 1;\n  if (missed >= 3) ws.terminate();\n}',
      },
      output: 'The file has been updated.',
      elapsed: 0.1,
    ),
    _result('t4', 5, 'The file has been updated.'),
    _tool(
      't5',
      5,
      'Edit',
      {
        'file_path':
            '/home/billy/agents/socketagent-app/lib/services/connection_manager.dart',
        'old_string': 'Future.delayed(const Duration(seconds: 2), reconnect);',
        'new_string':
            'final wait = _backoff.next();\nFuture.delayed(wait, reconnect);',
      },
      output: 'The file has been updated.',
      elapsed: 0.1,
    ),
    _result('t5', 5, 'The file has been updated.'),
    _tool(
      't6',
      4,
      'Agent',
      {
        'description': 'Review relay.ts for races in the dedupe path',
        'subagent_type': 'claude',
        'prompt': '...',
      },
      output: 'No races. The map is written on one event loop tick.',
      elapsed: 84,
    ),
    _result('t6', 3, 'No races. The map is written on one event loop tick.'),
    _tool(
      't7',
      3,
      'Bash',
      {
        'command': 'cd /home/billy/agents/socketagent && npm test -- relay',
        'description': 'Run the relay tests',
      },
      output:
          'FAILED relay.test.ts\n  reconnect dedupe keeps newest socket\n    expected 1 received 2',
      elapsed: 41,
    ),
    _result(
      't7',
      2,
      'FAILED relay.test.ts\n  reconnect dedupe keeps newest socket\n    expected 1 received 2',
    ),
    _tool(
      't8',
      2,
      'Bash',
      {
        'command': 'cd /home/billy/agents/socketagent && npm test -- relay',
        'description': 'Rerun after the fix',
      },
      streaming: true,
      elapsed: 0,
    ),
    if (withQuestion) q,
    _m(
      'a2',
      MessageSender.assistant,
      MessageType.text,
      1,
      text:
          'Both edits are in. One test still fails because the dedupe map keys on device id and the test registers two sockets for the same device within one tick. Rerunning now, then I will',
    ),
    _m(
      'u3',
      MessageSender.user,
      MessageType.text,
      0,
      text: 'Also bump the relay version when you are done.',
      pending: true,
      priority: 'later',
      delivery: MessageDelivery.received,
    ),
  ];
}

SessionView fakeSession({bool desktop = false}) => SessionView(
  id: 'relay',
  serverId: 'tower',
  computerName: 'tower',
  computerColor: _tower,
  title: 'Relay reconnect storm',
  harness: 'claude',
  cwd: '~/agents/socketagent',
  running: true,
  requiresAction: true,
  runStartedAt: now.subtract(const Duration(minutes: 6, seconds: 14)),
  permissionMode: 'bypassPermissions',
  model: 'claude-fable-5-1',
  models: const [
    ModelChoice('claude-fable-5-1', label: 'Fable 5.1', isDefault: true),
    ModelChoice('claude-opus-5-5', label: 'Opus 5.5'),
  ],
  effort: 'high',
  efforts: const ['low', 'medium', 'high', 'xhigh', 'max'],
  messages: fakeTranscript(),
  hasMoreHistory: true,
  olderCount: 212,
  tasks: [
    TaskItem(
      id: 't6',
      kind: TaskKind.subagent,
      description: 'Review relay.ts for races in the dedupe path',
      status: 'completed',
      durationMs: 84000,
      tokens: 41200,
      toolUses: 9,
      canDismiss: true,
    ),
    TaskItem(
      id: 'bg1',
      kind: TaskKind.background,
      description: 'npm test -- relay',
      status: 'running',
      startedAt: now.subtract(const Duration(seconds: 38)),
      lastTool: 'Bash',
      backgrounded: true,
      canStop: true,
    ),
    TaskItem(
      id: 'mon1',
      kind: TaskKind.monitor,
      description: 'Watch relay.log for terminate',
      status: 'running',
      startedAt: now.subtract(const Duration(minutes: 3)),
      progress: '0 new matches',
      canStop: true,
    ),
  ],
  plan: const [
    PlanStep('Raise missed-pong tolerance to 3', 'completed'),
    PlanStep('Jittered reconnect backoff in the app', 'completed'),
    PlanStep('Dedupe sockets per device', 'in_progress'),
    PlanStep('Bump relay version', 'pending'),
  ],
  planFromClaude: true,
  context: const ContextGauge(
    used: 118400,
    total: 200000,
    autoCompactAt: 170000,
    slices: [
      ContextSlice('system', 9800),
      ContextSlice('tools', 22100),
      ContextSlice('messages', 86500),
    ],
  ),
  runStats: SessionRunStats(
    completedCount: 12,
    totalDurationMs: 3_412_000,
    averageDurationMs: 284_000,
    longestDurationMs: 1_102_000,
    recentRuns: [
      SessionRunRecord(
        runId: 'run-10',
        runNumber: 10,
        startedAt: now.subtract(const Duration(hours: 3)),
        finishedAt: now.subtract(const Duration(hours: 2, minutes: 51)),
        durationMs: 540000,
        outcome: 'completed',
      ),
      SessionRunRecord(
        runId: 'run-11',
        runNumber: 11,
        startedAt: now.subtract(const Duration(minutes: 100)),
        finishedAt: now.subtract(const Duration(minutes: 95)),
        durationMs: 312000,
        outcome: 'completed',
      ),
      SessionRunRecord(
        runId: 'run-12',
        runNumber: 12,
        startedAt: now.subtract(const Duration(minutes: 48)),
        finishedAt: now.subtract(const Duration(minutes: 44)),
        durationMs: 228000,
        outcome: 'completed',
      ),
    ],
  ),
  suggestions: const ['Yes, dedupe by device id and keep the newest socket.'],
  slashCommands: const [
    SlashCommand('compact', description: 'Compact the context'),
    SlashCommand(
      'review',
      description: 'Review the current diff',
      kind: 'skill',
    ),
  ],
  queued: const [
    QueuedPrompt(
      id: 'u3',
      text: 'Also bump the relay version when you are done.',
      priority: 'later',
    ),
  ],
  pinned: true,
  children: [
    BoardSession(
      id: 'relay-review',
      serverId: 'tower',
      computerName: 'tower',
      computerColor: _tower,
      title: 'Review relay.ts for races',
      activity: SessionActivity.idle,
      lastActive: now.subtract(const Duration(minutes: 3)),
      parentId: 'relay',
      fleeting: true,
    ),
  ],
  turnCount: 14,
  canBackgroundTasks: true,
  plansCount: 1,
  secretInventory: const [],
);
