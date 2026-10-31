import 'package:flutter/material.dart';

import 'package:app/models/computer_access.dart';
import 'package:app/models/device_registry.dart' show PendingDevice;
import 'package:app/models/message.dart';
import 'package:app/ui_b/model/board_model.dart';

final now = DateTime(2026, 10, 31, 14, 32);

const tower = Color(0xFF4EA1FF);
const laptop = Color(0xFFE06C9F);
const mac = Color(0xFF9CDE5B);

List<ComputerChip> fakeComputers() => const [
  ComputerChip(
    id: 'tower',
    name: 'tower',
    link: ComputerLink.connected,
    color: tower,
    runningCount: 3,
    waitingCount: 2,
    version: '1.1.14',
    pushRegistered: true,
  ),
  ComputerChip(
    id: 'laptop',
    name: 'laptop',
    link: ComputerLink.connected,
    color: laptop,
    runningCount: 1,
    version: '1.1.14',
    pushRegistered: true,
    viaRelay: true,
  ),
  ComputerChip(
    id: 'mac',
    name: 'studio',
    link: ComputerLink.offline,
    color: mac,
    expectedOnline: true,
    version: '1.1.9',
    pushRegistered: false,
  ),
  ComputerChip(
    id: 'nas',
    name: 'nas',
    link: ComputerLink.connecting,
    color: Color(0xFFB08CFF),
  ),
];

BoardSession s(
  String id,
  String title, {
  String server = 'tower',
  String computer = 'tower',
  Color color = tower,
  String harness = 'codex',
  String cwd = '/home/billy/agents/socketagent-app',
  SessionActivity activity = SessionActivity.idle,
  int agoMinutes = 30,
  int runMinutes = 0,
  int turns = 40,
  bool pinned = false,
  bool muted = false,
  bool unread = false,
  bool fleeting = false,
  int children = 0,
  String? parent,
  String? outcome,
  bool scheduled = false,
}) => BoardSession(
  id: id,
  serverId: server,
  computerName: computer,
  computerColor: color,
  title: title,
  harness: harness,
  cwd: cwd,
  activity: activity,
  lastActive: now.subtract(Duration(minutes: agoMinutes)),
  runStartedAt: runMinutes > 0
      ? now.subtract(Duration(minutes: runMinutes, seconds: 17))
      : null,
  turnCount: turns,
  pinned: pinned,
  muted: muted,
  unread: unread,
  fleeting: fleeting,
  expiresAt: fleeting ? now.add(const Duration(hours: 4, minutes: 12)) : null,
  childCount: children,
  parentId: parent,
  lastRunOutcome: outcome,
  fromScheduledTask: scheduled,
);

List<BoardSession> fakeSessions() => [
  s(
    'ui-b',
    'UI revamp B',
    activity: SessionActivity.running,
    runMinutes: 24,
    turns: 212,
    pinned: true,
    children: 2,
  ),
  s(
    'relay',
    'Relay reconnect storm',
    activity: SessionActivity.waitingOnUser,
    agoMinutes: 6,
    turns: 88,
    cwd: '/home/billy/agents/socketagent',
  ),
  s(
    'ci',
    'Nightly CI watch',
    activity: SessionActivity.running,
    runMinutes: 2,
    turns: 331,
    harness: 'claude',
    scheduled: true,
    cwd: '/home/billy/agents/socketagent/server',
  ),
  s(
    'fleet',
    'Fleet health check',
    server: 'laptop',
    computer: 'laptop',
    color: laptop,
    activity: SessionActivity.running,
    runMinutes: 71,
    turns: 12,
    harness: 'claude',
  ),
  s(
    'child-a',
    'Review UI A for layout bugs',
    activity: SessionActivity.waitingOnAgent,
    agoMinutes: 1,
    turns: 3,
    harness: 'claude',
    parent: 'ui-b',
    fleeting: true,
  ),
  s(
    'quickbooks',
    'QuickBooks export',
    server: 'laptop',
    computer: 'laptop',
    color: laptop,
    agoMinutes: 18,
    unread: true,
    turns: 57,
    outcome: 'completed',
  ),
  s(
    'apk',
    'Release v1.0.299',
    agoMinutes: 42,
    unread: true,
    turns: 19,
    outcome: 'failed',
  ),
  s(
    'memory',
    'Session memory rollover bug',
    agoMinutes: 140,
    turns: 402,
    muted: true,
  ),
  s(
    'play',
    'Play Console listing copy',
    server: 'mac',
    computer: 'studio',
    color: mac,
    activity: SessionActivity.offline,
    agoMinutes: 900,
    turns: 9,
    harness: 'claude',
  ),
  s('ibs', 'IBS contract summary tool', agoMinutes: 1500, turns: 64),
  s(
    'tts',
    'Kokoro voice download',
    agoMinutes: 2900,
    turns: 23,
    harness: 'claude',
  ),
  s(
    'docs',
    'Capability spec draft',
    agoMinutes: 4000,
    turns: 150,
    cwd: '/home/billy/agents/socketagent/docs',
  ),
  s('outlook', 'Outlook private tools', agoMinutes: 6000, turns: 77),
  s(
    'nas',
    'NAS backup script',
    server: 'nas',
    computer: 'nas',
    color: Color(0xFFB08CFF),
    activity: SessionActivity.offline,
    agoMinutes: 9000,
    turns: 5,
  ),
  s('vault', 'Account vault merge', agoMinutes: 12000, turns: 31),
  s(
    'term',
    'Terminal scrollback',
    agoMinutes: 20000,
    turns: 14,
    harness: 'claude',
  ),
];

ChatMessage fakeQuestion() => ChatMessage.question(
  questionId: 'q1',
  questions: [
    QuestionItem(
      question:
          'Relay reconnects loop every 4s on the laptop. Which fix first?',
      header: 'Approach',
      options: [
        QuestionOption(
          label: 'Backoff',
          description: 'Exponential backoff with jitter, cap 60s',
        ),
        QuestionOption(
          label: 'Dedupe sockets',
          description: 'Close the older socket when identity matches',
        ),
        QuestionOption(
          label: 'Both',
          description: 'Backoff now, dedupe in a follow-up',
        ),
      ],
    ),
  ],
)..timestamp = now.subtract(const Duration(minutes: 6));

ChatMessage fakeSecret() => ChatMessage.secureInput(
  requestId: 's1',
  label: 'Cloudflare API token',
  reason: 'To purge the cache after deploy',
  envHint: 'CF_API_TOKEN',
  scope: 'project',
)..timestamp = now.subtract(const Duration(minutes: 41));

ChatMessage fakeAccess() => ChatMessage.computerAccess(
  const ComputerAccessRequest(
    requestId: 'a1',
    sessionId: 'fleet',
    kind: 'approval',
    sourceName: 'laptop',
    targetName: 'tower',
    targetPublicKey: 'k',
    action: 'run_command',
    summary: 'git -C ~/agents/socketagent pull --ff-only',
    digest: 'd',
    challengeId: 'c',
    expiresAt: 1793543520000,
    reason: 'Pull the latest server before the health check',
  ),
)..timestamp = now.subtract(const Duration(minutes: 2));

List<InboxItem> fakeInbox() => [
  InboxItem(
    id: 'q1',
    kind: InboxKind.question,
    title: 'Relay reconnects loop every 4s on the laptop. Which fix first?',
    detail: 'Backoff · Dedupe sockets · Both',
    since: now.subtract(const Duration(minutes: 6)),
    sessionId: 'relay',
    serverId: 'tower',
    sessionTitle: 'Relay reconnect storm',
    computerName: 'tower',
    computerColor: tower,
    message: fakeQuestion(),
  ),
  InboxItem(
    id: 'a1',
    kind: InboxKind.access,
    title: 'laptop wants to run a command on tower',
    detail: 'git -C ~/agents/socketagent pull --ff-only',
    since: now.subtract(const Duration(minutes: 2)),
    sessionId: 'fleet',
    serverId: 'laptop',
    sessionTitle: 'Fleet health check',
    computerName: 'laptop',
    computerColor: laptop,
    expiresAt: now.add(const Duration(minutes: 8)),
    message: fakeAccess(),
  ),
  InboxItem(
    id: 's1',
    kind: InboxKind.secret,
    title: 'Cloudflare API token',
    detail: 'CF_API_TOKEN · project scope · to purge the cache after deploy',
    since: now.subtract(const Duration(minutes: 41)),
    sessionId: 'deploy',
    serverId: 'tower',
    sessionTitle: 'Deploy relay 2.3',
    computerName: 'tower',
    computerColor: tower,
    expiresAt: now.add(const Duration(minutes: 19)),
    message: fakeSecret(),
  ),
  InboxItem(
    id: 'dev1',
    kind: InboxKind.device,
    title: 'Pixel 9 wants to pair with tower',
    since: now.subtract(const Duration(seconds: 50)),
    serverId: 'tower',
    computerName: 'tower',
    computerColor: tower,
    payload: const PendingDevice(
      serverId: 'tower',
      publicKey: 'pk',
      name: 'Pixel 9',
      platform: 'android',
      code: '418 206',
    ),
  ),
  InboxItem(
    id: 'auto1',
    kind: InboxKind.automation,
    title: 'Nightly CI watch finished: 2 flaky tests quarantined',
    since: now.subtract(const Duration(hours: 7)),
    serverId: 'tower',
    sessionId: 'ci',
    sessionTitle: 'Nightly CI watch',
    computerName: 'tower',
    computerColor: tower,
  ),
];

BoardModel fakeBoard({bool quiet = false}) => BoardModel(
  computers: fakeComputers(),
  inbox: quiet ? const [] : fakeInbox(),
  sessions: quiet
      ? fakeSessions()
            .map(
              (s) => s.activity == SessionActivity.waitingOnUser
                  ? BoardSession(
                      id: s.id,
                      serverId: s.serverId,
                      computerName: s.computerName,
                      computerColor: s.computerColor,
                      title: s.title,
                      harness: s.harness,
                      cwd: s.cwd,
                      activity: SessionActivity.idle,
                      lastActive: s.lastActive,
                      turnCount: s.turnCount,
                    )
                  : s,
            )
            .toList()
      : fakeSessions(),
  automationUnread: quiet ? 0 : 1,
  reviewsPending: 0,
);
